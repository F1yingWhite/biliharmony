const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
function fixture() {
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
    () => {}, () => {}, (...args) => done.push(args), (...args) => stalled.push(args));
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
  assert.deepEqual(f.audio.calls, [10000, 7200]); assert.equal(f.done.length, 0);
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
  const start = source.indexOf('  private checkAudioSync(');
  const end = source.indexOf('  private invalidatePlayerCreation()', start);
  assert.ok(start >= 0 && end > start);
  const module = {exports: {}};
  new Function('module', 'exports', ts.transpileModule('export class Harness {\n' + source.slice(start, end) + '\n}', {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText)(module, module.exports);
  const h = new module.exports.Harness();
  Object.assign(h, {playing: true, audioPrepared: true, audioDriftSamples: 0, lastAudioSyncAtMs: -1,
    seekCtl: {seekInFlight: false}, audioPlayer: {state: 'playing', currentTime: 12000}, calls: [],
    seekTo(time) {this.calls.push(time);}});
  return h;
}
test('sustained drift uses a paired correction and respects cooldown', () => {
  const h = syncHarness();
  h.checkAudioSync(10000); h.checkAudioSync(10000); assert.deepEqual(h.calls, []);
  h.checkAudioSync(10000); assert.deepEqual(h.calls, [10]);
  for (let i = 0; i < 10; i++) h.checkAudioSync(10000);
  assert.deepEqual(h.calls, [10]);
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
