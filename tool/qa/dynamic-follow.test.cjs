const test = require('node:test');
const assert = require('node:assert/strict');
const { environment, deferred, tick } = require('./dynamic-test-env.cjs');
function fixture() {
  const requests = [], live = [], states = [], user = { current: { mid: 1 }, ensureLoaded: async () => {} };
  const env = environment({
    'services/auth/UserStore': { UserStore: user },
    'api/UserApi': { UserApi: { getRelationUsers: mid => { const next = deferred(); requests.push({ ...next, mid }); return next.promise; } } },
    'api/LiveApi': { LiveApi: { getLiveStatusByUids: ids => { const next = deferred(); live.push({ ...next, ids }); return next.promise; } } },
  });
  const { DynamicFollowController } = env.load('components/dynamic/DynamicFollowController');
  return { controller: new DynamicFollowController(state => states.push(state)), requests, live, states, user,
    session: env.load('services/auth/AuthSession').AuthSession, state: () => states.at(-1) };
}

test('following loads once and live badges include only valid live rooms', async () => {
  const f = fixture(), pending = f.controller.load(); await f.controller.load();
  assert.equal(f.requests.length, 1); f.requests[0].resolve({ users: [{ mid: 10 }, { mid: 20 }] }); await pending;
  assert.deepEqual(f.state().followed.map(user => user.mid), [10, 20]); assert.deepEqual(f.live[0].ids, [10, 20]);
  f.live[0].resolve([{ uid: 10, liveStatus: 1, roomId: 100 }, { uid: 20, liveStatus: 0, roomId: 200 }]); await tick();
  assert.deepEqual([...f.state().liveRooms], [[10, 100]]); await f.controller.load(); assert.equal(f.requests.length, 1);
});

test('reset invalidates old-account list and badges without unlocking a newer request', async () => {
  const f = fixture(), old = f.controller.load(); await tick(); f.controller.reset(); f.user.current = { mid: 2 };
  const current = f.controller.load(); await tick(); f.requests[0].resolve({ users: [{ mid: 10 }] }); await old;
  assert.deepEqual(f.state().followed, []); await f.controller.load(); assert.equal(f.requests.length, 2);
  f.requests[1].resolve({ users: [{ mid: 20 }] }); await current; f.controller.reset();
  f.live[0].resolve([{ uid: 20, liveStatus: 1, roomId: 200 }]); await tick();
  assert.deepEqual(f.state().followed, []); assert.equal(f.state().liveRooms.size, 0);
});

test('session switch before login broadcast discards results and permits reloading', async () => {
  const f = fixture(), old = f.controller.load(); await tick(); f.session.advance(); f.user.current = { mid: 2 };
  f.requests[0].resolve({ users: [{ mid: 10 }] }); await old;
  const current = f.controller.load(); await tick(); assert.equal(f.requests.length, 2); assert.equal(f.requests[1].mid, 2);
  f.requests[1].resolve({ users: [] }); await current; assert.deepEqual(f.state().followed, []);
});

test('removing the page prevents both pending follow and live callbacks from publishing', async () => {
  const f = fixture(), pending = f.controller.load(); await tick(); f.controller.cancel();
  f.requests[0].resolve({ users: [{ mid: 10 }] }); await pending;
  assert.equal(f.states.length, 0); assert.equal(f.live.length, 0);
  const retry = f.controller.load(); await tick(); f.requests[1].resolve({ users: [{ mid: 20 }] }); await retry;
  const before = f.states.length; f.controller.cancel();
  f.live[0].resolve([{ uid: 20, liveStatus: 1, roomId: 200 }]); await tick(); assert.equal(f.states.length, before);
});
