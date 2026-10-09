const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture} = require('./player-session-fixture.cjs');

for (const transport of ['MP4', 'DASH']) {
  test(`engine clock: ${transport} startup needs one play and no correction seeks or mute fallback`, async () => {
    const f = fixture(); const {engine} = await f.boot(transport === 'DASH' ? f.dashSource() : f.source());
    f.playing(); for (const time of [250, 500, 1000, 1500, 2000, 10000]) {engine.currentTime = time; engine.emit('time', time);}
    f.advance(5000);
    assert.equal(f.opens.length, 1); assert.equal(f.calls(engine, 'play').length, 1);
    assert.equal(f.calls(engine, 'seek').length, 0); assert.equal(f.calls(engine, 'pause').length, 0);
    assert.equal(f.calls(engine, 'rate').length, 1, 'only prepared applies the selected speed');
    assert.equal(f.calls(engine, 'volume').some(call => call[1] === 0), false);
    assert.equal(f.timers.size, 0); f.session.deactivate();
  });

  test(`engine clock: ${transport} buffering never freezes or repositions an independent clock`, async () => {
    const f = fixture(); const {engine} = await f.boot(transport === 'DASH' ? f.dashSource() : f.source()); f.playing();
    engine.emit('buffer', f.PlayerBuffering.START, 0);
    assert.equal(f.state().buffering, true); f.advance(5000);
    engine.emit('buffer', f.PlayerBuffering.END, 0); assert.equal(f.state().buffering, false);
    assert.equal(f.calls(engine, 'pause').length, 0); assert.equal(f.calls(engine, 'seek').length, 0);
    assert.equal(f.calls(engine, 'play').length, 1); assert.equal(f.timers.size, 0); f.session.deactivate();
  });
}

test('engine clock: seekDone leaves unresolved native buffering active', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(4); f.advance(60); f.advance(180);
  engine.emit('buffer', f.PlayerBuffering.START, 0);
  engine.currentTime = 4000; engine.emit('seek', 4000);
  assert.equal(f.state().seekLocked, false); assert.equal(f.state().buffering, true);
  engine.emit('buffer', f.PlayerBuffering.END, 0); assert.equal(f.state().buffering, false); f.session.deactivate();
});

test('engine clock: native buffer end during seek clears buffering only when seek also completes', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(4); f.advance(60); f.advance(180);
  engine.emit('buffer', f.PlayerBuffering.START, 0);
  engine.emit('buffer', f.PlayerBuffering.END, 0); assert.equal(f.state().buffering, true);
  engine.currentTime = 4000; engine.emit('seek', 4000); assert.equal(f.state().buffering, false); f.session.deactivate();
});

test('engine clock: pause clears a native buffer spinner and late buffer end never starts playback', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); engine.emit('buffer', 0, 0);
  f.session.pause(); assert.equal(f.state().buffering, false); engine.emit('buffer', 1, 0);
  assert.equal(f.calls(engine, 'play').length, 1); assert.equal(f.state().playing, false); f.session.deactivate();
});

test('engine clock: speed changes never schedule a delayed buffer pause', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.beginHold(); engine.emit('buffer', 0, 0);
  f.advance(1000); engine.emit('buffer', 1, 0); f.session.endHold();
  assert.equal(f.calls(engine, 'pause').length, 0); assert.equal(f.calls(engine, 'seek').length, 0);
  assert.equal(f.timers.size, 0); f.session.deactivate();
});
