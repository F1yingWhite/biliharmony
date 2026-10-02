const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture, deferred, tick} = require('./player-session-fixture.cjs');

async function recovering(kind) {
  const f = fixture(); const pair = await f.boot(); f.playing();
  const release = deferred(); pair[kind].release = () => release.promise;
  const old = f.session.recoverSource(kind === 'audio', 'CDN failed');
  return {...f, ...pair, release, old};
}
for (const kind of ['video', 'audio']) {
  test(`player ${kind} recovery: switching video during release keeps the new primary source`, async () => {
    const f = await recovering(kind);
    const next = f.session.replaceSource(f.source({cid: 2, urls: ['new-main', 'new-backup']}));
    await tick(); assert.equal(f.creations.length, 2, 'replacement waits for the detached decoder release');
    f.release.resolve(); await Promise.all([f.old, next]); await tick();
    assert.equal(f.session.sourceIndex, 0); assert.equal(f.session.audioSourceIndex, 0);
    assert.equal(f.creations.length, 4); assert.equal(f.session.retryingSource, false);
    assert.equal(f.session.pair.video.source.url, 'new-main'); f.session.deactivate();
  });
  test(`player ${kind} recovery: leaving while release waits never rebuilds`, async () => {
    const f = await recovering(kind); f.session.deactivate(); f.release.resolve(); await f.old;
    assert.equal(f.creations.length, 2); assert.equal(f.session.pair.video, null); assert.equal(f.timers.size, 0);
  });
  test(`player ${kind} recovery: normal recovery still rebuilds the intended source`, async () => {
    const f = await recovering(kind); f.release.resolve(); await f.old; await tick();
    assert.equal(f.creations.length, 4); assert.equal(f.session.sourceIndex, kind === 'video' ? 1 : 0);
    assert.equal(f.session.audioSourceIndex, kind === 'audio' ? 1 : 0); assert.equal(f.session.retryingSource, false);
    assert.equal(f.session.pair[kind].source.url, kind === 'audio' ? 'audio-backup' : 'video-backup'); f.session.deactivate();
  });
}

test('player: source switch releases a previous retry lock before new player errors', async () => {
  const f = await recovering('video'); const next = f.session.replaceSource(f.source({cid: 2}));
  assert.equal(f.session.retryingSource, false); f.release.resolve(); await Promise.all([f.old, next]);
  f.session.deactivate();
});

test('player: old retry completion cannot release the lock or advance indexes of a newer retry', async () => {
  const f = await recovering('video');
  // The new source waits for release; callbacks already queued by the old SDK can still arrive later.
  const nextSource = f.session.replaceSource(f.source({cid: 2}));
  f.release.resolve(); await Promise.all([f.old, nextSource]); await tick();
  const nextRelease = deferred(), current = f.session.pair.video; current.release = () => nextRelease.promise;
  const next = f.session.recoverSource(false, 'new CDN failed');
  assert.equal(f.session.retryingSource, true);
  f.video.emit('error', {message: 'late old error'}); f.audio.emit('error', {message: 'late old audio error'}); await tick();
  assert.equal(f.session.retryingSource, true); assert.equal(f.session.sourceIndex, 0); assert.equal(f.creations.length, 4);
  nextRelease.resolve(); await next; assert.equal(f.session.sourceIndex, 1);
  assert.equal(f.session.retryingSource, false); assert.equal(f.creations.length, 6); f.session.deactivate();
});

test('player: exhausted audio sources stop both tracks instead of leaving a silent prepared wait', async () => {
  const f = fixture(); const {video, audio} = await f.boot(f.source({audioUrls: ['only-audio']}));
  audio.emit('error', {message: 'audio failed'}); await tick();
  assert.equal(f.session.pair.video, null); assert.equal(f.session.pair.audio, null);
  assert.equal(f.calls(video, 'release').length, 1); assert.equal(f.calls(audio, 'release').length, 1);
  assert.equal(f.state().buffering, false); assert.match(f.state().errorText, /音频播放出错/);
  assert.equal(f.timers.size, 0);
});
