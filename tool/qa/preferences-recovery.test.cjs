// Execute the real list stores; mock only Preferences, AppStorage and the flush clock.
// Node 20+: ARKTS_TEST_TYPESCRIPT points to an installed TypeScript module.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const tick = () => new Promise(resolve => setImmediate(resolve));

function persistence(seed) {
  const disk = new Map(Object.entries(seed).map(([name, entries]) =>
    [name, new Map(Object.entries(entries).map(([key, value]) => [key, JSON.stringify(value)]))]));
  let release, opened = false, opens = 0, flushes = 0;
  const ready = new Promise(resolve => {release = resolve;});
  const puts = [];
  const preferences = {async getPreferences(_context, {name}) {
    opens++;
    if (!opened) await ready;
    // A process restart gets a new handle and cannot see unflushed values.
    const values = new Map(disk.get(name) || []);
    return {getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
      putSync(key, value) {values.set(key, value);puts.push({name, key, value});},
      async flush() {flushes++;disk.set(name, new Map(values));}};
  }};
  return {preferences, puts, opens: () => opens, flushes: () => flushes,
    release() {opened = true;release();},
    read(name, key) {return JSON.parse(disk.get(name)?.get(key) || 'null');}};
}

function environment(boundary, legacy = {}) {
  const cache = new Map(), storage = new Map(Object.entries(legacy)), timers = new Map();
  let timerId = 0;
  function load(name) {
    if (cache.has(name)) return cache.get(name);
    const filename = path.join(root, name + '.ets');
    const override = process.env.ARKTS_TEST_SOURCE_ROOT &&
      path.join(process.env.ARKTS_TEST_SOURCE_ROOT, name + '.ets');
    const source = fs.readFileSync(override && fs.existsSync(override) ? override : filename, 'utf8');
    const code = ts.transpileModule(source, {compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}}).outputText;
    const module = {exports: {}};
    const requireModule = dependency => {
      if (dependency.startsWith('.')) {
        return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), dependency)));
      }
      if (dependency === '@kit.ArkData') return {preferences: boundary.preferences};
      if (dependency === '@kit.AbilityKit') return {};
      throw new Error('Unexpected platform dependency: ' + dependency);
    };
    new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage',
      'setTimeout', 'clearTimeout', code)(requireModule, module, module.exports,
      {get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)},
      {persistProp(key, value) {if (!storage.has(key)) storage.set(key, value);}},
      fn => {timers.set(++timerId, fn);return timerId;}, id => timers.delete(id));
    cache.set(name, module.exports);
    return module.exports;
  }
  return {load, storage, async flush() {
    await tick();
    for (const [id, fn] of [...timers]) {timers.delete(id);fn();}
    await tick();
  }};
}
const video = (id, title = id, at = 1) => ({id, title, channel: 'channel', thumbnail: '',
  duration: '', views: '', published: '', at});
const ids = rows => rows.map(row => row.id);
const plain = value => JSON.parse(JSON.stringify(value));
function history(env) {return env.load('common/YouTubeHistoryStore').YouTubeHistoryStore;}
function later(env) {return env.load('common/YouTubeWatchLaterStore').YouTubeWatchLaterStore;}
function keywords(env) {return env.load('common/SearchHistoryStore').SearchHistoryStore;}

async function roundTrip(env, boundary, store, open, prefName, key) {
  const expected = plain(await store.ensureLoaded());
  await env.flush();
  assert.deepEqual(boundary.read(prefName, key), expected, 'flush must store the final recovered list');
  const fresh = environment(boundary), reopened = open(fresh);
  reopened.init({});
  assert.deepEqual(plain(await reopened.ensureLoaded()), expected,
    'a new module graph and Preferences handle must recover the same list');
  return expected;
}

test('delayed history restore preserves old entries and every early add/update on disk', async () => {
  const disk = persistence({youtube_history: {youtubeHistoryJson: [video('old')]}});
  const env = environment(disk), store = history(env);store.init({});
  store.record(video('a', 'first'));store.record(video('b'));store.record(video('a', 'updated'));
  assert.equal(disk.puts.length, 0, 'no writes before Preferences opens');
  assert.deepEqual(disk.read('youtube_history', 'youtubeHistoryJson'), [video('old')]);
  disk.release();
  assert.deepEqual(ids(await store.ensureLoaded()), ['a', 'b', 'old']);
  const rows = await roundTrip(env, disk, store, history, 'youtube_history', 'youtubeHistoryJson');
  assert.equal(rows[0].title, 'updated');
  assert.ok(disk.flushes() > 0);
});

test('removing a disk-only watch-later entry before restore cannot resurrect it', async () => {
  const disk = persistence({youtube_watch_later: {youtubeWatchLaterJson: [video('remove'), video('keep')]}});
  const env = environment(disk), store = later(env);store.init({});
  store.remove('remove');store.add(video('new'));
  disk.release();
  assert.deepEqual(ids(await store.ensureLoaded()), ['new', 'keep']);
  await roundTrip(env, disk, store, later, 'youtube_watch_later', 'youtubeWatchLaterJson');
});

test('clear during restore removes disk and legacy keywords while allowing subsequent adds', async () => {
  const disk = persistence({bili_search_state: {searchHistoryJson: ['disk-old']}});
  const env = environment(disk, {searchHistoryJson: '["legacy-old"]'}), store = keywords(env);
  store.init({});store.add('before-clear');store.clear();store.add('after-clear');
  disk.release();
  assert.deepEqual(await store.ensureLoaded(), ['after-clear']);
  await roundTrip(env, disk, store, keywords, 'bili_search_state', 'searchHistoryJson');
});

test('early keyword removal preserves unrelated disk entries and mirrors only surviving values', async () => {
  const disk = persistence({bili_search_state: {searchHistoryJson: ['remove', 'keep']}});
  const env = environment(disk, {searchHistoryJson: '["remove"]'}), store = keywords(env);
  store.init({});store.remove('remove');store.add('new');
  disk.release();
  assert.deepEqual(await store.ensureLoaded(), ['new', 'keep']);
  assert.equal(env.storage.get('searchHistoryJson'), '["new","keep"]');
  await roundTrip(env, disk, store, keywords, 'bili_search_state', 'searchHistoryJson');
});

test('remove then re-add keeps the newest metadata; add then remove stays deleted', async () => {
  const disk = persistence({youtube_history: {youtubeHistoryJson: [video('a'), video('b'), video('keep')]}});
  const env = environment(disk), store = history(env);store.init({});
  store.remove('a');store.record(video('a', 'new title'));
  store.record(video('b'));store.remove('b');
  disk.release();
  assert.deepEqual(ids(await store.ensureLoaded()), ['a', 'keep']);
  const rows = await roundTrip(env, disk, store, history, 'youtube_history', 'youtubeHistoryJson');
  assert.equal(rows[0].title, 'new title');
});

test('clear without subsequent writes remains empty in memory, disk and a fresh process', async () => {
  const disk = persistence({youtube_watch_later: {youtubeWatchLaterJson: [video('old')]}});
  const env = environment(disk), store = later(env);store.init({});store.clear();
  disk.release();assert.deepEqual(await store.ensureLoaded(), []);
  assert.equal(env.storage.get('youtubeWatchLaterCount'), 0);
  await roundTrip(env, disk, store, later, 'youtube_watch_later', 'youtubeWatchLaterJson');
});

test('a write before init is merged and persisted when Preferences eventually opens', async () => {
  const disk = persistence({youtube_history: {youtubeHistoryJson: [video('old')]}});
  const env = environment(disk), store = history(env);store.record(video('new'));store.init({});
  disk.release();assert.deepEqual(ids(await store.ensureLoaded()), ['new', 'old']);
  await roundTrip(env, disk, store, history, 'youtube_history', 'youtubeHistoryJson');
});

test('pre-init clear also excludes the legacy keyword mirror', async () => {
  const disk = persistence({bili_search_state: {searchHistoryJson: ['disk-old']}});
  const env = environment(disk, {searchHistoryJson: '["legacy-old"]'}), store = keywords(env);
  store.clear();store.add('new');store.init({});disk.release();
  assert.deepEqual(await store.ensureLoaded(), ['new']);
  await roundTrip(env, disk, store, keywords, 'bili_search_state', 'searchHistoryJson');
});

test('repeated init shares restoration and cannot reload stale data over new changes', async () => {
  const disk = persistence({youtube_history: {youtubeHistoryJson: [video('old')]}});
  const env = environment(disk), store = history(env);store.init({});store.init({});
  assert.equal(disk.opens(), 1, 'only one Preferences restore may own the cache');
  disk.release();await store.ensureLoaded();store.remove('old');store.record(video('new'));store.init({});
  assert.equal(disk.opens(), 1);
  await roundTrip(env, disk, store, history, 'youtube_history', 'youtubeHistoryJson');
});

for (const failure of ['synchronous throw', 'asynchronous rejection']) {
  test(`explicit init retries after ${failure} and keeps early deletion intent`, async () => {
    const disk = persistence({youtube_watch_later: {youtubeWatchLaterJson: [video('remove'), video('keep')]}});
    const open = disk.preferences.getPreferences;let attempts = 0;
    disk.preferences.getPreferences = (...args) => {
      if (++attempts > 1) return open(...args);
      if (failure === 'synchronous throw') throw new Error('Preferences temporarily unavailable');
      return Promise.reject(new Error('Preferences temporarily unavailable'));
    };
    const env = environment(disk), store = later(env);store.init({});
    store.remove('remove');store.add(video('new'));
    await store.ensureLoaded();await env.flush();
    assert.equal(disk.puts.length, 0);assert.equal(disk.flushes(), 0);
    store.init({});
    assert.equal(attempts, 2, 'a failed restore must release the init latch');
    disk.release();
    assert.deepEqual(ids(await store.ensureLoaded()), ['new', 'keep']);
    await roundTrip(env, disk, store, later, 'youtube_watch_later', 'youtubeWatchLaterJson');
  });
}

test('failed initialization preserves clear intent across explicit retry and restart', async () => {
  const disk = persistence({bili_search_state: {searchHistoryJson: ['disk-old']}});
  const open = disk.preferences.getPreferences;let attempts = 0;
  disk.preferences.getPreferences = (...args) => ++attempts === 1
    ? Promise.reject(new Error('Preferences unavailable')) : open(...args);
  const env = environment(disk, {searchHistoryJson: '["legacy-old"]'}), store = keywords(env);
  store.init({});store.clear();store.add('new');
  await store.ensureLoaded();store.init({});
  assert.equal(attempts, 2);
  disk.release();assert.deepEqual(await store.ensureLoaded(), ['new']);
  await roundTrip(env, disk, store, keywords, 'bili_search_state', 'searchHistoryJson');
});

test('failed Preferences read cannot write an incomplete cache before a successful retry', async () => {
  const disk = persistence({youtube_history: {youtubeHistoryJson: [video('old')]}});
  const open = disk.preferences.getPreferences;let attempts = 0;
  let failedHandleWrites = 0, failedHandleFlushes = 0;
  disk.preferences.getPreferences = async (...args) => {
    if (++attempts > 1) return open(...args);
    return {getSync() {throw new Error('read failed');},
      putSync() {failedHandleWrites++;},
      async flush() {failedHandleFlushes++;}};
  };
  const env = environment(disk), store = history(env);store.init({});store.record(video('new'));
  await store.ensureLoaded();await env.flush();
  assert.equal(failedHandleWrites, 0, 'a failed restore must never write an incomplete cache');
  assert.equal(failedHandleFlushes, 0);
  store.init({});
  assert.equal(attempts, 2);
  disk.release();assert.deepEqual(ids(await store.ensureLoaded()), ['new', 'old']);
  await roundTrip(env, disk, store, history, 'youtube_history', 'youtubeHistoryJson');
});

test('local video filter also keeps its previous disk entries when hiding during startup', async () => {
  const disk = persistence({local_video_filter: {hidden_aids: [1, 2]}});
  const env = environment(disk), Filter = env.load('common/LocalVideoFilter').LocalVideoFilter;
  Filter.init({});const pending = Filter.hide(3);disk.release();await pending;
  assert.deepEqual(Filter.get().list(), [3, 1, 2]);await env.flush();
  assert.deepEqual(disk.read('local_video_filter', 'hidden_aids'), [3, 1, 2]);
  const fresh = environment(disk).load('common/LocalVideoFilter').LocalVideoFilter;
  fresh.init({});assert.equal(await fresh.isHidden(3), true);assert.equal(await fresh.isHidden(1), true);
});
