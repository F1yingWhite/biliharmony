const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture, deferred, tick} = require('./player-session-fixture.cjs');

test('pair: video prepared waits for the independent audio creation and first-frame gate', async () => {
  const f = fixture(), sound = deferred(), video = f.player('video'), audio = f.player('audio');
  f.createQueue.push(Promise.resolve(video), sound.promise); await f.boot();
  video.emit('stateChange', 'prepared'); assert.equal(f.calls(video, 'play').length, 0);
  sound.resolve(audio); await tick(); audio.emit('stateChange', 'prepared');
  assert.equal(f.calls(video, 'play').length, 1); assert.equal(f.calls(audio, 'play').length, 0);
  video.emit('stateChange', 'playing'); assert.equal(f.state().firstFrameShown, false);
  video.emit('startRenderFrame'); assert.equal(f.state().firstFrameShown, true);
  assert.equal(f.calls(audio, 'play').length, 1); f.session.deactivate();
});

test('pair: a late create result is released without binding source after exit', async () => {
  const f = fixture(), pending = deferred(), old = f.player(); f.createQueue.push(pending.promise);
  f.session.activate(f.source()); const work = f.session.setSurface('surface'); await tick(); f.session.deactivate();
  pending.resolve(old); await work;
  assert.equal(f.calls(old, 'release').length, 1); assert.equal(f.calls(old, 'source').length, 0);
  assert.equal(f.session.pair.video, null); assert.equal(f.timers.size, 0);
});

test('pair: source replacement waits for every detached decoder release before reusing Surface', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); const release = deferred();
  video.release = () => release.promise;
  const first = f.session.replaceSource(f.source({cid: 2, urls: ['intermediate']}));
  const next = f.session.replaceSource(f.source({cid: 3, urls: ['latest']})); await tick();
  assert.equal(f.creations.length, 2); assert.equal(f.calls(audio, 'release').length, 1);
  release.resolve(); await Promise.all([first, next]); await tick();
  assert.equal(f.session.pair.video.source.url, 'latest'); assert.equal(f.creations.length, 4); f.session.deactivate();
});

test('pair: delayed duration, state and error events never write to the replacement session', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); await f.session.replaceSource(f.source({cid: 2}));
  const count = f.states.length, creates = f.creations.length;
  video.emit('durationUpdate', 999000); video.emit('stateChange', 'playing'); video.emit('error', {message: 'stale'});
  audio.emit('error', {message: 'stale'}); await tick();
  assert.equal(f.states.length, count); assert.equal(f.creations.length, creates); f.session.deactivate();
});

test('session: serial seek waits for both tracks and holds the target through old timeUpdate', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); f.playing();
  f.session.seekTo(10.125); f.advance(60); await tick();
  assert.equal(f.calls(video, 'seek').at(-1)[1], 10125); assert.equal(f.calls(audio, 'seek').at(-1)[1], 10125);
  video.emit('timeUpdate', 1000); assert.equal(f.state().position, 10.125);
  audio.currentTime = 10125; audio.emit('seekDone', 10125); assert.equal(f.state().seekLocked, true);
  video.currentTime = 10125; video.emit('seekDone', 10125); assert.equal(f.state().seekLocked, false);
  assert.equal(f.calls(video, 'play').length, 2); assert.equal(f.calls(audio, 'play').length, 2);
  assert.equal(f.session.isFrameMuted, true); video.emit('timeUpdate', 1000); assert.equal(f.session.isFrameMuted, true);
  video.emit('timeUpdate', 10200); assert.equal(f.session.isFrameMuted, false); f.session.deactivate();
});

test('session: seeking to the endpoint preserves the final half-second instead of completing', async () => {
  const f = fixture(); const {video} = await f.boot(); f.prepared(); video.emit('durationUpdate', 100000);
  f.session.seekTo(100); f.advance(60); await tick();
  assert.equal(f.calls(video, 'seek').at(-1)[1], 99500); f.session.deactivate();
});

test('session: seek-stall recovery cannot overwrite a source selected during release', async () => {
  const f = fixture(); const {video} = await f.boot(); f.playing(); const release = deferred(); video.release = () => release.promise;
  const recovering = f.session.recoverSeek(7000);
  const replacing = f.session.replaceSource(f.source({cid: 2, urls: ['new-video']}));
  release.resolve(); await Promise.all([recovering, replacing]); await tick();
  assert.equal(f.session.pair.video.source.url, 'new-video'); assert.equal(f.session.resumeAfterPrepare, -1);
  assert.equal(f.creations.length, 4); f.session.deactivate();
});

test('session: quality API failure releases its lock and preserves current playback', async () => {
  const f = fixture(); const {video} = await f.boot(); f.playing();
  const work = f.session.changeQuality(64); f.apiCalls[0].reject(Error('offline')); await work;
  assert.equal(f.state().qualityLoading, false); assert.equal(f.session.pair.video, video);
  assert.match(f.state().errorText, /清晰度/); f.session.deactivate();
});

test('session: old quality response after source change cannot replace URLs or clear a newer request lock', async () => {
  const f = fixture(); await f.boot(); f.playing(); const old = f.session.changeQuality(64);
  await f.session.replaceSource(f.source({cid: 2})); const next = f.session.changeQuality(120);
  f.apiCalls[0].resolve({urls: ['old-quality'], audioUrls: [], qualities: [], quality: 64}); await old;
  assert.equal(f.state().qualityLoading, true); assert.notEqual(f.session.pair.video.source.url, 'old-quality');
  f.apiCalls[1].resolve({urls: ['new-quality'], audioUrls: [], qualities: [], quality: 120}); await next;
  assert.equal(f.state().activeQuality, 120); assert.equal(f.session.pair.video.source.url, 'new-quality'); f.session.deactivate();
});

test('session: navigation mutes immediately and cancelled audio alignment cannot resume sound', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); f.playing();
  video.currentTime = 5000; audio.currentTime = 0; const pause = deferred(); audio.pause = () => pause.promise;
  f.session.audioSync.gateAudioStart(); f.session.audioSync.tryStartGatedAudio();
  const before = f.calls(audio, 'play').length; f.session.stopForNavigation(); pause.resolve(); await tick();
  audio.emit('seekDone', 5000); assert.equal(f.calls(audio, 'play').length, before);
  assert.equal(f.state().playing, false); assert.equal(f.calls(audio, 'volume').at(-1)[1], 0);
  f.advance(100); assert.equal(f.calls(audio, 'volume').at(-1)[1], 1); f.session.deactivate();
});

test('session: re-entry keeps current progress paused and cannot jump back to the original initial seek', async () => {
  const f = fixture(); const input = f.source({initialSeek: 20}); await f.boot(input); f.prepared();
  f.session.state.position = 42; f.session.deactivate(); f.session.activate(input); await tick(); f.prepared();
  assert.equal(f.session.seek.pendingSeekMs, 42000); assert.equal(f.session.seek.seekResumePlaying, false); f.session.deactivate();
});

for (const method of ['prepare', 'play']) test(`pair: rejected native ${method} is handled by bounded CDN recovery`, async () => {
  const f = fixture(); const {video} = await f.boot(); video[method] = () => Promise.reject(Error('native'));
  if (method === 'prepare') video.emit('stateChange', 'initialized'); else f.prepared();
  await tick(); await tick(); assert.equal(f.session.sourceIndex, 1); assert.notEqual(f.session.pair.video, video);
  f.session.deactivate();
});

test('session: initial CDN failure retains autoplay intent through the replacement handshake', async () => {
  const f = fixture(); const {video} = await f.boot();
  video.emit('error', {message: 'primary unavailable'}); await tick(); await tick();
  const backup = f.session.pair.video; f.prepared();
  assert.notEqual(backup, video); assert.equal(f.calls(backup, 'play').length, 1); f.session.deactivate();
});

test('session: quality release racing exit never creates a replacement decoder', async () => {
  const f = fixture(); const {video} = await f.boot(); f.playing(); const released = deferred(); video.release = () => released.promise;
  const work = f.session.changeQuality(64);
  f.apiCalls[0].resolve({urls: ['quality'], audioUrls: [], qualities: [], quality: 64}); await tick();
  f.session.deactivate(); released.resolve(); await work;
  assert.equal(f.creations.length, 2); assert.equal(f.session.pair.video, null); assert.equal(f.timers.size, 0);
});

test('session: obsolete mute fallback cannot unmute or cancel a newer frame gate', async () => {
  const f = fixture(); const {audio} = await f.boot(); f.prepared();
  const old = [...f.timers.values()].find(t => t.ms === 900).fn;
  f.session.audioSync.armFirstFrameMute(10000, 1800);
  old(); assert.equal(f.session.isFrameMuted, true);
  assert.equal(f.calls(audio, 'volume').at(-1)[1], 0);
  f.advance(1800); assert.equal(f.session.isFrameMuted, false); f.session.deactivate();
});

test('session: sponsor mute persists through playback restoration and supported speed fallback', async () => {
  const f = fixture({muted: true}); const {video, audio} = await f.boot(); f.playing(); f.advance(900);
  assert.equal(f.calls(video, 'volume').at(-1)[1], 0); assert.equal(f.calls(audio, 'volume').at(-1)[1], 0);
  const setRate = audio.setPlaybackRate;
  audio.setPlaybackRate = rate => {if (rate === 3) throw Error('unsupported'); setRate(rate);};
  f.session.setSpeed(3);
  assert.equal(f.state().playbackRate, 1); assert.equal(f.calls(video, 'rate').at(-1)[1], 1);
  assert.equal(f.calls(audio, 'rate').at(-1)[1], 1); f.session.deactivate();
});

test('session: hold speed retains selected speed and resumes it without seeking either track', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); f.playing(); f.session.setSpeed(1.5);
  video.calls.length = audio.calls.length = 0;
  f.session.beginHold(); assert.equal(f.state().holdSpeedActive, true); assert.equal(f.state().playbackRate, 1.5);
  f.session.endHold(); assert.equal(f.state().holdSpeedActive, false);
  assert.deepEqual(f.calls(video, 'rate'), [['rate', 2], ['rate', 1.5]]);
  assert.deepEqual(f.calls(audio, 'rate'), [['rate', 2], ['rate', 1.5]]);
  assert.equal(f.calls(audio, 'seek').length, 0); assert.equal(f.calls(video, 'seek').length, 0); f.session.deactivate();
});

test('session: native playing submitted before navigation stop cannot revive either track', async () => {
  const f = fixture(); const {video, audio} = await f.boot(); f.prepared(); f.session.stopForNavigation();
  video.emit('stateChange', 'playing'); audio.emit('stateChange', 'playing');
  assert.equal(video.state, 'paused'); assert.equal(audio.state, 'paused'); assert.equal(f.state().playing, false);
  f.session.toggle(); assert.equal(video.state, 'playing', 'explicit resume creates a new playback intent'); f.session.deactivate();
});

test('session: a Surface arriving before appearance still autoplays the first source', async () => {
  const f = fixture(); await f.session.setSurface('surface'); f.session.activate(f.source()); await tick(); f.prepared();
  assert.equal(f.calls(f.session.pair.video, 'play').length, 1); f.session.deactivate();
});

test('session: source changed while hidden is adopted on re-entry instead of retaining stale URLs', async () => {
  const f = fixture(); await f.boot(); f.session.deactivate();
  f.session.activate(f.source({cid: 2, urls: ['hidden-change'], initialSeek: 30})); await tick();
  assert.equal(f.session.pair.video.source.url, 'hidden-change'); assert.equal(f.state().position, 30); f.session.deactivate();
});

for (const stage of ['initialized', 'playing']) test(`session: changing a ${stage} Surface rebuilds with the latest native handle`, async () => {
  const f = fixture(); const {video} = await f.boot();
  if (stage === 'playing') {f.playing(); video.currentTime = 17000; video.emit('timeUpdate', 17000);}
  await f.session.setSurface('surface-new'); await tick();
  const next = f.session.pair.video; next.emit('stateChange', 'initialized');
  assert.notEqual(next, video); assert.equal(next.surfaceId, 'surface-new'); assert.equal(f.calls(video, 'release').length, 1);
  if (stage === 'playing') {f.prepared(); assert.equal(f.session.seek.pendingSeekMs, 17000); assert.equal(f.session.seek.seekResumePlaying, true);}
  video.emit('stateChange', 'initialized'); assert.equal(f.calls(video, 'prepare').length, 0, 'old Surface callback is inert');
  f.session.deactivate();
});

for (const replacement of ['quality', 'CDN']) test(`session: native user pause remains paused after ${replacement} replacement`, async () => {
  const f = fixture(); const {video} = await f.boot(); f.playing(); video.emit('stateChange', 'paused');
  assert.equal(f.state().playing, false);
  if (replacement === 'quality') {
    const work = f.session.changeQuality(64);
    f.apiCalls[0].resolve({urls: ['quality'], audioUrls: [], qualities: [], quality: 64}); await work;
  } else {video.emit('error', {message: 'failed'}); await tick(); await tick();}
  f.prepared(); assert.equal(f.calls(f.session.pair.video, 'play').length, 0); f.session.deactivate();
});
