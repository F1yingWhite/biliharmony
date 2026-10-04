const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture, deferred, tick} = require('./player-session-fixture.cjs');

function completeSeek(video, audio, target) {
  video.currentTime = audio.currentTime = target;
  video.emit('seekDone', target);
  audio.emit('seekDone', target);
}

for (const stage of ['startup', 'resume']) {
  test(`audio sync: ${stage} freezes video while audio positioning is delayed`, async () => {
    const f = fixture(); const {video, audio} = await f.boot();
    if (stage === 'resume') {f.playing(); f.session.pause();}
    video.currentTime = 5000; audio.currentTime = 4500;
    if (stage === 'startup') f.prepared(); else f.session.toggle();
    const audioPlays = f.calls(audio, 'play').length;
    video.emit('stateChange', 'playing'); video.emit('startRenderFrame'); video.emit('timeUpdate', 5000);
    f.advance(60); await tick();
    assert.equal(video.state, 'paused');
    assert.equal(audio.state === 'playing', false);
    assert.equal(f.calls(video, 'seek').at(-1)[1], 5000);
    assert.equal(f.calls(audio, 'seek').at(-1)[1], 5000);
    video.emit('seekDone', 5000); f.advance(500);
    assert.equal(video.state, 'paused', 'the video clock must not advance while audio seeks');
    assert.equal(f.calls(audio, 'play').length, audioPlays);
    audio.currentTime = 5000; audio.emit('seekDone', 5000);
    assert.equal(video.state, 'playing'); assert.equal(audio.state, 'playing');
    assert.equal(f.calls(audio, 'play').length, audioPlays + 1);
    f.session.deactivate(); assert.equal(f.timers.size, 0);
  });
}

for (const drift of [-2000, 2000]) {
  test(`audio sync: sustained ${drift}ms drift uses one dual-track positioning barrier`, async () => {
    const f = fixture(); const {video, audio} = await f.boot(); f.playing();
    video.currentTime = audio.currentTime = 10000; video.emit('timeUpdate', 10000);
    audio.currentTime += drift;
    video.emit('timeUpdate', 10000); video.emit('timeUpdate', 10000);
    assert.equal(f.state().seekLocked, false, 'two samples do not trigger a hard correction');
    const audioPlays = f.calls(audio, 'play').length;
    video.emit('timeUpdate', 10000);
    assert.equal(f.state().seekLocked, true);
    f.advance(60); await tick();
    assert.equal(video.state, 'paused'); assert.equal(audio.state, 'paused');
    assert.deepEqual(f.calls(video, 'seek').map(call => call[1]), [10000]);
    assert.deepEqual(f.calls(audio, 'seek').map(call => call[1]), [10000]);
    for (let i = 0; i < 5; i++) video.emit('timeUpdate', 10000);
    completeSeek(video, audio, 10000);
    assert.equal(f.calls(audio, 'play').length, audioPlays + 1);
    assert.equal(f.state().seekLocked, false); f.session.deactivate();
  });
}

for (const action of ['pause', 'stopForNavigation']) {
  test(`audio sync: ${action} prevents a delayed positioning callback from restarting tracks`, async () => {
    const f = fixture(); const {video, audio} = await f.boot(); f.playing();
    video.currentTime = 5000; audio.currentTime = 0;
    f.session.audioSync.gateAudioStart(); f.session.audioSync.tryStartGatedAudio();
    f.advance(60); await tick();
    f.session[action]();
    const videoPlays = f.calls(video, 'play').length, audioPlays = f.calls(audio, 'play').length;
    completeSeek(video, audio, 5000); f.advance(5000); await tick();
    assert.equal(f.calls(video, 'play').length, videoPlays);
    assert.equal(f.calls(audio, 'play').length, audioPlays);
    assert.equal(f.state().playing, false); assert.equal(f.state().seekLocked, false);
    f.session.deactivate(); assert.equal(f.timers.size, 0);
  });
}

test('audio sync: already aligned startup plays audio without another seek', async () => {
  const f = fixture(); const {video, audio} = await f.boot();
  video.currentTime = 50; audio.currentTime = 0; f.playing();
  assert.equal(f.calls(audio, 'play').length, 1);
  assert.equal(f.calls(video, 'seek').length, 0); assert.equal(f.calls(audio, 'seek').length, 0);
  f.session.deactivate();
});

test('audio sync: buffer recovery waits for a delayed audio pause before aligning both tracks', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); f.playing();
  video.currentTime = audio.currentTime = 5000; video.emit('timeUpdate', 5000);
  const pause = deferred();
  audio.pause = () => {audio.calls.push(['pause']); return pause.promise;};
  video.emit('bufferingUpdate', f.media.BufferingInfoType.BUFFERING_START, 0);
  video.currentTime = 6000;
  const audioPlays = f.calls(audio, 'play').length;
  video.emit('bufferingUpdate', f.media.BufferingInfoType.BUFFERING_END, 0);
  assert.equal(f.calls(audio, 'play').length, audioPlays);
  audio.state = 'paused'; pause.resolve(); await tick();
  f.advance(60); await tick();
  assert.equal(video.state, 'paused');
  assert.deepEqual(f.calls(video, 'seek').map(call => call[1]), [6000]);
  assert.deepEqual(f.calls(audio, 'seek').map(call => call[1]), [6000]);
  video.emit('seekDone', 6000); f.advance(500);
  assert.equal(video.state, 'paused'); assert.equal(f.calls(audio, 'play').length, audioPlays);
  audio.currentTime = 6000; audio.emit('seekDone', 6000);
  assert.equal(video.state, 'playing'); assert.equal(audio.state, 'playing'); f.session.deactivate();
});

for (const [rate, drift] of [[8, -500], [0.125, 500]]) {
  test(`audio sync: ${rate}x speed boundary still recovers a ${drift}ms drift`, async () => {
    const f = fixture(); const {video, audio} = await f.boot(); f.playing(); f.session.setSpeed(rate);
    f.advance(3100);
    video.currentTime = audio.currentTime = 10000; video.emit('timeUpdate', 10000);
    audio.currentTime += drift;
    for (let i = 0; i < 3; i++) video.emit('timeUpdate', 10000);
    f.advance(60); await tick();
    assert.equal(video.state, 'paused'); assert.equal(audio.state, 'paused');
    assert.equal(f.calls(video, 'seek').at(-1)[1], 10000);
    assert.equal(f.calls(audio, 'seek').at(-1)[1], 10000);
    completeSeek(video, audio, 10000);
    assert.equal(f.state().playbackRate, rate); f.session.deactivate();
  });
}
