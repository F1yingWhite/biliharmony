const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

// Entire production controller and models run; API IO and login-state boundaries are controlled.
function fixture(hooks = {}) {
  const state = { time: 12, destroyed: false, login: true, cards: [], clock: 0 };
  const calls = [], snapshots = [], toasts = [], opened = [];
  const api = Object.fromEntries(['load', 'submitGrade', 'submitVote'].map(name => [name, (...args) => {
    calls.push([name, ...args]);
    return hooks[name] ? hooks[name](...args) : Promise.resolve(name === 'load' ? state.cards : { ok: true, message: '' });
  }]));
  const load = createArktsLoader({ mocks: {
    'api/VideoInteractionApi': { VideoInteractionApi: api },
    'services/auth/UserStore': { UserStore: { get isLogin() { return state.login; } } },
  }, globals: { Date: { now: () => state.clock } } });
  const { AuthSession } = load('services/auth/AuthSession');
  const { VideoInteractionCard, VideoInteractionOption, VideoInteractionLink } = load('model/video/VideoInteractionModels');
  const { PlayerInteractionController } = load('components/player/PlayerInteractionController');
  const ctl = new PlayerInteractionController({
    isDestroyed: () => state.destroyed, getPlayhead: () => state.time,
    applyState: value => snapshots.push(value), toast: text => toasts.push(text), openVideo: target => opened.push(target),
  });
  const bind = (id = 1, duration = 100) => ctl.bind({ aid: id, bvid: 'BV' + id, cid: id * 10, duration });
  const grade = (patch = {}) => Object.assign(new VideoInteractionCard(), {
    id: 'g', kind: 'grade', start: 10, end: 20, title: '评分', gradeId: '100', maxStars: 5,
    averageScore: 6, count: 3, ...patch,
  });
  const option = (id, patch = {}) => Object.assign(new VideoInteractionOption(), { id, text: '选项' + id, votes: id + 3, ...patch });
  const vote = (patch = {}) => Object.assign(new VideoInteractionCard(), {
    id: 'v', kind: 'vote', start: 10, end: 20, title: '投票', voteId: '200', options: [option(1), option(2)], ...patch,
  });
  const link = (patch = {}) => Object.assign(new VideoInteractionCard(), {
    id: 'l', kind: 'link', start: 10, end: 20, title: '关联视频',
    link: Object.assign(new VideoInteractionLink(), { aid: 2, bvid: 'BV2', title: '目标视频' }), ...patch,
  });
  const at = seconds => { state.time = seconds; ctl.update(seconds); };
  bind();
  return { ctl, state, calls, snapshots, toasts, opened, grade, vote, link, option, bind, at, AuthSession,
    ui: () => snapshots.at(-1), count: name => calls.filter(call => call[0] === name).length };
}

test('interaction windows include start, exclude end and follow seeks and replay', async () => {
  const f = fixture(); f.state.cards = [f.grade(), f.vote({ start: 25, end: 30 })];
  f.at(0); await f.ctl.load(); assert.equal(f.ui().current, null);
  f.at(10); assert.equal(f.ui().current.id, 'g');
  f.at(19.999); assert.equal(f.ui().current.id, 'g');
  f.at(20); assert.equal(f.ui().current, null);
  f.at(28); assert.equal(f.ui().current.id, 'v');
  f.at(12); assert.equal(f.ui().current.id, 'g');
  f.state.time = 0; f.ctl.resetForReplay(); assert.equal(f.ui().current, null);
  f.at(12); assert.equal(f.ui().current.id, 'g');
});

test('interaction cards ignore unknown commands, malformed windows, duplicates and cards beyond duration', async () => {
  const f = fixture(); f.state.cards = [f.grade({ id: 'unknown', kind: 'unknown' }), f.grade({ id: 'bad', start: NaN }),
    f.grade({ id: 'reverse', start: 20, end: 10 }), f.grade({ id: 'late', start: 100, end: 120 }),
    f.grade(), f.grade({ title: 'duplicate ID' })];
  await f.ctl.load(); assert.equal(f.ui().current.id, 'g'); assert.equal(f.ui().current.title, '评分');
  f.ctl.dismiss('g'); assert.equal(f.ui().current, null);
  f.at(101); assert.equal(f.ui().current, null);
});

test('dismiss advances overlapping cards and seeking outside the window permits them again', async () => {
  const f = fixture(); f.state.cards = [f.vote({ start: 11 }), f.grade()]; await f.ctl.load();
  assert.equal(f.ui().current.id, 'g'); f.ctl.dismiss('g'); assert.equal(f.ui().current.id, 'v');
  f.ctl.dismiss('v'); assert.equal(f.ui().current, null);
  f.at(5); f.at(12); assert.equal(f.ui().current.id, 'g');
  f.ctl.dismiss('g'); f.state.time = 12; f.ctl.resetForReplay(); assert.equal(f.ui().current.id, 'g');
});

test('disabled interactions disappear immediately, cannot submit or navigate, and resume at current playhead', async () => {
  const f = fixture(); f.state.cards = [f.grade(), f.vote(), f.link()]; await f.ctl.load();
  f.ctl.setEnabled(false); assert.equal(f.ui().current, null);
  assert.equal(await f.ctl.submitGrade('g', 5), false); assert.equal(await f.ctl.submitVote('v', 1), false);
  f.ctl.openLink('l'); await f.ctl.load();
  assert.equal(f.count('submitGrade'), 0); assert.equal(f.count('submitVote'), 0); assert.deepEqual(f.opened, []);
  f.state.time = 21; f.ctl.setEnabled(true); assert.equal(f.ui().current, null);
  f.ctl.setEnabled(false); f.state.time = 12; f.ctl.setEnabled(true); assert.equal(f.ui().current.id, 'g');
  assert.equal(f.count('load'), 1, 'restoring a completed read should reuse its data');
});

test('disabled-before-bind avoids all reads until enabled and load completion uses paused playhead', async () => {
  const pending = deferred(); const f = fixture({ load: () => pending.promise });
  f.ctl.invalidate(); f.ctl.setEnabled(false); f.bind(); await f.ctl.load(); assert.equal(f.count('load'), 0);
  f.ctl.setEnabled(true); assert.equal(f.count('load'), 1);
  f.state.time = 25; pending.resolve([f.grade(), f.vote({ start: 25, end: 30 })]); await tick();
  assert.equal(f.ui().current.id, 'v'); assert.equal(f.ui().loading, false);
});

test('read requests deduplicate; failures clear loading and explicit retry really reads again', async () => {
  const pending = deferred(); let attempts = 0;
  const f = fixture({ load: () => ++attempts === 1 ? pending.promise : Promise.resolve([f.grade()]) });
  const work = f.ctl.load(); await f.ctl.load(); assert.equal(attempts, 1); assert.equal(f.ui().loading, true);
  pending.reject(Error('offline')); await work; assert.equal(f.ui().loading, false); assert.match(f.ui().message, /失败/);
  f.state.clock = 5000; await f.ctl.load(); assert.equal(attempts, 2); assert.equal(f.ui().current.id, 'g'); assert.equal(f.ui().message, '');
});

test('progress never reads before the deferred initial load and retries failed reads at five-second intervals', async () => {
  let attempts = 0; const f = fixture({ load: async () => {
    if (++attempts < 3) throw Error('offline');
    return [f.grade()];
  } });
  f.at(12.2); assert.equal(attempts, 0, 'ordinary progress must preserve deferred initial loading');
  await f.ctl.load();
  for (let clock = 0; clock < 5000; clock += 200) { f.state.clock = clock; f.at(12.2); }
  await tick(); assert.equal(attempts, 1);
  f.state.clock = 5000; f.at(12.2); await tick(); assert.equal(attempts, 2);
  f.state.clock = 5200; f.at(12.2); await tick(); assert.equal(attempts, 2);
  f.state.clock = 10000; f.at(12.2); await tick(); assert.equal(attempts, 3); assert.equal(f.ui().current.id, 'g');
});

test('turning interactions off and on manually retries a failed read without waiting for the retry interval', async () => {
  let attempts = 0; const f = fixture({ load: async () => {
    if (++attempts === 1) throw Error('offline');
    return [f.grade()];
  } });
  await f.ctl.load(); f.ctl.setEnabled(false); f.ctl.setEnabled(true); await tick();
  assert.equal(attempts, 2); assert.equal(f.ui().current.id, 'g');
});

test('source A B A rejects old read and its finally cannot unlock the returning read', async () => {
  const old = deferred(), latest = deferred(); let reads = 0;
  const f = fixture({ load: () => ++reads === 1 ? old.promise : latest.promise });
  const first = f.ctl.load(); f.bind(2); f.bind(1); const returning = f.ctl.load();
  old.resolve([f.grade({ title: 'old' })]); await first; await f.ctl.load();
  assert.equal(reads, 2); assert.equal(f.ui().current, null); assert.equal(f.ui().loading, true);
  latest.resolve([f.grade({ title: 'current' })]); await returning; assert.equal(f.ui().current.title, 'current');
});

test('account A B A rejects old choices and source-independent old read locks', async () => {
  const old = deferred(), latest = deferred(); let reads = 0;
  const f = fixture({ load: () => ++reads === 1 ? old.promise : latest.promise });
  const first = f.ctl.load(); f.AuthSession.advance(); f.AuthSession.advance(); f.ctl.onAccountChanged();
  old.resolve([f.grade({ selectedStars: 5 })]); await first; await f.ctl.load();
  assert.equal(reads, 2); assert.equal(f.ui().current, null); assert.equal(f.ui().loading, true);
  latest.resolve([f.grade()]); await tick(); assert.equal(f.ui().current.selectedStars, 0);
});

test('a read completion after auth epoch changes is rejected even before the login watcher runs', async () => {
  const pending = deferred(); const f = fixture({ load: () => pending.promise }); const work = f.ctl.load();
  f.AuthSession.advance(); const writes = f.snapshots.length;
  pending.resolve([f.grade({ selectedStars: 5 })]); await work;
  assert.equal(f.snapshots.length, writes); assert.equal(f.ui().current, null);
});

test('a submit completion after auth epoch changes is rejected even before progress or the login watcher runs', async () => {
  const pending = deferred(); const f = fixture({ submitGrade: () => pending.promise });
  f.state.cards = [f.grade()]; await f.ctl.load(); const work = f.ctl.submitGrade('g', 5);
  f.AuthSession.advance(); const writes = f.snapshots.length;
  pending.resolve({ ok: true, message: '' }); assert.equal(await work, false);
  assert.equal(f.snapshots.length, writes); assert.equal(f.ui().current.selectedStars, 0);
});

test('the completed-login watcher re-reads even after progress observed the same new auth epoch', async () => {
  const f = fixture(); f.state.cards = [f.grade({ selectedStars: 4 })]; await f.ctl.load();
  f.AuthSession.advance(); f.at(12); await tick(); assert.equal(f.ui().current.selectedStars, 4);
  f.state.cards = [f.grade({ selectedStars: 0 })]; f.ctl.onAccountChanged();
  assert.equal(f.ui().current, null); await tick(); assert.equal(f.ui().current.selectedStars, 0);
  assert.equal(f.count('load'), 3);
});

test('login changes detected by an action clear old choices before accepting a click', async () => {
  const f = fixture(); f.state.cards = [f.grade()]; await f.ctl.load();
  f.AuthSession.advance(); assert.equal(await f.ctl.submitGrade('g', 5), false); assert.equal(f.count('submitGrade'), 0);
  await tick(); assert.equal(f.ui().current.selectedStars, 0);
});

test('grade rejects guests, stale cards and invalid scores before sending a request', async () => {
  const f = fixture(); f.state.cards = [f.grade()]; await f.ctl.load();
  for (const value of [0, 6, 2.5, NaN, Infinity]) assert.equal(await f.ctl.submitGrade('g', value), false);
  assert.equal(await f.ctl.submitGrade('wrong', 5), false);
  f.state.login = false; assert.equal(await f.ctl.submitGrade('g', 5), false); assert.equal(f.toasts.length, 1);
  f.state.login = true; f.state.time = 20; assert.equal(await f.ctl.submitGrade('g', 5), false);
  assert.equal(f.count('submitGrade'), 0);
});

test('grade submissions deduplicate and only confirmed success updates selection and aggregate score', async () => {
  const pending = deferred(); const f = fixture({ submitGrade: () => pending.promise });
  const input = f.grade(); f.state.cards = [input]; await f.ctl.load(); const before = f.ui().current;
  const work = f.ctl.submitGrade('g', 5); assert.equal(f.ui().submitting, true);
  assert.equal(await f.ctl.submitGrade('g', 4), false); assert.equal(f.count('submitGrade'), 1);
  assert.equal(f.ui().current.selectedStars, 0);
  pending.resolve({ ok: true, message: '' }); assert.equal(await work, true);
  assert.equal(f.ui().submitting, false); assert.equal(f.ui().current.selectedStars, 5);
  assert.equal(f.ui().current.count, 4); assert.equal(f.ui().current.averageScore, 7);
  assert.notEqual(f.ui().current, before); assert.equal(input.selectedStars, 0, 'input and earlier snapshots must remain unselected');
  assert.equal(await f.ctl.submitGrade('g', 3), false); assert.equal(f.count('submitGrade'), 1);
});

for (const reject of [false, true]) {
  test(`grade ${reject ? 'transport' : 'server'} failure stays unselected and can retry`, async () => {
    let attempts = 0; const f = fixture({ submitGrade: async () => {
      if (++attempts === 1) { if (reject) throw Error('offline'); return { ok: false, message: '暂时失败' }; }
      return { ok: true, message: '' };
    } });
    f.state.cards = [f.grade()]; await f.ctl.load(); assert.equal(await f.ctl.submitGrade('g', 3), false);
    assert.equal(f.ui().submitting, false); assert.equal(f.ui().current.selectedStars, 0); assert.match(f.ui().message, /失败/);
    assert.equal(await f.ctl.submitGrade('g', 3), true); assert.equal(f.ui().current.selectedStars, 3);
  });
}

test('loaded grade and vote selections are displayed and cannot be submitted again', async () => {
  const f = fixture(); f.state.cards = [f.grade({ selectedStars: 4 }), f.vote({ selectedOptionId: 2 })]; await f.ctl.load();
  assert.equal(f.ui().current.selectedStars, 4); assert.equal(await f.ctl.submitGrade('g', 5), false);
  f.ctl.dismiss('g'); assert.equal(f.ui().current.selectedOptionId, 2); assert.equal(await f.ctl.submitVote('v', 1), false);
  assert.equal(f.count('submitGrade') + f.count('submitVote'), 0);
});

test('vote validates option IDs, blocks custom text options and confirms only the chosen result count', async () => {
  const pending = deferred(); const f = fixture({ submitVote: () => pending.promise });
  const original = f.vote({ options: [f.option(1), f.option(2), f.option(3, { hasSelfDef: true })] });
  f.state.cards = [original]; await f.ctl.load();
  for (const id of [0, -1, 1.2, 3, 99, NaN]) assert.equal(await f.ctl.submitVote('v', id), false);
  const work = f.ctl.submitVote('v', 2); assert.equal(await f.ctl.submitVote('v', 1), false);
  pending.resolve({ ok: true, message: '' }); assert.equal(await work, true);
  assert.equal(f.ui().current.selectedOptionId, 2); assert.deepEqual(f.ui().current.options.map(option => option.votes), [4, 6, 6]);
  assert.deepEqual(original.options.map(option => option.votes), [4, 5, 6], 'results must update an independent command copy');
  assert.equal(await f.ctl.submitVote('v', 1), false); assert.equal(f.count('submitVote'), 1);
});

test('vote failure remains retryable and reports the server reason', async () => {
  let attempts = 0; const f = fixture({ submitVote: async () => ++attempts === 1 ? { ok: false, message: '已过期，请重试' } : { ok: true, message: '' } });
  f.state.cards = [f.vote()]; await f.ctl.load(); assert.equal(await f.ctl.submitVote('v', 2), false);
  assert.equal(f.ui().current.selectedOptionId, 0); assert.equal(f.ui().message, '已过期，请重试');
  assert.equal(await f.ctl.submitVote('v', 2), true);
});

test('a submission completing outside its window keeps the confirmed choice for a later seek', async () => {
  const pending = deferred(); const f = fixture({ submitVote: () => pending.promise }); f.state.cards = [f.vote()]; await f.ctl.load();
  const work = f.ctl.submitVote('v', 1); f.at(25); pending.resolve({ ok: true, message: '' }); await work;
  assert.equal(f.ui().current, null); f.at(12); assert.equal(f.ui().current.selectedOptionId, 1);
});

for (const kind of ['grade', 'vote']) {
  for (const change of ['source', 'account', 'disable', 'invalidate', 'destroy']) {
    test(`${kind} late submission after ${change} cannot publish a choice, toast or unlock replacement state`, async () => {
      const pending = deferred(); const hook = kind === 'grade' ? 'submitGrade' : 'submitVote';
      const f = fixture({ [hook]: () => pending.promise }); f.state.cards = [kind === 'grade' ? f.grade() : f.vote()]; await f.ctl.load();
      const work = kind === 'grade' ? f.ctl.submitGrade('g', 5) : f.ctl.submitVote('v', 2);
      if (change === 'source') { f.bind(2); await f.ctl.load(); }
      if (change === 'account') { f.AuthSession.advance(); f.ctl.onAccountChanged(); await tick(); }
      if (change === 'disable') f.ctl.setEnabled(false);
      if (change === 'invalidate') f.ctl.invalidate();
      if (change === 'destroy') f.state.destroyed = true;
      const writes = f.snapshots.length;
      pending.resolve({ ok: true, message: 'old success' }); assert.equal(await work, false);
      assert.equal(f.snapshots.length, writes); assert.deepEqual(f.toasts, []);
      if (change === 'source' || change === 'account') assert.equal(kind === 'grade' ? f.ui().current.selectedStars : f.ui().current.selectedOptionId, 0);
    });
  }
}

test('disable during read or submission re-reads on enable and stale finally never unlocks the newer request', async () => {
  const old = deferred(), latest = deferred(); let reads = 0;
  const f = fixture({ load: () => ++reads === 1 ? old.promise : latest.promise });
  const first = f.ctl.load(); f.ctl.setEnabled(false); f.ctl.setEnabled(true);
  old.resolve([f.grade({ selectedStars: 5 })]); await first; await f.ctl.load();
  assert.equal(reads, 2); assert.equal(f.ui().loading, true); assert.equal(f.ui().current, null);
  latest.resolve([f.grade()]); await tick(); assert.equal(f.ui().current.selectedStars, 0);
});

test('re-enabling after an in-flight submission re-reads the server choice before allowing another vote', async () => {
  const pending = deferred(); const f = fixture({ submitVote: () => pending.promise });
  f.state.cards = [f.vote()]; await f.ctl.load(); const work = f.ctl.submitVote('v', 2);
  f.ctl.setEnabled(false); f.state.cards = [f.vote({ selectedOptionId: 2 })]; f.ctl.setEnabled(true);
  assert.equal(f.ui().loading, true); assert.equal(await f.ctl.submitVote('v', 1), false);
  await tick(); assert.equal(f.ui().current.selectedOptionId, 2);
  pending.resolve({ ok: true, message: '' }); assert.equal(await work, false);
  assert.equal(f.ui().current.selectedOptionId, 2); assert.equal(await f.ctl.submitVote('v', 1), false);
  assert.equal(f.count('submitVote'), 1);
});

test('source changes suppress an old submit finally while the new source is submitting the same ID', async () => {
  const old = deferred(), latest = deferred(); let submissions = 0;
  const f = fixture({ submitGrade: () => ++submissions === 1 ? old.promise : latest.promise });
  f.state.cards = [f.grade()]; await f.ctl.load(); const first = f.ctl.submitGrade('g', 2);
  f.bind(2); await f.ctl.load(); const second = f.ctl.submitGrade('g', 5);
  old.resolve({ ok: false, message: 'old failure' }); await first;
  assert.equal(f.ui().submitting, true); assert.equal(f.ui().message, ''); assert.equal(await f.ctl.submitGrade('g', 4), false);
  latest.resolve({ ok: true, message: '' }); await second; assert.equal(f.ui().current.selectedStars, 5);
});

test('link navigation passes the supported video or episode target and never sends a mutation', async () => {
  const f = fixture(); f.state.cards = [f.link()]; await f.ctl.load(); f.ctl.openLink('wrong'); f.ctl.openLink('l');
  assert.deepEqual(f.opened.map(target => [target.aid, target.bvid, target.epId]), [[2, 'BV2', 0]]);
  f.bind(2); const episode = f.link(); episode.link.aid = 0; episode.link.bvid = ''; episode.link.epId = 123;
  f.state.cards = [episode]; await f.ctl.load(); f.ctl.openLink('l'); assert.equal(f.opened[1].epId, 123);
  f.state.time = 20; f.ctl.openLink('l'); assert.equal(f.opened.length, 2);
  assert.equal(f.count('submitGrade') + f.count('submitVote'), 0);
});

test('destruction suppresses an in-flight read and prevents later read, action and navigation calls', async () => {
  const pending = deferred(); const f = fixture({ load: () => pending.promise });
  const work = f.ctl.load(); f.state.destroyed = true; const writes = f.snapshots.length;
  pending.resolve([f.grade(), f.link()]); await work; await f.ctl.load(); f.ctl.openLink('l');
  assert.equal(await f.ctl.submitGrade('g', 5), false); assert.equal(f.snapshots.length, writes);
  assert.equal(f.count('load'), 1); assert.deepEqual(f.opened, []);
});

test('unchanged progress does not publish another view snapshot on every playback tick', async () => {
  const f = fixture(); f.state.cards = [f.grade()]; await f.ctl.load(); const writes = f.snapshots.length;
  for (const seconds of [12.1, 12.2, 12.5, 13]) f.at(seconds);
  assert.equal(f.snapshots.length, writes);
});
