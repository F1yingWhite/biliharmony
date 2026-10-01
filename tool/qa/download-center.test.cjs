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

function fixture(getPlayUrl, downloadFile, preferencesMock) {
  const source = fs.readFileSync('entry/src/main/ets/services/media/DownloadCenter.ets', 'utf8');
  const module = {exports: {}};
  const writes = [];
  const platform = {
    '@kit.AbilityKit': {common: {}},
    '@kit.BasicServicesKit': {request: {downloadFile}},
    '@kit.CoreFileKit': {fileIo: {
      accessSync: () => false, mkdirSync() {}, unlinkSync() {}, moveFileSync() {},
    }},
    '@kit.ArkData': {preferences: preferencesMock || {}},
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
  if (preferencesMock) {
    Center.context = null;
    Center.store = null;
    Center.ready = null;
    Center.tasks = [];
  }
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

function restoration(getPreferences) {
  return fixture(async () => null, async () => systemTask(), {getPreferences}).Center;
}
const context = {filesDir: '/tmp/test-downloads'};
function savedStore(raw) {
  const writes = [];
  return {
    getSync: () => raw,
    putSync: (_key, value) => {raw = value; writes.push(value);},
    flush: async () => {},
    writes,
    raw: () => raw,
  };
}
const savedTasks = JSON.stringify([
  {id: 'done', status: 2, filePath: '/saved.m4a'},
  {id: 'queued', status: 0, progress: 20},
  {id: 'running', status: 1, progress: 60},
]);

test('real initialization shares restore and persists interrupted tasks for a fresh module', async () => {
  const pending = deferred(); const store = savedStore(savedTasks); let opens = 0;
  const Center = restoration(() => {opens++; return pending.promise;});
  const first = Center.init(context);
  assert.equal(Center.init(context), first);
  pending.resolve(store);
  await first;
  assert.equal(opens, 1);
  assert.deepEqual(Center.list().map(t => t.status), [2, 4, 4]);
  assert.equal(Center.list()[0].filePath, '/saved.m4a');
  assert.equal(Center.list()[1].progress, -1);
  assert.equal(store.writes.length, 1);
  const fresh = restoration(async () => store);
  await fresh.init(context);
  assert.deepEqual(fresh.list().map(t => t.status), [2, 4, 4]);
  assert.equal(store.writes.length, 1);
});

for (const synchronous of [false, true]) {
  test(`preferences ${synchronous ? 'synchronous' : 'asynchronous'} failure rejects concurrent init and allows retry`, async () => {
    const store = savedStore(savedTasks); let opens = 0;
    const Center = restoration(() => {
      if (++opens === 1) {
        if (synchronous) throw new Error('unavailable');
        return Promise.reject(new Error('unavailable'));
      }
      return Promise.resolve(store);
    });
    const first = Center.init(context);
    const second = Center.init(context);
    assert.equal(first, second);
    await Promise.all([assert.rejects(first, /恢复失败/), assert.rejects(second, /恢复失败/)]);
    assert.equal(Center.store, null);
    assert.equal(Center.ready, null);
    await Center.init(context);
    assert.equal(opens, 2);
    assert.equal(Center.list().length, 3);
  });
}

test('read failure blocks every mutation without overwriting records and enqueue recovers later', async () => {
  const store = savedStore(savedTasks); let fail = true;
  const read = store.getSync;
  store.getSync = () => {if (fail) throw new Error('read unavailable'); return read();};
  const Center = restoration(async () => store);
  const initial = await Promise.allSettled([Center.init(context)]);
  const enqueue = () => Center.enqueue(1, 1, 'BVtest', 1, 0, 0, 'new', 'audio');
  Center.pump = () => {};
  const attempted = await Promise.allSettled([enqueue()]);
  assert.equal(store.writes.length, 0, 'failed restore must not overwrite original records');
  assert.equal(initial[0].status, 'rejected');
  assert.equal(attempted[0].status, 'rejected');
  await assert.rejects(Center.remove('done'), /恢复失败/);
  await assert.rejects(Center.retry('done'), /恢复失败/);
  await assert.rejects(Center.clearFinished(), /恢复失败/);
  assert.equal(store.raw(), savedTasks);
  assert.equal(store.writes.length, 0);
  assert.deepEqual(Center.list(), []);
  fail = false;
  Center.pump = () => {};
  await enqueue();
  assert.deepEqual(Center.list().map(t => t.id).slice(1), ['done', 'queued', 'running']);
  const fresh = restoration(async () => store);
  await fresh.init(context);
  assert.equal(fresh.list().length, 4);
});

for (const raw of ['{broken', '{}']) {
  test(`invalid stored tasks (${raw}) reject without destructive writes`, async () => {
    const store = savedStore(raw);
    const Center = restoration(async () => store);
    await assert.rejects(Center.init(context), /恢复失败/);
    await assert.rejects(Center.clearFinished(), /恢复失败/);
    assert.equal(store.raw(), raw);
    assert.equal(store.writes.length, 0);
    assert.equal(Center.store, null);
  });
}

test('empty preferences initialize normally', async () => {
  const store = savedStore('');
  const Center = restoration(async () => store);
  await Center.init(context);
  assert.deepEqual(Center.list(), []);
  assert.equal(store.writes.length, 0);
});
