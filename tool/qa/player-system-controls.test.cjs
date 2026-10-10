const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');
const { fixture: playbackFixture } = require('./player-session-fixture.cjs');

// Load the complete production helpers. Only OS session/background boundaries are mocked.
function fixture({ stage, pending, backgroundPending, failOn = new Set(), failOff = new Set() } = {}) {
  const handlers = new Map();
  const calls = { on: [], off: [], metadata: [], state: [], activate: 0,
    deactivate: 0, destroy: 0, backgroundStart: [], backgroundStop: [] };
  const session = {
    on(name, callback) {
      calls.on.push(name); if (failOn.has(name)) throw Error('on failed: ' + name);
      handlers.set(name, callback);
    },
    off(name) {
      calls.off.push(name); if (failOff.has(name)) throw Error('off failed: ' + name);
      handlers.delete(name);
    },
    async activate() { calls.activate++; if (stage === 'activate') await pending.promise; },
    async setBackgroundPlayMode() { if (stage === 'backgroundMode') await pending.promise; },
    async setAVMetadata(value) { calls.metadata.push(value); },
    async setAVPlaybackState(value) { calls.state.push(value); },
    async deactivate() { calls.deactivate++; },
    async destroy() { calls.destroy++; }
  };
  const context = {};
  const load = createArktsLoader({ mocks: {
    '@kit.AbilityKit': { wantAgent: {
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async () => ({ kind: 'clickAgent' })
    } },
    '@kit.AVSessionKit': { avSession: {
      createAVSession: async () => stage === 'create' ? pending.promise : session,
      BackgroundPlayMode: { ENABLE_BACKGROUND_PLAY: 1 },
      PlaybackState: { PLAYBACK_STATE_PLAY: 1 }
    } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: {
      ContinuousTaskRequest: class { isModeSupported() { return true; } },
      BackgroundTaskMode: { MODE_AV_PLAYBACK_AND_RECORD: 2 },
      BackgroundTaskSubmode: { SUBMODE_AVSESSION_AUDIO_PLAYBACK: 3 },
      async startBackgroundRunning(ctx, request) {
        calls.backgroundStart.push({ ctx, request });
        return backgroundPending ? backgroundPending.promise : { continuousTaskId: 42 };
      },
      async stopBackgroundRunning(ctx, id) { calls.backgroundStop.push({ ctx, id }); }
    } },
    '@kit.PerformanceAnalysisKit': { hilog: {} },
    BuildProfile: { DEBUG: false }
  } });
  const { PlayerAvSessionHelper } = load('components/player/PlayerAvSessionHelper');
  const helper = new PlayerAvSessionHelper(context);
  const callbacks = { play: 0, pause: 0, seek: [] };
  const ensure = (commands = {}, metadata = { assetId: 'BV1:11' }, state = { state: 0 }) =>
    helper.ensure(() => callbacks.play++, () => callbacks.pause++, time => callbacks.seek.push(time),
      metadata, state, commands);
  return { helper, session, handlers, calls, callbacks, ensure, context };
}

test('single video registers core controls without fake next/previous or optional controls', async () => {
  const f = fixture(); await f.ensure();
  assert.deepEqual(f.calls.on, ['play', 'pause', 'seek']);
  f.handlers.get('play')(); f.handlers.get('pause')(); f.handlers.get('seek')(12345);
  assert.deepEqual(f.callbacks, { play: 1, pause: 1, seek: [12345] });
});

test('available commands register once, read current callbacks, and revoke independently', async () => {
  const f = fixture(), invoked = [];
  await f.ensure({ next: () => invoked.push('next1'), previous: () => invoked.push('previous1'),
    skip: seconds => invoked.push(seconds), speed: rate => invoked.push(rate) });
  const oldNext = f.handlers.get('playNext');
  const oldSkip = f.handlers.get('fastForward');
  f.helper.setCommands({ next: () => invoked.push('next2'), previous: () => invoked.push('previous2'),
    skip: seconds => invoked.push(seconds * 2), speed: rate => invoked.push(rate * 2) });
  assert.equal(f.calls.on.filter(name => name === 'playNext').length, 1);
  assert.equal(f.calls.on.filter(name => name === 'fastForward').length, 1);
  oldNext(); f.handlers.get('playPrevious')(); oldSkip(10000); f.handlers.get('setSpeed')(1.5);
  assert.deepEqual(invoked, ['next2', 'previous2', 20, 3]);
  f.helper.setCommands({ previous: () => invoked.push('previous3') });
  assert.deepEqual(f.calls.off, ['playNext', 'fastForward', 'rewind', 'setSpeed']);
  oldNext(); oldSkip(10000);
  assert.deepEqual(invoked, ['next2', 'previous2', 20, 3]);
  f.handlers.get('playPrevious')(); assert.equal(invoked.at(-1), 'previous3');
  f.helper.setCommands({ previous: () => {} });
  assert.equal(f.calls.off.length, 4);
});

test('system skip converts milliseconds into player seconds while seek remains milliseconds', async () => {
  const f = fixture(), skips = [];
  await f.ensure({ skip: value => skips.push(value) });
  const forward = f.handlers.get('fastForward'), rewind = f.handlers.get('rewind');
  forward(10000); rewind(15000); forward(250); rewind(); forward();
  forward(NaN); forward(Infinity); forward(0); forward(-5000); forward(7200000);
  f.handlers.get('seek')(98765);
  assert.deepEqual(skips, [10, -15, 0.25, -10, 10, 10, 10, 10, 10, 3600]);
  assert.deepEqual(f.callbacks.seek, [98765]);
});

test('system speed accepts positive finite values only and revocation blocks captured handler', async () => {
  const f = fixture(), rates = []; await f.ensure({ speed: value => rates.push(value) });
  const speed = f.handlers.get('setSpeed');
  for (const value of [NaN, Infinity, -Infinity, 0, -1, 0.75, 2]) speed(value);
  assert.deepEqual(rates, [0.75, 2]);
  f.helper.setCommands({}); speed(3); assert.deepEqual(rates, [0.75, 2]);
  assert.deepEqual(f.calls.off, ['setSpeed']);
});

test('one optional registration failure leaves core and other controls active and retries that command', async () => {
  const failOn = new Set(['fastForward']), f = fixture({ failOn }), values = [];
  const commands = { next: () => values.push('next'), skip: value => values.push(value),
    speed: rate => values.push(rate) };
  await f.ensure(commands);
  assert.equal(f.calls.destroy, 0); assert.equal(f.handlers.has('fastForward'), false);
  f.handlers.get('play')(); f.handlers.get('playNext')(); f.handlers.get('rewind')(15000);
  f.handlers.get('setSpeed')(1.5);
  assert.equal(f.callbacks.play, 1); assert.deepEqual(values, ['next', -15, 1.5]);
  failOn.clear(); f.helper.setCommands(commands);
  assert.equal(f.calls.on.filter(name => name === 'fastForward').length, 2);
  assert.equal(f.calls.on.filter(name => name === 'rewind').length, 1);
  assert.equal(f.calls.on.filter(name => name === 'playNext').length, 1);
  f.handlers.get('fastForward')(10000); assert.equal(values.at(-1), 10);
});

test('failed optional revocation cannot invoke removed commands and retries without blocking other revocations', async () => {
  const failOff = new Set(['fastForward']), f = fixture({ failOff }), values = [];
  await f.ensure({ next: () => values.push('next'), previous: () => values.push('previous'),
    skip: value => values.push(value), speed: rate => values.push(rate) });
  const oldForward = f.handlers.get('fastForward');
  assert.doesNotThrow(() => f.helper.setCommands({}));
  assert.equal(f.handlers.has('rewind'), false); assert.equal(f.handlers.has('playNext'), false);
  assert.equal(f.handlers.has('playPrevious'), false); assert.equal(f.handlers.has('setSpeed'), false);
  oldForward(10000); assert.deepEqual(values, []);
  f.handlers.get('play')(); assert.equal(f.callbacks.play, 1);
  failOff.clear(); f.helper.setCommands({});
  assert.equal(f.handlers.has('fastForward'), false);
  assert.equal(f.calls.off.filter(name => name === 'fastForward').length, 2);
  assert.equal(f.calls.off.filter(name => name === 'rewind').length, 1);
});

for (const stage of ['create', 'activate', 'backgroundMode']) {
  test(`pending ${stage} publishes latest commands and metadata after activation`, async () => {
    const pending = deferred(), f = fixture({ stage, pending }), invoked = [];
    const creating = f.ensure({ next: () => invoked.push('old') }, { assetId: 'old' });
    await tick();
    f.helper.setCommands({ previous: () => invoked.push('latest') });
    f.helper.setMetadata({ assetId: 'latest', duration: 22000 });
    f.helper.setPlaybackState({ state: 0, speed: 2, position: { elapsedTime: 11000, updateTime: 123456 } });
    pending.resolve(stage === 'create' ? f.session : undefined); await creating;
    assert.equal(f.handlers.has('playNext'), false);
    assert.equal(f.handlers.has('playPrevious'), true);
    f.handlers.get('playPrevious')(); assert.deepEqual(invoked, ['latest']);
    assert.deepEqual(f.calls.metadata.at(-1), { assetId: 'latest', duration: 22000 });
    assert.deepEqual(f.calls.state.at(-1), {
      state: 0, speed: 2, position: { elapsedTime: 11000, updateTime: 123456 }
    });
  });
  test(`release during ${stage} destroys once and never exposes late optional controls`, async () => {
    const pending = deferred(), f = fixture({ stage, pending }); let next = 0;
    const creating = f.ensure({ next: () => next++ });
    await tick(); f.helper.release();
    f.helper.setCommands({ previous: () => next++ });
    pending.resolve(stage === 'create' ? f.session : undefined); await creating;
    for (const handler of f.handlers.values()) handler(1000);
    assert.equal(next, 0); assert.equal(f.callbacks.play, 0); assert.equal(f.callbacks.pause, 0);
    assert.deepEqual(f.callbacks.seek, []);
    assert.equal(f.handlers.has('playNext'), false); assert.equal(f.handlers.has('playPrevious'), false);
    assert.equal(f.calls.destroy, 1);
    f.helper.release(); await f.ensure({ next: () => next++ }); await tick();
    assert.equal(f.calls.destroy, 1);
  });
}

test('released active session rejects captured controls and destroys once', async () => {
  const f = fixture(), invoked = [];
  await f.ensure({ next: () => invoked.push('next'), previous: () => invoked.push('previous'),
    skip: value => invoked.push(value), speed: value => invoked.push(value) });
  const captured = [...f.handlers.values()];
  f.helper.release(); f.helper.release(); await tick();
  for (const callback of captured) callback(10000);
  assert.deepEqual(invoked, []); assert.deepEqual(f.callbacks, { play: 0, pause: 0, seek: [] });
  assert.equal(f.calls.deactivate, 1); assert.equal(f.calls.destroy, 1);
});

test('background task that starts after release is immediately stopped using its real id', async () => {
  const backgroundPending = deferred(), f = fixture({ backgroundPending });
  await f.ensure({}, undefined, { state: 1 }); await tick();
  assert.equal(f.calls.backgroundStart.length, 1);
  const { request } = f.calls.backgroundStart[0];
  assert.deepEqual(request.backgroundTaskModes, [2]);
  assert.deepEqual(request.backgroundTaskSubmodes, [3]);
  f.helper.release(); backgroundPending.resolve({ continuousTaskId: 73 });
  await tick(); await tick();
  assert.deepEqual(f.calls.backgroundStop, [{ ctx: f.context, id: 73 }]);
});

test('play to pause during background start stops it without a duplicate start', async () => {
  const backgroundPending = deferred(), f = fixture({ backgroundPending });
  await f.ensure({}, undefined, { state: 1 }); await tick();
  f.helper.setPlaybackState({ state: 0 });
  backgroundPending.resolve({ continuousTaskId: 84 }); await tick(); await tick();
  assert.equal(f.calls.backgroundStart.length, 1);
  assert.deepEqual(f.calls.backgroundStop, [{ ctx: f.context, id: 84 }]);
});

function queueFixture() {
  return createArktsLoader()('components/video/VideoSystemQueue').VideoSystemQueue;
}
function detail({ pages = [11], episodes = null, ...rest } = {}) {
  return { aid: 1, bvid: 'BV1', pages: pages.map((cid, index) => ({ cid, part: `Part ${index + 1}` })),
    ugcSeason: episodes === null ? null : { sections: episodes.map(items => ({ episodes: items })) }, ...rest };
}
function episode(aid, cid, bvid = `BV${aid}`) { return { aid, cid, bvid, title: `Video ${aid}` }; }

test('parts have stable distinct asset ids and take precedence over collections', () => {
  const queue = queueFixture(), d = detail({ pages: [11, 12, 13], episodes: [[episode(1, 11), episode(2, 21)]] });
  assert.deepEqual(queue.neighbor(d, 11, 1), {
    assetId: 'BV1:12', aid: 1, bvid: 'BV1', cid: 12, title: 'Part 2', pageIndex: 1
  });
  assert.equal(queue.neighbor(d, 13, -1).cid, 12);
  assert.equal(queue.assetId(1, '', 11), 'av1:11');
  assert.notEqual(queue.assetId(1, 'BV1', 11), queue.assetId(1, 'BV1', 12));
});

test('explicit collection traverses section boundaries and stops at both ends', () => {
  const queue = queueFixture(), d = detail({ pages: [21], aid: 2, bvid: 'BV2',
    episodes: [[episode(1, 11)], [episode(2, 21), episode(3, 31)]] });
  assert.equal(queue.neighbor(d, 21, -1).assetId, 'BV1:11');
  assert.equal(queue.neighbor(d, 21, 1).assetId, 'BV3:31');
  const first = detail({ episodes: [[episode(1, 11), episode(2, 21)]] });
  assert.equal(queue.neighbor(first, 11, -1), undefined);
  const last = detail({ pages: [31], aid: 3, bvid: 'BV3', episodes: [[episode(1, 11), episode(3, 31)]] });
  assert.equal(queue.neighbor(last, 31, 1), undefined);
});

test('last part advances to collection video even if collection identifies only the first part', () => {
  const queue = queueFixture(), d = detail({ pages: [11, 12],
    episodes: [[episode(1, 11), episode(2, 21)]] });
  assert.equal(queue.neighbor(d, 12, 1).assetId, 'BV2:21');
  assert.equal(queue.neighbor(d, 12, -1).assetId, 'BV1:11');
});

test('collection avoids reselecting other entries of the same multipart video', () => {
  const queue = queueFixture(), d = detail({ pages: [11, 12],
    episodes: [[episode(3, 31), episode(1, 11), episode(1, 12), episode(2, 21)]] });
  assert.equal(queue.neighbor(d, 12, 1).assetId, 'BV2:21');
  assert.equal(queue.neighbor(d, 11, -1).assetId, 'BV3:31');
});

test('unknown current cid and malformed targets do not advertise queue actions', () => {
  const queue = queueFixture(), d = detail({ episodes: [[episode(1, 11), episode(2, 21)]] });
  for (const cid of [0, -1, NaN, 999]) assert.equal(queue.neighbor(d, cid, 1), undefined);
  for (const direction of [0, 2, NaN]) assert.equal(queue.neighbor(d, 11, direction), undefined);
  assert.equal(queue.neighbor(detail({ pages: [11, 0] }), 11, 1), undefined);
  assert.equal(queue.neighbor(detail({ episodes: [[episode(1, 11), episode(0, 21, '')]] }), 11, 1), undefined);
});

test('recommendations are never treated as an explicit playback queue', () => {
  const queue = queueFixture(), d = detail({ related: [episode(2, 21)], recommendations: [episode(3, 31)] });
  assert.equal(queue.neighbor(d, 11, 1), undefined);
  assert.equal(queue.neighbor(d, 11, -1), undefined);
});

for (const initialSeek of [0, 17]) test(`restored autoPlay=false remains paused at ${initialSeek}s and later user play works`, async () => {
  const f = playbackFixture();
  const { engine } = await f.boot(f.source({ autoPlay: false, initialSeek }));
  f.prepared(); f.advance(60); await tick();
  assert.equal(f.calls(engine, 'play').length, 0); assert.equal(f.state().playing, false);
  if (initialSeek > 0) {
    assert.equal(f.calls(engine, 'seek').at(-1)[1], initialSeek * 1000);
    engine.currentTime = initialSeek * 1000; engine.emit('seek', initialSeek * 1000); await tick();
  }
  assert.equal(f.state().position, initialSeek); assert.equal(f.state().seekLocked, false);
  assert.equal(f.calls(engine, 'play').length, 0);
  f.session.toggle(); await tick();
  assert.equal(f.calls(engine, 'play').length, 1); assert.equal(f.state().playing, true);
  engine.emit('state', 'playing'); engine.emit('time', (initialSeek + 1) * 1000);
  assert.equal(f.state().position, initialSeek + 1);
  f.session.deactivate();
});

function adapterClass(file, ranges, bindings = {}) {
  // ArkUI's struct/build DSL is compiled by CompileArkTS. Execute its unchanged adapter
  // method here, while the playback/session graph in these tests is loaded in full.
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, file + '.ets'), 'utf8').replace(/\r\n/g, '\n');
  const methods = ranges.map(([first, last]) => {
    const start = source.indexOf(first), end = source.indexOf(last, start);
    assert.ok(start >= 0 && end > start, 'unchanged UI adapter anchors: ' + first);
    return source.slice(start, end);
  }).join('\n');
  const code = ts.transpileModule('class View {\n' + methods + '\n}; return View;',
    { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
  return new Function(...Object.keys(bindings), code)(...Object.values(bindings));
}

function recoverySourceAdapter(load) {
  const { PlayerPlaybackSource } = load('components/player/PlayerPlaybackState');
  const View = adapterClass('components/player/PlayerView', [
    ['  private playbackSource():', '  private onPlaybackEvent(']
  ], { PlayerPlaybackSource });
  return Object.assign(new View(), { aid: 1, bvid: 'BV1', cid: 11, epId: 0, sourceVersion: 1,
    videoUrls: [], videoUrl: '', audioUrls: [], qualityOptions: [], currentQuality: 80,
    initialSeekSeconds: 0, initiallyPaused: true, recoveryPauseConsumed: false, previewPlayback: false });
}

test('empty source does not consume the one-time recovered pause before usable URLs arrive', async () => {
  const f = playbackFixture(), view = recoverySourceAdapter(f.load);
  let input = view.playbackSource();
  assert.deepEqual(input.urls, []); assert.equal(input.autoPlay, false);
  assert.equal(view.recoveryPauseConsumed, false);
  await f.boot(input); assert.equal(f.opens.length, 0);
  view.sourceVersion++; view.videoUrl = 'video-ready';
  input = view.playbackSource(); assert.equal(input.autoPlay, false);
  assert.equal(view.recoveryPauseConsumed, true);
  await f.session.replaceSource(input); await tick(); f.prepared();
  assert.equal(f.calls(f.session.core.engine, 'play').length, 0);
  view.sourceVersion++; view.cid = 12; view.videoUrls = ['next-part'];
  input = view.playbackSource(); assert.equal(input.autoPlay, true);
  await f.session.replaceSource(input); await tick(); f.prepared();
  assert.equal(f.calls(f.session.core.engine, 'play').length, 1);
  f.session.deactivate();
});

function detailRecoveryAdapter(load, param = { bvid: 'BV1', aid: 1, title: 'Video' }) {
  const { AppRecoveryState } = load('common/AppRecoveryState');
  const View = adapterClass('pages/VideoDetail', [
    ['  private applyPlaybackSource(', '  async init():'],
    ['  private playbackRecoveryKey():', '  private playSystemNeighbor('],
    ['  aboutToAppear(): void', '  /** 播放区在窗口中的 hero 矩形']
  ], { AppRecoveryState, AppTheme: { loadDanmakuSettings: () => ({ enabled: true }) } });
  const heartbeats = [];
  const page = Object.assign(new View(), { destroyed: false, loading: false, playbackAddressFailed: false,
    param, bvid: 'BV1', aid: 1, currentCid: 11, playerSourceVersion: 1, initialSeekSeconds: 0,
    videoProgressSeconds: 97, playerPlaying: true,
    playback: { resetHeartbeat() {}, reportHeartbeat: (...args) => heartbeats.push(args) },
    resetPlaybackSize() {}, danmakuSubmit: { reset() {} }, replySubmit: { reset() {} },
    favoritePicker: { reset() {} }, refreshScreenSize() {}, startInit() {},
    hero: { resetForReuse() {}, prepareWholeCardEntrance: () => false, prepareCardEntrance() {},
      triggerEntranceExpansion() {} },
    onPlayerPlayingChange(value) { this.playerPlaying = value; }
  });
  const saved = () => JSON.parse(AppRecoveryState.serialize()).views.find(entry => entry.key === page.playbackRecoveryKey())?.state;
  return { page, saved, heartbeats, AppRecoveryState };
}

test('new part resets progress and rejects old source progress/playing while allowing new source callbacks', () => {
  const load = createArktsLoader(), { page, saved, heartbeats } = detailRecoveryAdapter(load);
  page.onPlaybackProgress(97, 1); assert.deepEqual(saved(), { cid: 11, position: 97, playing: true });
  page.applyPlaybackSource({ urls: ['part2'], url: 'part2', audioUrls: [], qualities: [], subtitles: [], quality: 80 }, 12, 1, 0);
  assert.equal(page.videoProgressSeconds, 0); assert.equal(page.playerPlaying, false);
  assert.equal(page.playerSourceVersion, 2);
  page.onPlaybackProgress(98, 1); page.onPlaybackPlayingChange(true, 1);
  assert.equal(page.videoProgressSeconds, 0); assert.equal(page.playerPlaying, false);
  assert.deepEqual(saved(), { cid: 11, position: 97, playing: true });
  assert.deepEqual(heartbeats, [[97, true]]);
  page.onPlaybackPlayingChange(false, 2);
  assert.deepEqual(saved(), { cid: 12, position: 0, playing: false });
  page.onPlaybackProgress(1.25, 2); page.onPlaybackPlayingChange(true, 2);
  assert.deepEqual(saved(), { cid: 12, position: 1.25, playing: true });
  page.destroyed = true; page.onPlaybackProgress(2, 2); page.onPlaybackPlayingChange(false, 2);
  assert.deepEqual(saved(), { cid: 12, position: 1.25, playing: true });
});

test('restored positive seek ignores pre-prepare old position and user seek to zero remains saveable', async () => {
  const f = playbackFixture(), { page, saved } = detailRecoveryAdapter(f.load);
  page.applyPlaybackSource({ urls: ['restored'], url: 'restored', audioUrls: [], qualities: [], subtitles: [], quality: 80 }, 12, 1, 17);
  const original = f.session.observer;
  f.session.observer = { ...original, progress(seconds, background) {
    original.progress(seconds, background); page.onPlaybackProgress(seconds, f.session.sourceVersion);
  } };
  const { engine } = await f.boot(f.source({ version: page.playerSourceVersion, cid: 12, initialSeek: 17, autoPlay: false }));
  engine.emit('time', 0); engine.emit('time', 97000);
  assert.equal(f.state().position, 17); assert.equal(page.videoProgressSeconds, 17);
  assert.equal(saved(), undefined);
  f.prepared(); f.advance(60); engine.currentTime = 17000; engine.emit('seek', 17000); await tick();
  engine.emit('time', 17000); assert.deepEqual(saved(), { cid: 12, position: 17, playing: false });
  f.session.seekTo(0); f.advance(60); engine.currentTime = 0; engine.emit('seek', 0); await tick();
  engine.emit('time', 0); assert.deepEqual(saved(), { cid: 12, position: 0, playing: false });
  assert.equal(f.calls(engine, 'play').length, 0); f.session.deactivate();
});

test('PlayerView progress stamps the adopted session version even when reactive props have advanced', () => {
  const f = playbackFixture(), values = [];
  const View = adapterClass('components/player/PlayerView', [
    ['  private onPlaybackProgress(', '  private auxiliary:']
  ]);
  const view = Object.assign(new View(), { playback: f.session, sourceVersion: 22,
    interactionCtl: { update() {} }, dmEngine: { lastPlayerTime: 0 }, timerFireAt: 0,
    onProgress: (seconds, version) => values.push([seconds, version]),
    reportContinueWatching() {}, updateAVSessionPlaybackState() {}, lastSystemPlaybackBucket: -1,
    sponsorCtl: { maybeSkipSponsor() {} }
  });
  f.session.activate(f.source({ version: 11 }));
  view.onPlaybackProgress(97, true);
  assert.deepEqual(values, [[97, 11]]);
  f.session.deactivate();
});

test('PGC episode-only routes restore independently and consume their own state once', () => {
  const load = createArktsLoader();
  const first = detailRecoveryAdapter(load, { bvid: '', aid: 0, epId: 101, title: 'Episode 1' });
  const second = detailRecoveryAdapter(load, { bvid: '', aid: 0, epId: 102, title: 'Episode 2' });
  first.page.currentCid = 1001; first.page.videoProgressSeconds = 17; first.page.playerPlaying = false;
  second.page.currentCid = 1002; second.page.videoProgressSeconds = 29; second.page.playerPlaying = true;
  first.page.savePlaybackRecovery(); second.page.savePlaybackRecovery();
  assert.deepEqual(JSON.parse(first.AppRecoveryState.serialize()).views.map(entry => entry.key), ['video:ep101', 'video:ep102']);
  first.AppRecoveryState.restore(first.AppRecoveryState.serialize());
  first.page.aboutToAppear(); second.page.aboutToAppear();
  assert.equal(first.page.param.cid, 1001); assert.equal(first.page.param.resumePosition, 17);
  assert.equal(first.page.param.initiallyPaused, true);
  assert.equal(second.page.param.cid, 1002); assert.equal(second.page.param.resumePosition, 29);
  assert.equal(second.page.param.initiallyPaused, false);
  first.page.param = { ...first.page.param, resumePosition: 0 }; first.page.aboutToAppear();
  assert.equal(first.page.param.resumePosition, 0);
});

test('PGC epId has priority and non-PGC recovery keeps the incoming route identity after detail resolves', () => {
  const load = createArktsLoader();
  const pgc = detailRecoveryAdapter(load, { bvid: 'BVsame', aid: 42, epId: 201, title: 'PGC' });
  assert.equal(pgc.page.playbackRecoveryKey(), 'video:ep201');
  const byAid = detailRecoveryAdapter(load, { bvid: '', aid: 42, title: 'AV route' });
  byAid.page.bvid = 'BVresolved'; byAid.page.aid = 42;
  assert.equal(byAid.page.playbackRecoveryKey(), 'video:av42');
  byAid.page.savePlaybackRecovery();
  const byBvid = detailRecoveryAdapter(load, { bvid: 'BVroute', aid: 0, title: 'BV route' });
  byBvid.page.bvid = 'BVresolved'; byBvid.page.aid = 99;
  assert.equal(byBvid.page.playbackRecoveryKey(), 'video:BVroute'); byBvid.page.savePlaybackRecovery();
  byAid.AppRecoveryState.restore(byAid.AppRecoveryState.serialize());
  byAid.page.aboutToAppear(); byBvid.page.aboutToAppear();
  assert.equal(byAid.page.param.resumePosition, 97); assert.equal(byBvid.page.param.resumePosition, 97);
  assert.equal(byAid.page.param.cid, 11); assert.equal(byBvid.page.param.cid, 11);
});
