const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function videoFixture() {
  const pending = [], notices = [], dialogs = [];
  const api = name => (...args) => {const d = deferred(); pending.push({name, args, ...d}); return d.promise;};
  const state = {destroyed: false, login: true, aid: 1, bvid: 'BV1', upMid: 101, actionBusy: false,
    followLoading: false, liked: false, disliked: false, likeCount: 10, coinCountByMe: 0,
    coinCount: 2, coinChoice: 1, coinWithLike: true, coinSheetOpen: true,
    favorited: false, favoriteCount: 3, following: false};
  const store = {current: {mid: 7}};
  const load = createArktsLoader({mocks: {
    'api/BiliApi': {BiliApi: {likeVideo: api('like'), dislikeVideo: api('dislike'),
      coinVideo: api('coin'), likeTriple: api('triple')}},
    'api/UserApi': {UserApi: {setFollowed: api('follow')}},
    'api/HistoryApi': {HistoryApi: {addWatchLater: api('watch')}},
    'api/FavoriteApi': {FavoriteApi: {getFavoriteFoldersForVideo: api('folders'),
      addFavoriteFolder: api('create'), modifyVideoFavorite: api('favorite')}},
    'services/auth/UserStore': {UserStore: store}
  }});
  const access = {isDestroyed: () => state.destroyed, ensureLogin: () => state.login,
    toast: value => notices.push(value), isActionBusy: () => state.actionBusy,
    getAccent: () => 'pink', bumpLikeVersion() {}, bumpCoinVersion() {}, bumpFavoriteVersion() {},
    getUIContext: () => ({getPromptAction: () => ({showDialog: () => {
      const d = deferred(); dialogs.push(d); return d.promise;
    }})})};
  for (const key of Object.keys(state)) {
    const suffix = key[0].toUpperCase() + key.slice(1);
    access['get' + suffix] = () => state[key]; access['set' + suffix] = value => state[key] = value;
  }
  return {controller: new (load('components/video/VideoActionController').VideoActionController)(access),
    state, pending, notices, dialogs, store, auth: load('services/auth/AuthSession').AuthSession};
}

for (const method of ['actionLike', 'actionDislike', 'actionFollow', 'actionWatchLater', 'submitCoin', 'doTriple']) {
  test(`${method}: account change rejects late errors and reset lets a new operation keep its lock`, async () => {
    const f = videoFixture(); const old = f.controller[method]();
    assert.equal(f.pending.length, 1); f.auth.advance(); f.controller.reset();
    f.state.liked = false; f.state.disliked = false; f.state.following = false; f.state.coinCountByMe = 0;
    const fresh = f.controller[method](); assert.equal(f.pending.length, 2);
    f.pending[0].reject(Error('old account')); await old;
    assert.deepEqual(f.notices, []);
    assert.equal(method === 'actionFollow' ? f.state.followLoading : f.state.actionBusy, true);
    f.pending[1].resolve({ok: true, message: 'done'}); await fresh;
    assert.equal(method === 'actionFollow' ? f.state.followLoading : f.state.actionBusy, false);
  });
}

test('video action: changing target without a reset still prevents rollback and follow toast', async () => {
  for (const method of ['actionLike', 'actionFollow']) {
    const f = videoFixture(); const pending = f.controller[method]();
    f.state.aid = 2; f.state.bvid = 'BV2'; f.state.upMid = 202; f.state.liked = false; f.state.following = false;
    f.pending[0].resolve({ok: false, message: 'old error'}); await pending;
    assert.equal(f.state.liked, false); assert.equal(f.state.following, false); assert.deepEqual(f.notices, []);
  }
});

test('video action: disposal and same-target page reuse cannot revive a stale operation', async () => {
  const f = videoFixture(); const old = f.controller.actionLike(); f.controller.dispose();
  f.state.destroyed = true; f.state.destroyed = false; f.controller.reset(); f.state.liked = false;
  const fresh = f.controller.actionLike(); f.pending[0].resolve({ok: false, message: 'old'}); await old;
  assert.equal(f.state.liked, true); assert.equal(f.state.actionBusy, true);
  f.pending[1].resolve({ok: true}); await fresh;
});

test('video actions restore both mutually exclusive reactions after a failure', async () => {
  const like = videoFixture(); like.state.disliked = true;
  const a = like.controller.actionLike(); like.pending[0].resolve({ok: false, message: 'no'}); await a;
  assert.deepEqual([like.state.liked, like.state.disliked, like.state.likeCount], [false, true, 10]);
  const dislike = videoFixture(); dislike.state.liked = true;
  const b = dislike.controller.actionDislike(); dislike.pending[0].reject(Error('network')); await b;
  assert.deepEqual([dislike.state.liked, dislike.state.disliked], [true, false]);
});

test('coin failure uses the submitted checkbox snapshot even after editing the next form', async () => {
  const f = videoFixture(); const pending = f.controller.submitCoin();
  assert.deepEqual(f.pending[0].args, [1, 'BV1', 1, true]); f.state.coinWithLike = false; f.state.coinChoice = 2;
  f.pending[0].resolve({ok: false, message: 'failed'}); await pending;
  assert.deepEqual([f.state.liked, f.state.likeCount, f.state.coinCountByMe, f.state.coinCount], [false, 10, 0, 2]);
});

test('triple dialog is scoped to its target/account and cannot send after switching', async () => {
  for (const invalidate of [f => f.state.aid = 2, f => f.auth.advance(), f => f.controller.dispose()]) {
    const f = videoFixture(); f.controller.actionTriple(); invalidate(f);
    f.dialogs[0].resolve({index: 1}); await tick(); assert.equal(f.pending.length, 0);
  }
});

test('triple preserves existing coins/favorites and repeated confirmations cannot duplicate writes', async () => {
  const f = videoFixture(); f.state.favorited = true; f.state.coinCountByMe = 2;
  f.controller.actionTriple(); f.controller.actionTriple(); f.dialogs[0].resolve({index: 1}); await tick();
  f.dialogs[1].resolve({index: 1}); await tick(); assert.equal(f.pending.length, 1);
  f.pending[0].resolve({ok: true}); await tick();
  assert.equal(f.state.coinCountByMe, 2); assert.equal(f.state.favoriteCount, 3);
});

test('favorite multi-step flow captures IDs and cancels before creating or saving for a new account', async () => {
  const f = videoFixture(); const pending = f.controller.actionFavorite();
  assert.deepEqual(f.pending[0].args, [1, 7]); f.auth.advance(); f.controller.reset();
  f.pending[0].resolve([]); await pending; assert.equal(f.pending.length, 1); assert.deepEqual(f.notices, []);
  const g = videoFixture(); const save = g.controller.actionFavorite();
  g.pending[0].resolve([{id: 8, favorited: false}]); await tick();
  assert.deepEqual(g.pending[1].args, [1, [8], []]);
  g.state.aid = 2; g.state.favorited = false; g.pending[1].reject(Error('old target')); await save;
  assert.equal(g.state.favorited, false); assert.deepEqual(g.notices, []);
});

function bangumiFixture() {
  const pending = [], states = [], notices = [];
  const api = (...args) => {const d = deferred(); pending.push({args, ...d}); return d.promise;};
  const page = {destroyed: false, season: {seasonId: 1, followed: false, favorites: 5}, closed: 0};
  const load = createArktsLoader({mocks: {'api/BangumiApi': {BangumiApi: {setFollowed: api, updateFollowStatus: api}}}});
  const controller = new (load('components/bangumi/BangumiFollowController').BangumiFollowController)({
    getSeason: () => page.season, isDestroyed: () => page.destroyed, ensureLogin: () => true,
    toast: text => notices.push(text), publish: state => states.push(state), closeStatusPanel: () => page.closed++
  });
  controller.initialize(page.season);
  return {controller, page, pending, states, notices, auth: load('services/auth/AuthSession').AuthSession};
}

for (const method of ['toggle', 'setStatus']) {
  test(`bangumi ${method}: account and target changes suppress old writes before UI watchers run`, async () => {
    for (const invalidate of [f => f.auth.advance(), f => f.page.season = {seasonId: 2}]) {
      const f = bangumiFixture(); const pending = f.controller[method](4); invalidate(f);
      f.pending[0].resolve({ok: true, message: 'done'}); await pending;
      assert.equal(f.states.at(-1).followed, false); assert.equal(f.page.closed, 0); assert.deepEqual(f.notices, []);
    }
  });
}

test('bangumi initialization invalidates old writes, resets status and keeps the fresh operation busy', async () => {
  const f = bangumiFixture(); const old = f.controller.setStatus(4);
  f.controller.dispose(); f.page.season = {seasonId: 2, followed: false, favorites: 9};
  f.controller.initialize(f.page.season); const fresh = f.controller.toggle();
  f.pending[0].reject(Error('old')); await old; assert.equal(f.states.at(-1).busy, true);
  f.pending[1].resolve({ok: true, message: 'done'}); await fresh;
  assert.deepEqual({...f.states.at(-1)}, {followed: true, status: 0, favorites: 10, busy: false});
});
