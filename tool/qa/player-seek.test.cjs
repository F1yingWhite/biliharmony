const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader} = require('./arkts-module.cjs');

function fixture() {
  const timers = new Map(); let id = 0;
  const load = createArktsLoader({globals: {
    setTimeout(fn, ms) {timers.set(++id, {fn, ms}); return id;}, clearTimeout: n => timers.delete(n)}});
  const {PlayerSeekController} = load('components/player/PlayerSeekController');
  let prepared = true;
  const engine = {state: 'playing', currentTime: 0, calls: [],
    pause() {assert.fail('a native seek must not add an artificial playback pause');},
    seek(ms, mode) {this.calls.push([ms, mode]);}};
  let current = engine;
  const done = [], stalled = [], spinner = [], dispatch = [];
  const ctl = new PlayerSeekController(() => current, () => prepared,
    (...args) => dispatch.push(args), (...args) => spinner.push(args),
    (...args) => done.push(args), (...args) => stalled.push(args));
  return {ctl, engine, done, stalled, spinner, dispatch, timers,
    setPrepared(value) {prepared = value;}, replace(value) {current = value;},
    fire(ms) {for (const [key, timer] of [...timers]) if (timer.ms === ms) {timers.delete(key); timer.fn();}}};
}

test('seek: multiple drag updates dispatch only the latest target and keep the native clock running', () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.ctl.request(20000, true, true); f.fire(60);
  assert.deepEqual(f.engine.calls, [[20000, 0]]); assert.equal(f.engine.state, 'playing');
  f.ctl.onSeekDone(f.engine, 20000, 20040); assert.deepEqual(f.done, [[true, 20040]]);
  assert.equal(f.timers.size, 0);
});

test('seek: in-flight gestures coalesce without resuming the superseded position', () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60);
  f.ctl.request(15000, true, true); f.ctl.request(20000, true, true);
  f.ctl.onSeekDone(f.engine, 10000, 10020);
  assert.deepEqual(f.engine.calls, [[10000, 0], [20000, 0]]); assert.deepEqual(f.done, []);
  f.ctl.onSeekDone(f.engine, 20000, 20010); assert.deepEqual(f.done, [[true, 20010]]);
});

test('seek: nearby stale callback cannot finish a newer request', () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60);
  f.ctl.onSeekDone(f.engine, 10000, 10000);
  f.ctl.request(10200, true, true); f.fire(60);
  f.ctl.onSeekDone(f.engine, 10000, 10000);
  assert.equal(f.ctl.seekInFlight, true); assert.deepEqual(f.done, [[true, 10000]]);
  f.ctl.onSeekDone(f.engine, 10200, 10200); assert.deepEqual(f.done, [[true, 10000], [true, 10200]]);
});

test('seek: keyframe callback request and actual landing are distinct', () => {
  const f = fixture(); f.ctl.request(10000, false, true); f.fire(60);
  assert.deepEqual(f.engine.calls, [[10000, 1]]);
  f.ctl.onSeekDone(f.engine, 7200, 7200); assert.deepEqual(f.done, []);
  f.ctl.onSeekDone(f.engine, 10000, 7200); assert.deepEqual(f.done, [[true, 7200]]);
});

test('seek: missing explicit landing uses the engine position, then the requested target for invalid values', () => {
  for (const actual of [7200, NaN, -1]) {
    const f = fixture(); f.engine.currentTime = actual;
    f.ctl.request(10000, false, true); f.fire(60); f.ctl.onSeekDone(f.engine, 10000);
    assert.deepEqual(f.done, [[true, Number.isFinite(actual) && actual >= 0 ? 7200 : 10000]]);
  }
});

test('seek: cancellation clears dispatch, spinner and watchdog and ignores delayed callbacks', () => {
  for (const dispatched of [false, true]) {
    const f = fixture(); f.ctl.request(10000, true, true); if (dispatched) f.fire(60);
    f.ctl.cancel(); f.ctl.onSeekDone(f.engine, 10000, 10000); f.fire(4000);
    assert.equal(f.timers.size, 0); assert.deepEqual(f.done, []); assert.deepEqual(f.stalled, []);
    assert.equal(f.ctl.seekResumePlaying, false);
  }
});

test('seek: missing callback recovers at the latest user target and never pretends completion', () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60); f.fire(180);
  assert.deepEqual(f.spinner, [[true]]);
  f.ctl.request(20000, true, true); f.fire(4000);
  assert.deepEqual(f.stalled, [[f.engine, 20000]]); assert.deepEqual(f.done, []); f.ctl.cancel();
});

test('seek: thrown native command recovers promptly and cancels both timers', () => {
  const f = fixture(); f.engine.seek = () => {throw Error('native seek');};
  f.ctl.request(10000, true, true); f.fire(60);
  assert.deepEqual(f.stalled, [[f.engine, 10000]]); assert.equal(f.timers.size, 0); f.ctl.cancel();
});

test('seek: user pause while a seek is outstanding suppresses autoplay restoration', () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60); f.ctl.seekResumePlaying = false;
  f.ctl.onSeekDone(f.engine, 10000, 10000); assert.deepEqual(f.done, [[false, 10000]]);
});

test('seek: a callback from a detached engine cannot complete the current request', () => {
  const f = fixture(); f.ctl.request(10000, true, true); f.fire(60); f.replace({});
  f.ctl.onSeekDone(f.engine, 10000, 10000); assert.deepEqual(f.done, []); f.ctl.cancel();
});
