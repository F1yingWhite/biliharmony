const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve;
  const promise = new Promise(yes => {resolve = yes;});
  return {promise, resolve};
}

const STATE = {INITIALIZED: 0, WAITING: 0x10, RUNNING: 0x20, RETRYING: 0x21, PAUSED: 0x30,
  STOPPED: 0x31, COMPLETED: 0x40, FAILED: 0x41, REMOVED: 0x50};
function fixture(getPlayUrl, downloadFile, preferencesMock, files = new Set(), hooks = {}) {
  const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(sourceRoot, 'services/media/DownloadCenter.ets'), 'utf8');
  const module = {exports: {}};
  const writes = [];
  const systems = new Map(); const configs = []; let sequence = 0;
  const agent = {
    State: STATE, Action: {DOWNLOAD: 0}, Mode: {BACKGROUND: 0}, WaitingReason: {NETWORK_NOT_MATCH: 1},
    async create(context, config) {
      configs.push(config);
      const system = await downloadFile(context, {url: config.url, filePath: config.saveas});
      if (!system.tid) system.tid = 'system' + (++sequence);
      systems.set(system.tid, system);
      return system;
    },
    async getTask(context, id) {
      if (hooks.getTask) return hooks.getTask(context, id);
      if (!systems.has(id)) throw Object.assign(new Error('missing'), {code: 21900006});
      return systems.get(id);
    },
    async show(id) {if (hooks.show) return hooks.show(id); return {progress: systems.get(id).info};},
    async remove(id) {
      if (hooks.remove) return hooks.remove(id);
      if (!systems.has(id)) throw Object.assign(new Error('missing'), {code: 21900006});
      await systems.get(id).delete(); systems.delete(id);
    },
  };
  const platform = {
    '@kit.AbilityKit': {common: {}},
    '@kit.BasicServicesKit': {request: {agent}},
    '@kit.CoreFileKit': {fileIo: {
      accessSync: name => files.has(name), mkdirSync(name) {files.add(name);},
      unlinkSync(name) {assert.ok(files.delete(name), 'unlink missing file: ' + name);},
      moveFileSync(from, to) {assert.ok(files.delete(from), 'move missing file: ' + from); files.add(to);},
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
  return {Center, item, writes, files, systems, configs, exports: module.exports};
}

function systemTask() {
  const handlers = new Map(); let deletes = 0, starts = 0;
  return {
    info: {state: STATE.RUNNING, processed: 0, sizes: [100]},
    on(name, fn) {handlers.set(name, fn);},
    off(name) {handlers.delete(name);},
    emit(name, ...args) {
      name = {complete: 'completed', fail: 'failed'}[name] || name;
      if (name === 'progress' && typeof args[0] === 'number') args = [{state: STATE.RUNNING, processed: args[0], sizes: [args[1]]}];
      if (args[0]?.state !== undefined) this.info = args[0];
      handlers.get(name)?.(...args);
    },
    async start() {starts++;},
    async resume() {},
    async delete() {deletes++; this.emit('remove');},
    deletes: () => deletes,
    starts: () => starts,
    handlers,
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
  const {Center, item, writes, files} = fixture(async () => ({downloadAudioUrls: ['cdn1']}),
    async () => task);
  const running = Center.runOne(item);
  await tick();
  for (let i = 1; i <= 80; i++) task.emit('progress', i, 100);
  assert.equal(item.progress, 80);
  const before = writes.length;
  assert.equal(before, 3, 'creation path and ID must be saved before starting; progress waits for timer');
  files.add(item.partPath);
  task.emit('complete');
  await running;
  assert.equal(item.status, 2);
  assert.equal(writes.length, before + 2);
  assert.equal(Center.progressPersistTimer, -1);
  assert.equal(files.has(item.filePath), true);
  assert.equal(files.has(item.partPath), false);
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

test('clearing legacy records preserves unknown-writer partial files but removes completed files', async () => {
  const store = savedStore(JSON.stringify([
    {id: 'interrupted', status: 1, filePath: ''},
    {id: 'done', status: 2, filePath: context.filesDir + '/downloads/done.m4a'},
  ]));
  const files = new Set([context.filesDir + '/downloads/interrupted.part', context.filesDir + '/downloads/done.m4a']);
  const {Center} = fixture(async () => null, async () => systemTask(), {getPreferences: async () => store}, files);
  await Center.init(context);
  assert.equal(Center.list()[0].status, 4);
  await Center.clearFinished();
  assert.deepEqual(Center.list(), []);
  assert.deepEqual([...files], [context.filesDir + '/downloads/interrupted.part'], 'legacy task has no recoverable ID: never delete a possible live writer');
  assert.equal(store.raw(), '[]');
});

test('clearing finished records preserves active download records and their partial files', async () => {
  const files = new Set(['/tmp/test-downloads/downloads/task1.part', '/tmp/test-downloads/downloads/failed.part']);
  const {Center, item} = fixture(async () => null, async () => systemTask(), null, files);
  item.status = 1;
  Center.tasks.push(fixture(async () => null, async () => systemTask()).exports.DownloadTaskItem.from({id: 'failed', status: 3, filePath: ''}));
  await Center.clearFinished();
  assert.deepEqual(Center.list().map(task => task.id), ['task1']);
  assert.deepEqual([...files], ['/tmp/test-downloads/downloads/task1.part', '/tmp/test-downloads/downloads/failed.part']);
});

test('legacy retry isolates the attempt and never removes a possible old writer', async () => {
  const old = context.filesDir + '/downloads/task1.part';
  const system = systemTask();
  const f = fixture(async () => ({downloadAudioUrls: ['only-cdn']}), async () => system, null, new Set([old]));
  f.item.status = 4;
  await f.Center.retry(f.item.id); await tick();
  assert.equal(f.configs.length, 1);
  assert.equal(f.configs[0].saveas, context.filesDir + '/downloads/task1.a1.part');
  assert.equal(f.configs[0].mode, 0);
  assert.equal(f.configs[0].metered, true);
  assert.equal(f.configs[0].roaming, false);
  assert.equal(f.configs[0].overwrite, false);
  assert.equal(f.configs[0].gauge, true);
  f.files.add(f.item.partPath);
  const run = f.Center.currentRun;
  system.emit('complete'); await run;
  assert.equal(f.item.status, 2);
  assert.equal(f.files.has(old), true);
});

test('failed CDN is stopped before deleting its partial file and trying a distinct second attempt', async () => {
  const first = systemTask(), second = systemTask(); let calls = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn1', 'cdn2']}), async () => ++calls === 1 ? first : second);
  const run = f.Center.runOne(f.item); await tick();
  const initialPath = f.item.partPath; f.files.add(initialPath);
  first.emit('fail'); await tick();
  assert.equal(first.deletes(), 1);
  assert.equal(f.files.has(initialPath), false);
  assert.equal(calls, 2);
  assert.notEqual(f.item.partPath, initialPath);
  f.files.add(f.item.partPath); second.emit('complete'); await run;
  assert.equal(f.item.status, 2);
});

test('failed system removal blocks CDN fallback and preserves the possible live partial file', async () => {
  const system = systemTask(); let creates = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn1', 'cdn2']}), async () => {creates++; return system;},
    null, new Set(), {remove: async () => {throw Object.assign(new Error('service unavailable'), {code: 13400003});}});
  const run = f.Center.runOne(f.item); await tick();
  const partial = f.item.partPath; f.files.add(partial); system.emit('fail'); await run;
  assert.equal(creates, 1);
  assert.equal(f.files.has(partial), true);
  assert.ok(f.item.systemTaskId);
  assert.equal(f.item.status, 3);
  await assert.rejects(f.Center.remove(f.item.id));
  assert.equal(f.Center.list()[0], f.item);
  assert.equal(f.files.has(partial), true);
});

test('task ID is durably saved before start; save failure removes the initialized system without starting it', async () => {
  const system = systemTask();
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => system);
  f.Center.store.flush = async () => {if (f.item.systemTaskId) throw new Error('disk full');};
  await f.Center.runOne(f.item);
  assert.equal(system.starts(), 0);
  assert.equal(system.deletes(), 1);
  assert.equal(f.item.status, 3);
  assert.match(f.item.message, /保存失败/);
});

test('restarting attaches the saved system task without reparsing URLs or creating another download', async () => {
  const system = systemTask(); system.tid = 'saved-id';
  const part = context.filesDir + '/downloads/resumed.a3.part';
  let state = STATE.RUNNING, queries = 0, creates = 0, urls = 0;
  const store = savedStore(JSON.stringify([{id: 'resumed', kind: 1, status: 1, systemTaskId: system.tid,
    attempt: 3, partPath: part, progress: 10}]));
  const f = fixture(async () => {urls++; return null;}, async () => {creates++; return system;},
    {getPreferences: async () => store}, new Set([part]), {
      getTask: async (_context, id) => {assert.equal(id, system.tid); return system;},
      show: async () => {queries++; return {progress: {state, processed: 80, sizes: [100]}};},
      remove: async () => system.delete(),
    });
  await f.Center.init(context); await tick();
  const restored = f.Center.list()[0];
  assert.equal(restored.status, 1); assert.equal(restored.progress, 80);
  assert.equal(system.starts(), 0); assert.equal(creates, 0); assert.equal(urls, 0);
  // No completion callback while backgrounded: foreground query must complete and rename.
  state = STATE.COMPLETED;
  const run = f.Center.currentRun;
  await f.Center.onForeground(context); await run;
  assert.equal(restored.status, 2); assert.equal(restored.filePath, context.filesDir + '/downloads/resumed.m4a');
  assert.equal(f.files.has(restored.filePath), true);
  assert.ok(queries >= 2);
});

test('saved initialized task starts once after attaching listeners', async () => {
  const system = systemTask(); system.tid = 'saved';
  const f = fixture(async () => null, async () => system, null, new Set(), {
    getTask: async () => system,
    show: async () => ({progress: {state: STATE.INITIALIZED, processed: 0, sizes: [-1]}}),
    remove: async () => system.delete(),
  });
  f.item.systemTaskId = 'saved'; f.item.partPath = context.filesDir + '/downloads/task1.a1.part';
  f.item.attempt = 1; f.item.status = 5;
  const run = f.Center.runOne(f.item); await tick();
  assert.equal(system.starts(), 1);
  f.files.add(f.item.partPath); system.emit('complete'); await run;
  assert.equal(f.item.status, 2);
});

test('wait/pause events and foreground synchronization update states without recreating the task', async () => {
  const system = systemTask(); let state = STATE.RUNNING, queryCount = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => system, null, new Set(), {
    show: async () => {queryCount++; return {progress: {state, processed: 44, sizes: [100]}};},
  });
  f.Center.pump(); await tick();
  system.emit('wait', 1); assert.equal(f.item.status, 5); assert.match(f.item.message, /网络/);
  system.emit('pause', {state: STATE.PAUSED, processed: 46, sizes: [100]});
  assert.equal(f.item.status, 6); assert.equal(f.item.progress, 46);
  state = STATE.RUNNING;
  await f.Center.onForeground(context);
  assert.equal(f.item.status, 1); assert.equal(f.item.progress, 44); assert.equal(f.item.message, '');
  assert.equal(f.configs.length, 1); assert.ok(queryCount >= 2);
  const run = f.Center.currentRun; await f.Center.remove(f.item.id); await run;
  assert.equal(system.handlers.size, 0); assert.deepEqual(f.Center.list(), []);
});

test('concurrent foreground checks share one query and a stale response cannot overwrite a newer progress event', async () => {
  const pending = deferred(); const system = systemTask(); let queries = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => system, null, new Set(), {
    show: async () => ++queries === 1 ? {progress: system.info} : pending.promise,
  });
  f.Center.pump(); await tick();
  const first = f.Center.onForeground(context), second = f.Center.onForeground(context);
  assert.equal(first, second); await tick();
  system.emit('progress', 80, 100);
  pending.resolve({progress: {state: STATE.PAUSED, processed: 10, sizes: [100]}});
  await first;
  assert.equal(queries, 2); assert.equal(f.item.status, 1); assert.equal(f.item.progress, 80);
  await f.Center.remove(f.item.id);
});

test('retrying paused task stops and drains old observers before creating a new attempt', async () => {
  const first = systemTask(), next = systemTask(); let creates = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => ++creates === 1 ? first : next);
  f.Center.pump(); await tick();
  const oldPart = f.item.partPath; f.files.add(oldPart);
  first.emit('pause', {state: STATE.PAUSED, processed: 10, sizes: [100]});
  await f.Center.retry(f.item.id); await tick();
  assert.equal(first.deletes(), 1); assert.equal(first.handlers.size, 0);
  assert.equal(creates, 2); assert.equal(f.files.has(oldPart), false);
  assert.notEqual(f.item.partPath, oldPart); assert.equal(f.item.status, 1);
  f.files.add(f.item.partPath); const run = f.Center.currentRun; next.emit('complete'); await run;
  assert.equal(f.item.status, 2);
});

test('canceling while a saved system handle is being recovered never attaches or resumes it', async () => {
  const handle = deferred(), system = systemTask(); system.tid = 'old';
  let removed = 0;
  const f = fixture(async () => assert.fail('must not parse URLs'), async () => assert.fail('must not create'), null,
    new Set(), {getTask: () => handle.promise, remove: async id => {assert.equal(id, 'old'); removed++;}});
  f.item.status = 5; f.item.systemTaskId = 'old'; f.item.attempt = 2;
  f.item.partPath = context.filesDir + '/downloads/task1.a2.part'; f.files.add(f.item.partPath);
  f.Center.pump(); await tick();
  const deleting = f.Center.remove(f.item.id); await tick();
  assert.equal(removed, 1);
  handle.resolve(system); await deleting;
  assert.equal(system.starts(), 0); assert.equal(system.handlers.size, 0);
  assert.deepEqual(f.Center.list(), []); assert.equal(f.files.size, 0);
});

test('queue remains FIFO and starts one system download at a time', async () => {
  const first = systemTask(), second = systemTask(); let creations = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => ++creations === 1 ? first : second);
  const newer = new f.exports.DownloadTaskItem(); newer.id = 'newer'; newer.kind = 1;
  f.Center.tasks.unshift(newer); f.Center.pump(); await tick();
  assert.equal(creations, 1); assert.equal(f.Center.currentRequestId, f.item.id);
  f.files.add(f.item.partPath); first.emit('complete'); await tick();
  assert.equal(creations, 2); assert.equal(f.Center.currentRequestId, newer.id);
  f.files.add(newer.partPath); const run = f.Center.currentRun; second.emit('complete'); await run;
  assert.equal(f.item.status, 2); assert.equal(newer.status, 2); assert.equal(f.Center.running, false);
});

test('unconfirmed old system writer prevents a new queued task from running', async () => {
  let creates = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => {creates++; return systemTask();});
  const uncertain = new f.exports.DownloadTaskItem(); uncertain.id = 'uncertain'; uncertain.status = 4;
  uncertain.systemTaskId = 'still-may-run'; f.Center.tasks.push(uncertain);
  f.Center.pump(); await tick();
  assert.equal(creates, 0); assert.equal(f.Center.hasActive(), true);
  await f.Center.remove(uncertain.id); await tick();
  assert.equal(creates, 1);
  await f.Center.remove(f.item.id);
});

test('paused resume queries actual state and resumes the existing task without a second download', async () => {
  const system = systemTask(); let resumed = 0, state = STATE.RUNNING;
  system.resume = async () => {resumed++; state = STATE.RUNNING;};
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => system, null, new Set(), {
    show: async () => ({progress: {state, processed: 20, sizes: [100]}}),
  });
  f.Center.pump(); await tick(); state = STATE.PAUSED;
  system.emit('pause', {state, processed: 20, sizes: [100]});
  await Promise.all([f.Center.resume(f.item.id), f.Center.resume(f.item.id)]);
  assert.equal(resumed, 1); assert.equal(f.configs.length, 1); assert.equal(f.item.status, 1);
  await f.Center.remove(f.item.id);
});

test('transient foreground query failure keeps callbacks attached and a later foreground can complete', async () => {
  const system = systemTask(); let query = 0;
  const f = fixture(async () => ({downloadAudioUrls: ['cdn']}), async () => system, null, new Set(), {
    show: async () => {
      if (++query === 2) throw Object.assign(new Error('service unavailable'), {code: 13400003});
      return {progress: {state: query >= 3 ? STATE.COMPLETED : STATE.RUNNING, processed: 100, sizes: [100]}};
    },
  });
  f.Center.pump(); await tick(); const run = f.Center.currentRun;
  await assert.rejects(f.Center.onForeground(context));
  assert.ok(system.handlers.has('completed')); assert.equal(f.configs.length, 1);
  f.files.add(f.item.partPath); await f.Center.onForeground(context); await run;
  assert.equal(f.item.status, 2); assert.equal(system.handlers.size, 0);
});
