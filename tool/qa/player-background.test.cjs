const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture, tick} = require('./player-session-fixture.cjs');
const plays = f => f.players.reduce((count, player) => count + f.calls(player, 'play').length, 0);

test('preparing then background then prepared never starts playback when disabled', async () => {
  const f = fixture(); await f.boot(); f.policy.background = true; f.session.onBackgroundChanged(); f.prepared();
  assert.equal(plays(f), 0); assert.equal(f.session.shouldPlayAfterPrepare, false);
  f.policy.background = false; f.session.onBackgroundChanged(); f.session.startPrepared();
  assert.equal(plays(f), 0, 'returning does not revive cancelled autoplay');
  f.session.toggle(); assert.equal(plays(f), 1); f.session.deactivate();
});

test('a source prepared while already in background checks current policy without another Watch event', async () => {
  const f = fixture({background: true}); await f.boot(); f.prepared();
  assert.equal(plays(f), 0); assert.equal(f.session.shouldPlayAfterPrepare, false); f.session.deactivate();
});

test('seek completion captured before background cannot resume either prepared track', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); f.playing(); f.session.seekTo(4); f.advance(60); await tick();
  f.policy.background = true; f.session.onBackgroundChanged(); const before = plays(f);
  video.currentTime = 4000; audio.currentTime = 4000; video.emit('seekDone', 4000); audio.emit('seekDone', 4000);
  assert.equal(plays(f), before); assert.equal(f.session.seek.seekResumePlaying, false);
  assert.equal(f.state().seekLocked, false); assert.equal(f.state().buffering, false); f.session.deactivate();
});

test('late audio alignment completion checks background policy independently of playing flag', async () => {
  const f = fixture(); const {audio} = await f.boot(); f.playing(); const before = plays(f);
  f.policy.background = true; f.session.audioSync.finishGatedAudioStart(audio);
  assert.equal(plays(f), before); assert.equal(f.session.audioSync.audioStartPending, false); f.session.deactivate();
});

test('late native playing event is paused instead of reactivating a disabled background session', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); f.prepared();
  f.policy.background = true; audio.state = 'playing'; const before = plays(f); video.emit('stateChange', 'playing');
  assert.equal(f.state().playing, false); assert.equal(video.state, 'paused'); assert.equal(audio.state, 'paused');
  assert.equal(plays(f), before); f.session.deactivate();
});

test('late native audio playing event pauses an audio start that was already submitted before background', async () => {
  const f = fixture(); const {audio} = await f.boot(); f.prepared();
  f.policy.background = true; f.session.onBackgroundChanged(); audio.emit('stateChange', 'playing');
  assert.equal(audio.state, 'paused'); assert.equal(f.calls(audio, 'pause').length, 1); f.session.deactivate();
});

test('exhausted seek recovery cannot restart video in a disabled background session', async () => {
  const f = fixture(); await f.boot(); f.prepared(); f.policy.background = true;
  f.session.seekRecoveryAttempts = 1; f.session.seek.seekResumePlaying = true; const before = plays(f);
  await f.session.recoverSeek(4000); assert.equal(plays(f), before); f.session.deactivate();
});

for (const mode of ['foreground', 'backgroundPlaybackEnabled', 'pipActive', 'pipStarting', 'pipRestoring']) {
  test(`prepared and seek restoration stay allowed for ${mode}`, async () => {
    const f = fixture({background: mode !== 'foreground', allowBackground: mode === 'backgroundPlaybackEnabled',
      pipKeepsAlive: mode.startsWith('pip'), pipVisible: mode === 'pipActive' || mode === 'pipStarting'});
    const {video, audio} = await f.boot(); f.session.onBackgroundChanged(); f.prepared();
    assert.equal(f.calls(video, 'play').length, 1);
    f.session.state.playing = true; f.session.seekTo(4); f.advance(60); await tick();
    const videoBefore = f.calls(video, 'play').length, audioBefore = f.calls(audio, 'play').length;
    video.currentTime = 4000; audio.currentTime = 4000; video.emit('seekDone', 4000); audio.emit('seekDone', 4000);
    assert.equal(f.calls(video, 'play').length, videoBefore + 1); assert.equal(f.calls(audio, 'play').length, audioBefore + 1);
    f.session.deactivate();
  });
}

test('background audio keeps logical playback and returns through the real dual-track seek controller', async () => {
  const f = fixture({allowBackground: true}); const {video, audio} = await f.boot(); f.playing();
  f.policy.background = true; f.session.onBackgroundChanged();
  assert.equal(video.state, 'paused'); assert.equal(audio.state, 'playing'); assert.equal(f.state().playing, true);
  audio.currentTime = 12000; audio.emit('timeUpdate', 12000); assert.equal(f.progress.at(-1).background, true);
  f.policy.background = false; f.session.onBackgroundChanged(); f.advance(60); await tick();
  assert.equal(f.calls(video, 'seek').at(-1)[1], 12000); assert.equal(f.calls(audio, 'seek').at(-1)[1], 12000);
  video.currentTime = 12000; video.emit('seekDone', 12000); audio.emit('seekDone', 12000);
  assert.equal(video.state, 'playing'); assert.equal(audio.state, 'playing'); f.session.deactivate();
});
