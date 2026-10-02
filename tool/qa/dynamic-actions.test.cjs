// Production DynCard action/lifecycle methods, model defaults, AuthSession and feed writeback.
// Controlled API promises and ArkUI's prop rebinding/prompt boundary make races deterministic.
const test = require('node:test');
const assert = require('node:assert/strict');
const { environment } = require('./dynamic-test-env.cjs');
function fixture() {
  const notices = [], requests = [];
  const pending = (kind, args) => {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    requests.push({ kind, args, resolve, reject });
    return promise;
  };
  const env = environment({
    'api/DynamicApi': { DynamicApi: {
      likeDynamic: (...args) => pending('like', args), repostDynamic: (...args) => pending('forward', args),
    } },
    'services/auth/UserStore': { UserStore: { isLogin: true } },
  });
  const { AuthSession } = env.load('services/auth/AuthSession');
  const { DynamicCardActions } = env.load('components/dynamic/DynamicCardActions');
  const { DynamicFeedController } = env.load('components/dynamic/DynamicFeedController');
  const item = (liked, like, dynId = 'same') => ({ dynId, liked, like, forward: 0 });
  function feed(liked, like) {
    const controller = new DynamicFeedController(() => 0, () => {});
    const dynSource = controller.source('all'), cached = controller.source('video');
    dynSource.reset([item(liked, like)]); cached.reset([item(liked, like)]);
    const callbacks = [];
    return { view: { dynSource }, callbacks, cached,
      callback: (...args) => { callbacks.push(args); controller.updateLike(...args); } };
  }
  const origin = feed(true, 20), destination = feed(false, 19);
  const card = { item: item(true, 20), onLikeResult: origin.callback };
  let state;
  const actions = new DynamicCardActions(() => card.item, () => card.onLikeResult,
    value => { state = value; }, message => notices.push(message));
  for (const [field, key] of [['liked', 'liked'], ['likeCount', 'likeCount'],
    ['forwardCount', 'forwardCount'], ['actionBusy', 'busy']]) {
    Object.defineProperty(card, field, { get: () => state[key] });
  }
  card.toggleLike = () => actions.toggleLike();
  card.forwardDynamic = () => actions.forwardDynamic();
  card.onItemChanged = () => actions.sync();
  card.aboutToDisappear = () => actions.invalidate();
  actions.sync();
  function reuse(liked = false, like = 19, callback = destination.callback) {
    actions.invalidate(); card.item = item(liked, like); card.onLikeResult = callback; actions.sync();
  }
  return { card, AuthSession, origin, destination, requests, notices, reuse, item };
}

for (const result of ['failure', 'success', 'rejection']) {
  test(`late dynamic like ${result} from a replaced account cannot change its same-id card or feed`, async () => {
    const f = fixture(), old = f.card.toggleLike();
    assert.equal(f.card.liked, false, 'first account optimistically unlikes');
    f.AuthSession.advance(); f.reuse();
    if (result === 'rejection') f.requests[0].reject(Error('old account offline'));
    else f.requests[0].resolve({ ok: result === 'success', message: 'old account result' });
    await old;
    assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like], [false, 19, false, 19]);
    assert.equal(f.destination.view.dynSource.getData(0).liked, false);
    assert.deepEqual(f.origin.callbacks, []); assert.deepEqual(f.destination.callbacks, []);
    assert.deepEqual(f.notices, []); assert.equal(f.card.actionBusy, false);
  });
}

test('an account change without prop rebinding releases the completed request own busy flag while ignoring its result', async () => {
  for (const action of ['toggleLike', 'forwardDynamic']) {
    for (const outcome of ['failure', 'success', 'rejection']) {
      const f = fixture(), pending = f.card[action]();
      const originalItem = f.card.item;
      const expected = [f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like, f.card.forwardCount];
      f.AuthSession.advance();
      if (outcome === 'rejection') f.requests[0].reject(Error('old account offline'));
      else f.requests[0].resolve({ ok: outcome === 'success', message: 'old account result' });
      await pending;
      assert.equal(f.card.item, originalItem, 'no native rebind/disappear has occurred yet');
      assert.equal(f.card.actionBusy, false, action + '/' + outcome + ': the completed request must release its own lock');
      assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like, f.card.forwardCount], expected);
      assert.deepEqual(f.origin.callbacks, []); assert.deepEqual(f.destination.callbacks, []);
      assert.deepEqual(f.notices, []);
    }
  }
});

test('same-id reuse: an old like failure and finally cannot roll back or unlock a newer action', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.reuse(false, 50);
  const current = f.card.toggleLike();
  assert.equal(f.requests.length, 2); assert.equal(f.card.actionBusy, true);
  f.requests[0].resolve({ ok: false, message: 'first request failed' }); await old;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.like], [true, 51, 51]);
  assert.equal(f.card.actionBusy, true); assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.equal(f.card.actionBusy, false); assert.deepEqual(f.destination.callbacks, [['same', true, 51]]);
});

test('same account late success writes the originating callback and all its cached categories after reuse', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.reuse(false, 50);
  const current = f.card.toggleLike();
  f.requests[0].resolve({ ok: true }); await old;
  assert.deepEqual(f.origin.callbacks, [['same', false, 19]]);
  assert.deepEqual([f.origin.view.dynSource.getData(0).liked, f.origin.cached.getData(0).liked], [false, false]);
  assert.deepEqual(f.destination.callbacks, [], 'the reused card callback belongs to its new host');
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [true, 51, true]);
  assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.deepEqual(f.destination.callbacks, [['same', true, 51]]);
  assert.equal(f.card.actionBusy, false);
});

test('prop rebinding invalidates an old like failure even when the dynamic id is unchanged', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.card.item = f.item(false, 60); f.card.onItemChanged();
  const current = f.card.toggleLike();
  assert.equal(f.requests.length, 2, 'rebinding must release the old row action lock');
  f.requests[0].reject(Error('old row offline')); await old;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [true, 61, true]);
  assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.equal(f.card.actionBusy, false);
});

test('a disappeared like row can update its same-account feed but cannot show a stale toast or mutate its old UI', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.card.aboutToDisappear();
  assert.equal(f.card.actionBusy, false);
  f.requests[0].resolve({ ok: true }); await old;
  assert.deepEqual(f.origin.callbacks, [['same', false, 19]]);
  assert.deepEqual(f.notices, []);
});

test('current like failures still roll back, show the error and allow retry; success commits once', async () => {
  const f = fixture(), failed = f.card.toggleLike();
  f.requests[0].resolve({ ok: false, message: 'server refused' }); await failed;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like], [true, 20, true, 20]);
  assert.equal(f.card.actionBusy, false); assert.deepEqual(f.notices, ['server refused']);
  const success = f.card.toggleLike();
  await f.card.toggleLike(); assert.equal(f.requests.length, 2, 'busy guard blocks a duplicate request');
  f.requests[1].resolve({ ok: true }); await success;
  assert.deepEqual(f.origin.callbacks, [['same', false, 19]]);
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [false, 19, false]);
});

test('an optimistic field-change watch on the same item does not invalidate or unlock its own request', async () => {
  const f = fixture(), current = f.card.toggleLike();
  f.card.onItemChanged(); // ArkUI @Watch may run for the optimistic item.liked/item.like writes.
  assert.equal(f.card.actionBusy, true);
  await f.card.toggleLike(); assert.equal(f.requests.length, 1);
  f.requests[0].resolve({ ok: false, message: 'server refused' }); await current;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [true, 20, false]);
  assert.deepEqual(f.notices, ['server refused']);
});

test('an old forward result cannot mutate a reused card or unlock its pending like request', async () => {
  const f = fixture(), old = f.card.forwardDynamic();
  f.reuse(false, 50); const current = f.card.toggleLike();
  f.requests[0].resolve({ ok: true }); await old;
  assert.equal(f.card.forwardCount, 0); assert.equal(f.card.item.forward, 0);
  assert.equal(f.card.actionBusy, true); assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.equal(f.card.actionBusy, false);
});
