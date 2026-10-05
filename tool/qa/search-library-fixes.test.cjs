// Execute full search controllers and production WatchLater methods; only platform/API boundaries are fake.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || root;
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function read(file) {
  const override = path.join(sourceRoot, file + '.ets');
  return fs.readFileSync(fs.existsSync(override) ? override : path.join(root, file + '.ets'), 'utf8').replace(/\r\n/g, '\n');
}
function section(source, start, end) {
  const begin = source.indexOf(start), finish = source.indexOf(end, begin);
  assert.ok(begin >= 0 && finish > begin, 'production anchors: ' + start + ' -> ' + end);
  return source.slice(begin, finish);
}
function environment(overrides = {}) {
  const cache = new Map();
  function compile(source, file, globals = {}) {
    const module = { exports: {} };
    const code = ts.transpileModule(source, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const requireLocal = name => {
      if (name.startsWith('.')) return load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)));
      if (name === '@kit.ArkTS') return { collections: { Array }, util: {}, taskpool: {} };
      if (name === '@kit.PerformanceAnalysisKit') return { hilog: { debug() {}, info() {}, warn() {}, error() {} } };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: {} };
      throw new Error('unmocked platform dependency: ' + name);
    };
    new Function('require', 'module', 'exports', 'Sendable', 'Concurrent', ...Object.keys(globals), code)(
      requireLocal, module, module.exports, x => x, x => x, ...Object.values(globals));
    return module.exports;
  }
  function load(file) {
    if (Object.hasOwn(overrides, file)) return overrides[file];
    if (!cache.has(file)) cache.set(file, compile(read(file), file));
    return cache.get(file);
  }
  function component(file, name, firstMethod, ranges, globals) {
    const source = read(file);
    // Keep actual @State/private field defaults so newly added production state cannot be omitted by the fixture.
    const declarations = section(source, 'export struct ' + name + ' {', firstMethod)
      .replace('export struct ' + name, 'export class Harness')
      .replace(/@(?:Prop|State|StorageProp|Watch)\s*(?:\([^)]*\))?\s*/g, '');
    const methods = ranges.map(([start, end]) => section(source, start, end)).join('\n');
    return compile(declarations + methods + '\n}', file, globals).Harness;
  }
  return { load, component, compile };
}
function searchHarness(overrides = {}) {
  const calls = [];
  const api = {};
  for (const method of ['searchAll', 'searchVideosByType', 'searchUsers', 'searchMedia', 'searchLiveRooms', 'searchArticles']) {
    api[method] = async (...args) => {
      calls.push({ method, args });
      if (overrides[method]) return overrides[method](...args);
      if (method === 'searchAll') return allResult(args[0], 10);
      if (method === 'searchVideosByType') return { videos: [video(args[0], args[1])], numResults: 3 };
      if (method === 'searchUsers') return { users: [{ mid: args[1] }], numResults: 1 };
      throw new Error('test must supply response for ' + method);
    };
  }
  const env = environment({ 'api/SearchApi': { SearchApi: api } });
  const { SearchResultsController } = env.load('components/search/SearchResultsController');
  const { SearchQuery } = env.load('components/search/SearchQuery');
  return { controller: new SearchResultsController(), query: new SearchQuery(), calls, env };
}
function inputPage(controller, query, storage = new Map()) {
  const env = environment({ 'api/SearchApi': { SearchApi: {} } });
  const { SearchQuery } = env.load('components/search/SearchQuery');
  const { SearchResultsView } = env.load('components/search/SearchResultsController');
  const Harness = env.component('pages/Search', 'SearchPage', '  async aboutToAppear()', [
    ['  async aboutToAppear()', '  @Builder\n  SortRow()'],
  ], { SearchQuery, SearchResultsView, SearchDiscoveryView: class {},
    SearchResultsController: class {}, SearchDiscoveryController: class {},
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    inputMethod: { getController: () => ({ hideTextInput: async () => {} }) } });
  const page = new Harness();
  page.resultsController = controller;
  page.query = query;
  page.discoveryController = { input() {}, submit() {} };
  return page;
}

function initialSearchPage({initialKeyword = '', storage = new Map(), ready = Promise.resolve()} = {}) {
  const search = searchHarness(), history = [];
  const page = inputPage(search.controller, search.query, storage);
  page.initialKeyword = initialKeyword;
  page.discoveryController = { input() {}, activate: () => ready, dispose() {}, submit: keyword => history.push(keyword) };
  return {...search, page, storage, history};
}

test('Index actual search destination validates and forwards only this route keyword', () => {
  const env = environment(), source = read('pages/Index'), calls = [];
  const helpers = section(source, '  private static asVideoDetailParam(', '  @Builder\n  InvalidParamContent()');
  const branch = section(source, '    } else if (name === NAV_SEARCH) {', '    } else if (name === NAV_MESSAGES) {')
    .replace('    } else if (name === NAV_SEARCH) {', '')
    .replace('NavDestination() {', 'NavDestination(() => {')
    .replace(/\n      }\n      \.stdDestination/, '\n      })\n      .stdDestination');
  const chain = {stdDestination() {return this;}, backgroundColor() {return this;}};
  const {render} = env.compile('class Index {\n' + helpers + '\n}\nexports.render = function(param) {\n' + branch + '\n};',
    'pages/Index', {SearchPage: props => calls.push(props), NavDestination: child => {child(); return chain;},
      Immersive: {setBarIcons() {}}});
  for (const param of [undefined, null, {}, 42, 'not a route object', {keyword: 42}, {keyword: ''}, {keyword: '  '}]) {
    render.call({isDark: false}, param);
    assert.deepEqual(calls.at(-1), {initialKeyword: ''}, 'invalid or empty parameters preserve an empty search entry');
  }
  render.call({isDark: false}, {keyword: '  路由搜索词  '});
  assert.deepEqual(calls.at(-1), {initialKeyword: '路由搜索词'});
});

test('search route keyword submits through the real results controller and cannot leak to the next empty entry', async () => {
  const storage = new Map([['searchPrefillKeyword', '旧话题']]);
  const first = initialSearchPage({initialKeyword: '  路由标题  ', storage});
  await first.page.aboutToAppear(); await tick();
  assert.equal(first.calls.filter(call => call.method === 'searchAll').length, 1);
  assert.equal(first.calls[0].args[0], '路由标题');
  assert.deepEqual(first.history, ['路由标题']);
  assert.equal(storage.get('searchPrefillKeyword'), '');
  first.page.aboutToDisappear();
  const next = initialSearchPage({storage}); await next.page.aboutToAppear(); await tick();
  assert.equal(next.calls.length, 0); assert.equal(next.page.keyword, '');
});

test('search route is consumed once while tag and topic prefill remain compatible', async () => {
  const route = initialSearchPage({initialKeyword: 'route'}); await route.page.aboutToAppear(); await tick();
  route.page.onInput('my edited draft'); route.page.aboutToDisappear();
  await route.page.aboutToAppear(); await tick();
  assert.equal(route.calls.length, 1); assert.equal(route.page.keyword, 'my edited draft');
  const legacy = initialSearchPage({storage: new Map([['searchPrefillKeyword', '  动态话题  ']])});
  await legacy.page.aboutToAppear(); await tick();
  assert.equal(legacy.calls[0].args[0], '动态话题');
  assert.equal(legacy.storage.get('searchPrefillKeyword'), '');
});

test('an ordinary empty entry still submits typed input and its suggested keyword while active', async () => {
  const f = initialSearchPage(); await f.page.aboutToAppear();
  f.page.onInput('  手动输入  '); f.page.submitSearch(); await tick();
  f.page.suggestedKeyword = '默认推荐'; f.page.onInput(''); f.page.submitSearch(); await tick();
  assert.deepEqual(f.calls.filter(call => call.method === 'searchAll').map(call => call.args[0]), ['手动输入', '默认推荐']);
  assert.deepEqual(f.history, ['手动输入', '默认推荐']);
});

test('a departing search page cannot submit or consume a later page prefill after discovery resolves', async () => {
  const ready = deferred(), storage = new Map([['searchPrefillKeyword', '旧标签']]);
  const old = initialSearchPage({initialKeyword: 'old route', storage, ready: ready.promise});
  const appear = old.page.aboutToAppear(); old.page.aboutToDisappear();
  storage.set('searchPrefillKeyword', '下一页面的话题');
  old.page.keyword = 'late button event'; old.page.submitSearch();
  ready.resolve(); await appear; await tick();
  assert.equal(old.calls.length, 0); assert.deepEqual(old.history, []);
  assert.equal(storage.get('searchPrefillKeyword'), '下一页面的话题');
  const next = initialSearchPage({storage}); await next.page.aboutToAppear(); await tick();
  assert.equal(next.calls[0].args[0], '下一页面的话题');
});

test('late appearance from an earlier lifecycle cannot replace the current route or submit twice', async () => {
  const pending = deferred(), f = initialSearchPage({initialKeyword: 'first', ready: pending.promise});
  const old = f.page.aboutToAppear(); f.page.aboutToDisappear();
  f.page.discoveryController.activate = async () => {};
  f.storage.set('searchPrefillKeyword', 'second');
  await f.page.aboutToAppear(); await tick(); pending.resolve(); await old; await tick();
  assert.deepEqual(f.calls.filter(call => call.method === 'searchAll').map(call => call.args[0]), ['second']);
  assert.equal(f.page.keyword, 'second');
});
function video(keyword, page = 1) { return { bvid: 'BV-' + keyword + '-' + page, aid: page, title: keyword }; }
function allResult(keyword, total) {
  return { sections: [{ type: 'video', videos: [video(keyword)], users: [], pgc: [], articles: [] }], totals: new Map([['video', total]]) };
}
async function submit(controller, query, keyword) { await controller.submit(keyword, query); }
async function selectTab(controller, query, index) { controller.select(index, query); await tick(); }

test('search restores cached category pagination after visiting an exhausted category', async () => {
  const { controller, query, calls } = searchHarness();
  await submit(controller, query, 'alpha'); await selectTab(controller, query, 1);
  await selectTab(controller, query, 6); assert.equal(controller.view.hasMore, false);
  await selectTab(controller, query, 1); controller.loadMore(); await tick();
  assert.deepEqual(calls.filter(x => x.method === 'searchVideosByType').map(x => x.args.slice(0, 2)), [['alpha', 1], ['alpha', 2]]);
  assert.deepEqual(controller.store.videos.getAll().map(x => x.bvid), ['BV-alpha-1', 'BV-alpha-2']);
  assert.equal(controller.view.hasMore, true);
});

for (const outcome of ['success', 'failure']) {
  test(`search returning to cached category isolates another category's late ${outcome}`, async () => {
    const pending = deferred(); let userCalls = 0;
    const { controller, query } = searchHarness({ searchUsers: () => ++userCalls === 1 ? pending.promise : { users: [{ mid: 2 }], numResults: 1 } });
    await submit(controller, query, 'alpha'); await selectTab(controller, query, 1); await selectTab(controller, query, 6);
    assert.equal(controller.view.loading, true);
    await selectTab(controller, query, 1);
    assert.equal(controller.view.loading, false); assert.equal(controller.view.hasMore, true);
    if (outcome === 'success') pending.resolve({ users: [{ mid: 99 }], numResults: 1 });
    else pending.reject(new Error('old user request failed'));
    await tick();
    assert.equal(controller.view.error, ''); assert.equal(controller.view.moreError, ''); assert.equal(controller.view.hasMore, true);
    assert.equal(controller.store.users.totalCount(), 0);
    await selectTab(controller, query, 6);
    assert.equal(userCalls, 2); assert.equal(controller.store.users.getData(0).mid, 2); assert.equal(controller.view.hasMore, false);
  });
}

test('search preserves each category pagination error and retries its failed page', async () => {
  let failed = false;
  const { controller, query, calls } = searchHarness({ searchUsers: (kw, pn) => {
    if (pn === 2 && !failed) { failed = true; throw new Error('user page offline'); }
    return { users: [{ mid: pn }], numResults: 2 };
  } });
  await submit(controller, query, 'alpha'); await selectTab(controller, query, 1); await selectTab(controller, query, 6);
  controller.loadMore(); await tick(); assert.equal(controller.view.moreError, 'user page offline');
  await selectTab(controller, query, 1); assert.equal(controller.view.moreError, ''); assert.equal(controller.view.error, '');
  await selectTab(controller, query, 6); assert.equal(controller.view.moreError, 'user page offline');
  const beforeRetry = calls.length; controller.loadMore(); await tick(); assert.equal(calls.length, beforeRetry);
  controller.loadMore(true); await tick();
  assert.deepEqual(calls.filter(x => x.method === 'searchUsers').map(x => x.args[1]), [1, 2, 2]);
  assert.equal(controller.view.moreError, ''); assert.equal(controller.store.users.totalCount(), 2); assert.equal(controller.view.hasMore, false);
});

test('search keeps initial category failures local and its retry starts at page one', async () => {
  let attempts = 0;
  const { controller, query, calls } = searchHarness({ searchUsers: () => {
    if (++attempts === 1) throw new Error('users offline');
    return { users: [{ mid: 1 }], numResults: 1 };
  } });
  await submit(controller, query, 'alpha'); await selectTab(controller, query, 1); await selectTab(controller, query, 6);
  assert.equal(controller.view.error, 'users offline');
  await selectTab(controller, query, 1); assert.equal(controller.view.error, '');
  await selectTab(controller, query, 6); assert.equal(controller.view.error, 'users offline');
  await controller.refresh(query);
  assert.deepEqual(calls.filter(x => x.method === 'searchUsers').map(x => x.args[1]), [1, 1]);
  assert.equal(controller.view.error, ''); assert.equal(controller.store.users.totalCount(), 1);
});

test('search draft edits cannot change pagination, sort or category query until submission', async () => {
  const { controller, query, calls } = searchHarness();
  await submit(controller, query, 'alpha'); await selectTab(controller, query, 1);
  const page = inputPage(controller, query); page.onInput('beta'); controller.loadMore(); await tick();
  assert.deepEqual(calls.at(-1).args.slice(0, 2), ['alpha', 2]);
  assert.equal(controller.view.keyword, 'alpha');
  query.videoOrder = 'pubdate'; await controller.refresh(query);
  assert.deepEqual(calls.at(-1).args.slice(0, 3), ['alpha', 1, 'pubdate']);
  await selectTab(controller, query, 6); assert.equal(calls.at(-1).args[0], 'alpha');
  await submit(controller, query, 'beta');
  assert.deepEqual(calls.at(-1).args.slice(0, 2), ['beta', 1]);
  assert.equal(controller.view.keyword, 'beta'); assert.equal(controller.store.videos.totalCount(), 0);
  assert.equal(controller.store.users.totalCount(), 0);
  await selectTab(controller, query, 1);
  assert.deepEqual(calls.at(-1).args.slice(0, 2), ['beta', 1]);
  assert.deepEqual(controller.store.videos.getAll().map(x => x.bvid), ['BV-beta-1']);
});

test('search invalidates cached comprehensive results after changing shared video sort', async () => {
  const { controller, query, calls } = searchHarness();
  await submit(controller, query, 'alpha'); await selectTab(controller, query, 1);
  query.videoOrder = 'pubdate'; await controller.refresh(query); await selectTab(controller, query, 0);
  assert.deepEqual(calls.filter(x => x.method === 'searchAll').map(x => x.args.slice(0, 3)),
    [['alpha', 1, 'totalrank'], ['alpha', 1, 'pubdate']]);
  assert.equal(controller.view.error, '');
});

test('search cancelling a refresh preserves cached cursor and exhaustion state', async () => {
  const refresh = deferred(); let requests = 0;
  const { controller, query, calls } = searchHarness({ searchVideosByType: (kw, pn) => {
    if (++requests === 3) return refresh.promise;
    return { videos: [video(kw, pn)], numResults: 2 };
  } });
  await submit(controller, query, 'alpha'); await selectTab(controller, query, 1);
  controller.loadMore(); await tick(); assert.equal(controller.view.hasMore, false);
  const pending = controller.refresh(query); await selectTab(controller, query, 0);
  refresh.resolve({ videos: [video('obsolete')], numResults: 100 }); await pending;
  await selectTab(controller, query, 1);
  assert.equal(controller.view.hasMore, false);
  assert.deepEqual(controller.store.videos.getAll().map(x => x.bvid), ['BV-alpha-1', 'BV-alpha-2']);
  const before = calls.length; controller.loadMore(); await tick(); assert.equal(calls.length, before);
});

function watchLaterHarness(api) {
  const env = environment(); const toasts = [];
  const Harness = env.component('pages/library/WatchLaterPage', 'WatchLaterPage', '  aboutToDisappear()', [
    ['  async load(): Promise<void> {', '  @Builder\n  HeaderSelectAction()'],
  ], { BasicDataSource: env.load('common/BasicDataSource').BasicDataSource,
    RequestEpoch: env.load('common/RequestEpoch').RequestEpoch, HistoryApi: api });
  const page = new Harness(); page.toast = text => toasts.push(text);
  page.itemsSource.reset([101, 102, 103].map(aid => ({ video: { aid } })));
  page.itemCount = 3; page.selecting = true; page.selectedAids = new Set([101, 102]);
  return { page, toasts };
}
for (const order of ['read-first', 'delete-first']) {
  test(`watch later batch removal uses submitted ids and isolates old list response (${order})`, async () => {
    const readRequest = deferred(), deletion = deferred(), deleted = [];
    const { page } = watchLaterHarness({ getWatchLaterList: () => readRequest.promise,
      delWatchLater: ids => { deleted.push(ids); return deletion.promise; } });
    const read = page.load(); const remove = page.removeSelected();
    page.toggleSelect(103); // Selection can change while the server handles the original IDs.
    if (order === 'read-first') { readRequest.resolve([101, 102, 103].map(aid => ({ video: { aid } }))); await read; }
    deletion.resolve({ ok: true }); await remove;
    if (order === 'delete-first') { readRequest.resolve([101, 102, 103].map(aid => ({ video: { aid } }))); await read; }
    assert.deepEqual(deleted, [[101, 102]]);
    assert.deepEqual(page.itemsSource.getAll().map(x => x.video.aid), [103]);
    assert.equal(page.itemCount, 1); assert.equal(page.loading, false); assert.equal(page.actionBusy, false);
    assert.equal(page.selecting, false); assert.equal(page.selectedAids.size, 0);
  });
}
test('watch later failed batch removal preserves selection; successful retry can empty the list', async () => {
  let attempts = 0;
  const { page, toasts } = watchLaterHarness({ delWatchLater: async () =>
    ++attempts === 1 ? { ok: false, message: 'server refused' } : { ok: true } });
  page.selectedAids = new Set([101, 102, 103]);
  await page.removeSelected();
  assert.equal(page.itemCount, 3); assert.equal(page.selecting, true); assert.equal(page.selectedAids.size, 3);
  assert.equal(page.actionBusy, false); assert.equal(toasts[0], 'server refused');
  await page.removeSelected();
  assert.equal(page.itemCount, 0); assert.equal(page.itemsSource.totalCount(), 0); assert.equal(page.selecting, false);
});
