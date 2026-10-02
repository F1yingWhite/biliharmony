const test = require('node:test');
const assert = require('node:assert/strict');
const { environment, deferred, tick, read } = require('./dynamic-test-env.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const page = (id, offset, hasMore = true) => ({ items: [{ dynId: id }], offset, hasMore });
function fixture() {
  const requests = [], published = [];
  let hostMid = 0;
  const request = args => { const next = deferred(); requests.push({ ...next, ...args }); return next.promise; };
  const env = environment({ 'api/DynamicApi': { DynamicApi: {
    getDynamicFeed: (offset, type) => request({ offset, type }),
    getUserDynamicFeed: (mid, offset) => request({ mid, offset }),
  } } });
  const { DynamicFeedController } = env.load('components/dynamic/DynamicFeedController');
  const feed = new DynamicFeedController(() => hostMid, states => published.push(states));
  return { feed, requests, published, session: env.load('services/auth/AuthSession').AuthSession,
    setHost: value => { hostMid = value; } };
}
async function seed(f, type, id, hasMore = true) {
  const pending = f.feed.activeType === type ? f.feed.load(true) : f.feed.select(type);
  f.requests.at(-1).resolve(page(id, type + '-next', hasMore)); await pending;
}
const ids = source => source.getAll().map(item => item.dynId);

test('cached return rejects the previous category response and cursor', async () => {
  const f = fixture(); await seed(f, 'all', 'all-original');
  const video = f.feed.select('video'); await f.feed.select('all');
  f.requests.at(-1).resolve(page('video-late', 'wrong', false)); await video;
  assert.deepEqual(ids(f.feed.source('all')), ['all-original']);
  assert.equal(f.feed.state().offset, 'all-next'); assert.equal(f.feed.state().hasMore, true);
  assert.equal(f.feed.state().loading, false); assert.equal(f.requests.length, 2);
});

test('mounted tabs own stable independent sources through selection and pagination', async () => {
  const f = fixture(), all = f.feed.source('all'), video = f.feed.source('video');
  let notices = 0;
  all.registerDataChangeListener({ onDataReloaded: () => notices++, onDataAdd: () => notices++ });
  await seed(f, 'all', 'a'); const count = notices;
  assert.deepEqual(ids(video), []); assert.equal(f.feed.state('video').loading, true);
  await seed(f, 'video', 'v');
  const pending = f.feed.load(false); f.requests.at(-1).resolve(page('v2', 'video-2', false)); await pending;
  assert.equal(f.feed.source('video'), video); assert.equal(f.feed.source('all'), all);
  assert.deepEqual(ids(video), ['v', 'v2']); assert.deepEqual(ids(all), ['a']); assert.equal(notices, count);
});

test('initial errors and cached empty results remain local to each category', async () => {
  const f = fixture(), failed = f.feed.load(true); f.requests[0].reject(Error('all-only')); await failed;
  assert.equal(f.feed.state().errorText, 'all-only'); assert.equal(f.feed.state().loading, false);
  assert.equal(f.feed.state('video').errorText, ''); assert.equal(f.feed.state('video').loading, true);
  await seed(f, 'all', 'a');
  const empty = f.feed.select('video');
  f.requests.at(-1).resolve({ items: [], offset: '', hasMore: false }); await empty;
  await f.feed.select('all'); await f.feed.select('video');
  assert.equal(f.requests.length, 3); assert.equal(f.feed.state().loaded, true);
  assert.equal(f.feed.state().loading, false); assert.equal(f.feed.state().count, 0);
  assert.equal(f.feed.state().hasMore, false);
});

test('late continuation cannot append into a cached destination or hide its load', async () => {
  const f = fixture(); await seed(f, 'video', 'v'); await seed(f, 'all', 'a');
  const old = f.feed.load(false), oldRequest = f.requests.at(-1);
  await f.feed.select('video'); const current = f.feed.load(false), next = f.requests.at(-1);
  oldRequest.resolve(page('old', 'wrong', false)); await old;
  assert.equal(f.feed.state().loading, true); assert.deepEqual(ids(f.feed.source('video')), ['v']);
  next.resolve(page('v2', 'next')); await current;
  assert.deepEqual(ids(f.feed.source('video')), ['v', 'v2']); assert.deepEqual(ids(f.feed.source('all')), ['a']);
});

test('uncached selection and superseded failures retain only the latest error and loading', async () => {
  const f = fixture(), video = f.feed.select('video'), pgc = f.feed.select('pgc');
  f.requests[0].reject(Error('登录已失效，请重新登录后查看动态')); await video;
  assert.equal(f.feed.state().loading, true); assert.equal(f.feed.state().needsLogin, false);
  f.requests[1].reject(Error('pgc offline')); await pgc;
  assert.equal(f.feed.activeType, 'pgc'); assert.equal(f.feed.state().errorText, 'pgc offline');
  assert.equal(f.feed.state().loading, false);
});

test('failed continuation retains cards and cursor and retries the same page', async () => {
  const f = fixture(); await seed(f, 'all', 'a');
  const failed = f.feed.load(false); f.requests.at(-1).reject(Error('offline')); await failed;
  assert.equal(f.feed.state().moreFailed, true); assert.equal(f.feed.state().retryReset, false);
  assert.equal(f.feed.state().offset, 'all-next'); assert.deepEqual(ids(f.feed.source('all')), ['a']);
  const retry = f.feed.load(false); assert.equal(f.requests.at(-1).offset, 'all-next');
  f.requests.at(-1).resolve(page('b', 'end', false)); await retry;
  assert.equal(f.feed.state().moreFailed, false); assert.deepEqual(ids(f.feed.source('all')), ['a', 'b']);
});

test('cached refresh failure retains reset retry mode and expired-login state', async () => {
  const f = fixture(); await seed(f, 'video', 'v'); const failed = f.feed.load(true);
  f.requests.at(-1).reject(Error('登录已失效，请重新登录后查看动态')); await failed;
  await seed(f, 'all', 'a'); await f.feed.select('video'); const state = f.feed.state();
  assert.equal(state.needsLogin, true); assert.equal(state.moreFailed, true); assert.equal(state.retryReset, true);
  assert.deepEqual(ids(f.feed.source('video')), ['v']);
});

test('reset clears mounted sources while retaining their identity and rejects old results', async () => {
  const f = fixture(); await seed(f, 'video', 'v'); await seed(f, 'all', 'a');
  const all = f.feed.source('all'), video = f.feed.source('video'), old = f.feed.load(false);
  f.feed.reset(); f.requests.at(-1).resolve(page('old-account', 'wrong')); await old;
  assert.equal(f.feed.source('all'), all); assert.equal(f.feed.source('video'), video);
  assert.deepEqual(ids(all), []); assert.deepEqual(ids(video), []);
  assert.equal(f.feed.state().offset, ''); assert.equal(f.feed.state().loaded, false);
});

test('page removal cancels pending work without notifying a destroyed subscriber', async () => {
  const f = fixture(); await seed(f, 'all', 'a'); const pending = f.feed.load(false);
  const before = f.published.length; f.feed.cancel();
  f.requests.at(-1).resolve(page('late', 'wrong')); await pending;
  assert.equal(f.published.length, before); assert.deepEqual(ids(f.feed.source('all')), ['a']);
  const retry = f.feed.load(false); f.requests.at(-1).resolve(page('new', 'next')); await retry;
  assert.deepEqual(ids(f.feed.source('all')), ['a', 'new']);
});

test('account changes before UI broadcast and host changes both reject stale responses', async () => {
  for (const change of ['session', 'host']) {
    const f = fixture(), old = f.feed.load(true);
    if (change === 'session') f.session.advance(); else f.setHost(42);
    f.requests[0].resolve(page('stale', 'wrong')); await old;
    assert.deepEqual(ids(f.feed.source('all')), []);
    const retry = f.feed.load(true); assert.equal(f.requests.length, 2);
    f.requests[1].resolve(page('fresh', 'right')); await retry;
    assert.deepEqual(ids(f.feed.source('all')), ['fresh']);
  }
});

test('public user feed passes host id and guards duplicate and end-of-list requests', async () => {
  const f = fixture(); f.setHost(123); const first = f.feed.load(false); await f.feed.load(false);
  assert.equal(f.requests.length, 1); assert.equal(f.requests[0].mid, 123);
  f.requests[0].resolve(page('user', 'end', false)); await first; await f.feed.load(false);
  assert.equal(f.requests.length, 1);
});

test('late likes update every cached copy without rebinding mounted rows', async () => {
  const f = fixture(); await seed(f, 'all', 'same'); await seed(f, 'video', 'same');
  f.feed.updateLike('same', true, 4);
  for (const type of ['all', 'video']) {
    assert.equal(f.feed.source(type).getData(0).liked, true); assert.equal(f.feed.source(type).getData(0).like, 4);
  }
});

function viewHarness(f) {
  const source = read('views/DynamicView');
  const method = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
  const methods = method('  private onRefresh()', '  @Builder\n  DynRefreshHeader()') +
    method('  private changeDynType(', '  @Builder\n  DynTypeChip(');
  const module = { exports: {} };
  new Function('module', 'exports', 'RefreshStatus', ts.transpileModule('export class View {' + methods + '}',
    { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText)(
      module, module.exports, { Inactive: 0 });
  const view = Object.assign(new module.exports.View(), { feed: f.feed, feedStates: f.feed.snapshots(),
    dynTypes: f.feed.types, dynType: 'all', refreshOperation: 0, refreshing: false,
    loadFeed: reset => f.feed.load(reset) });
  return { view, source };
}

test('old category refresh cannot hide the new refresh indicator', async () => {
  const f = fixture(); await seed(f, 'video', 'v'); await seed(f, 'all', 'a'); const { view } = viewHarness(f);
  view.onRefresh(); const old = f.requests.at(-1); view.changeDynType('video'); view.onRefresh();
  old.resolve(page('old', 'wrong')); await tick(); assert.equal(view.refreshing, true);
  f.requests.at(-1).resolve(page('new', 'right')); await tick(); assert.equal(view.refreshing, false);
});

test('page binds stable per-tab sources and ignores hidden-tab events', async () => {
  const f = fixture(); await seed(f, 'all', 'a'); const { view, source } = viewHarness(f);
  assert.match(source, /LazyForEach\(this\.pageSource\(tabIdx\)/);
  assert.match(source, /if \(this\.isActivePage\(tabIdx\) && !this\.pageState\(tabIdx\)\.moreFailed\) this\.loadFeed\(false\)/);
  assert.match(source, /onRefreshing\(\(\) => \{ if \(this\.isActivePage\(tabIdx\)\) this\.onRefresh\(\)/);
  assert.equal(view.isActivePage(1), false); assert.notEqual(view.pageSource(0), view.pageSource(1));
  assert.equal(view.pageState(1).loading, true); assert.equal(view.pageState(0).count, 1);
});

function lifecycleHarness(f, user) {
  const source = read('views/DynamicView');
  const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
  const methods = section('  aboutToAppear()', '  /** 惯用手切换') +
    section('  async init()', '  private onRefresh()');
  const module = { exports: {} };
  new Function('module', 'exports', 'UserStore', 'RefreshStatus', 'EmoteResolver', 'AppTheme', 'Handedness',
    ts.transpileModule('export class View {' + methods + '}', { compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
    } }).outputText)(module, module.exports, user, { Inactive: 0 }, { ensureLoaded() {} },
      { resetHeaderFade() {} }, { LEFT: 'left' });
  return Object.assign(new module.exports.View(), { feed: f.feed, active: true, lifecycle: 0,
    initializing: false, initPending: false, loading: true, login: false, hostMid: 0, embedded: false,
    refreshOperation: 0, refreshing: true, follow: { cancel() {}, load() {} },
    composer: { detach() {}, reset() {} } });
}

test('a destroyed page ignores delayed account initialization and cannot start a feed request', async () => {
  const f = fixture(), loaded = deferred(), user = { isLogin: false, ensureLoaded: () => loaded.promise };
  const view = lifecycleHarness(f, user), pending = view.init(); view.aboutToDisappear();
  user.isLogin = true; loaded.resolve(); await pending;
  assert.equal(f.requests.length, 0); assert.equal(view.login, false); assert.equal(view.refreshing, false);
});

test('reappearing during old initialization queues exactly one current lifecycle load', async () => {
  const f = fixture(), loaded = deferred(), user = { isLogin: false, ensureLoaded: () => loaded.promise };
  const view = lifecycleHarness(f, user), pending = view.init(); view.aboutToDisappear(); view.aboutToAppear();
  user.isLogin = true; loaded.resolve(); await pending; await tick();
  assert.equal(f.requests.length, 1); assert.equal(view.loading, true);
  f.requests[0].resolve(page('fresh', 'next')); await tick();
  assert.equal(view.loading, false); assert.equal(view.login, true);
});
