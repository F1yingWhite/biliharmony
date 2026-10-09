const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture, deferred, tick} = require('./player-session-fixture.cjs');

test('native: missing external audio tries its backup without rotating a healthy video CDN', async () => {
  const f = fixture(); await f.boot(f.dashSource()); f.playing();
  const old = f.session.core.engine;
  old.emit('audio-error', '音轨加载失败'); await tick(); await tick();
  const next = f.session.core.engine;
  assert.equal(next.videoUrl, 'https://video.test/main');
  assert.equal(next.audioUrl, 'https://audio.test/backup');
  assert.equal(f.session.sourceIndex, 0); assert.equal(f.session.audioSourceIndex, 1);
  assert.equal(f.calls(old, 'release').length, 1);
  f.playing(); assert.equal(f.state().errorText, ''); assert.equal(f.state().playing, true);
  f.session.deactivate();
});

async function recovering(dash = false) {
  const f = fixture(); const {engine} = await f.boot(dash ? f.dashSource() : f.source()); f.playing();
  const release = deferred(); engine.release = () => release.promise;
  const old = f.session.recoverSource(false, 'CDN failed'); return {...f, engine, release, old};
}
for (const dash of [false, true]) {
  test(`CDN recovery: ${dash ? 'DASH' : 'MP4'} replacement during release keeps the new primary`, async () => {
    const f = await recovering(dash); const next = f.session.replaceSource(f.source({cid: 2, urls: ['new-main', 'new-backup']}));
    await tick(); assert.equal(f.opens.length, 1); f.release.resolve(); await Promise.all([f.old, next]); await tick();
    assert.equal(f.session.sourceIndex, 0); assert.equal(f.session.audioSourceIndex, 0); assert.equal(f.opens.length, 2);
    assert.equal(f.session.retryingSource, false); assert.equal(f.session.core.engine.videoUrl, 'new-main'); f.session.deactivate();
  });
  test(`CDN recovery: ${dash ? 'DASH' : 'MP4'} exit during release never rebuilds`, async () => {
    const f = await recovering(dash); f.session.deactivate(); f.release.resolve(); await f.old;
    assert.equal(f.opens.length, 1); assert.equal(f.session.core.engine, null); assert.equal(f.timers.size, 0);
  });
  test(`CDN recovery: ${dash ? 'DASH' : 'MP4'} ordinary failure selects the next CDN`, async () => {
    const f = await recovering(dash); f.release.resolve(); await f.old; await tick();
    assert.equal(f.opens.length, 2); assert.equal(f.session.sourceIndex, 1); assert.equal(f.session.audioSourceIndex, 0);
    assert.equal(f.session.core.engine.videoUrl, dash ? 'https://video.test/backup' : 'video-backup'); f.session.deactivate();
  });
}

test('CDN recovery: obsolete retry cannot clear a newer retry lock or advance its indexes', async () => {
  const f = await recovering(); const nextSource = f.session.replaceSource(f.source({cid: 2}));
  f.release.resolve(); await Promise.all([f.old, nextSource]); await tick();
  const nextRelease = deferred(), current = f.session.core.engine; current.release = () => nextRelease.promise;
  const next = f.session.recoverSource(false, 'new CDN failed'); assert.equal(f.session.retryingSource, true);
  f.engine.emit('error', 'old error'); await tick();
  assert.equal(f.session.retryingSource, true); assert.equal(f.session.sourceIndex, 0); assert.equal(f.opens.length, 2);
  nextRelease.resolve(); await next; assert.equal(f.session.sourceIndex, 1); assert.equal(f.opens.length, 3); f.session.deactivate();
});

test('CDN recovery: native DASH tries bounded video/audio CDN combinations, including audio backup', async () => {
  const f = fixture(); await f.boot(f.dashSource()); f.playing();
  for (let i = 0; i < 3; i++) {f.session.core.engine.emit('error', 'CDN failed'); await tick(); await tick();}
  assert.deepEqual(f.engines.map(r => [r.videoUrl, r.audioUrl]), [
    ['https://video.test/main', 'https://audio.test/main'], ['https://video.test/backup', 'https://audio.test/main'],
    ['https://video.test/main', 'https://audio.test/backup'], ['https://video.test/backup', 'https://audio.test/backup']]);
  f.session.core.engine.emit('error', 'last failure'); await tick();
  assert.equal(f.opens.length, 4); assert.equal(f.session.core.engine, null);
  assert.equal(f.state().buffering, false); assert.match(f.state().errorText, /播放出错/); assert.equal(f.timers.size, 0);
  assert.equal(f.engines.every(r => f.calls(r, 'release').length === 1), true);
});

test('CDN recovery: an audio-only CDN alternative is reachable when no video backup exists', async () => {
  const f = fixture(); await f.boot(f.dashSource({urls: ['https://video.test/main']}));
  f.session.core.engine.emit('error', 'audio CDN failed'); await tick(); await tick();
  assert.equal(f.session.audioSourceIndex, 1); assert.equal(f.session.sourceIndex, 0);
  assert.equal(f.engines.at(-1).audioUrl, 'https://audio.test/backup'); f.session.deactivate();
});

 test('CDN recovery: no remaining source releases the player and reports a bounded failure', async () => {
  const f = fixture(); const {engine} = await f.boot(f.source({urls: ['only-video']})); engine.emit('error', 'failed'); await tick();
  assert.equal(f.session.core.engine, null); assert.equal(f.calls(engine, 'release').length, 1);
  assert.equal(f.state().buffering, false); assert.match(f.state().errorText, /播放出错/); assert.equal(f.timers.size, 0);
});
