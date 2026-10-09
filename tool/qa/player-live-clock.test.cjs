const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture} = require('./player-session-fixture.cjs');

test('engine timeline: pre-seek timeline events cannot overwrite the requested position while seek is pending', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(10); f.advance(60);
  engine.emit('time', 1000); assert.equal(f.state().position, 10);
  engine.currentTime = 10200; engine.emit('seek', 10000, 10200);
  assert.equal(f.state().position, 10.2); assert.equal(f.state().seekLocked, false);
  engine.emit('time', 10250); assert.equal(f.session.state.position, 10.25);
  assert.equal(f.progress.at(-1).seconds, 10.25); assert.equal(f.calls(engine, 'seek').length, 1); f.session.deactivate();
});

test('engine timeline: timeline consumers use the reported event even when the cached position differs', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); engine.currentTime = 1000;
  engine.emit('time', 12100);
  assert.equal(f.state().position, 12.1); assert.equal(f.progress.at(-1).seconds, 12.1);
  assert.equal(f.calls(engine, 'seek').length, 0); f.session.deactivate();
});

test('engine timeline: keyframe completion uses the explicitly reported landing rather than the request', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(10, false); f.advance(60);
  engine.currentTime = 10000; engine.emit('seek', 10000, 7200);
  assert.equal(f.state().position, 7.2); assert.equal(f.state().seekLocked, false); f.session.deactivate();
});

test('engine timeline: invalid landing falls back to the same core position, then the requested position', async () => {
  for (const actual of [12000, NaN, -1]) {
    const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(10); f.advance(60);
    engine.currentTime = actual; engine.emit('seek', 10000, NaN);
    assert.equal(f.state().position, Number.isFinite(actual) && actual >= 0 ? 12 : 10);
    assert.equal(f.state().seekLocked, false); f.session.deactivate();
  }
});
