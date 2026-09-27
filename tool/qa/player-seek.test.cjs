const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
function fixture(getAudioPause = () => null) {
  const timers = new Map(); let id = 0;
  const module = {exports: {}};
  const source = fs.readFileSync('entry/src/main/ets/components/player/PlayerSeekController.ets', 'utf8');
  new Function('require', 'module', 'exports', 'setTimeout', 'clearTimeout', ts.transpileModule(source, {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText)(() => ({media: {SeekMode: {SEEK_CLOSEST: 0, SEEK_PREV_SYNC: 1}}}), module, module.exports,
    (fn, ms) => {timers.set(++id, {fn, ms}); return id;}, n => timers.delete(n));
  const makePlayer = () => ({state: 'playing', currentTime: 0, calls: [],
    pause() {this.state = 'paused'; return Promise.resolve();},
    seek(ms) {this.calls.push(ms);}});
  const video = makePlayer(), audio = makePlayer(), done = [], stalled = [];
  const ctl = new module.exports.PlayerSeekController(() => video, () => audio, () => true, () => true,
    () => {}, () => {}, (...args) => done.push(args), (...args) => stalled.push(args), getAudioPause);
  return {ctl, video, audio, done, stalled, fire(ms) {
    for (const [key, timer] of [...timers]) if (timer.ms === ms) {timers.delete(key); timer.fn();}
  }};
}
const flush = () => new Promise(resolve => setImmediate(resolve));
test('seek waits for both pauses and coalesces requests arriving during pause', async () => {
  const f = fixture(); let finishPause;
  f.video.pause = () => new Promise(resolve => {finishPause = resolve;});
  f.ctl.request(10000, true, true); f.fire(60); await flush();
  assert.deepEqual(f.video.calls, []); assert.deepEqual(f.audio.calls, []);
  f.ctl.request(20000, true, true); finishPause(); await flush();
  assert.deepEqual(f.video.calls, [20000]); assert.deepEqual(f.audio.calls, [20000]);
  f.ctl.onAudioSeekDone(f.audio, 20000); assert.equal(f.done.length, 0);
  f.ctl.onVideoSeekDone(f.video, 20000); assert.deepEqual(f.done, [[true, 20000]]);
});
test('cancel invalidates a delayed pause completion', async () => {
  const f = fixture(); let finishPause;
  f.video.pause = () => new Promise(resolve => {finishPause = resolve;});
  f.ctl.request(10000, true, true); f.fire(60); f.ctl.cancel(); finishPause(); await flush();
  assert.deepEqual(f.video.calls, []); assert.deepEqual(f.audio.calls, []); assert.equal(f.done.length, 0);
});
test('missing audio callback cannot resume an audio track at the old position', async () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60); await flush();
  f.ctl.onVideoSeekDone(f.video, 10000); f.fire(900);
  assert.equal(f.done.length, 0); f.fire(4000); assert.equal(f.stalled.length, 1);
});
test('missing audio callback is tolerated only when the playback head confirms arrival', async () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60); await flush();
  f.ctl.onVideoSeekDone(f.video, 10000); f.audio.currentTime = 10000; f.fire(900);
  assert.deepEqual(f.done, [[true, 10000]]);
});
test('keyframe recovery aligns audio to the actual video landing position', async () => {
  const f = fixture(); f.ctl.request(10000, false, true); f.fire(60); await flush();
  f.ctl.onAudioSeekDone(f.audio, 10000); f.ctl.onVideoSeekDone(f.video, 7200);
  assert.deepEqual(f.audio.calls, [7200]); assert.equal(f.done.length, 0);
  f.ctl.onAudioSeekDone(f.audio, 10000); assert.equal(f.done.length, 0);
  f.ctl.onAudioSeekDone(f.audio, 7200); assert.deepEqual(f.done, [[true, 7200]]);
});
test('user pause during seek prevents automatic playback restoration', async () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60); await flush();
  f.ctl.seekResumePlaying = false;
  f.ctl.onVideoSeekDone(f.video, 10000); f.ctl.onAudioSeekDone(f.audio, 10000);
  assert.deepEqual(f.done, [[false, 10000]]);
});
function syncHarness() {
  const source = fs.readFileSync('entry/src/main/ets/components/player/PlayerView.ets', 'utf8');
  const start = source.indexOf('  private audioSyncRate:');
  const end = source.indexOf('  private invalidatePlayerCreation()', start);
  assert.ok(start >= 0 && end > start);
  const module = {exports: {}};
  new Function('module', 'exports', ts.transpileModule('export class Harness {\n' + source.slice(start, end) + '\n}', {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText)(module, module.exports);
  const h = new module.exports.Harness();
  Object.assign(h, {playing: true, audioPrepared: true, audioDriftSamples: 0, lastAudioSyncAtMs: -1,
    playbackRate: 1, seekCtl: {seekInFlight: false}, calls: [],
    audioPlayer: {state: 'playing', currentTime: 12000, setPlaybackRate(rate) {h.calls.push(rate);},
      pause() {assert.fail('continuous audio must not pause');}, seek() {assert.fail('continuous audio must not seek');}},
    seekTo() {assert.fail('automatic correction must not seek video');},
    gateAudioStart() {assert.fail('continuous audio must not enter pause/seek gate');}});
  return h;
}
test('sustained drift smoothly adjusts audio without pause or seek and respects cooldown', () => {
  const h = syncHarness();
  h.checkAudioSync(10000); h.checkAudioSync(10000); assert.deepEqual(h.calls, []);
  h.checkAudioSync(10000); assert.deepEqual(h.calls, [0.97]);
  for (let i = 0; i < 10; i++) h.checkAudioSync(10000);
  assert.deepEqual(h.calls, [0.97]);
});
test('a transient clock difference does not interrupt playback', () => {
  const h = syncHarness(); h.checkAudioSync(10000); h.checkAudioSync(12000);
  h.checkAudioSync(10000); h.checkAudioSync(10000); assert.deepEqual(h.calls, []);
});
test('buffering, background playback and active seek do not trigger drift correction', () => {
  for (const flag of ['buffering', 'backgroundAudioOnly', 'seekLocked', 'audioStartPending']) {
    const h = syncHarness(); h[flag] = true;
    for (let i = 0; i < 10; i++) h.checkAudioSync(10000);
    assert.deepEqual(h.calls, [], flag);
  }
});

test('delayed timeUpdate does not look like drift when live player clocks agree', () => {
  const h = syncHarness();
  h.player = {currentTime: 12000};
  for (let i = 0; i < 10; i++) h.checkAudioSync(10000);
  assert.deepEqual(h.calls, []);
});

test('audio correction converges and restores the selected playback rate', () => {
  const h = syncHarness();
  for (let i = 0; i < 3; i++) h.checkAudioSync(10000);
  h.checkAudioSync(11950);
  assert.deepEqual(h.calls, [0.97, 1]);
  h.checkAudioSync(12000);
  assert.deepEqual(h.calls, [0.97, 1], 'do not resend the same rate every frame');
});
test('lagging audio speeds up and temporary speed is never overwritten', () => {
  const h = syncHarness(); h.playbackRate = 2;
  for (let i = 0; i < 3; i++) h.checkAudioSync(13000);
  assert.deepEqual(h.calls, [2.06]);
  h.holdSpeedActive = true;
  h.checkAudioSync(13000);
  assert.deepEqual(h.calls, [2.06]);
});
test('unsupported fine rate adjustment never falls back to interrupting audio', () => {
  const h = syncHarness(); h.audioPlayer.setPlaybackRate = () => {throw new Error('unsupported');};
  for (let i = 0; i < 9; i++) h.checkAudioSync(10000);
  assert.equal(h.audioSyncRate, -1);
});

test('speed transition suppresses transient drift without changing audio rate', () => {
  const h = syncHarness();
  h.speedTransitionUntilMs = Date.now() + 1500;
  for (let i = 0; i < 10; i++) h.checkAudioSync(10000);
  assert.deepEqual(h.calls, []);
  h.speedTransitionUntilMs = 0;
  for (let i = 0; i < 3; i++) h.checkAudioSync(10000);
  assert.deepEqual(h.calls, [0.97]);
});

function bufferHarness() {
  const source = fs.readFileSync('entry/src/main/ets/components/player/PlayerView.ets', 'utf8');
  const a = source.indexOf('      let bufferingAudioPause:');
  const b = source.indexOf("      p.on('videoSizeChange'", a);
  assert.ok(a >= 0 && b > a);
  const code = ts.transpileModule(source.slice(a, b), {
    compilerOptions: {target: ts.ScriptTarget.ES2020}
  }).outputText;
  let handler, timer, pauses = 0, gates = 0, finishPause;
  const p = {on(name, callback) {handler = callback;}};
  const h = {player: p, playing: true, audioPrepared: true, audioGateGeneration: 0,
    speedTransitionUntilMs: Date.now() + 1500, seekCtl: {seekInFlight: false},
    dmClock: {pause() {}, start() {}, stop() {}},
    cancelAudioGate() {this.audioGateGeneration++;},
    gateAudioStart() {gates++; this.audioStartPending = true;}, tryStartGatedAudio() {},
    pauseAudioForSync(audio) {return audio.pause();},
    audioPlayer: {state: 'playing', setVolume() {}, pause() {
      pauses++; return new Promise(resolve => {finishPause = resolve;});
    }}};
  new Function('p', 'media', 'setTimeout', 'clearTimeout', 'const DEBUG = false;\n' + code).call(h, p,
    {BufferingInfoType: {BUFFERING_START: 0, BUFFERING_END: 1}},
    callback => {timer = callback; return 1;}, () => {timer = null;});
  return {h, start: () => handler(0, 0), end: () => handler(1, 0),
    fire: () => timer(), resolve: () => finishPause(),
    pauses: () => pauses, gates: () => gates, timer: () => timer};
}
test('short speed-change buffering does not pause audio, sustained buffering still does', () => {
  const f = bufferHarness(); f.start(); assert.equal(f.pauses(), 0);
  f.end(); assert.equal(f.timer(), null); assert.equal(f.pauses(), 0);
  f.start(); f.fire(); assert.equal(f.pauses(), 1);
});
test('buffer end during first-frame recovery retains the audio restart request', async () => {
  const f = bufferHarness(); f.start(); f.fire();
  f.h.seekRecoveryActive = true;
  f.end(); f.resolve(); await flush();
  assert.equal(f.h.buffering, true);
  assert.equal(f.h.audioStartPending, true);
  assert.equal(f.gates(), 1);
});
test('seek supersedes a delayed buffer completion without another audio seek', async () => {
  const f = bufferHarness(); f.start(); f.fire(); f.end();
  f.h.cancelAudioGate(); // seek owns audio now, even if it finishes before the old callback
  f.resolve(); await flush(); assert.equal(f.gates(), 0);
});
test('delayed speed buffer timer cannot pause audio after a seek takes ownership', () => {
  const f = bufferHarness(); f.start(); f.h.seekLocked = true; f.fire();
  assert.equal(f.pauses(), 0);
});
test('seek waits for an already issued audio pause before seeking or resuming', async () => {
  let resolvePause;
  const pause = new Promise(resolve => {resolvePause = resolve;});
  const f = fixture(() => pause);
  f.audio.pause = () => assert.fail('must not enqueue a second pause');
  f.ctl.request(10000, true, true); f.fire(60); await flush();
  assert.deepEqual(f.video.calls, []); assert.deepEqual(f.audio.calls, []);
  resolvePause(); await flush();
  assert.deepEqual(f.video.calls, [10000]); assert.deepEqual(f.audio.calls, [10000]);
});
test('keyframe recovery also verifies missing audio seekDone at its actual landing point', async () => {
  const f = fixture(); f.ctl.request(10000, false, true); f.fire(60); await flush();
  assert.deepEqual(f.audio.calls, []);
  f.ctl.onVideoSeekDone(f.video, 7200); f.audio.currentTime = 7200; f.fire(900);
  assert.deepEqual(f.done, [[true, 7200]]);
});
