// Exercise the whole homepage -> FeedApi -> ApiCommon -> HttpClient/HttpResponse chain.
// Only native transport, signing and unrelated account/follow/filter boundaries are fake.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');
const webItem = aid => ({ goto: 'av', id: aid, bvid: 'BV' + aid, owner: { mid: 3, name: 'up' }, title: 'video ' + aid });
const appItem = (aid, idx) => ({ card_goto: 'av', can_play: 1, param: String(aid), idx, title: 'video ' + aid });
const response = (json, status = 200) => ({ responseCode: status, header: {}, result: JSON.stringify(json) });
const page = (source, aid, cursor = aid) => response({ code: 0, data: source === 'web' ?
  { item: aid ? [webItem(aid)] : [], feed_id: 'feed-' + cursor, bucket_id: 'bucket-' + cursor } :
  { items: aid ? [appItem(aid, cursor)] : [] } });
function fixture({ mode = 'web', loggedIn = true, handler } = {}) {
  const storage = new Map([['recommendMode', mode]]), requests = [], snapshots = [];
  const load = createArktsLoader({ mocks: {
    'common/WbiSign': { WbiSign: { encWbi: async () => {}, invalidate() {} } },
    'common/AppSign': { appSign: async () => {} },
    'api/LiveApi': { LiveApi: {} }, 'api/UserApi': { UserApi: { loadFeedFollowStates: async () => {} } },
    'services/auth/UserStore': { UserStore: { ensureLoaded: async () => {} } },
    'services/auth/CookieRefresher': { CookieRefresher: { onAuthFailure() {} } },
    'common/LocalVideoFilter': { LocalVideoFilter: { filterVideos: rows => rows, hide: async () => {} } },
    '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { taskpool: { execute: async (fn, ...args) => fn(...args) } },
    '@kit.NetworkKit': { connection: {}, http: {
      RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0, ARRAY_BUFFER: 1 },
      createHttp: () => ({ request(url, options) {
        const source = url.includes('/feed/rcmd') ? 'web' : 'app';
        assert.ok(url.includes('/feed/rcmd') || url.includes('/feed/index'), url);
        const request = { source, url, options, params: new URL(url).searchParams };
        requests.push(request); return handler(request);
      }, destroy() {} })
    } }
  }, globals: { AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) } } });
  const { HttpClient } = load('services/network/HttpClient');
  HttpClient.setCookie('buvid3', 'test-device');
  if (loggedIn) { HttpClient.setCookie('SESSDATA', 'fake-account'); HttpClient.setCookie('DedeUserID', '1'); HttpClient.setAppAccessToken('fake-access'); }
  const { HomeFeedController, homeFeedPhase, HomeFeedPhase } = load('components/home/HomeFeedController');
  const controller = new HomeFeedController(value => snapshots.push(value));
  return { controller, requests, snapshots, HttpClient,
    FeedApi: load('api/FeedApi').FeedApi, AuthSession: load('services/auth/AuthSession').AuthSession,
    state: () => snapshots.at(-1).channels[0], phase: () => homeFeedPhase(snapshots.at(-1).channels[0]), HomeFeedPhase };
}
const failures = {
  transport: () => Promise.reject({ code: 2300007 }),
  http: () => response({}, 503),
  business: () => response({ code: -352, message: 'blocked' }),
  json: () => ({ responseCode: 200, header: {}, result: '{broken' }),
  missingData: () => response({ code: 0 }),
  missingItems: () => response({ code: 0, data: {} }),
  invalidItems: () => response({ code: 0, data: { item: {}, items: {} } })
};
for (const [name, failure] of Object.entries(failures)) {
  test(`real homepage shows ERROR when both recommendation sources fail (${name})`, async () => {
    const f = fixture({ handler: failure }); await f.controller.activate();
    assert.equal(f.phase(), f.HomeFeedPhase.ERROR);
    assert.equal(f.controller.recommend.totalCount(), 0);
    assert.equal(f.state().refreshing, false); assert.equal(f.state().settled, true);
    assert.deepEqual(f.requests.map(x => x.source), ['web', 'app']);
  });
}
for (const mode of ['web', 'app']) {
  const other = mode === 'web' ? 'app' : 'web';
  test(`valid empty ${mode} page stays EMPTY if fallback ${other} fails`, async () => {
    const f = fixture({ mode, handler: request => request.source === mode ? page(mode, 0) : failures.http() });
    await f.controller.activate(); assert.equal(f.phase(), f.HomeFeedPhase.EMPTY); assert.equal(f.state().error, '');
  });
  test(`failed ${mode} source uses fallback ${other} content`, async () => {
    const f = fixture({ mode, handler: request => request.source === mode ? failures.missingItems() : page(other, 7) });
    await f.controller.activate(); assert.equal(f.phase(), f.HomeFeedPhase.CONTENT);
    assert.equal(f.controller.recommend.getData(0).aid, 7);
    assert.deepEqual(f.requests.map(x => x.source), [mode, other]);
  });
  test(`${mode} load-more failure preserves rows and retry requests the retained cursor`, async () => {
    let failing = false;
    const f = fixture({ mode, handler: request => {
      if (failing || request.source !== mode) return failures.missingItems();
      const next = mode === 'web' ? request.params.get('fresh_idx') === '2' : request.params.get('idx') === '11';
      return page(mode, next ? 2 : 1, next ? 22 : 11);
    } });
    await f.controller.activate(); failing = true; await f.controller.load(0, false);
    assert.equal(f.phase(), f.HomeFeedPhase.CONTENT); assert.ok(f.state().error.length > 0);
    assert.deepEqual(f.controller.recommend.getAll().map(x => x.aid), [1]);
    failing = false; await f.controller.retry(0);
    assert.equal(f.state().error, ''); assert.deepEqual(f.controller.recommend.getAll().map(x => x.aid), [1, 2]);
    const primary = f.requests.filter(x => x.source === mode);
    assert.deepEqual(primary.map(x => x.params.get(mode === 'web' ? 'fresh_idx' : 'idx')), mode === 'web' ? ['1', '2', '2'] : ['0', '11', '11']);
    if (mode === 'web') assert.equal(primary[2].params.get('feed_id'), 'feed-11');
  });
}
test('valid fallback empty page also yields EMPTY when the primary source fails', async () => {
  const f = fixture({ handler: request => request.source === 'web' ? failures.http() : page('app', 0) });
  await f.controller.activate(); assert.equal(f.phase(), f.HomeFeedPhase.EMPTY); assert.equal(f.state().error, '');
});
test('guest Web mode keeps its App-only routing and reports its real failure', async () => {
  const f = fixture({ loggedIn: false, handler: failures.http }); await f.controller.activate();
  assert.equal(f.phase(), f.HomeFeedPhase.ERROR); assert.deepEqual(f.requests.map(x => x.source), ['app']);
});
test('old recommendation failure stays silent after a new account has loaded content', async () => {
  const old = deferred(); let first = true;
  const f = fixture({ handler: request => { if (first) { first = false; return old.promise; } return page(request.source, 2, 22); } });
  const obsolete = f.controller.activate(); await tick();
  f.AuthSession.advance(); await f.controller.accountChanged();
  const published = f.snapshots.length;
  old.resolve(failures.http()); await obsolete;
  assert.equal(f.snapshots.length, published); assert.equal(f.state().error, '');
  assert.deepEqual(f.controller.recommend.getAll().map(x => x.aid), [2]);
  await f.FeedApi.getRecommendWeb();
  assert.equal(f.requests.at(-1).params.get('fresh_idx'), '2');
  assert.equal(f.requests.at(-1).params.get('feed_id'), 'feed-22');
});

test('late malformed response from a reset feed session cannot publish error or change its cursor', async () => {
  const old = deferred(); let first = true;
  const f = fixture({ handler: request => { if (first) { first = false; return old.promise; } return page(request.source, 3, 33); } });
  const obsolete = f.controller.activate(); await tick();
  await f.controller.recommendModeChanged(); const published = f.snapshots.length;
  old.resolve(failures.json()); await obsolete;
  assert.equal(f.snapshots.length, published); assert.equal(f.state().error, '');
  assert.deepEqual(f.controller.recommend.getAll().map(x => x.aid), [3]);
  await f.FeedApi.getRecommendWeb();
  assert.equal(f.requests.at(-1).params.get('fresh_idx'), '2');
  assert.equal(f.requests.at(-1).params.get('feed_id'), 'feed-33');
});
