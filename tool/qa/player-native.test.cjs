const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function fixture() {
  const calls = [], events = [], logs = [], timers = new Map(), states = new Map(), focuses = [];
  const createQueue = [], openQueue = [], releaseQueue = [];
  let sequence = 0, timerId = 0;
  const state = () => ({position: 0, duration: 10, width: 1280, height: 720, paused: true,
    buffering: false, eof: false, loaded: false, speed: 1, volume: 100, hwdec: 'ohcodec',
    avSync: 0, droppedFrames: 0, decoderDroppedFrames: 0, events: []});
  const mpv = {
    async create(surface, caFile) {const id = ++sequence; calls.push(['create', id, surface, caFile]); states.set(id, state()); return createQueue.shift() || id;},
    async open(id, video, audio, headers) {calls.push(['open', id, video, audio, headers]); return openQueue.shift();},
    poll(id) {const value = states.get(id); const result = {...value, events: value.events.splice(0)}; calls.push(['poll', id]); return result;},
    play(id) {calls.push(['play', id]);}, pause(id) {calls.push(['pause', id]);},
    seek(...args) {calls.push(['seek', ...args]);}, rate(...args) {calls.push(['rate', ...args]);},
    volume(...args) {calls.push(['volume', ...args]);}, resize(...args) {calls.push(['resize', ...args]);},
    async release(id) {calls.push(['release', id]); return releaseQueue.shift();},
  };
  class Focus {
    constructor(onInterrupt) {this.onInterrupt = onInterrupt; this.activations = 0; this.releases = 0; this.pending = null; focuses.push(this);}
    async activate() {this.activations++; if (this.pending) await this.pending;}
    async release() {this.releases++;}
  }
  const load = createArktsLoader({globals: {
    setTimeout(fn, ms) {const id = ++timerId; timers.set(id, {fn, ms}); return id;},
    clearTimeout(id) {timers.delete(id);},
  }, mocks: {
    'libbilimpv.so': {default: mpv},
    'components/player/PlayerAudioFocus': {PlayerAudioFocus: Focus},
    'components/player/PlayerMpvResources': {PlayerMpvResources: {async caFile() {return '/app/ca.pem';}}},
    '@kit.PerformanceAnalysisKit': {hilog: {info(...args) {logs.push(args);}, error(...args) {logs.push(args);}}},
    BuildProfile: {DEBUG: false},
  }});
  const {PlayerEngineController} = load('components/player/PlayerEngineController');
  const owner = new PlayerEngineController(event => events.push(event));
  function poll(patch = {}, nativeEvents = [], id = 1) {
    const value = states.get(id); Object.assign(value, patch); value.events.push(...nativeEvents);
    const [timer, work] = timers.entries().next().value; timers.delete(timer); work.fn();
  }
  const event = (kind, patch = {}) => ({kind, request: -1, position: 0, errorCode: 0, ...patch});
  function loaded() {poll({loaded: true}, [event('file-loaded')]);}
  return {owner, calls, events, timers, focuses, states, logs, createQueue, openQueue, releaseQueue, poll, event, loaded};
}

test('libmpv: MP4 and split tracks use one engine and exact remote URLs, without MPD or byte proxy', async () => {
  for (const audio of ['', 'https://cdn/audio.m4s?x=a,b:c']) {
    const f = fixture(); await f.owner.open('https://cdn/video.m4s?x=a,b:c', audio, 'surface-123');
    assert.equal(f.calls.filter(x => x[0] === 'create').length, 1);
    const opened = f.calls.find(x => x[0] === 'open');
    assert.equal(opened[2], 'https://cdn/video.m4s?x=a,b:c'); assert.equal(opened[3], audio);
    assert(opened[4].some(x => x === 'Referer: https://www.bilibili.com/'));
    assert(opened[4].some(x => x.startsWith('User-Agent: ')));
    assert.equal(f.calls[0][3], '/app/ca.pem');
    f.loaded(); assert.equal(f.owner.prepared, true);
    await f.owner.release(); assert.equal(f.timers.size, 0);
  }
});

test('libmpv: clock, duration, size, buffering, speed and first frame come from native observations', async () => {
  const f = fixture(); await f.owner.open('video', 'audio', 'surface'); f.loaded();
  f.poll({position: 1.25, buffering: true, speed: 1.5, paused: false}, [f.event('playing'), f.event('playback-restart')]);
  assert.equal(f.owner.engine.currentTime, 1250); assert.equal(f.owner.firstRenderReady, true);
  assert(f.events.some(x => x.kind === 'duration' && x.value === 10000));
  assert(f.events.some(x => x.kind === 'size' && x.value === 1280 && x.second === 720));
  assert(f.events.some(x => x.kind === 'buffer' && x.value === 0));
  assert(f.events.some(x => x.kind === 'rate' && x.value === 1.5));
  assert(f.events.some(x => x.kind === 'state' && x.state === 'playing'));
  f.poll({buffering: false}); assert(f.events.some(x => x.kind === 'buffer' && x.value === 1));
  await f.owner.release();
});

test('libmpv: cached pause snapshot cannot overwrite prepared or acknowledge an unexecuted command', async () => {
  const f = fixture(); await f.owner.open('video', '', 'surface'); f.loaded();
  await f.owner.engine.play(); f.poll({paused: true}); assert.equal(f.owner.engine.state, 'prepared');
  f.poll({paused: false}, [f.event('playing')]); assert.equal(f.owner.engine.state, 'playing');
  await f.owner.engine.pause(); f.poll({paused: false}); assert.equal(f.owner.engine.state, 'playing');
  f.poll({paused: false}, [f.event('paused'), f.event('playing')]);
  assert.deepEqual(f.events.filter(x => x.kind === 'state').slice(-2).map(x => x.state), ['paused', 'playing']);
  await f.owner.release();
});

test('libmpv: every native pause acknowledgment remains observable even when already paused', async () => {
  const f = fixture(); await f.owner.open('video', '', 'surface'); f.loaded();
  f.poll({}, [f.event('paused'), f.event('paused')]);
  assert.equal(f.events.filter(x => x.kind === 'state' && x.state === 'paused').length, 2);
  await f.owner.release();
});

test('libmpv: pause while focus activation is pending cancels the late play', async () => {
  const f = fixture(); await f.owner.open('video', '', 'surface'); f.loaded();
  const gate = deferred(); f.focuses[0].pending = gate.promise;
  const starting = f.owner.engine.play(); await tick(); await f.owner.engine.pause();
  gate.resolve(); await starting;
  assert.equal(f.calls.filter(x => x[0] === 'play').length, 0);
  assert.equal(f.calls.filter(x => x[0] === 'pause').length, 1); await f.owner.release();
});

test('libmpv: focus denial pauses intent without treating it as a failed CDN or preventing explicit retry', async () => {
  const f = fixture(); await f.owner.open('video', '', 'surface'); f.loaded();
  f.focuses[0].pending = Promise.reject(Error('focus preemption denied'));
  await f.owner.engine.play(); assert.equal(f.events.at(-1).kind, 'interruption');
  assert.equal(f.calls.filter(x => x[0] === 'play').length, 0);
  assert.equal(f.events.filter(x => x.kind === 'error').length, 0);
  f.focuses[0].pending = null; await f.owner.engine.play(); assert.equal(f.calls.filter(x => x[0] === 'play').length, 1);
  await f.owner.release();
});

test('libmpv: focus interruption reaches session policy and never auto-resumes playback', async () => {
  const f = fixture(); await f.owner.open('video', '', 'surface'); f.loaded();
  f.focuses[0].onInterrupt(); assert.equal(f.events.at(-1).kind, 'interruption');
  assert.equal(f.calls.filter(x => x[0] === 'play').length, 0);
  await f.owner.release(); const count = f.events.length; f.focuses[0].onInterrupt(); assert.equal(f.events.length, count);
});

test('libmpv: seek completion carries exact request plus actual keyframe position', async () => {
  const f = fixture(); await f.owner.open('video', 'audio', 'surface'); f.loaded();
  f.owner.engine.seek(2000, 1); assert.deepEqual(f.calls.at(-1), ['seek', 1, 2, 2000, false]);
  f.poll({position: 1.8}, [f.event('playback-restart', {request: 2000, position: 1.8})]);
  assert.deepEqual(f.events.filter(x => x.kind === 'seek').map(x => [x.value, x.second]), [[2000, 1800]]);
  f.owner.engine.seek(0, 0); f.poll({position: 0}, [f.event('playback-restart', {request: 0, position: 0})]);
  assert(f.events.some(x => x.kind === 'seek' && x.value === 0)); await f.owner.release();
});

test('libmpv: release waits for a late create and its native destruction before replacement', async () => {
  const f = fixture(), create = deferred(), shutdown = deferred(); f.createQueue.push(create.promise); f.releaseQueue.push(shutdown.promise);
  const opening = f.owner.open('video', 'audio', 'surface'); await tick();
  let closed = false; const closing = f.owner.release().then(() => {closed = true;});
  const next = f.owner.open('next', '', 'surface'); await tick(); assert.equal(f.calls.filter(x => x[0] === 'create').length, 1);
  create.resolve(1); await tick(); assert.equal(closed, false); assert.deepEqual(f.calls.at(-1), ['release', 1]);
  shutdown.resolve(); await Promise.all([opening, closing, next]);
  assert.equal(f.calls.filter(x => x[0] === 'create').length, 2);
  assert.equal(f.calls.filter(x => x[0] === 'open').length, 1); await f.owner.release();
});

test('libmpv: release waits for in-flight open, clears timers and prevents late events or play', async () => {
  const f = fixture(), gate = deferred(); f.openQueue.push(gate.promise);
  const opening = f.owner.open('video', 'audio', 'surface'); await tick();
  let closed = false; const closing = f.owner.release().then(() => {closed = true;}); await tick(); assert.equal(closed, false);
  gate.resolve(); await Promise.all([opening, closing]); assert.equal(f.timers.size, 0); assert.equal(f.owner.engine, null);
  assert.equal(f.events.length, 0);
});

test('libmpv: native errors and rejected URLs are sanitized, with no signed query leakage', async () => {
  const f = fixture(); f.openQueue.push(Promise.reject(Error('https://cdn?token=secret')));
  await f.owner.open('video', 'audio', 'surface'); assert.equal(f.events[0].kind, 'error');
  assert.doesNotMatch(f.events[0].message, /secret|token/); await f.owner.release();
  const g = fixture(); await g.owner.open('video', '', 'surface'); g.loaded();
  g.poll({}, [g.event('error', {errorCode: -13})]); assert.equal(g.events.at(-1).kind, 'error');
  assert.equal(g.timers.size, 0); await g.owner.release();
});

test('libmpv: surface resize and user rate/volume reach existing instance without reopen or seek', async () => {
  const f = fixture(); await f.owner.open('video', 'audio', 'surface'); f.loaded();
  f.owner.engine.resize(1920, 1080); f.owner.engine.setPlaybackRate(2); f.owner.engine.setVolume(0);
  assert.deepEqual(f.calls.filter(x => ['resize', 'rate', 'volume'].includes(x[0])),
    [['resize', 1, 1920, 1080], ['rate', 1, 2], ['volume', 1, 0]]);
  assert.equal(f.calls.filter(x => x[0] === 'create').length, 1); assert.equal(f.calls.filter(x => x[0] === 'seek').length, 0);
  await f.owner.release();
});

test('libmpv: EOF comes from native timeline and replay may seek on the same retained instance', async () => {
  const f = fixture(); await f.owner.open('video', 'audio', 'surface'); f.loaded();
  f.poll({eof: true, position: 10}); assert.equal(f.owner.engine.state, 'completed');
  f.owner.engine.seek(0, 0); f.poll({eof: false, position: 0}, [f.event('playback-restart', {request: 0})]);
  await f.owner.engine.play(); f.poll({}, [f.event('playing')]); assert.equal(f.owner.engine.state, 'playing');
  assert.equal(f.calls.filter(x => x[0] === 'create').length, 1); await f.owner.release();
});

test('libmpv: failed native destruction rejects its barrier and prevents a replacement decoder', async () => {
  const f = fixture(); await f.owner.open('video', 'audio', 'surface');
  f.releaseQueue.push(Promise.reject(Error('native completion unavailable')));
  await assert.rejects(f.owner.release(), /completion unavailable/);
  await f.owner.open('next', '', 'surface');
  assert.equal(f.calls.filter(x => x[0] === 'create').length, 1);
  assert.equal(f.events.at(-1).kind, 'error');
});

test('libmpv: missing external audio fails before prepared and is classified for audio CDN recovery', async () => {
  const f = fixture(); await f.owner.open('video', 'audio', 'surface');
  f.poll({loaded: false}, [f.event('audio-error', {errorCode: -13})]);
  assert.equal(f.owner.prepared, false); assert.equal(f.events.at(-1).kind, 'audio-error');
  assert.equal(f.events.filter(x => x.kind === 'state' && x.state === 'prepared').length, 0);
  await f.owner.release();
});
