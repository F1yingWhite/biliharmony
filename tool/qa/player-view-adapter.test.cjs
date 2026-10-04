const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const {fixture, tick} = require('./player-session-fixture.cjs');
const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/components/player/PlayerView.ets'), 'utf8');
function between(a, b) {
  const start = source.indexOf(a), end = source.indexOf(b, start);
  assert.ok(start >= 0 && end > start, 'native UI adapter anchors: ' + a);
  return source.slice(start, end);
}

// Only ArkUI adapters need extraction. They receive events from the whole real
// session/pair/seek/sync graph; AVPlayer and window/Canvas effects remain fake.
function viewFixture() {
  const f = fixture(), effects = [];
  const stateBody = between('    state: (state: PlayerPlaybackState): void => {', '    event: (event: PlayerPlaybackEvent)')
    .replace('    state: (state: PlayerPlaybackState): void => {', '  publish(state: PlayerPlaybackState): void {').replace(/},\s*$/, '}');
  const methods = between('  private onPlaybackEvent(', '  private auxiliary:') +
    between('  endReplay():', '  /** 结束画面关闭：') +
    between('  private requestSeekPreview(', '  private closeSeekPreview():');
  const code = ts.transpileModule('class View {\n' + stateBody + methods + '\n}; return View;',
    {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  const {PlayerPlaybackConfig} = f.load('components/player/PlayerPlaybackConfig');
  const View = new Function('Immersive', 'clearTimeout', 'PlayerPlaybackConfig', code)(
    {setKeepScreenOn: value => effects.push(['screen', value])}, f.globals.clearTimeout, PlayerPlaybackConfig);
  const page = Object.assign(new View(), {
    playback: f.session, playing: false, prepared: false, curTime: 0, playheadSec: 0, duration: 0,
    firstFrameShown: false, seekPreviewSeconds: -1, seekPreviewFrame: {}, compactMode: true, fullscreen: false,
    hideTimer: -1, timerFireAt: 0, lastSystemPlaybackBucket: -1, playMode: 0, endScreenOpen: true,
    dmEngine: {lastPlayerTime: 0, list: ['loaded'], setPlaybackRate: rate => effects.push(['rate', rate])},
    dmClock: {start: () => effects.push(['clock', 'start']), pause: () => effects.push(['clock', 'pause']), stop: () => effects.push(['clock', 'stop'])},
    pictureInPicture: {sync: () => effects.push(['pip'])},
    auxiliary: {prefetch: seconds => effects.push(['prefetch', seconds])},
    interactionCtl: {update: seconds => effects.push(['interaction.time', seconds]),
      resetForReplay: () => effects.push(['interaction.replay'])},
    sponsorCtl: {maybeSkipSponsor: () => false, resetForReplay: () => effects.push(['sponsor.replay'])},
    seekTargetCtl: {show: value => effects.push(['seek.target', value])},
    onPlayingChange: value => effects.push(['playing', value]), onFirstFrameShown: () => effects.push(['firstFrame']),
    scheduleDeferredLoads: () => effects.push(['deferred']), scheduleControlsHide: () => effects.push(['hide']),
    ensureAVSession: () => effects.push(['av.ensure']), updateAVSessionPlaybackState: () => effects.push(['av.state']),
    updateAVSessionMetadata: () => effects.push(['av.metadata']), onEnded: () => effects.push(['ended']),
    applyPgcSkipIntroOnce() {}, clearSeekPreviewInteraction() {}, closeSettingPanels() {}, release() {},
    resetDanmakuAt: seconds => effects.push(['dm.reset', seconds]), onProgress: seconds => effects.push(['progress', seconds]),
    updateSubtitle: seconds => effects.push(['subtitle', seconds]), spawnDanmaku: seconds => effects.push(['dm.spawn', seconds]),
    reportContinueWatching: seconds => effects.push(['continue', seconds]), pauseForTimer: () => f.session.pause(),
    onResumeRequest: () => effects.push(['resume']), onVideoSizeChange: (width, height) => effects.push(['size', width, height]),
  });
  const original = f.session.observer;
  f.session.observer = {policy: original.policy,
    state(value) {original.state(value); page.publish(value);},
    event(value) {original.event(value); page.onPlaybackEvent(value);},
    progress(seconds, background) {return page.onPlaybackProgress(seconds, background);}};
  return {...f, page, effects};
}

test('player UI adapter: native first frame, size, play and pause update cover, AVSession and clock', async () => {
  const f = viewFixture(); const {video} = await f.boot(); f.prepared();
  assert.equal(f.page.prepared, true); assert.equal(f.page.firstFrameShown, false);
  assert.deepEqual(f.effects.find(e => e[0] === 'size'), ['size', 1920, 1080]);
  video.emit('stateChange', 'playing'); assert.equal(f.page.playing, true);
  assert.equal(f.effects.filter(e => e[0] === 'firstFrame').length, 0);
  video.emit('startRenderFrame'); assert.equal(f.page.firstFrameShown, true);
  assert.equal(f.effects.filter(e => e[0] === 'firstFrame').length, 1);
  assert.equal(f.effects.filter(e => e[0] === 'deferred').length, 1);
  f.session.pause(); assert.equal(f.page.playing, false); assert.equal(f.page.showControls, true);
  assert.ok(f.effects.some(e => e[0] === 'av.state')); assert.ok(f.effects.some(e => e[0] === 'clock' && e[1] === 'pause'));
  f.session.deactivate();
});

test('player UI adapter: timeline reaches subtitles, danmaku, prefetch and continue-watching', async () => {
  const f = viewFixture(); const {video} = await f.boot(); f.playing();
  video.emit('durationUpdate', 100000); video.currentTime = 5050; video.emit('timeUpdate', 5050);
  assert.equal(f.page.duration, 100); assert.equal(f.page.curTime, 5.05); assert.equal(f.page.playheadSec, 5.05);
  for (const kind of ['subtitle', 'dm.spawn', 'prefetch', 'continue', 'interaction.time']) assert.ok(f.effects.some(e => e[0] === kind && e[1] === 5.05));
  video.emit('timeUpdate', 5200); assert.equal(f.page.curTime, 5.05, 'reactive time remains second-granular');
  assert.equal(f.page.playheadSec, 5.2); f.session.deactivate();
});

test('player UI adapter: replay retains loaded danmaku while the core performs the seek', async () => {
  const f = viewFixture(); const {video, audio} = await f.boot(); f.playing(); f.page.endReplay();
  f.advance(60); await tick();
  assert.deepEqual(f.page.dmEngine.list, ['loaded']); assert.equal(f.page.endScreenOpen, false);
  assert.equal(f.calls(video, 'seek').at(-1)[1], 0); assert.equal(f.calls(audio, 'seek').at(-1)[1], 0);
  assert.ok(f.effects.some(e => e[0] === 'sponsor.replay')); assert.ok(f.effects.some(e => e[0] === 'dm.reset' && e[1] === 0));
  assert.ok(f.effects.some(e => e[0] === 'interaction.replay'), 'replay restores dismissed UP interaction cards');
  f.session.deactivate();
});

test('player UI adapter: seek dispatch clears unrelated preview and completion clears the target overlay', async () => {
  const f = viewFixture(); const {video, audio} = await f.boot(); f.playing(); f.session.seekTo(12);
  f.advance(60); await tick(); assert.equal(f.page.seekPreviewFrame, null); assert.equal(f.page.curTime, 12);
  assert.ok(f.effects.some(e => e[0] === 'prefetch' && e[1] === 12), 'paused/active seek should request the target danmaku segment');
  assert.ok(f.effects.some(e => e[0] === 'interaction.time' && e[1] === 12), 'seek updates command-card visibility while paused');
  video.currentTime = audio.currentTime = 12000; video.emit('seekDone', 12000); audio.emit('seekDone', 12000);
  assert.ok(f.effects.some(e => e[0] === 'seek.target' && e[1] === -1)); f.session.deactivate();
});

test('player UI adapter: seek previews use the actual quality and CDN source with playback headers', async () => {
  const f = viewFixture(); const {video} = await f.boot(); const requests = [];
  f.page.seekPreviewCtl = {request: (...args) => requests.push(args)};
  f.page.requestSeekPreview(3); assert.equal(requests.at(-1)[4], 'video-primary');
  video.emit('error', {message: 'retry'}); await tick(); await tick();
  f.page.requestSeekPreview(3); assert.equal(requests.at(-1)[4], 'video-backup');
  const quality = f.session.changeQuality(64);
  f.apiCalls[0].resolve({urls: ['quality'], audioUrls: [], qualities: [], quality: 64}); await quality;
  f.page.requestSeekPreview(3); assert.equal(requests.at(-1)[4], 'quality');
  assert.equal(requests.at(-1)[5].Referer, 'https://www.bilibili.com/'); f.session.deactivate();
});
