const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');

// Execute complete production controllers and their real model/epoch/auth modules.
// Only network, palette extraction and host rendering are replaced at the boundary.
function loader(overrides) {
  const cache = new Map();
  function load(name) {
    if (Object.hasOwn(overrides, name)) return overrides[name];
    if (cache.has(name)) return cache.get(name).exports;
    const module = {exports: {}}; cache.set(name, module);
    const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
      compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
    }).outputText;
    new Function('require', 'module', 'exports', code)(specifier => {
      assert.ok(specifier.startsWith('.'), 'unexpected platform boundary: ' + specifier);
      return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), specifier)));
    }, module, module.exports);
    return module.exports;
  }
  return load;
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
}
function endpoint() {
  const calls = [];
  const fn = (...args) => {const d = deferred(); calls.push({args, ...d}); return d.promise;};
  return {calls, fn};
}
const flush = async () => {for (let i = 0; i < 6; i++) await Promise.resolve();};
const video = (aid, mid = aid + 100) => ({aid, bvid: 'BV' + aid, upMid: mid, cover: 'cover-' + aid});

function videoFixture() {
  const detail = endpoint(), stats = endpoint(), arcs = endpoint(), tags = endpoint(), palette = endpoint();
  const page = {alive: true, statuses: [], metadata: [], loaded: []};
  let gate = Promise.resolve();
  const load = loader({
    'api/BiliApi': {BiliApi: {getVideoDetail: detail.fn, getVideoTags: tags.fn}},
    'api/UserApi': {UserApi: {getUserStat: stats.fn, getUserSpaceArcs: arcs.fn}},
    'common/ImageColor': {ImageColor: {extract: palette.fn}}
  });
  const {VideoDetailController} = load('components/video/VideoDetailController');
  const controller = new VideoDetailController({isAlive: () => page.alive,
    waitEntrance: () => gate, publishStatus: status => page.statuses.push(status),
    publishMetadata: metadata => page.metadata.push(metadata), onLoaded: item => page.loaded.push(item)});
  return {controller, detail, stats, arcs, tags, palette, page,
    auth: load('services/auth/AuthSession').AuthSession, gate: value => gate = value};
}
const target = aid => ({aid, bvid: 'BV' + aid, epId: aid + 1000});

test('video detail waits for entrance before committing and starts public metadata independently', async () => {
  const f = videoFixture(), gate = deferred(); f.gate(gate.promise);
  const selected = target(1), pending = f.controller.load(selected); selected.aid = 99;
  assert.deepEqual(f.detail.calls[0].args, [1, 'BV1', 1001]);
  f.detail.calls[0].resolve(video(1)); await flush();
  assert.equal(f.page.loaded.length, 0); assert.equal(f.stats.calls.length, 0);
  gate.resolve(); await pending;
  assert.equal(f.page.loaded[0].aid, 1); assert.equal(f.page.statuses.at(-1).loading, false);
  assert.deepEqual(f.tags.calls[0].args, [1, 'BV1']);
  f.stats.calls[0].resolve({follower: 32}); f.arcs.calls[0].resolve({total: 14});
  f.tags.calls[0].resolve([{name: 'tag'}]); f.palette.calls[0].resolve({dominant: '#112233'}); await flush();
  assert.deepEqual(f.page.metadata.at(-1), {followers: 32, videos: 14, tags: [{name: 'tag'}], tint: '#112233'});
});

test('video detail: a superseded response and its finalizer cannot replace the new loading state', async () => {
  const f = videoFixture(); const a = f.controller.load(target(1)); const b = f.controller.load(target(2));
  f.detail.calls[0].resolve(video(1)); await a;
  assert.equal(f.page.loaded.length, 0); assert.equal(f.page.statuses.at(-1).loading, true);
  f.detail.calls[1].resolve(video(2)); await b;
  assert.deepEqual(f.page.loaded.map(x => x.aid), [2]);
});

test('video detail: old metadata for the same UP cannot write into a newly loaded video', async () => {
  const f = videoFixture(); const a = f.controller.load(target(1)); f.detail.calls[0].resolve(video(1, 7)); await a;
  const b = f.controller.load(target(2)); f.detail.calls[1].resolve(video(2, 7)); await b;
  const count = f.page.metadata.length;
  f.stats.calls[0].resolve({follower: 999}); f.arcs.calls[0].resolve({total: 999});
  f.tags.calls[0].resolve([{name: 'old'}]); f.palette.calls[0].resolve({dominant: 'old'}); await flush();
  assert.equal(f.page.metadata.length, count);
  f.stats.calls[1].resolve({follower: 2}); f.arcs.calls[1].resolve({total: 3}); await flush();
  assert.equal(f.page.metadata.at(-1).followers, 2); assert.equal(f.page.metadata.at(-1).videos, 3);
});

test('video metadata failure keeps unknown counts; emitted arrays are detached from later snapshots', async () => {
  const f = videoFixture(); const pending = f.controller.load(target(1)); f.detail.calls[0].resolve(video(1)); await pending;
  f.stats.calls[0].reject(Error('offline')); f.arcs.calls[0].reject(Error('offline')); await flush();
  assert.equal(f.page.metadata.at(-1).followers, -1); assert.equal(f.page.metadata.at(-1).videos, -1);
  f.tags.calls[0].resolve([{name: 'one'}]); await flush(); f.page.metadata.at(-1).tags.push({name: 'host mutation'});
  f.palette.calls[0].resolve({dominant: 'blue'}); await flush();
  assert.deepEqual(f.page.metadata.at(-1).tags, [{name: 'one'}]);
});

test('video detail: no UP produces real zero counts without issuing invalid user requests', async () => {
  const f = videoFixture(); const pending = f.controller.load(target(1)); f.detail.calls[0].resolve(video(1, 0)); await pending;
  assert.equal(f.stats.calls.length, 0); assert.equal(f.arcs.calls.length, 0);
  assert.equal(f.page.metadata.at(-1).followers, 0); assert.equal(f.page.metadata.at(-1).videos, 0);
});

test('video detail: exit invalidates primary and metadata requests across reuse', async () => {
  const f = videoFixture(); const a = f.controller.load(target(1)); f.controller.dispose(); f.page.alive = false;
  f.detail.calls[0].resolve(video(1)); await a; assert.equal(f.page.loaded.length, 0);
  f.page.alive = true; const b = f.controller.load(target(2)); f.detail.calls[1].resolve(video(2)); await b;
  const before = f.page.metadata.length; f.controller.dispose();
  f.stats.calls[0].resolve({follower: 999}); await flush(); assert.equal(f.page.metadata.length, before);
});

test('video detail: a changed account during the entrance wait drops the old response', async () => {
  const f = videoFixture(), gate = deferred(); f.gate(gate.promise);
  const pending = f.controller.load(target(1)); f.detail.calls[0].resolve(video(1)); await flush();
  f.auth.advance(); gate.resolve(); await pending;
  assert.equal(f.page.loaded.length, 0); assert.equal(f.page.statuses.at(-1).loading, false);
});

test('video detail: null and network failures publish retry errors', async () => {
  for (const failed of [false, true]) {
    const f = videoFixture(); const pending = f.controller.load(target(1));
    if (failed) f.detail.calls[0].reject(Error('offline')); else f.detail.calls[0].resolve(null);
    await pending; assert.equal(f.page.loaded.length, 0); assert.equal(f.page.statuses.at(-1).loading, false);
    assert.ok(f.page.statuses.at(-1).error.length > 0);
  }
});

function accountFixture() {
  const relation = endpoint(), follow = endpoint(), emotes = endpoint();
  const store = {isLogin: true};
  const page = {alive: true, revision: {like: 0, coin: 0, favorite: 0, follow: 0},
    relations: [], follows: [], emotes: []};
  const load = loader({
    'api/BiliApi': {BiliApi: {getVideoRelation: relation.fn}},
    'api/UserApi': {UserApi: {getRelation: follow.fn}},
    'api/CommentApi': {CommentApi: {getUserEmotes: emotes.fn}},
    'services/auth/UserStore': {UserStore: store}
  });
  const {VideoAccountController} = load('components/video/VideoAccountController');
  const controller = new VideoAccountController({isAlive: () => page.alive, getRevision: () => page.revision,
    publishRelation: snapshot => page.relations.push(snapshot), publishFollow: status => page.follows.push(status),
    publishEmotes: status => page.emotes.push(status)});
  return {controller, relation, follow, emotes, page, store, auth: load('services/auth/AuthSession').AuthSession};
}
const liked = {liked: true, disliked: false, coin: 1, favorite: true};

test('video account: relation revisions are captured and read results do not republish unrelated state', async () => {
  const f = accountFixture(); f.controller.activate(video(1));
  f.page.revision.like++; f.page.revision.coin++; f.page.revision.favorite++;
  f.relation.calls[0].resolve(liked); await flush();
  assert.deepEqual(f.page.relations.at(-1), {value: liked, revision: {like: 0, coin: 0, favorite: 0, follow: 0}});
  const relationCount = f.page.relations.length;
  f.follow.calls[0].resolve(6); f.emotes.calls[0].resolve([{id: 10}]); await flush();
  assert.equal(f.page.relations.length, relationCount);
  assert.deepEqual(f.page.follows.at(-1), {following: true, loading: false, revision: 0});
  assert.deepEqual(f.page.emotes.at(-1), {packages: [{id: 10}], loading: false});
});

test('video account: changing video/UP invalidates every older result and does not unlock the new request', async () => {
  const f = accountFixture(); f.controller.activate(video(1)); f.controller.activate(video(2));
  const counts = [f.page.relations.length, f.page.follows.length, f.page.emotes.length];
  f.relation.calls[0].resolve(liked); f.follow.calls[0].resolve(6); f.emotes.calls[0].resolve([]); await flush();
  assert.deepEqual([f.page.relations.length, f.page.follows.length, f.page.emotes.length], counts);
  assert.equal(f.emotes.calls.length, 2); // stale reply packages must not start a dynamic fallback
  assert.equal(f.page.follows.at(-1).loading, true); assert.equal(f.page.emotes.at(-1).loading, true);
  f.follow.calls[1].resolve(128); f.emotes.calls[1].resolve([{id: 2}]); await flush();
  assert.equal(f.page.follows.at(-1).following, false); assert.deepEqual(f.page.emotes.at(-1).packages, [{id: 2}]);
});

test('video account: logout clears personalized data and late requests; login fetches fresh packages', async () => {
  const f = accountFixture(); f.controller.activate(video(1));
  f.auth.advance(); f.store.isLogin = false; f.controller.refresh();
  const count = f.page.emotes.length;
  f.relation.calls[0].resolve(liked); f.follow.calls[0].resolve(2); f.emotes.calls[0].resolve([{id: 1}]); await flush();
  assert.equal(f.page.emotes.length, count); assert.deepEqual(f.page.emotes.at(-1), {packages: [], loading: false});
  assert.equal(f.page.relations.at(-1).value.liked, false); assert.equal(f.page.follows.at(-1).following, false);
  f.auth.advance(); f.store.isLogin = true; f.controller.refresh();
  assert.equal(f.emotes.calls.length, 2); assert.equal(f.follow.calls.length, 2); assert.equal(f.relation.calls.length, 2);
});

test('video account: auth changes reject results even before the UI account watcher runs', async () => {
  const f = accountFixture(); f.controller.activate(video(1)); f.auth.advance();
  const counts = [f.page.relations.length, f.page.follows.length, f.page.emotes.length];
  f.relation.calls[0].resolve(liked); f.follow.calls[0].resolve(2); f.emotes.calls[0].resolve([]); await flush();
  assert.deepEqual([f.page.relations.length, f.page.follows.length, f.page.emotes.length], counts);
  await f.controller.loadEmotes(); assert.equal(f.emotes.calls.length, 2);
});

test('video emotes: duplicate opens coalesce, empty reply falls back, accepted packages are cached', async () => {
  const f = accountFixture(); f.controller.activate(video(1));
  await f.controller.loadEmotes(); assert.equal(f.emotes.calls.length, 1);
  f.emotes.calls[0].resolve([]); await flush(); assert.deepEqual(f.emotes.calls[1].args, ['dynamic']);
  f.emotes.calls[1].resolve([{id: 3}]); await flush(); await f.controller.loadEmotes();
  assert.equal(f.emotes.calls.length, 2); assert.deepEqual(f.page.emotes.at(-1), {packages: [{id: 3}], loading: false});
});

test('video emotes: failures release the lock for retry; null relation leaves follow state untouched', async () => {
  const f = accountFixture(); f.controller.activate(video(1));
  f.emotes.calls[0].reject(Error('offline')); f.follow.calls[0].resolve(null); await flush();
  assert.equal(f.page.emotes.at(-1).loading, false);
  assert.deepEqual(f.page.follows.at(-1), {following: null, loading: false, revision: 0});
  const pending = f.controller.loadEmotes(); assert.equal(f.emotes.calls.length, 2);
  f.emotes.calls[1].resolve([{id: 4}]); await pending; assert.equal(f.page.emotes.at(-1).packages[0].id, 4);
});

test('video account: leave/reenter and reset invalidate old follow and fallback completions', async () => {
  const f = accountFixture(); f.controller.activate(video(1)); f.emotes.calls[0].resolve([]); await flush();
  f.controller.dispose(); f.page.alive = false;
  const counts = [f.page.relations.length, f.page.follows.length, f.page.emotes.length];
  f.follow.calls[0].resolve(2); f.emotes.calls[1].resolve([{id: 99}]); await flush();
  assert.deepEqual([f.page.relations.length, f.page.follows.length, f.page.emotes.length], counts);
  f.page.alive = true; f.controller.activate(video(2)); f.controller.reset();
  const count = f.page.follows.length; f.follow.calls[1].resolve(6); await flush();
  assert.equal(f.page.follows.length, count); assert.equal(f.page.follows.at(-1).following, false);
});

function simpleFixture(kind) {
  const api = endpoint(), page = {alive: true, states: [], accepted: []};
  const bangumi = kind === 'bangumi';
  const load = loader(bangumi ? {'api/BangumiApi': {BangumiApi: {getSeason: api.fn}}} :
    {'api/DynamicApi': {DynamicApi: {getDynamicDetail: api.fn}}});
  const Controller = load(bangumi ? 'components/bangumi/BangumiDetailController' :
    'components/dynamic/DynamicDetailController')[bangumi ? 'BangumiDetailController' : 'DynamicDetailController'];
  const controller = new Controller({isAlive: () => page.alive, publish: state => page.states.push(state),
    onLoaded: (item, epId) => page.accepted.push({item, epId})});
  return {controller, api, page, auth: load('services/auth/AuthSession').AuthSession,
    load: id => bangumi ? controller.load(id, id + 10) : controller.load(String(id)),
    failed: () => bangumi ? page.states.at(-1).error.length > 0 : page.states.at(-1).failed};
}

for (const kind of ['bangumi', 'dynamic']) {
  test(`${kind} detail: newest target wins while loading and old finalizers leave the new spinner intact`, async () => {
    const f = simpleFixture(kind); const a = f.load(1), b = f.load(2);
    f.api.calls[0].reject(Error('old request')); await a;
    assert.equal(f.page.states.at(-1).loading, true); assert.equal(f.failed(), false);
    f.api.calls[1].resolve({id: 2}); await b;
    assert.deepEqual(f.page.accepted.map(x => x.item.id), [2]); assert.equal(f.page.states.at(-1).loading, false);
    if (kind === 'bangumi') assert.equal(f.page.accepted[0].epId, 12);
  });
  test(`${kind} detail: old account and disposed sessions cannot publish content after reuse`, async () => {
    const f = simpleFixture(kind); const a = f.load(1); f.auth.advance();
    f.api.calls[0].resolve({id: 1}); await a; assert.equal(f.page.accepted.length, 0);
    const b = f.load(2); f.controller.dispose(); f.page.alive = false;
    f.api.calls[1].resolve({id: 2}); await b; assert.equal(f.page.accepted.length, 0);
    f.page.alive = true; const c = f.load(3); f.api.calls[2].resolve({id: 3}); await c;
    assert.deepEqual(f.page.accepted.map(x => x.item.id), [3]);
  });
  test(`${kind} detail: null/error are retryable and successful retry clears the failure`, async () => {
    const f = simpleFixture(kind); const a = f.load(1); f.api.calls[0].resolve(null); await a; assert.equal(f.failed(), true);
    const b = f.load(1); f.api.calls[1].reject(Error('network')); await b; assert.equal(f.failed(), true);
    const c = f.load(1); f.api.calls[2].resolve({id: 1}); await c; assert.equal(f.failed(), false);
  });
}

test('dynamic detail: empty target invalidates older work without leaving a loading lock', async () => {
  const f = simpleFixture('dynamic'); const pending = f.load(1); await f.controller.load('');
  f.api.calls[0].resolve({id: 1}); await pending;
  assert.equal(f.page.accepted.length, 0); assert.deepEqual(f.page.states.at(-1), {loading: false, failed: false});
});
