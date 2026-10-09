const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture, deferred, tick} = require('./player-session-fixture.cjs');
const land = (engine, requested, actual = requested) => {engine.currentTime = actual; engine.emit('seek', requested);};

test('session: DASH uses one engine and starts audio and video together without frame gating', async () => {
  const f = fixture(); const {engine} = await f.boot(f.dashSource());
  assert.equal(f.opens.length, 1); assert.equal(f.engines.length, 1);
  assert.equal(engine.audioUrl, 'https://audio.test/main');
  f.prepared(); assert.equal(f.calls(engine, 'play').length, 1);
  engine.emit('state', 'playing'); assert.equal(f.state().firstFrameShown, false);
  engine.emit('frame'); assert.equal(f.state().firstFrameShown, true);
  assert.equal(f.calls(engine, 'seek').length, 0);
  assert.equal(f.calls(engine, 'volume').some(call => call[1] === 0), false); f.session.deactivate();
});

test('session: a late open result is released without binding source after exit', async () => {
  const f = fixture(), pending = deferred(); f.openQueue.push(pending.promise);
  f.session.activate(f.source()); const work = f.session.setSurface('surface'); await tick(); f.session.deactivate();
  const old = f.engines[0]; pending.resolve(); await work;
  assert.equal(f.calls(old, 'release').length, 1); assert.equal(old.videoUrl, undefined);
  assert.equal(f.session.core.engine, null); assert.equal(f.timers.size, 0);
});

test('session: replacement waits for detached release before reusing the Surface', async () => {
  const f = fixture(); const {engine} = await f.boot(); const release = deferred(); engine.release = () => release.promise;
  const first = f.session.replaceSource(f.source({cid: 2, urls: ['intermediate']}));
  const next = f.session.replaceSource(f.source({cid: 3, urls: ['latest']})); await tick();
  assert.equal(f.opens.length, 1);
  release.resolve(); await Promise.all([first, next]); await tick();
  assert.equal(f.session.core.engine.videoUrl, 'latest'); assert.equal(f.opens.length, 2); f.session.deactivate();
});

test('session: detached duration, state, seek and error callbacks cannot affect a replacement', async () => {
  const f = fixture(); const {engine} = await f.boot(); await f.session.replaceSource(f.source({cid: 2}));
  const count = f.states.length, creates = f.opens.length;
  engine.emit('duration', 999000); engine.emit('state', 'playing');
  engine.emit('seek', 999000); engine.emit('error', 'stale'); await tick();
  assert.equal(f.states.length, count); assert.equal(f.opens.length, creates); f.session.deactivate();
});

test('session: seek holds requested progress, lands on the real clock and does not pause or replay', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing();
  f.session.seekTo(10.125); f.advance(60); await tick();
  assert.equal(f.calls(engine, 'seek').at(-1)[1], 10125);
  engine.emit('time', 1000); assert.equal(f.state().position, 10.125);
  land(engine, 10125, 10180); assert.equal(f.state().seekLocked, false); assert.equal(f.state().position, 10.18);
  assert.equal(f.calls(engine, 'pause').length, 0); assert.equal(f.calls(engine, 'play').length, 1);
  f.session.deactivate();
});

test('session: pause then resume while seek is outstanding waits for completion and pending pause', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing();
  f.session.seekTo(5); f.advance(60); const paused = deferred();
  engine.pause = () => paused.promise;
  f.session.pause(); f.session.toggle();
  assert.equal(f.calls(engine, 'play').length, 1); land(engine, 5000);
  assert.equal(f.calls(engine, 'play').length, 1);
  engine.state = 'paused'; engine.emit('state', 'paused'); paused.resolve(); await tick();
  assert.equal(f.calls(engine, 'play').length, 2); assert.equal(f.state().playing, true); f.session.deactivate();
});

test('session: rapid pause/resume serializes native commands and respects a final pause', async () => {
  for (const finalPause of [false, true]) {
    const f = fixture(); const {engine} = await f.boot(); f.playing(); const paused = deferred();
    engine.pause = () => paused.promise; f.session.pause(); f.session.toggle();
    assert.equal(f.calls(engine, 'play').length, 1);
    if (finalPause) f.session.pause();
    engine.emit('state', 'paused'); paused.resolve(); await tick();
    assert.equal(f.calls(engine, 'play').length, finalPause ? 1 : 2);
    assert.equal(f.state().playing, !finalPause); f.session.deactivate();
  }
});

test('session: endpoint seek preserves the final half-second', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.prepared(); engine.emit('duration', 100000);
  f.session.seekTo(100); f.advance(60); assert.equal(f.calls(engine, 'seek').at(-1)[1], 99500); f.session.deactivate();
});

test('session: seek recovery cannot overwrite a newer selected source during release', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); const release = deferred(); engine.release = () => release.promise;
  const recovering = f.session.recoverSeek(7000); const replacing = f.session.replaceSource(f.source({cid: 2, urls: ['new-video']}));
  release.resolve(); await Promise.all([recovering, replacing]); await tick();
  assert.equal(f.session.core.engine.videoUrl, 'new-video'); assert.equal(f.session.resumeAfterPrepare, -1);
  assert.equal(f.opens.length, 2); f.session.deactivate();
});

test('session: repeated seek timeout stops with an error after one rebuild', async () => {
  const f = fixture(); await f.boot(); f.playing(); f.session.seekTo(7); f.advance(60); f.advance(4000); await tick(); await tick();
  assert.equal(f.opens.length, 2); f.prepared(); f.advance(60); f.advance(4000); await tick();
  assert.equal(f.opens.length, 2); assert.match(f.state().errorText, /定位超时/);
  assert.equal(f.state().playing, false); assert.equal(f.state().seekLocked, false); assert.equal(f.state().buffering, false);
  f.session.deactivate(); assert.equal(f.timers.size, 0);
});

test('session: quality failure clears its loading lock and preserves playback', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); const work = f.session.changeQuality(64);
  f.apiCalls[0].reject(Error('offline')); await work;
  assert.equal(f.state().qualityLoading, false); assert.equal(f.session.core.engine, engine);
  assert.match(f.state().errorText, /清晰度/); f.session.deactivate();
});

test('session: obsolete quality response cannot replace a source or clear a newer request lock', async () => {
  const f = fixture(); await f.boot(); f.playing(); const old = f.session.changeQuality(64);
  await f.session.replaceSource(f.source({cid: 2})); const next = f.session.changeQuality(120);
  f.apiCalls[0].resolve({urls: ['old-quality'], audioUrls: [], qualities: [], quality: 64}); await old;
  assert.equal(f.state().qualityLoading, true);
  f.apiCalls[1].resolve({urls: ['new-quality'], audioUrls: [], qualities: [], quality: 120}); await next;
  assert.equal(f.state().activeQuality, 120); assert.equal(f.session.core.engine.videoUrl, 'new-quality'); f.session.deactivate();
});

test('session: navigation mutes immediately and a delayed pause cannot produce a timed unmute', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); const pause = deferred(); engine.pause = () => pause.promise;
  f.session.stopForNavigation(); assert.equal(f.calls(engine, 'volume').at(-1)[1], 0);
  f.advance(5000); assert.equal(f.calls(engine, 'volume').at(-1)[1], 0);
  engine.emit('state', 'playing'); pause.resolve(); await tick(); assert.equal(f.state().playing, false);
  f.session.toggle(); await tick(); assert.equal(f.calls(engine, 'volume').at(-1)[1], 1); f.session.deactivate();
});

test('session: re-entry restores current progress paused instead of the original initial seek', async () => {
  const f = fixture(); const input = f.source({initialSeek: 20}); await f.boot(input); f.prepared();
  f.session.state.position = 42; f.session.deactivate(); f.session.activate(input); await tick(); f.prepared();
  assert.equal(f.session.seek.pendingSeekMs, 42000); assert.equal(f.session.seek.seekResumePlaying, false); f.session.deactivate();
});

for (const method of ['open', 'play']) test(`session: rejected ${method} uses bounded CDN recovery`, async () => {
  const f = fixture();
  if (method === 'open') f.openQueue.push(Promise.reject(Error('native')));
  const {engine: current} = await f.boot();
  const engine = method === 'open' ? f.engines[0] : current;
  if (method === 'play') {engine.play = () => Promise.reject(Error('native')); f.prepared();}
  await tick(); await tick(); assert.equal(f.session.sourceIndex, 1); assert.notEqual(f.session.core.engine, engine); f.session.deactivate();
});

test('session: initial CDN failure retains autoplay through replacement', async () => {
  const f = fixture(); const {engine} = await f.boot(); engine.emit('error', 'failed'); await tick(); await tick();
  const backup = f.session.core.engine; f.prepared(); assert.notEqual(backup, engine);
  assert.equal(f.calls(backup, 'play').length, 1); f.session.deactivate();
});

test('session: exit racing a quality release never creates another decoder', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); const release = deferred(); engine.release = () => release.promise;
  const work = f.session.changeQuality(64); f.apiCalls[0].resolve({urls: ['quality'], audioUrls: [], qualities: [], quality: 64}); await tick();
  f.session.deactivate(); release.resolve(); await work; assert.equal(f.opens.length, 1);
  assert.equal(f.session.core.engine, null); assert.equal(f.timers.size, 0);
});

test('session: sponsor mute survives restoration and rejected playback speed falls back once', async () => {
  const f = fixture({muted: true}); const {engine} = await f.boot(); f.playing();
  assert.equal(f.calls(engine, 'volume').at(-1)[1], 0); const original = engine.setPlaybackRate;
  engine.setPlaybackRate = rate => {if (rate === 3) throw Error('unsupported'); original(rate);};
  f.session.setSpeed(3); assert.equal(f.state().playbackRate, 1); assert.equal(f.calls(engine, 'rate').at(-1)[1], 1); f.session.deactivate();
});

test('session: hold speed changes a shared rate once and resumes the selected rate without seeking', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.setSpeed(1.5); engine.calls.length = 0;
  f.session.beginHold(); assert.equal(f.state().holdSpeedActive, true); assert.equal(f.state().playbackRate, 1.5);
  f.session.endHold(); assert.equal(f.state().holdSpeedActive, false);
  assert.deepEqual(f.calls(engine, 'rate'), [['rate', 2], ['rate', 1.5]]); assert.equal(f.calls(engine, 'seek').length, 0); f.session.deactivate();
});

test('session: focus interruption cancels temporary speed, pending autoplay and seek resume', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.beginHold(); f.session.seekTo(4);
  engine.emit('interruption'); f.advance(60); land(engine, 4000);
  assert.equal(f.state().holdSpeedActive, false); assert.equal(f.state().playing, false); assert.equal(f.session.shouldPlayAfterPrepare, false);
  assert.equal(f.calls(engine, 'play').length, 1); f.session.deactivate();
});

test('session: a stale speed acknowledgement cannot overwrite a newer request', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.setSpeed(1.5); f.session.setSpeed(2);
  const count = f.events.filter(e => e.kind === 'rate').length; engine.emit('rate', 1.5);
  assert.equal(f.events.filter(e => e.kind === 'rate').length, count); assert.equal(f.state().playbackRate, 2); f.session.deactivate();
});

test('session: a Surface arriving before appearance still autoplays the first source', async () => {
  const f = fixture(); await f.session.setSurface('surface'); f.session.activate(f.source()); await tick(); f.prepared();
  assert.equal(f.calls(f.session.core.engine, 'play').length, 1); f.session.deactivate();
});

test('session: a source changed while hidden is adopted on re-entry', async () => {
  const f = fixture(); await f.boot(); f.session.deactivate();
  f.session.activate(f.source({cid: 2, urls: ['hidden-change'], initialSeek: 30})); await tick();
  assert.equal(f.session.core.engine.videoUrl, 'hidden-change'); assert.equal(f.state().position, 30); f.session.deactivate();
});

for (const stage of ['initialized', 'playing']) test(`session: replacing a ${stage} Surface resumes on the latest handle`, async () => {
  const f = fixture(); const {engine} = await f.boot();
  if (stage === 'playing') {f.playing(); engine.currentTime = 17000; engine.emit('time', 17000);}
  await f.session.setSurface('surface-new'); await tick(); const next = f.session.core.engine; next.emit('state', 'initialized');
  assert.notEqual(next, engine); assert.equal(next.surfaceId, 'surface-new'); assert.equal(f.calls(engine, 'release').length, 1);
  if (stage === 'playing') {f.prepared(); assert.equal(f.session.seek.pendingSeekMs, 17000); assert.equal(f.session.seek.seekResumePlaying, true);}
  const published = f.states.length, commands = next.calls.length;
  engine.emit('state', 'initialized');
  assert.equal(f.states.length, published); assert.equal(next.calls.length, commands); f.session.deactivate();
});

for (const replacement of ['quality', 'CDN']) test(`session: a system pause remains paused after ${replacement} replacement`, async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); engine.emit('state', 'paused');
  if (replacement === 'quality') {const work = f.session.changeQuality(64); f.apiCalls[0].resolve({urls: ['quality'], audioUrls: [], qualities: [], quality: 64}); await work;}
  else {engine.emit('error', 'failed'); await tick(); await tick();}
  f.prepared(); assert.equal(f.calls(f.session.core.engine, 'play').length, 0); assert.equal(f.state().buffering, false); f.session.deactivate();
});

test('session: own paused callback arriving after pause promise and a new play cannot cancel resume', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); const pause = deferred(); engine.pause = () => pause.promise;
  f.session.pause(); f.session.toggle(); engine.state = 'paused'; pause.resolve(); await tick();
  assert.equal(f.calls(engine, 'play').length, 2); engine.emit('state', 'playing');
  engine.emit('state', 'paused');
  assert.equal(f.session.shouldPlayAfterPrepare, true); assert.equal(f.state().playing, true); f.session.deactivate();
});

test('session: a system interruption cancels autoplay even while an own pause callback is outstanding', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); const pause = deferred(); engine.pause = () => pause.promise;
  f.session.pause(); f.session.toggle(); engine.emit('interruption'); engine.emit('state', 'paused');
  pause.resolve(); await tick(); assert.equal(f.state().playing, false); assert.equal(f.calls(engine, 'play').length, 1); f.session.deactivate();
});

for (const newer of ['pause', 'resume']) test(`session: an obsolete play rejection cannot rebuild after a newer ${newer}`, async () => {
  const f = fixture(); const {engine} = await f.boot(); const oldPlay = deferred(), original = engine.play;
  engine.play = () => oldPlay.promise; f.prepared(); engine.emit('state', 'playing'); f.session.pause();
  if (newer === 'resume') {await tick(); engine.play = original; f.session.toggle();}
  oldPlay.reject(Error('old rejected play')); await tick(); await tick();
  assert.equal(f.session.core.engine, engine); assert.equal(f.opens.length, 1); assert.equal(f.session.sourceIndex, 0);
  assert.equal(f.state().playing, newer === 'resume'); f.session.deactivate();
});

test('session: a version replacement honors its refreshed history position', async () => {
  const f = fixture(); await f.boot(); f.playing();
  await f.session.replaceSource(f.source({version: 2, initialSeek: 17})); f.prepared();
  assert.equal(f.state().position, 17); assert.equal(f.session.seek.pendingSeekMs, 17000);
  assert.equal(f.session.seek.seekResumePlaying, true); f.advance(60);
  const engine = f.session.core.engine; land(engine, 17000);
  assert.equal(f.calls(engine, 'play').length, 1); assert.equal(f.state().seekLocked, false); f.session.deactivate();
});

for (const initialSeek of [NaN, Infinity, -4]) test(`session: replacement clamps invalid history ${initialSeek}`, async () => {
  const f = fixture(); await f.boot(); await f.session.replaceSource(f.source({version: 2, initialSeek})); f.prepared();
  assert.equal(f.state().position, 0); assert.equal(f.session.seek.pendingSeekMs, -1); f.session.deactivate();
});

test('session: changed keyframe landing resets subtitle/danmaku consumers to the actual time', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(10, false); f.advance(60);
  land(engine, 10000, 7200);
  assert.deepEqual(f.events.filter(e => e.kind === 'seek').map(e => e.value), [10, 7.2]);
  assert.equal(f.events.at(-1).kind, 'seek.finished'); f.session.deactivate();
});

test('session: unchanged landing emits no redundant business seek event', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(10); f.advance(60); land(engine, 10000);
  assert.deepEqual(f.events.filter(e => e.kind === 'seek').map(e => e.value), [10]); f.session.deactivate();
});

test('session: quality selection updates the source snapshot and observable metadata together', async () => {
  const f = fixture(); await f.boot(); f.playing(); const work = f.session.changeQuality(120);
  const qualities = [{qn: 120, name: '4K'}];
  f.apiCalls[0].resolve({urls: ['quality'], audioUrls: [], quality: 120, qualities, isPreview: true}); await work;
  assert.equal(f.session.source.quality, 120); assert.equal(f.state().activeQuality, 120);
  assert.equal(f.session.source.preview, true); assert.equal(f.state().preview, true);
  assert.deepEqual(f.session.source.qualities, qualities); assert.deepEqual(f.state().qualities, qualities);
  assert.notEqual(f.session.source.qualities, qualities); f.session.deactivate();
});
