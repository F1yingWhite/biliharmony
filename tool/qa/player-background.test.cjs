// Execute production lifecycle/start/seek completion code; only platform effects are faked.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || root;
const source = fs.readFileSync(path.join(sourceRoot, 'components/player/PlayerView.ets'), 'utf8').replace(/\r\n/g, '\n');
function between(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, 'production anchors: ' + start);
  return source.slice(a, b);
}
const seekBody = between('          this.seekRecoveryAttempts = 0;', '        },\n        (video: media.AVPlayer | null, targetMs: number): void => {');
const playingBody = between("        } else if (state === 'playing') {", "        } else if (state === 'paused' && (this.backgroundAudioOnly")
  .slice("        } else if (state === 'playing') {".length);
const moduleBody = 'export class Harness {\n' +
  between('  onAppBackgroundChanged():', '  private setBackgroundPlayback(') +
  between('  private tryStartPreparedPlayers():', '  /** 起播时先等待') +
  between('  private finishGatedAudioStart(', '  /** 所有自动音轨暂停') +
  between('  togglePlay():', '  /** 结束画面「重播」') +
  between('  private async recoverPlayersAfterSeekStall(', '  toggleFullscreen():') +
  '  seekCompleted(resume: boolean, targetMs: number): void {\n' + seekBody + '\n}\n' +
  '  bindAudioEvents(audio: any): void {\n' + between("    audio.on('stateChange'", "    audio.on('playbackRateDone'") + '\n}\n' +
  '  playingEvent(p: any): void {\n' + playingBody + '\n}\n}\n';
const mod = {exports: {}};
new Function('module', 'exports', 'Immersive', ts.transpileModule(moduleBody, {
  compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
}).outputText)(mod, mod.exports, {setKeepScreenOn() {}});

function setup(patch = {}) {
  const effects = [];
  const player = name => ({state: 'prepared', currentTime: 4000, handlers: {},
    on(event, handler) {this.handlers[event] = handler;},
    play() {effects.push(name + '.play'); this.state = 'playing'; return Promise.resolve();},
    pause() {effects.push(name + '.pause'); this.state = 'paused'; return Promise.resolve();}});
  const view = Object.assign(new mod.exports.Harness(), {
    destroyed: false, appInBackground: false, backgroundPlaybackEnabled: false,
    pipActive: false, pipStarting: false, pipRestoring: false,
    playing: false, prepared: false, audioPrepared: false, player: player('video'), audioPlayer: null,
    shouldPlayAfterPrepare: true, resumeAfterPrepare: -1, seekRecoveryAttempts: 0,
    audioGateTimer: -1, audioStartPending: false, buffering: true, seekLocked: false,
    seekCtl: {seekResumePlaying: true, cancel() {}}, seekTargetCtl: {show() {}},
    dmClock: {pause() {}, start() {}, release() {}},
    cancelAudioGate() {this.audioStartPending = false;}, cancelFirstFrameMute() {},
    disarmFirstFrameMute() {}, armFirstFrameMute() {}, restoreUserVolume() {},
    gateAudioStart() {this.audioStartPending = true;},
    resetDanmakuAt() {}, spawnDanmaku() {}, leaveBackgroundAudioOnly() {},
    enterBackgroundAudioOnly() {effects.push('backgroundAudio');},
    onPlayingChange() {}, updateAVSessionPlaybackState() {}, onResumeRequest() {},
    scheduleControlsHide() {}, applyPgcSkipIntroOnce() {}, revealFirstFrameIfReady() {}, ensureAVSession() {},
    ...patch,
  });
  return {view, effects, makeAudio() {view.audioPlayer = player('audio'); view.audioPrepared = true;}};
}

test('preparing then background then prepared never starts playback when disabled', () => {
  const {view, effects} = setup();
  view.appInBackground = true; view.onAppBackgroundChanged();
  view.prepared = true; view.tryStartPreparedPlayers();
  assert.deepEqual(effects, []);
  assert.equal(view.shouldPlayAfterPrepare, false);
  view.appInBackground = false; view.onAppBackgroundChanged();
  view.tryStartPreparedPlayers();
  assert.deepEqual(effects, [], 'returning does not revive cancelled autoplay');
  view.togglePlay();
  assert.deepEqual(effects, ['video.play'], 'explicit foreground play remains usable');
});

test('a source prepared while already in background checks current policy without another Watch event', () => {
  const {view, effects} = setup({appInBackground: true, prepared: true});
  view.tryStartPreparedPlayers();
  assert.deepEqual(effects, []);
  assert.equal(view.shouldPlayAfterPrepare, false);
});

test('seek completion captured before background cannot resume either prepared track', () => {
  const f = setup({prepared: true, playing: false, seekLocked: true}); f.makeAudio();
  f.view.appInBackground = true; f.view.onAppBackgroundChanged();
  f.view.seekCompleted(true, 4000);
  assert.deepEqual(f.effects, []);
  assert.equal(f.view.seekCtl.seekResumePlaying, false);
  assert.equal(f.view.seekLocked, false);
  assert.equal(f.view.buffering, false);
});

test('late audio alignment completion checks background policy independently of playing flag', () => {
  const f = setup({appInBackground: true, prepared: true, playing: true}); f.makeAudio();
  f.view.finishGatedAudioStart(f.view.audioPlayer);
  assert.deepEqual(f.effects, []);
  assert.equal(f.view.audioStartPending, false);
});

test('late native playing event is paused instead of reactivating a disabled background session', () => {
  const f = setup({appInBackground: true, prepared: true}); f.makeAudio();
  f.view.player.state = 'playing'; f.view.audioPlayer.state = 'playing';
  f.view.playingEvent(f.view.player);
  assert.equal(f.view.playing, false);
  assert.equal(f.view.player.state, 'paused');
  assert.equal(f.view.audioPlayer.state, 'paused');
  assert.equal(f.effects.some(x => x.endsWith('.play')), false);
});

test('late native audio playing event pauses an audio start that was already submitted before background', () => {
  const f = setup({prepared: true}); f.makeAudio();
  f.view.bindAudioEvents(f.view.audioPlayer);
  f.view.appInBackground = true; f.view.onAppBackgroundChanged();
  f.view.audioPlayer.state = 'playing'; // Native completion arrives after the background Watch.
  f.view.audioPlayer.handlers.stateChange('playing');
  assert.equal(f.view.audioPlayer.state, 'paused');
  assert.deepEqual(f.effects, ['audio.pause']);
});

test('exhausted seek recovery cannot restart video in a disabled background session', async () => {
  const f = setup({appInBackground: true, prepared: true, seekRecoveryAttempts: 1});
  await f.view.recoverPlayersAfterSeekStall(f.view.player, 4000);
  assert.deepEqual(f.effects, []);
});

for (const policy of ['foreground', 'backgroundPlaybackEnabled', 'pipActive', 'pipStarting', 'pipRestoring']) {
  test(`prepared and seek restoration stay allowed for ${policy}`, () => {
    const f = setup({prepared: true, appInBackground: policy !== 'foreground',
      ...(policy === 'foreground' ? {} : {[policy]: true})});
    f.makeAudio();
    if (f.view.appInBackground) f.view.onAppBackgroundChanged();
    f.view.tryStartPreparedPlayers();
    assert.ok(f.effects.includes('video.play'));
    f.effects.length = 0; f.view.player.state = 'paused';
    f.view.seekCompleted(true, 4000);
    assert.deepEqual(f.effects, ['video.play', 'audio.play']);
  });
}
