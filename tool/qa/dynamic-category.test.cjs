// Execute production category/loading methods with controlled API promises.
// Node 20 compatible: ArkTS types are removed by the same TypeScript compiler as other QA suites.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceOverride = process.env.ARKTS_TEST_SOURCE_ROOT;
function read(name) {
  const relative = name + '.ets';
  const override = sourceOverride && path.join(sourceOverride, relative);
  return fs.readFileSync(override && fs.existsSync(override) ? override : path.join(root, relative), 'utf8')
    .replace(/\r\n/g, '\n');
}
function compile(source, globals = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  }).outputText;
  new Function('module', 'exports', ...Object.keys(globals), code)(module, module.exports, ...Object.values(globals));
  return module.exports;
}
const { BasicDataSource } = compile(read('common/BasicDataSource'));
const { RequestEpoch } = compile(read('common/RequestEpoch'));
const source = read('views/DynamicView');
function method(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, 'Production method anchors must match: ' + start);
  return source.slice(from, to);
}
const methods = [
  method('  async loadFeed(reset: boolean): Promise<void> {', '  private recoverFeed(): void {'),
  method('  private changeDynType(type: string): void {', '  @Builder\n  DynTypeChip('),
  method('  private onRefresh(): void {', '  @Builder\n  DynRefreshHeader()'),
].join('\n');
const RefreshStatus = { Inactive: 0, Refresh: 3 };
function fixture(initialItems = [{ dynId: 'all-original' }]) {
  const requests = [];
  const DynamicApi = { getDynamicFeed(offset, type) {
    let resolve, reject;
    const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
    requests.push({ offset, type, resolve, reject });
    return promise;
  }};
  const { Harness } = compile('export class Harness {\n' + methods + '\n}', { DynamicApi, RefreshStatus, BasicDataSource });
  const dynSource = new BasicDataSource();
  dynSource.reset(initialItems);
  const view = Object.assign(new Harness(), {
    feedEpoch: new RequestEpoch(), dynType: 'all', dynTab: 0, hostMid: 0,
    dynTypes: ['all', 'video', 'pgc', 'article'], loading: false, login: true, feedLoaded: initialItems.length > 0,
    feedLoading: false, feedMoreFailed: false, feedNeedsLogin: false,
    feedRetryReset: false, errorText: '', dynHasMore: true, dynOffset: 'all-next',
    dynSource, dynCount: initialItems.length, refreshing: false,
    refreshStatus: RefreshStatus.Inactive, refreshOperation: 0,
    typeItems: new Map(), typeOffset: new Map(), typeHasMore: new Map(),
    typeSources: new Map(), typeStates: new Map(),
  });
  return { view, requests };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
const page = (id, offset, hasMore = true) => ({ items: [{ dynId: id }], offset, hasMore });
function cacheVideo(view) {
  view.typeItems.set('video', [{ dynId: 'video-cached' }]);
  view.typeOffset.set('video', 'video-next');
  view.typeHasMore.set('video', true);
}
function visibleState(view) {
  return { type: view.dynType, items: view.dynSource.getAll(), count: view.dynCount,
    offset: view.dynOffset, hasMore: view.dynHasMore };
}

test('returning to a cached category rejects the previous category response and cursor', async () => {
  const { view, requests } = fixture();
  view.changeDynType('video');
  view.changeDynType('all');
  assert.equal(requests.length, 1, 'cached return should not need another request');
  requests[0].resolve(page('video-late', 'video-offset', false));
  await tick();
  assert.deepEqual(visibleState(view), { type: 'all', items: [{ dynId: 'all-original' }],
    count: 1, offset: 'all-next', hasMore: true });
  assert.equal(view.feedLoading, false);
});

// Evaluate the bindings used by the actual ArkUI builder. The list boundary only substitutes
// native LazyForEach subscription; category selection, request completion and data notifications
// all execute production code and the production BasicDataSource.
const dynBody = method('  DynBody(tabIdx: number) {', '  /** 发布动态（纯文字 / 图文）底部面板');
const sourceBinding = /LazyForEach\((.+?), \(item: DynamicItem\)/.exec(dynBody);
assert.ok(sourceBinding, 'Find the actual LazyForEach data source argument');
const { renderedSource } = compile('export function renderedSource(tabIdx: number) { return ' + sourceBinding[1] + '; }');
const emptyBinding = /LoadingView\((\{ skeleton: 'social',\n[\s\S]*?\n      \})\)/.exec(dynBody);
assert.ok(emptyBinding, 'Find the actual empty-page component parameters');
const { renderedEmptyState } = compile('export function renderedEmptyState(tabIdx: number) { return ' + emptyBinding[1] + '; }');
const initialLoadingBinding = /\n    if \((.+)\) \{/.exec(dynBody);
assert.ok(initialLoadingBinding);
const { renderedInitialLoading } = compile('export function renderedInitialLoading(tabIdx: number) { return ' + initialLoadingBinding[1] + '; }');
function bindingCallback(name) {
  const start = dynBody.indexOf('.' + name + '(') + name.length + 2;
  assert.ok(start > name.length + 1);
  let depth = 1, end = start;
  for (; end < dynBody.length && depth > 0; end++) {
    if (dynBody[end] === '(') depth++;
    if (dynBody[end] === ')') depth--;
  }
  const { callback } = compile('export function callback(tabIdx: number) { return ' + dynBody.slice(start, end - 1) + '; }');
  return callback;
}
function mountTab(view, index) {
  const source = renderedSource.call(view, index);
  const result = { source, ids: source.getAll().map(item => item.dynId), notifications: 0 };
  const changed = () => { result.ids = source.getAll().map(item => item.dynId); result.notifications++; };
  source.registerDataChangeListener({ onDataReloaded: changed, onDataAdd: changed, onDataChange: changed, onDataDelete: changed });
  return result;
}

test('swiping into an unvisited dynamic tab never renders the selected category cards', () => {
  const { view } = fixture();
  const current = mountTab(view, 0), incoming = mountTab(view, 1);
  assert.deepEqual(current.ids, ['all-original']);
  assert.deepEqual(incoming.ids, [], 'the video page must not show the all-category feed before onChange');
  assert.notEqual(current.source, incoming.source);
});

test('two mounted dynamic tabs retain independent lists through selection and pagination', async () => {
  const { view, requests } = fixture();
  cacheVideo(view);
  const all = mountTab(view, 0), video = mountTab(view, 1);
  assert.deepEqual(video.ids, ['video-cached']);
  view.changeDynType('video');
  assert.equal(renderedSource.call(view, 1), video.source, 'a mounted tab keeps its data source identity');
  assert.deepEqual(all.ids, ['all-original']);
  const request = view.loadFeed(false);
  requests[0].resolve(page('video-next-page', 'video-offset-2', false));
  await request;
  assert.deepEqual(video.ids, ['video-cached', 'video-next-page']);
  assert.deepEqual(all.ids, ['all-original']);
  assert.equal(all.notifications, 0, 'another category must not notify this mounted LazyForEach');
});

test('hidden dynamic tab reach-end and refresh callbacks cannot change the selected category', async () => {
  const { view, requests } = fixture();
  bindingCallback('onReachEnd').call(view, 1)();
  bindingCallback('onRefreshing').call(view, 1)();
  assert.equal(requests.length, 0, 'callbacks from a cached adjacent page must not request the active feed');
  assert.equal(view.refreshing, false);
  bindingCallback('onReachEnd').call(view, 0)();
  assert.equal(requests.length, 1);
  requests[0].resolve(page('all-next-page', 'all-next-2'));
  await tick();
  assert.equal(view.dynCount, 2);
});

test('an unvisited adjacent page renders its own skeleton rather than the active category error', async () => {
  const { view, requests } = fixture([]);
  const request = view.loadFeed(true);
  requests[0].reject(new Error('all-only error'));
  await request;
  assert.equal(renderedEmptyState.call(view, 0).errorText, 'all-only error');
  const incoming = renderedEmptyState.call(view, 1);
  assert.equal(incoming.loading, true);
  assert.equal(incoming.errorText, '');
  assert.equal(incoming.empty, false);
});

test('initialization loading does not replace an already cached adjacent list with a skeleton', () => {
  const { view } = fixture();
  cacheVideo(view);
  view.loading = true;
  assert.equal(renderedInitialLoading.call(view, 1), false);
  assert.deepEqual(renderedSource.call(view, 1).getAll(), [{ dynId: 'video-cached' }]);
  assert.equal(renderedInitialLoading.call(view, 2), true, 'an unseen empty category still has an initial placeholder');
});

test('a successfully empty category remains empty while swiping and is cached on return', async () => {
  const { view, requests } = fixture();
  view.changeDynType('video');
  requests[0].resolve({ items: [], offset: '', hasMore: false });
  await tick();
  view.changeDynType('all');
  assert.deepEqual(renderedSource.call(view, 1).getAll(), []);
  const empty = renderedEmptyState.call(view, 1);
  assert.equal(empty.loading, false);
  assert.equal(empty.empty, true);
  view.changeDynType('video');
  assert.equal(requests.length, 1, 'successful empty pages are real cached results');
  assert.equal(view.dynCount, 0);
  assert.equal(view.dynHasMore, false);
});

test('late likes update their originating cached category after selection changes', () => {
  const { view } = fixture([{ dynId: 'all-original', liked: false, like: 3 }]);
  const { Like } = compile('export class Like {\n' +
    method('  private handleLikeResult(', '  /** 并行拉取关注 UP 主') + '\n}');
  view.handleLikeResult = Like.prototype.handleLikeResult;
  const origin = mountTab(view, 0);
  cacheVideo(view);
  view.changeDynType('video');
  view.handleLikeResult('all-original', true, 4);
  assert.equal(origin.source.getData(0).liked, true);
  assert.equal(origin.source.getData(0).like, 4);
  assert.deepEqual(view.dynSource.getAll(), [{ dynId: 'video-cached' }]);
});

function navigationFixture(reduced) {
  const navigations = [], flags = [], snapshots = [];
  let layoutReads = 0;
  const code = method('  private openDetail(', '  private openItemDetail(') +
    method('  private openVideo(', '  @Builder\n  ForwardedCard(');
  const { Card } = compile('export class Card {\n' + code + '\n}', {
    MotionTokens: { isReduced: () => reduced },
    AppNavStack: { pushPathByName: (...args) => navigations.push(args) },
    AppStorage: { setOrCreate: (...args) => flags.push(args) },
    NAV_VIDEO_DETAIL: 'video', NAV_DYNAMIC_DETAIL: 'dynamic', NAV_IMAGE_VIEWER: 'images',
    HERO_NAV_TRANSITION_ACTIVE_KEY: 'heroActive', HERO_NAV_TRANSITION_DURATION_KEY: 'heroDuration',
    biliImageThumbnail: (url, width) => url + '@' + width,
    setHeroBgSnapshot: value => snapshots.push(value), Curve: { EaseInOut: 'curve' },
  });
  const item = { dynId: 'source-dynamic', bvid: 'BV-source', aid: 123, title: 'source title', cover: 'cover.jpg',
    images: Array.from({ length: 11 }, (_, index) => 'original-' + index + '.jpg') };
  const view = Object.assign(new Card(), { item, detailMode: false, sharedImageTransition: false,
    cardId: () => 'card', videoCardId: () => 'video-card', videoCoverId: () => 'video-cover',
    imgId: (_id, index) => 'img-' + index, imgTransitionId: (_id, index) => 'transition-' + index,
    getUIContext: () => {
      layoutReads++;
      return { px2vp: value => value,
        getComponentUtils: () => ({ getRectangleById: () => ({ size: { width: 100, height: 80 }, windowOffset: { x: 1, y: 2 } }) }),
        getComponentSnapshot: () => ({ getSync: () => ({ snapshot: true }) }),
        animateTo: (_options, callback) => callback(),
      };
    },
  });
  return { view, item, navigations, flags, snapshots, layoutReads: () => layoutReads };
}

test('reduced motion dynamic video, detail and images preserve content while bypassing hero preparation', () => {
  const f = navigationFixture(true);
  f.view.openVideo(f.item);
  f.view.openDetail(true);
  f.view.openItemImage(f.item, 10);
  assert.deepEqual(f.navigations.map(call => [call[0], call[2]]), [['video', false], ['dynamic', false], ['images', false]]);
  assert.equal(f.navigations[0][1].bvid, f.item.bvid);
  assert.equal(f.navigations[0][1].aid, 123);
  assert.equal(f.navigations[0][1].title, 'source title');
  assert.equal(f.navigations[0][1].cover, 'cover.jpg@480');
  assert.equal(f.navigations[1][1].item, f.item);
  assert.equal(f.navigations[1][1].focusComments, true);
  assert.deepEqual(f.navigations[2][1], { images: f.item.images, initialIndex: 10 });
  assert.equal(f.layoutReads(), 0, 'reduced motion must not measure or snapshot a hero source');
  assert.deepEqual(f.snapshots, []);
  assert.deepEqual(f.flags, [], 'plain navigation must not activate hero input locking');
});

test('normal motion dynamic video still captures and supplies its source rectangle', () => {
  const f = navigationFixture(false);
  f.view.openVideo(f.item);
  assert.equal(f.navigations[0][0], 'video');
  assert.deepEqual(f.navigations[0][1].cardRect, { x: 1, y: 2, w: 100, h: 80 });
  assert.deepEqual(f.snapshots, [{ snapshot: true }]);
  assert.ok(f.layoutReads() > 0);
  assert.ok(f.flags.some(([key, value]) => key === 'heroActive' && value === true));
});

test('a late pagination response cannot append into a cached destination category', async () => {
  const { view, requests } = fixture();
  cacheVideo(view);
  const old = view.loadFeed(false);
  assert.equal(requests[0].offset, 'all-next');
  view.changeDynType('video');
  requests[0].resolve(page('all-late-page', 'all-offset-2', false));
  await old;
  assert.deepEqual(visibleState(view), { type: 'video', items: [{ dynId: 'video-cached' }],
    count: 1, offset: 'video-next', hasMore: true });
  assert.equal(view.feedLoading, false);
});

test('cached switches clear loading and error states and allow pagination immediately', async () => {
  const { view, requests } = fixture();
  cacheVideo(view);
  Object.assign(view, { feedLoading: true, feedMoreFailed: true, feedNeedsLogin: true,
    feedRetryReset: true, errorText: 'old category error', refreshing: true,
    refreshStatus: RefreshStatus.Refresh });
  view.changeDynType('video');
  assert.deepEqual({ loading: view.feedLoading, moreFailed: view.feedMoreFailed,
    needsLogin: view.feedNeedsLogin, retryReset: view.feedRetryReset,
    error: view.errorText, refreshing: view.refreshing, status: view.refreshStatus },
  { loading: false, moreFailed: false, needsLogin: false, retryReset: false,
    error: '', refreshing: false, status: RefreshStatus.Inactive });
  const current = view.loadFeed(false);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].offset, 'video-next');
  requests[0].resolve(page('video-next-page', 'video-offset-2'));
  await current;
  assert.equal(view.dynCount, 2);
});

test('a stale pagination rejection cannot publish errors or finish a new category request', async () => {
  const { view, requests } = fixture();
  cacheVideo(view);
  const old = view.loadFeed(false);
  view.changeDynType('video');
  const current = view.loadFeed(false);
  requests[0].reject(new Error('登录已失效，请重新登录后查看动态'));
  await old;
  assert.equal(view.feedLoading, true);
  assert.equal(view.feedNeedsLogin, false);
  assert.equal(view.feedMoreFailed, false);
  assert.equal(view.errorText, '');
  assert.equal(requests.length, 2);
  requests[1].resolve(page('video-next-page', 'video-offset-2'));
  await current;
  assert.equal(view.feedLoading, false);
  assert.equal(view.dynOffset, 'video-offset-2');
});

test('uncached switches preserve the latest request loading and error state', async () => {
  const { view, requests } = fixture();
  view.changeDynType('video');
  view.changeDynType('pgc');
  requests[0].resolve(page('video-late', 'video-offset'));
  await tick();
  assert.equal(view.feedLoading, true);
  assert.equal(view.dynCount, 0);
  requests[1].reject(new Error('pgc network failure'));
  await tick();
  assert.equal(view.dynType, 'pgc');
  assert.equal(view.feedLoading, false);
  assert.equal(view.errorText, 'pgc network failure');
});

test('an old category refresh completion cannot hide a newer refresh indicator', async () => {
  const { view, requests } = fixture();
  cacheVideo(view);
  view.onRefresh();
  view.changeDynType('video');
  view.onRefresh();
  requests[0].resolve(page('all-refresh-late', 'all-new'));
  await tick();
  assert.equal(view.refreshing, true);
  assert.equal(view.feedLoading, true);
  requests[1].resolve(page('video-refreshed', 'video-new'));
  await tick();
  assert.equal(view.refreshing, false);
  assert.equal(view.feedLoading, false);
  assert.deepEqual(visibleState(view), { type: 'video', items: [{ dynId: 'video-refreshed' }],
    count: 1, offset: 'video-new', hasMore: true });
});
