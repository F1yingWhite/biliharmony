const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

function fixture(hooks = {}) {
  const calls = [], output = [], state = { duration: 900, destroyed: false };
  const methods = ['getDanmakuSeg', 'getDanmaku', 'getVideoHeatPoints', 'getVideoChapters', 'getOnlineTotal'];
  const api = Object.fromEntries(methods.map(name => [name, (...args) => {
    calls.push([name, ...args]);
    return hooks[name] ? hooks[name](...args) : Promise.resolve(name === 'getOnlineTotal' ? '10' : []);
  }]));
  const load = createArktsLoader({ mocks: { 'api/BiliApi': { BiliApi: api } } });
  const { PlayerAuxiliaryController } = load('components/player/PlayerAuxiliaryController');
  const ctl = new PlayerAuxiliaryController({
    isDestroyed: () => state.destroyed, duration: () => state.duration,
    danmaku: (items, replace) => output.push(['dm', items, replace]),
    heatPoints: items => output.push(['heat', items]), chapters: items => output.push(['chapters', items]),
    online: value => output.push(['online', value]),
  });
  const bind = id => ctl.bind({ aid: id, bvid: 'BV' + id, cid: id * 10 });
  bind(1);
  return { ctl, calls, output, state, bind };
}

test('auxiliary initial loading deduplicates, preserves empty segments and respects duration', async () => {
  const pending = deferred();
  const f = fixture({ getDanmakuSeg: () => pending.promise });
  f.state.duration = 300;
  const work = f.ctl.loadDanmaku(); await f.ctl.loadDanmaku();
  assert.equal(f.calls.length, 1);
  pending.resolve([]); await work;
  f.ctl.prefetch(350); await tick();
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.output, [['dm', [], true]]);
});

test('auxiliary failed initial request can retry without changing sources', async () => {
  let attempt = 0;
  const f = fixture({ getDanmakuSeg: async () => { if (++attempt === 1) throw Error('offline'); return []; } });
  f.state.duration = 20;
  await f.ctl.loadDanmaku(); await f.ctl.loadDanmaku();
  assert.equal(attempt, 2); assert.equal(f.output.length, 1);
});

test('auxiliary null segment falls back to ordered XML once and disables prefetch', async () => {
  const f = fixture({ getDanmakuSeg: async () => null, getDanmaku: async () => [{ time: 9 }, { time: 1 }] });
  await f.ctl.loadDanmaku(); f.ctl.prefetch(400); await f.ctl.loadDanmaku();
  assert.deepEqual(f.output, [['dm', [{ time: 1 }, { time: 9 }], true]]);
  assert.deepEqual(f.calls.map(c => c[0]), ['getDanmakuSeg', 'getDanmaku']);
});

test('auxiliary A B A replacement keeps old first completion from unlocking the new request', async () => {
  const old = deferred(), current = deferred(); let count = 0;
  const f = fixture({ getDanmakuSeg: () => ++count === 1 ? old.promise : current.promise });
  f.state.duration = 100;
  const first = f.ctl.loadDanmaku(); f.bind(2); f.bind(1);
  const latest = f.ctl.loadDanmaku(); old.resolve([{ time: 1 }]); await first;
  await f.ctl.loadDanmaku(); assert.equal(count, 2); assert.deepEqual(f.output, []);
  current.resolve([{ time: 2 }]); await latest;
  assert.deepEqual(f.output, [['dm', [{ time: 2 }], true]]);
});

test('auxiliary stale XML fallback cannot populate a replacement session', async () => {
  const xml = deferred();
  const f = fixture({ getDanmakuSeg: async () => null, getDanmaku: () => xml.promise });
  const first = f.ctl.loadDanmaku(); await tick(); f.bind(2);
  xml.resolve([{ time: 2 }]); await first; assert.deepEqual(f.output, []);
});

test('auxiliary segment failure retries, concurrent prefetch deduplicates and empty is cached', async () => {
  const segment = deferred(); let attempts = 0;
  const f = fixture({ getDanmakuSeg: (_cid, _aid, index) => index === 1 ? Promise.resolve([]) :
    ++attempts === 1 ? Promise.reject(Error('offline')) : segment.promise });
  await f.ctl.loadDanmaku(); await tick();
  f.ctl.prefetch(350); f.ctl.prefetch(360); assert.equal(attempts, 2);
  segment.resolve([]); await tick(); f.ctl.prefetch(360); assert.equal(attempts, 2);
});

test('auxiliary stale segment finally cannot unlock the replacement segment', async () => {
  const old = deferred(), current = deferred(); let second = 0;
  const f = fixture({ getDanmakuSeg: (_cid, _aid, index) => index === 1 ? Promise.resolve([]) :
    ++second === 1 ? old.promise : current.promise });
  await f.ctl.loadDanmaku(); f.bind(2); await f.ctl.loadDanmaku();
  old.resolve([{ time: 500 }]); await tick(); f.ctl.prefetch(350);
  assert.equal(second, 2); assert.equal(f.output.length, 2);
  current.resolve([{ time: 600 }]); await tick();
  assert.deepEqual(f.output.at(-1), ['dm', [{ time: 600 }], false]);
});

for (const [api, method, label] of [
  ['getVideoHeatPoints', 'loadHeatPoints', 'heat'],
  ['getVideoChapters', 'loadChapters', 'chapters'],
  ['getOnlineTotal', 'loadOnline', 'online'],
]) {
  test(`auxiliary ${label} publishes only the latest request and rejects leave/reenter ABA`, async () => {
    const old = deferred(), latest = deferred(), returning = deferred(); let n = 0;
    const f = fixture({ [api]: () => [old, latest, returning][n++].promise });
    const a = f.ctl[method](), b = f.ctl[method]();
    latest.resolve('latest'); await b; old.resolve('old'); await a;
    assert.deepEqual(f.output, [[label, 'latest']]);
    const c = f.ctl[method](); f.ctl.invalidate(); f.bind(1);
    returning.resolve('detached'); await c; assert.equal(f.output.length, 1);
  });
}

test('auxiliary destruction suppresses all requests already in flight', async () => {
  const pending = deferred(); const f = fixture({ getDanmakuSeg: () => pending.promise, getOnlineTotal: () => pending.promise });
  const a = f.ctl.loadDanmaku(), b = f.ctl.loadOnline(); f.state.destroyed = true;
  pending.resolve([]); await Promise.all([a, b]); assert.deepEqual(f.output, []);
});
