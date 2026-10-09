const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function fixture({active = false} = {}) {
  const calls = [], handlers = new Map(), activationQueue = [], releaseQueue = [];
  let interruptions = 0, managerReads = 0;
  const session = {
    active,
    isAudioSessionActivated() {return session.active;},
    setAudioSessionScene(scene) {calls.push(['scene', scene]);},
    on(type, callback) {calls.push(['on', type, callback]); handlers.set(type, callback);},
    off(type, callback) {calls.push(['off', type, callback]); if (handlers.get(type) === callback) handlers.delete(type);},
    async activateAudioSession(strategy) {
      calls.push(['activate', strategy]);
      await (activationQueue.shift() ?? Promise.resolve()); session.active = true;
    },
    async deactivateAudioSession() {
      calls.push(['deactivate']); await (releaseQueue.shift() ?? Promise.resolve()); session.active = false;
    },
  };
  const audio = {getAudioManager() {managerReads++; return {getSessionManager: () => session};},
    AudioSessionScene: {AUDIO_SESSION_SCENE_MEDIA: 0}, AudioConcurrencyMode: {CONCURRENCY_DEFAULT: 0},
    AudioSessionStateChangeHint: {AUDIO_SESSION_STATE_CHANGE_HINT_RESUME: 0,
      AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE: 1, AUDIO_SESSION_STATE_CHANGE_HINT_STOP: 2},
    AudioSessionDeactivatedReason: {DEACTIVATED_LOWER_PRIORITY: 0, DEACTIVATED_TIMEOUT: 1}};
  const {PlayerAudioFocus} = createArktsLoader({mocks: {'@kit.AudioKit': {audio}}})('components/player/PlayerAudioFocus');
  const focus = new PlayerAudioFocus(() => interruptions++);
  return {focus, calls, handlers, session, activationQueue, releaseQueue,
    count: type => calls.filter(call => call[0] === type).length,
    state: hint => handlers.get('audioSessionStateChanged')?.({stateChangeHint: hint}),
    deactivated(reason) {session.active = false; handlers.get('audioSessionDeactivated')?.({reason});},
    interruptions: () => interruptions, managerReads: () => managerReads};
}

test('audio focus is lazy and explicit activation selects media with the default concurrency policy', async () => {
  const f = fixture(); assert.equal(f.managerReads(), 0);
  await f.focus.activate();
  assert.deepEqual(f.calls.map(call => call.slice(0, 2)), [
    ['scene', 0], ['on', 'audioSessionStateChanged'], ['on', 'audioSessionDeactivated'],
    ['activate', {concurrencyMode: 0}]]);
  assert.equal(f.session.active, true); await f.focus.release(); assert.equal(f.count('deactivate'), 1);
});

test('audio focus pauses on pause, stop and priority loss and never starts on a resume hint', async () => {
  const f = fixture(); await f.focus.activate();
  f.state(0); assert.equal(f.interruptions(), 0);
  f.state(1); f.state(2); assert.equal(f.interruptions(), 2);
  f.deactivated(0); assert.equal(f.interruptions(), 3);
  f.state(0); f.state(1); assert.equal(f.interruptions(), 3);
  await f.focus.activate(); f.state(1); assert.equal(f.interruptions(), 4);
  await f.focus.release();
});

test('audio focus borrows an already active app session without changing its scene or deactivating it', async () => {
  const f = fixture({active: true}); await f.focus.activate(); f.state(1);
  assert.equal(f.interruptions(), 1); assert.equal(f.count('scene'), 0); assert.equal(f.count('activate'), 0);
  await f.focus.release(); assert.equal(f.count('deactivate'), 0); assert.equal(f.session.active, true);
  assert.equal(f.handlers.size, 0);
});

test('audio focus joins concurrent activation and exact listeners are removed once during release', async () => {
  const f = fixture(), pending = deferred(); f.activationQueue.push(pending.promise);
  const first = f.focus.activate(), next = f.focus.activate(); await tick();
  assert.equal(f.count('activate'), 1);
  const registered = f.calls.filter(call => call[0] === 'on');
  pending.resolve(); await Promise.all([first, next]);
  await Promise.all([f.focus.release(), f.focus.release()]);
  assert.equal(f.count('off'), 2); assert.equal(f.count('deactivate'), 1);
  for (const [, type, callback] of registered) assert.ok(f.calls.some(call => call[0] === 'off' && call[1] === type && call[2] === callback));
});

test('audio focus delivers interrupts while activation is pending so a late focus grant cannot revive playback', async () => {
  const f = fixture(), pending = deferred(); f.activationQueue.push(pending.promise);
  const activation = f.focus.activate(); await tick();
  f.state(1); f.state(2); assert.equal(f.interruptions(), 2);
  f.deactivated(0); assert.equal(f.interruptions(), 3);
  pending.resolve(); await activation;
  await f.focus.release(); assert.equal(f.count('deactivate'), 1);
});

test('audio focus revokes playback intent when the grant was already lost before its promise completed', async () => {
  const f = fixture(), original = f.session.activateAudioSession;
  f.session.activateAudioSession = async strategy => {await original(strategy); f.session.active = false;};
  await f.focus.activate(); assert.equal(f.interruptions(), 1); assert.equal(f.focus.active, false);
  await f.focus.release(); assert.equal(f.count('deactivate'), 0);
});

test('audio focus release awaits a late activation, removes callbacks immediately and never resurrects intent', async () => {
  const f = fixture(), pending = deferred(), releasing = deferred();
  f.activationQueue.push(pending.promise); f.releaseQueue.push(releasing.promise);
  const activation = f.focus.activate(); const old = f.handlers.get('audioSessionStateChanged');
  let complete = false; const release = f.focus.release().then(() => complete = true); await tick();
  assert.equal(f.handlers.size, 0); assert.equal(complete, false); old({stateChangeHint: 1});
  assert.equal(f.interruptions(), 0); assert.equal(f.count('deactivate'), 0);
  pending.resolve(); await activation; await tick();
  assert.equal(f.count('deactivate'), 1); assert.equal(complete, false);
  releasing.resolve(); await release; assert.equal(f.session.active, false);
  await f.focus.activate(); assert.equal(f.count('activate'), 1);
});

test('audio focus activation rejection can be retried and does not retain a failed promise', async () => {
  const f = fixture(); f.activationQueue.push(Promise.reject(Error('focus unavailable')));
  await assert.rejects(f.focus.activate(), /音频焦点申请失败/);
  assert.equal(f.focus.activation, null); assert.equal(f.session.active, false);
  f.state(1); assert.equal(f.interruptions(), 0);
  await f.focus.activate(); assert.equal(f.count('activate'), 2); assert.equal(f.count('on'), 2);
  await f.focus.release(); assert.equal(f.count('deactivate'), 1);
});

test('audio focus partial listener setup failure removes only its own callback and allows a later retry', async () => {
  const f = fixture(), original = f.session.on;
  f.session.on = (type, callback) => {if (type === 'audioSessionDeactivated') throw Error('unsupported'); original(type, callback);};
  await assert.rejects(f.focus.activate(), /音频焦点初始化失败/);
  assert.equal(f.handlers.size, 0); assert.equal(f.count('activate'), 0);
  f.session.on = original; await f.focus.activate(); assert.equal(f.managerReads(), 2);
  await f.focus.release(); assert.equal(f.handlers.size, 0);
});

test('audio focus timeout does not pause already idle playback or deactivate a session the system already released', async () => {
  const f = fixture(); await f.focus.activate(); f.deactivated(1);
  assert.equal(f.interruptions(), 0); await f.focus.release(); assert.equal(f.count('deactivate'), 0);
});

test('audio focus failed native deactivation still completes local cleanup and release is idempotent', async () => {
  const f = fixture(); await f.focus.activate(); f.releaseQueue.push(Promise.reject(Error('server died')));
  await f.focus.release(); await f.focus.release();
  assert.equal(f.handlers.size, 0); assert.equal(f.count('deactivate'), 1); assert.equal(f.focus.session, null);
});

test('releasing unused audio focus never touches the process audio session', async () => {
  const f = fixture(); await f.focus.release(); await f.focus.activate(); assert.equal(f.managerReads(), 0);
});
