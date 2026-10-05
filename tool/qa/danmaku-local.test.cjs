const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createArktsLoader } = require('./arkts-module.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function fixture() {
  const api = {}, pixels = [], frames = [];
  const load = createArktsLoader({ mocks: {
    'api/BiliApi': api, 'services/auth/UserStore': { UserStore: { isLogin: true } },
    '@kit.BasicServicesKit': { pasteboard: {} },
    '@kit.ArkGraphics2D': { displaySync: { create: () => ({
      setExpectedFrameRateRange() {}, on: (_name, callback) => frames.push(callback), start() {}, stop() {}, off() {},
    }) } },
  } });
  const { DanmakuItem } = load('model/video/VideoAuxiliaryModels'); api.DanmakuItem = DanmakuItem;
  const { PlayerDanmakuEngine } = load('components/player/PlayerDanmakuEngine');
  const { PlayerDanmakuClock } = load('components/player/PlayerDanmakuClock');
  const { PlayerDanmakuInteractionController } = load('components/player/PlayerDanmakuInteractionController');
  const ctx = { measureText: text => ({ width: text.length * 8 }), clearRect: () => { pixels.length = 0; },
    strokeText() {}, fillText(text, x, y) { if (x < 390 && x + text.length * 8 > 0 && y > 0 && y <= 220) pixels.push(text); } };
  const engine = new PlayerDanmakuEngine(ctx); engine.setViewport(390, 220);
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'components/player/PlayerView.ets'), 'utf8').replace(/\r\n/g, '\n');
  const slice = (from, to) => {
    const begin = source.indexOf(from), end = source.indexOf(to, begin);
    assert.ok(begin >= 0 && end > begin, 'production View adapter anchors must exist'); return source.slice(begin, end);
  };
  const compiled = ts.transpileModule('export class View {\n' +
    slice('  onLocalDanmakuRequested(): void {', '  onCompactModeChanged(): void {') +
    slice('  spawnDanmaku(now: number): void {', '  toggleDanmaku(): void {') + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const mod = { exports: {} }; new Function('exports', 'DanmakuItem', compiled)(mod.exports, DanmakuItem);
  const view = new mod.exports.View();
  const clock = new PlayerDanmakuClock({ isPlaying: () => view.playing, isDanmakuOn: () => view.externalDanmakuOn,
    getFrameRate: () => 60, getEngine: () => engine, clearPinned() {} });
  Object.assign(view, { dmEngine: engine, dmInteraction: new PlayerDanmakuInteractionController(engine), dmClock: clock,
    destroyed: false, appInBackground: false, playing: true, externalDanmakuOn: true, danmakuOn: true,
    playheadSec: 10, localDanmakuText: 'mine', localDanmakuSeconds: 10, localDanmakuId: '10000000000000001', localDanmakuToken: 1 });
  const remote = (time, text, idStr = '') => new DanmakuItem(time, 1, 16777215, text, 0, 25, 9, idStr);
  const visibleOwn = () => pixels.some(text => text === 'mine');
  return { engine, view, clock, pixels, frames, remote, visibleOwn, DanmakuItem };
}

test('confirmed local comments are visible immediately even after the remote cursor pre-consumed its 100ms window', () => {
  const f = fixture(); f.engine.setList([f.remote(10.08, 'pre-consumed'), f.remote(20, 'future')]);
  f.engine.lastPlayerTime = 10; f.engine.spawn(10); f.view.onLocalDanmakuRequested();
  assert.equal(f.visibleOwn(), true); assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'pre-consumed').length, 1, 'local echo must not replay old remote comments');
});

test('a paused confirmed send draws inside the viewport without waiting for a playback or display-sync frame', () => {
  const f = fixture(); f.view.playing = false; f.view.onLocalDanmakuRequested();
  assert.equal(f.visibleOwn(), true); assert.equal(f.clock.isRunning(), false, 'a paused echo must not start an idle frame source');
  const position = f.engine.active[0].x; f.clock.redraw(); assert.equal(f.engine.active[0].x, position);
});

test('local echo retains the submitted timestamp and precise ID while displaying at the current response time', () => {
  const f = fixture(); f.view.localDanmakuSeconds = 7; f.view.playheadSec = 10; f.view.onLocalDanmakuRequested();
  assert.equal(f.visibleOwn(), true); assert.equal(f.engine.list[0].time, 7);
  assert.equal(f.engine.list[0].idStr, '10000000000000001'); assert.equal(f.engine.active[0].born, 10);
});

test('the same watch token or confirmed server ID cannot create another local echo', () => {
  const f = fixture(); f.view.onLocalDanmakuRequested(); f.view.onLocalDanmakuRequested();
  f.view.localDanmakuToken = 2; f.view.onLocalDanmakuRequested();
  assert.equal(f.engine.list.filter(item => item.text === 'mine').length, 1);
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
});

test('later playback and duplicate-setting changes do not replay the already-visible local echo', () => {
  const f = fixture(); f.view.onLocalDanmakuRequested();
  f.engine.lastPlayerTime = 10.2; f.engine.spawn(10.2); f.engine.setMergeDuplicates(true); f.engine.spawn(10.2);
  f.engine.setMergeDuplicates(false); f.engine.spawn(10.2);
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
});

test('late first-segment or XML replacement retains the local echo; matching remote IDs do not duplicate it', () => {
  const f = fixture(); f.view.onLocalDanmakuRequested(); const own = f.engine.list[0];
  f.engine.setList([]); assert.equal(f.engine.list.includes(own), true, 'an empty server segment must not erase a confirmed send');
  f.engine.setList([f.remote(10, 'mine', own.idStr), f.remote(20, 'later')]);
  f.engine.appendSorted([f.remote(10, 'mine', own.idStr), f.remote(360, 'next segment')]);
  assert.equal(f.engine.list.filter(item => item.idStr === own.idStr).length, 1);
  f.engine.lastPlayerTime = 10.2; f.engine.spawn(10.2);
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
});

for (const alreadyActive of [false, true]) {
  test(`a remote copy arriving before confirmation is unified with the ${alreadyActive ? 'already rendered' : 'pending'} local send`, () => {
    const f = fixture(); const id = f.view.localDanmakuId;
    f.engine.setList([f.remote(10, 'mine', id), f.remote(20, 'future')]); f.engine.lastPlayerTime = 10;
    if (alreadyActive) f.engine.spawn(10);
    f.view.onLocalDanmakuRequested();
    assert.equal(f.engine.list.filter(item => item.idStr === id).length, 1);
    assert.equal(f.engine.active.filter(dm => dm.item.idStr === id).length, 1); assert.equal(f.visibleOwn(), true);
    f.engine.lastPlayerTime = 10.2; f.engine.spawn(10.2);
    assert.equal(f.engine.active.filter(dm => dm.item.idStr === id).length, 1, 'confirmation cannot replay the server copy');
    f.engine.spawn(20); assert.equal(f.engine.active.filter(dm => dm.item.text === 'future').length, 1, 'removing the server copy preserves the remaining cursor');
  });
}

test('confirming an already-pinned remote copy preserves the pinned active identity', () => {
  const f = fixture(); f.engine.setList([f.remote(10, 'mine', f.view.localDanmakuId)]);
  f.engine.lastPlayerTime = 10; f.engine.spawn(10); const pinned = f.engine.active[0]; f.engine.pin(pinned);
  f.view.onLocalDanmakuRequested();
  assert.equal(f.engine.pinned, pinned); assert.equal(f.engine.active.length, 1);
  assert.equal(f.engine.active.includes(pinned), true, 'the pinned object must remain an active drawn comment');
  assert.equal(pinned.item, f.engine.list[0]);
});

test('seeking back replays a confirmed local comment once at its original submitted time', () => {
  const f = fixture(); f.view.localDanmakuSeconds = 7; f.view.onLocalDanmakuRequested();
  f.engine.resetAt(7); f.engine.spawn(7); f.engine.drawFrame(true, 1000); f.engine.drawFrame(true, 2000);
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
  f.engine.spawn(7.1); assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
  f.engine.lastPlayerTime = 7.1; f.engine.setList([]); f.engine.spawn(7.1);
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1, 'a late server replacement must not replay the seeked local item');
});

test('source reset clears confirmed local caches and permits a new source to reuse the event token', () => {
  const f = fixture(); f.view.onLocalDanmakuRequested(); f.engine.resetList();
  f.engine.setList([f.remote(20, 'new source')]); assert.deepEqual(f.engine.active, []);
  assert.equal(f.engine.list.some(item => item.text === 'mine'), false);
  f.view.localDanmakuId = '20000000000000001'; f.view.onLocalDanmakuRequested();
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
});

test('local echoes respect scrolling filters and disabled/background/destroyed surfaces', () => {
  for (const mode of ['filter', 'disabled', 'background', 'destroyed']) {
    const f = fixture();
    if (mode === 'filter') f.engine.blockScrollDm = true;
    if (mode === 'disabled') { f.engine.enabled = false; f.view.externalDanmakuOn = false; }
    if (mode === 'background') f.view.appInBackground = true;
    if (mode === 'destroyed') f.view.destroyed = true;
    f.view.onLocalDanmakuRequested(); assert.equal(f.visibleOwn(), false, mode); assert.equal(f.engine.active.length, 0, mode);
    if (mode === 'background') {
      assert.equal(f.engine.list.length, 1, 'background confirmation remains available for subsequent seek');
      f.view.appInBackground = false; f.engine.resetAt(10); f.engine.spawn(10);
      assert.equal(f.engine.active.length, 1);
    }
  }
});

test('crowded ordinary density cannot silently drop the sender local confirmation', () => {
  const f = fixture(); f.engine.setList(Array.from({ length: 100 }, (_, id) => f.remote(10, 'remote-' + id)));
  f.engine.lastPlayerTime = 10; f.engine.spawn(10); assert.ok(f.engine.active.length > 0);
  f.view.onLocalDanmakuRequested(); assert.equal(f.visibleOwn(), true);
  assert.equal(f.engine.active.filter(dm => dm.item.text === 'mine').length, 1);
});
