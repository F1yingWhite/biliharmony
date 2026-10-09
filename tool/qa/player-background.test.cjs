const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture, tick} = require('./player-session-fixture.cjs');
const plays = f => f.engines.reduce((n, p) => n + f.calls(p, 'play').length, 0);

test('background: preparing then background then prepared never starts when disabled', async () => {
  const f = fixture(); await f.boot(); f.policy.background = true; f.session.onBackgroundChanged(); f.prepared();
  assert.equal(plays(f), 0); assert.equal(f.session.shouldPlayAfterPrepare, false);
  f.policy.background = false; f.session.onBackgroundChanged(); f.session.startPrepared(); assert.equal(plays(f), 0);
  f.session.toggle(); assert.equal(plays(f), 1); f.session.deactivate();
});

test('background: prepared checks current background policy without a Watch event', async () => {
  const f = fixture({background: true}); await f.boot(); f.prepared();
  assert.equal(plays(f), 0); assert.equal(f.state().buffering, false); f.session.deactivate();
});

test('background: captured seek completion cannot resume after background playback is disabled', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.playing(); f.session.seekTo(4); f.advance(60);
  f.policy.background = true; f.session.onBackgroundChanged(); const before = plays(f); await tick();
  engine.currentTime = 4000; engine.emit('seek', 4000);
  assert.equal(plays(f), before); assert.equal(f.state().seekLocked, false); assert.equal(f.state().playing, false); f.session.deactivate();
});

test('background: delayed playing cannot revive a disabled background session', async () => {
  const f = fixture(); const {engine} = await f.boot(); f.prepared(); f.policy.background = true;
  engine.emit('state', 'playing'); await tick();
  assert.equal(f.state().playing, false); assert.equal(engine.state, 'paused'); f.session.deactivate();
});

for (const mode of ['foreground', 'backgroundPlaybackEnabled', 'pipActive', 'pipStarting', 'pipRestoring']) {
  test(`background: preparation and restoration remain allowed for ${mode}`, async () => {
    const f = fixture({background: mode !== 'foreground', allowBackground: mode === 'backgroundPlaybackEnabled',
      pipKeepsAlive: mode.startsWith('pip')});
    const {engine} = await f.boot(); f.session.onBackgroundChanged(); f.prepared(); assert.equal(plays(f), 1);
    f.session.state.playing = true; f.session.seekTo(4); f.advance(60);
    engine.currentTime = 4000; engine.emit('seek', 4000);
    assert.equal(plays(f), 1, 'a native playing seek requires no stop/restart'); assert.equal(f.state().seekLocked, false); f.session.deactivate();
  });
}

test('background: native DASH clock keeps running and returns without seek, pause or restart', async () => {
  const f = fixture({allowBackground: true}); const {engine} = await f.boot(f.dashSource()); f.playing();
  const before = plays(f); f.policy.background = true; f.session.onBackgroundChanged();
  assert.equal(engine.state, 'playing'); assert.equal(f.state().playing, true); assert.equal(f.state().backgroundAudioOnly, true);
  engine.currentTime = 12000; engine.emit('time', 12000); assert.equal(f.progress.at(-1).background, true);
  f.policy.background = false; f.session.onBackgroundChanged();
  assert.equal(f.state().backgroundAudioOnly, false); assert.equal(f.state().position, 12);
  assert.equal(f.calls(engine, 'seek').length, 0); assert.equal(f.calls(engine, 'pause').length, 0); assert.equal(plays(f), before); f.session.deactivate();
});

test('background: completion on the shared player reports background completion once', async () => {
  const f = fixture({allowBackground: true}); const {engine} = await f.boot(); f.playing();
  f.policy.background = true; f.session.onBackgroundChanged(); engine.emit('state', 'completed');
  assert.deepEqual(f.events.filter(e => e.kind === 'ended').map(e => e.value), [1]); assert.equal(f.state().playing, false); f.session.deactivate();
});
