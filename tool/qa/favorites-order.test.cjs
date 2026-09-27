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
function harness(result) {
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
    FavoriteApi: {sortFavoriteVideos: async (id, aids) => {calls.push({id, aids}); return await result();}},
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
