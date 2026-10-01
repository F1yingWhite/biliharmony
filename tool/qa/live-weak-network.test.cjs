// Production live-player methods, fake native events, and a deterministic timer queue.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const relative = 'components/live/LivePlayerView.ets';
const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, relative);
const source = fs.readFileSync(override && fs.existsSync(override) ? override : path.join(root, relative), 'utf8')
  .replace(/\r\n/g, '\n');
const begin = source.indexOf('  async restartForSource():');
const end = source.indexOf('  togglePlay():', begin);
assert.ok(begin >= 0 && end > begin);
const callbackBegin = source.indexOf('class LiveHeldFrameCallback');
const callbackEnd = callbackBegin >= 0 ? source.indexOf('\n/**', callbackBegin) : -1;
const callbackSource = callbackBegin >= 0 && callbackEnd > callbackBegin ?
  source.slice(callbackBegin, callbackEnd) : '';
const code = ts.transpileModule(
  "import { media } from '@kit.MediaKit'; import { image } from '@kit.ImageKit';\n" +
  "import { FrameCallback } from '@kit.ArkUI';\n" + callbackSource + '\n' +
  'const Constants={browserUa:"test"}; export class Harness {\n' + source.slice(begin, end) + '\n}',
  { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;

const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function timerQueue() {
  let now = 0, next = 1;
  const timers = new Map();
  return {
    timers,
    setTimeout(callback, delay) { const id = next++; timers.set(id, { callback, at: now + delay, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    advance(ms) {
      const target = now + ms;
      while (true) {
        const nextTimer = [...timers].filter(([, value]) => value.at <= target)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (!nextTimer) break;
        timers.delete(nextTimer[0]); now = nextTimer[1].at; nextTimer[1].callback();
      }
      now = target;
    }
  };
}
function pixelMap() {
  const frame = { releases: 0, release: async () => { frame.releases++; } };
  return frame;
}
async function fixture(capture, deferPaint = false) {
  const clock = timerQueue(), players = [], order = [], uiFrames = [];
  const frame = pixelMap();
  let captures = 0;
  const media = {
    BufferingInfoType: { BUFFERING_START: 0, BUFFERING_END: 1 },
    VideoScaleType: { VIDEO_SCALE_TYPE_SCALED_ASPECT: 0 },
    createMediaSourceWithUrl: id => ({ id }),
    createAVPlayer: async () => {
      const handlers = {};
      const player = { handlers, releases: 0, volumes: [], prepare: async () => {}, play: async () => {},
        setVolume(value) { player.volumes.push(value); }, on(name, callback) { handlers[name] = callback; },
        setMediaSource: async (source, strategy) => { player.source = source; player.strategy = strategy; },
        release: async () => { player.releases++; order.push('release'); } };
      players.push(player); return player;
    }
  };
  const image = { createPixelMapFromSurface: () => {
    captures++; order.push('capture'); return capture ? capture() : Promise.resolve(frame);
  } };
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'setTimeout', 'clearTimeout', code)(
    name => name === '@kit.MediaKit' ? { media } :
      (name === '@kit.ArkUI' ? { FrameCallback: class {} } : { image }), module, module.exports,
    clock.setTimeout, clock.clearTimeout);
  const view = Object.assign(new module.exports.Harness(), {
    destroyed: false, player: null, playerGeneration: 0, playerCreating: false, playerRestartPending: false,
    surfaceId: 'surface', playInfo: { urls: ['primary', 'backup'] }, sourceIndex: 0,
    dmRenderer: { setPlayback() {}, release() {} }, scheduleHide() {},
    prepared: false, playing: false, buffering: true, errorText: '',
    firstFrameShown: false, firstRenderReady: false, heldFrame: null, capturingFrame: false,
    frameCaptureOwner: null, pendingPlayerRelease: null, releasingPlayers: new Set(), nativeBuffering: false,
    startupHintTimer: -1, startupTimer: -1, bufferingStartTimer: -1, bufferingEndTimer: -1,
    hideTimer: -1, fullscreenTimer: -1, slowLoading: false, cover: 'room-cover',
    getUIContext() { return { postFrameCallback(callback) {
      uiFrames.push(callback); if (!deferPaint) callback.onIdle(2_000_000);
    } }; }
  });
  await view.initPlayer();
  function ready(player = view.player) {
    player.handlers.stateChange('prepared');
    player.handlers.stateChange('playing');
    if (player.handlers.startRenderFrame) player.handlers.startRenderFrame();
  }
  ready();
  return { view, clock, players, frame, order, ready, uiFrames, captures: () => captures,
    buffer(on, player = view.player) { player.handlers.bufferingUpdate(on ? 0 : 1); } };
}

test('short weak-network buffering bursts preserve the Surface without blinking the loading layer', async () => {
  const f = await fixture();
  f.buffer(true);
  assert.equal(f.view.buffering, false, 'A brief stall must not immediately add a loading overlay');
  f.clock.advance(100);
  f.buffer(false);
  f.clock.advance(300);
  assert.equal(f.view.buffering, false);
  assert.equal(f.captures(), 0, 'Normal buffering must not repeatedly capture the Surface');
  assert.equal(f.players.length, 1);
  assert.equal(f.players[0].releases, 0);
});

test('sustained buffering shows once and waits for a stable end before hiding', async () => {
  const f = await fixture();
  f.buffer(true); f.clock.advance(200);
  assert.equal(f.view.buffering, true);
  f.buffer(false); f.clock.advance(100); f.buffer(true); f.clock.advance(200);
  assert.equal(f.view.buffering, true, 'An unstable recovery cannot blink the indicator off');
  f.buffer(false); f.clock.advance(199);
  assert.equal(f.view.buffering, true);
  f.clock.advance(1);
  assert.equal(f.view.buffering, false);
});

test('backup connection holds the decoded frame until playing and the real first frame both arrive', async () => {
  const f = await fixture();
  await f.players[0].handlers.error({ message: 'network disconnected' });
  assert.deepEqual(f.order, ['capture', 'release'], 'Capture must precede releasing the old Surface');
  assert.equal(f.view.heldFrame, f.frame);
  assert.equal(f.view.firstFrameShown, false);
  const backup = f.view.player;
  backup.handlers.stateChange('prepared');
  backup.handlers.stateChange('playing');
  assert.equal(f.view.heldFrame, f.frame, 'playing is not proof of a visible video frame');
  assert.equal(f.view.buffering, true);
  assert.equal(f.frame.releases, 0);
  backup.handlers.startRenderFrame();
  assert.equal(f.view.firstFrameShown, true);
  assert.equal(f.view.heldFrame, null);
  assert.equal(f.frame.releases, 1);
  assert.equal(f.view.buffering, false);
});

test('old Surface remains until the held-frame layer has actually rendered', async () => {
  const f = await fixture(undefined, true);
  const restarting = f.view.restartForSource();
  await tick();
  assert.equal(f.view.heldFrame, f.frame);
  assert.equal(f.view.capturingFrame, false);
  assert.equal(f.players[0].releases, 0, 'Image state alone cannot release the old Surface');
  assert.equal(f.uiFrames.length, 1);
  f.uiFrames[0].onIdle(2_000_000);
  await restarting;
  assert.equal(f.players[0].releases, 1);
  assert.equal(f.players.length, 2);
});

test('a suspended UI frame has a bounded release fallback', async () => {
  const f = await fixture(undefined, true);
  const restarting = f.view.restartForSource();
  await tick();
  assert.equal(f.players[0].releases, 0);
  f.clock.advance(250);
  await restarting;
  assert.equal(f.players[0].releases, 1);
  assert.equal(f.players.length, 2);
});

test('a prepared first frame still retains the replacement cover until playing arrives', async () => {
  const f = await fixture();
  await f.view.restartForSource();
  const replacement = f.view.player;
  replacement.handlers.stateChange('prepared');
  assert.ok(replacement.handlers.startRenderFrame, 'The real native frame event must be subscribed');
  replacement.handlers.startRenderFrame();
  assert.equal(f.view.firstFrameShown, false);
  assert.equal(f.view.heldFrame, f.frame);
  replacement.handlers.stateChange('playing');
  assert.equal(f.view.firstFrameShown, true);
  assert.equal(f.frame.releases, 1);
});

test('a source change discards a late capture and waits for the old player release', async () => {
  const pending = deferred();
  const f = await fixture(() => pending.promise);
  const first = f.view.restartForSource();
  assert.equal(f.view.capturingFrame, true, 'Keep the old Surface visible while capturing its frame');
  assert.equal(f.players[0].releases, 0);
  f.view.playInfo = { urls: ['newest'] };
  const second = f.view.restartForSource();
  assert.equal(f.players.length, 1, 'No new Surface producer can precede the old release');
  pending.resolve(f.frame);
  await Promise.all([first, second]);
  assert.equal(f.frame.releases, 1, 'The obsolete PixelMap must be freed');
  assert.equal(f.view.heldFrame, null);
  assert.equal(f.players.length, 2);
  assert.equal(f.view.player.source.id, 'newest');
  assert.equal(f.players[0].releases, 1);
});

test('leaving during capture releases the late PixelMap and never recreates a player', async () => {
  const pending = deferred();
  const f = await fixture(() => pending.promise);
  const restarting = f.view.restartForSource();
  assert.deepEqual(f.players[0].volumes, [], 'Source replacement preserves the old player until its cover is ready');
  f.view.destroyed = true; f.view.release();
  assert.deepEqual(f.players[0].volumes, [0], 'Leaving must mute the old player while its capture is pending');
  assert.equal(f.players[0].releases, 0, 'Muting does not release the Surface before its capture completes');
  pending.resolve(f.frame);
  await restarting;
  assert.equal(f.frame.releases, 1);
  assert.equal(f.view.heldFrame, null);
  assert.equal(f.view.player, null);
  assert.equal(f.players.length, 1);
  assert.equal(f.players[0].releases, 1);
  assert.equal(f.view.releasingPlayers.size, 0);
});

test('leaving while the held frame awaits painting mutes without releasing the player twice', async () => {
  const f = await fixture(undefined, true);
  const restarting = f.view.restartForSource();
  await tick();
  assert.equal(f.players[0].releases, 0);
  f.view.destroyed = true; f.view.release();
  assert.deepEqual(f.players[0].volumes, [0], 'The old player stays reachable after capture has finished');
  assert.equal(f.players[0].releases, 0);
  f.uiFrames[0].onIdle(2_000_000);
  await restarting;
  assert.equal(f.players[0].releases, 1);
  assert.equal(f.frame.releases, 1);
  assert.equal(f.view.releasingPlayers.size, 0);
  assert.equal(f.players.length, 1);
});

test('rapid same-instance re-entry waits for ordinary disappearance release before creating a new player', async () => {
  const f = await fixture();
  const releasing = deferred(), old = f.view.player;
  old.release = async () => { old.releases++; await releasing.promise; };
  f.view.destroyed = true;
  f.view.release();
  assert.deepEqual(old.volumes, [0], 'Leaving must mute immediately while native release is pending');
  f.view.destroyed = false;
  const reentering = f.view.initPlayer();
  await tick();
  assert.equal(f.players.length, 1, 'The replacement producer must wait for the old Surface release');
  assert.equal(old.releases, 1);
  assert.equal(f.captures(), 0, 'Ordinary disappearance does not preserve a frame');
  assert.equal(f.uiFrames.length, 0, 'Ordinary disappearance does not wait for a cover paint');
  releasing.resolve();
  await reentering;
  assert.equal(f.players.length, 2);
  assert.notEqual(f.view.player, old);
  assert.equal(f.view.pendingPlayerRelease, null);
});

test('capture failures fall back to the room cover and do not block backup playback', async () => {
  const f = await fixture(() => Promise.reject(new Error('Surface capture unavailable')));
  await f.players[0].handlers.error({ message: 'network disconnected' });
  assert.equal(f.captures(), 1);
  assert.equal(f.view.capturingFrame, false);
  assert.equal(f.view.heldFrame, null);
  assert.equal(f.view.firstFrameShown, false);
  assert.equal(f.players.length, 2);
  f.ready();
  assert.equal(f.view.firstFrameShown, true);
});

test('a stalled capture times out, and its late PixelMap cannot cover the recovered video', async () => {
  const pending = deferred();
  const f = await fixture(() => pending.promise);
  const restarting = f.view.restartForSource();
  f.clock.advance(250);
  await restarting;
  assert.equal(f.players.length, 2);
  f.ready();
  pending.resolve(f.frame); await tick();
  assert.equal(f.frame.releases, 1);
  assert.equal(f.view.firstFrameShown, true);
  assert.equal(f.view.heldFrame, null);
});

test('obsolete buffer timers cannot revive overlays or overwrite a newer timer after replacing the player', async () => {
  const f = await fixture();
  f.buffer(true);
  const stale = [...f.clock.timers.values()].find(timer => timer.delay === 200);
  assert.ok(stale, 'Sustained-buffer hint must be scheduled');
  await f.view.restartForSource(); f.ready();
  f.buffer(true);
  const newerTimer = f.view.bufferingStartTimer;
  stale.callback();
  assert.equal(f.view.buffering, false);
  assert.equal(f.view.bufferingStartTimer, newerTimer);
  f.view.destroyed = true; f.view.release(); f.clock.advance(1000);
  assert.equal(f.view.buffering, false);
});

test('playing without a real frame keeps the startup watchdog active for recovery', async () => {
  const f = await fixture();
  await f.view.restartForSource();
  f.view.player.handlers.stateChange('prepared');
  f.view.player.handlers.stateChange('playing');
  assert.equal(f.view.firstFrameShown, false);
  assert.equal(f.view.heldFrame, f.frame);
  f.clock.advance(15000); await tick();
  assert.equal(f.players.length, 3, 'A black Surface must still time out to its backup');
  assert.equal(f.view.firstFrameShown, false);
});

test('live resume reserves two seconds and respects the SDK catch-up threshold margin', async () => {
  const f = await fixture();
  const strategy = f.view.player.strategy;
  assert.ok(strategy.preferredBufferDurationForPlaying >= 2);
  assert.ok(strategy.thresholdForAutoQuickPlay >= strategy.preferredBufferDurationForPlaying + 2);
  assert.ok(strategy.preferredBufferDuration >= strategy.thresholdForAutoQuickPlay);
});
