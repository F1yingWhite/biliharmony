// Actual FavoritesPage editing and API orchestration, with controlled server responses.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return {promise, resolve, reject}; }
function read(name) {
  const alternative = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, name + '.ets');
  return fs.readFileSync(alternative && fs.existsSync(alternative) ? alternative : path.join(root, name + '.ets'), 'utf8').replace(/\r\n/g, '\n');
}
function harness(result = () => ({ok: true}), api = {}) {
  const modules = new Map(), calls = [], notices = [], pops = [];
  function compile(source, name, globals = {}) {
    const module = {exports: {}};
    const compiled = ts.transpileModule(source, {compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}}).outputText;
    new Function('require', 'module', 'exports', ...Object.keys(globals), compiled)(dependency => {
      if (dependency.startsWith('.')) return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), dependency)));
      if (dependency === '@kit.ArkTS') return {collections: {Array}};
      throw new Error('Unexpected platform import: ' + dependency);
    }, module, module.exports, ...Object.values(globals));
    return module.exports;
  }
  function load(name) { if (!modules.has(name)) modules.set(name, compile(read(name), name)); return modules.get(name); }
  const name = 'pages/library/FavoritesPage';
  const source = read(name), begin = source.indexOf('export struct FavoritesPage {'), end = source.indexOf('  @Builder', begin);
  assert.ok(begin >= 0 && end > begin);
  const {Harness} = compile(source.slice(begin, end).replace('export struct FavoritesPage', 'export class Harness')
    .replace(/@(?:State|StorageProp|Watch)\s*(?:\([^)]*\))?\s*/g, '') + '\n}', name, {
    ...load('model/library/LibraryModels'), BasicDataSource: load('common/BasicDataSource').BasicDataSource,
    FavoriteApi: {sortFavoriteVideos: async (id, aids) => {calls.push({id, aids}); return await result();}, ...api},
    UserStore: {current: {mid: 7}},
    AppNavStack: {pop: () => pops.push(true)}
  });
  const page = new Harness();
  page.selected.id = 42;
  page.videosSource.reset([{aid: 1}, {aid: 2}, {aid: 3}]);
  page.getUIContext = () => ({getPromptAction: () => ({showToast: value => notices.push(value.message)})});
  return {page, calls, notices, pops};
}
for (const exit of ['goBack', 'toggleEdit']) {
  test(`favorites ${exit} saves the visible order once before leaving edit mode`, async () => {
    const pending = deferred(), {page, calls, pops} = harness(() => pending.promise);
    page.toggleEdit(); page.moveVideo(2, -1); page.checkedAids = [3];
    page[exit]();
    assert.deepEqual(calls, [{id: 42, aids: [1, 3, 2]}]);
    assert.equal(page.editing, true, 'keep the editing context until server success');
    page.goBack(); page.toggleEdit(); page.moveVideo(0, 1);
    assert.equal(calls.length, 1, 'duplicate exits cannot submit competing orders');
    assert.deepEqual(page.videosSource.getAll().map(v => v.aid), [1, 3, 2]);
    pending.resolve({ok: true}); await tick();
    assert.equal(page.editing, false); assert.equal(page.orderDirty, false); assert.equal(page.actionBusy, false);
    assert.deepEqual(page.checkedAids, []); assert.deepEqual(pops, []); assert.equal(page.selected.id, 42);
  });
}
for (const rejected of [false, true]) {
  test(`favorites failed order save preserves edits and supports retry (reject=${rejected})`, async () => {
    let failed = true;
    const {page, calls, notices} = harness(() => { if (failed && rejected) throw new Error('offline'); return {ok: !failed, message: 'save failed'}; });
    page.toggleEdit(); page.moveVideo(1, -1); page.checkedAids = [2]; page.goBack(); await tick();
    assert.equal(page.editing, true); assert.equal(page.orderDirty, true); assert.equal(page.actionBusy, false);
    assert.deepEqual(page.checkedAids, [2]); assert.ok(notices.length > 0);
    failed = false; page.goBack(); await tick();
    assert.equal(page.editing, false); assert.equal(page.orderDirty, false);
    assert.deepEqual(calls.map(c => c.aids), [[2, 1, 3], [2, 1, 3]]);
  });
}
test('favorites unmodified edits exit locally without a server write', () => {
  const {page, calls} = harness(() => {throw new Error('should not be called');});
  page.toggleEdit(); page.goBack();
  assert.equal(page.editing, false); assert.equal(page.selected.id, 42); assert.deepEqual(calls, []);
});

test('returning from a folder preserves an exhausted root folder list', async () => {
  const folderRequests = [];
  const {page} = harness(undefined, {
    getFavoriteFolders: async (_mid, pn) => {
      folderRequests.push(pn);
      return {folders: [{id: 42, type: 0}], hasMore: false};
    },
    getFavoriteVideos: async () => ({videos: [{aid: 1}], hasMore: true}),
  });
  page.selected.id = 0;
  await page.loadFolders(true);
  assert.equal(page.footerHasMore(), false);
  await page.openFolder({id: 42, type: 0});
  assert.equal(page.footerHasMore(), true);
  page.goBack();
  assert.equal(page.footerHasMore(), false, 'opening videos must not restart root pagination');
  page.loadMore(); await tick();
  assert.deepEqual(folderRequests, [1]);
  assert.equal(page.foldersSource.totalCount(), 1);
});

test('a late root folder response cannot change the open video list pagination', async () => {
  for (const [folderMore, videoMore] of [[false, true], [true, false]]) {
    const pending = deferred(), videoRequests = [];
    const {page} = harness(undefined, {
      getFavoriteFolders: () => pending.promise,
      getFavoriteVideos: async (_id, pn) => {
        videoRequests.push(pn);
        return {videos: [{aid: pn}], hasMore: videoMore};
      },
    });
    page.selected.id = 0;
    const rootLoad = page.loadFolders(true);
    await page.openFolder({id: 42, type: 0});
    pending.resolve({folders: [{id: 42, type: 0}], hasMore: folderMore});
    await rootLoad;
    assert.equal(page.footerHasMore(), videoMore);
    page.loadMore(); await tick();
    assert.deepEqual(videoRequests, videoMore ? [1, 2] : [1]);
    page.goBack();
    assert.equal(page.footerHasMore(), folderMore);
  }
});

test('finishing edit mode discards a delayed move folder picker', async () => {
  const pending = deferred();
  const {page, notices} = harness(undefined, {getAllFavoriteFolders: () => pending.promise});
  page.toggleEdit(); page.checkedAids = [1];
  const opening = page.openMoveSheet();
  page.toggleEdit();
  pending.resolve([{id: 42, type: 0}, {id: 84, type: 0}]); await opening;
  assert.equal(page.moveSheetVisible, false);
  assert.deepEqual(page.moveTargets, []);
  assert.deepEqual(page.checkedAids, []);
  assert.deepEqual(notices, []);
});

test('a move picker from an earlier editing session cannot reopen over a new selection', async () => {
  for (const revisitFolder of [false, true]) {
    const pending = deferred();
    const {page} = harness(undefined, {
      getAllFavoriteFolders: () => pending.promise,
      getFavoriteVideos: async () => ({videos: [{aid: 3}], hasMore: false}),
    });
    page.toggleEdit(); page.checkedAids = [1];
    const opening = page.openMoveSheet();
    page.toggleEdit();
    if (revisitFolder) {
      page.goBack();
      await page.openFolder({id: 42, type: 0});
    }
    page.toggleEdit(); page.checkedAids = [3];
    pending.resolve([{id: 42, type: 0}, {id: 84, type: 0}]); await opening;
    assert.equal(page.moveSheetVisible, false);
    assert.deepEqual(page.checkedAids, [3]);
    assert.deepEqual(page.moveTargets, []);
  }
});

test('an obsolete move picker failure stays quiet and a current request can still open', async () => {
  const pending = deferred(); let calls = 0;
  const {page, notices} = harness(undefined, {getAllFavoriteFolders: () => ++calls === 1 ?
    pending.promise : Promise.resolve([{id: 42, type: 0}, {id: 84, type: 0}])});
  page.toggleEdit(); page.checkedAids = [1];
  const opening = page.openMoveSheet(); page.toggleEdit();
  pending.reject(new Error('old request offline')); await opening;
  assert.deepEqual(notices, []);
  page.toggleEdit(); page.checkedAids = [2];
  await page.openMoveSheet();
  assert.equal(page.moveSheetVisible, true);
  assert.deepEqual(page.moveTargets.map(folder => folder.id), [84]);
});
