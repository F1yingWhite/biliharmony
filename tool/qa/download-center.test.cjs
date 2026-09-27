const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(yes => {resolve = yes;});
  return {promise, resolve};
}

function fixture(getPlayUrl, downloadFile) {
  const source = fs.readFileSync('entry/src/main/ets/services/media/DownloadCenter.ets', 'utf8');
  const module = {exports: {}};
  const writes = [];
  const platform = {
    '@kit.AbilityKit': {common: {}},
    '@kit.BasicServicesKit': {request: {downloadFile}},
    '@kit.CoreFileKit': {fileIo: {
      accessSync: () => false, mkdirSync() {}, unlinkSync() {}, moveFileSync() {},
    }},
    '@kit.ArkData': {preferences: {}},
    '../network/HttpClient': {HttpClient: {getDownloadHeaders: () => ({})}},
    '../../api/BiliApi': {BiliApi: {getPlayUrl}},
    '../../model/Models': {PlayUrlInfo: class {}},
  };
  const code = ts.transpileModule(source, {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText;
  new Function('require', 'module', 'exports', code)(
    name => {assert.ok(name in platform, name); return platform[name];}, module, module.exports);
  const Center = module.exports.DownloadCenter;
  Center.context = {filesDir: '/tmp/test-downloads'};
  Center.store = {putSync: (_key, value) => writes.push(value), flush: async () => {}};
  Center.ready = Promise.resolve();
  const item = new module.exports.DownloadTaskItem();
  item.id = 'task1'; item.kind = module.exports.DOWNLOAD_KIND_AUDIO;
  item.status = module.exports.DOWNLOAD_STATUS_QUEUED;
  Center.tasks = [item];
  return {Center, item, writes};
}

function systemTask() {
  const handlers = new Map(); let deletes = 0;
  return {
    on(name, fn) {handlers.set(name, fn);},
    off(name) {handlers.delete(name);},
    emit(name, ...args) {handlers.get(name)?.(...args);},
    async delete() {deletes++; this.emit('remove');},
    deletes: () => deletes,
  };
}

test('removing during URL resolution never starts a system download', async () => {
  const playUrl = deferred(); let downloads = 0;
  const {Center, item} = fixture(() => playUrl.promise, () => {downloads++; return systemTask();});
  const running = Center.runOne(item);
  await tick();
  await Center.remove(item.id);
  playUrl.resolve({downloadAudioUrls: ['cdn1', 'cdn2']});
  await running;
  assert.equal(downloads, 0);
  assert.deepEqual(Center.list(), []);
});

test('removing while system download is being created deletes it without trying the next CDN', async () => {
  const created = deferred(); const task = systemTask(); let downloads = 0;
  const {Center, item} = fixture(async () => ({downloadAudioUrls: ['cdn1', 'cdn2']}),
    () => {downloads++; return created.promise;});
  const running = Center.runOne(item);
  await tick();
  assert.equal(downloads, 1);
  await Center.remove(item.id);
  created.resolve(task);
  await running;
  assert.equal(task.deletes(), 1);
  assert.equal(downloads, 1);
  assert.deepEqual(Center.list(), []);
});

test('removing an active system download stops it without trying another CDN', async () => {
  const task = systemTask(); let downloads = 0;
  const {Center, item} = fixture(async () => ({downloadAudioUrls: ['cdn1', 'cdn2']}),
    async () => {downloads++; return task;});
  const running = Center.runOne(item);
  await tick();
  await Center.remove(item.id);
  await running;
  assert.equal(task.deletes(), 1);
  assert.equal(downloads, 1);
  assert.deepEqual(Center.list(), []);
});

test('many progress callbacks coalesce writes while completion persists immediately', async () => {
  const task = systemTask();
  const {Center, item, writes} = fixture(async () => ({downloadAudioUrls: ['cdn1']}),
    async () => task);
  const running = Center.runOne(item);
  await tick();
  for (let i = 1; i <= 80; i++) task.emit('progress', i, 100);
  assert.equal(item.progress, 80);
  assert.equal(writes.length, 1, 'progress events should wait for the coalescing timer');
  task.emit('complete');
  await running;
  assert.equal(item.status, 2);
  assert.equal(writes.length, 2);
  assert.equal(Center.progressPersistTimer, -1);
});
