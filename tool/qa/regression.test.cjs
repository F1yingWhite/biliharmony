// Run actual ArkTS service code with fake platform boundaries. No network, credentials or device required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

function environment(mocks = {}) {
  const cache = new Map();
  const storage = new Map();
  function compile(source, filename) {
    const module = { exports: {} };
    const code = ts.transpileModule(source, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const localRequire = name => {
      if (name.startsWith('.')) {
        return load(path.relative(root, path.resolve(path.dirname(filename), name)).replaceAll('\\', '/'));
      }
      if (name in mocks) return mocks[name];
      throw new Error('Missing platform mock: ' + name);
    };
    new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage', code)(
      localRequire, module, module.exports,
      { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
      { persistProp() {} }
    );
    return module.exports;
  }
  function load(name) {
    name = name.replace(/\.ets$/, '');
    if (name in mocks) return mocks[name];
    if (!cache.has(name)) {
      const filename = path.join(root, name + '.ets');
      cache.set(name, compile(fs.readFileSync(filename, 'utf8'), filename));
    }
    return cache.get(name);
  }
  // Extract the unchanged production method body; ArkUI's build DSL is verified separately by CompileArkTS.
  function methodHarness(file, start, end, imports = '') {
    const source = fs.readFileSync(path.join(root, file + '.ets'), 'utf8');
    const begin = source.indexOf(start);
    const finish = source.indexOf(end, begin);
    assert.ok(begin >= 0 && finish > begin);
    return compile(imports + '\nexport class Harness {\n' + source.slice(begin, finish) + '\n}',
      path.join(root, file + '.ets')).Harness;
  }
  return { load, storage, methodHarness };
}

function httpMock(handler) {
  const calls = [];
  return {
    calls,
    http: {
      RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 'STRING', ARRAY_BUFFER: 'ARRAY_BUFFER' },
      createHttp() {
        return { async request(url, options) { calls.push({ url, options }); return handler(url, options); }, destroy() {} };
      }
    }
  };
}
const response = (body, header = {}, responseCode = 200) => ({ result: JSON.stringify(body), header, responseCode });

test('HTTP: third-party requests never send/absorb credentials or wait for Bilibili SPI', async () => {
  const net = httpMock(() => response({}, { 'set-cookie': 'SESSDATA=foreign' }));
  const env = environment({ '@kit.NetworkKit': net });
  const { HttpClient } = env.load('services/network/HttpClient');
  HttpClient.setCookie('SESSDATA', 'test-session');
  await HttpClient.get('https://www.bsbsb.top/api/skipSegments', { cOoKiE: 'test-override', Authorization: 'test-auth' });
  await HttpClient.post('https://www.bsbsb.top/api/vote', 'x=1');
  assert.equal(net.calls.length, 2);
  for (const call of net.calls) {
    assert.ok(Object.keys(call.options.header).every(key => !['cookie', 'authorization'].includes(key.toLowerCase())));
  }
  assert.equal(HttpClient.getCookie('SESSDATA'), 'test-session');
  assert.equal(HttpClient.getDownloadHeaders('https://www.bilibili.com/video/test').Cookie, undefined);
});

test('HTTP: trusted API receives cookies, forbids credential redirects, rejects spoofed hosts', async () => {
  const net = httpMock(() => response({ code: 0, data: {} }));
  const env = environment({ '@kit.NetworkKit': net });
  const { CredentialPolicy } = env.load('services/network/CredentialPolicy');
  const { HttpClient } = env.load('services/network/HttpClient');
  for (const url of ['http://api.bilibili.com/x', 'https://api.bilibili.com.evil.test/x',
    'https://api.bilibili.com@evil.test/x', 'https://evil.test/api.bilibili.com',
    'https://api.bilibili.com:8443/x', 'https://api.bilibili.com\\@evil.test/x']) assert.equal(CredentialPolicy.allows(url), false);
  HttpClient.setCookie('buvid3', 'real-device-id');
  HttpClient.setCookie('SESSDATA', 'test-session');
  await HttpClient.get('https://api.bilibili.com/x/web-interface/nav');
  assert.match(net.calls[0].options.header.Cookie, /SESSDATA=test-session/);
  assert.equal(net.calls[0].options.maxRedirects, 0);
});

test('HTTP: an old response cannot restore cookies after logout', async () => {
  const pending = deferred();
  const env = environment({ '@kit.NetworkKit': httpMock(() => pending.promise) });
  const { HttpClient } = env.load('services/network/HttpClient');
  const { AuthSession } = env.load('services/auth/AuthSession');
  HttpClient.setCookie('buvid3', 'real-device-id');
  HttpClient.setCookie('SESSDATA', 'test-old');
  const request = HttpClient.get('https://api.bilibili.com/x/test');
  await tick();
  AuthSession.advance();
  HttpClient.removeCookie('SESSDATA');
  pending.resolve(response({ code: 0, data: {} }, { 'set-cookie': 'SESSDATA=test-old' }));
  assert.equal((await request).ok, false);
  assert.equal(HttpClient.getCookie('SESSDATA'), '');
});

test('Unread: logout resets immediately; old account and pre-clear responses cannot write back', async () => {
  const requests = [];
  const env = environment({
    'services/network/HttpClient': { HttpClient: { getCookie: () => 'test-session' } },
    'api/MessageApi': { MessageApi: { getMsgFeedUnread() { const d = deferred(); requests.push(d); return d.promise; } } }
  });
  const { MsgUnreadStore } = env.load('services/message/MsgUnreadStore');
  const { AuthSession } = env.load('services/auth/AuthSession');
  const { MsgFeedUnread } = env.load('model/Models');
  const unread = count => Object.assign(new MsgFeedUnread(), { reply: count });
  const old = MsgUnreadStore.refresh();
  AuthSession.advance();
  MsgUnreadStore.resetSession();
  const next = MsgUnreadStore.refresh();
  requests[0].resolve(unread(9));
  await old;
  assert.equal(env.storage.get('msgUnreadTotal'), 0);
  requests[1].resolve(unread(2));
  await next;
  assert.equal(env.storage.get('msgUnreadTotal'), 2);
  const preClear = MsgUnreadStore.refresh();
  MsgUnreadStore.clearAll();
  requests[2].resolve(unread(5));
  await preClear;
  assert.equal(env.storage.get('msgUnreadTotal'), 0);
});

test('Playback: manual selection invalidates initial and resume-part requests', async () => {
  const requests = [];
  const env = environment({ 'api/BiliApi': { BiliApi: { getPlayUrl() { const d = deferred(); requests.push(d); return d.promise; } } } });
  const { PlaybackSourceCoordinator } = env.load('services/media/PlaybackSourceCoordinator');
  const ctl = new PlaybackSourceCoordinator();
  const detail = { aid: 1, bvid: 'test', cid: 10, pages: [{ cid: 10 }, { cid: 20 }] };
  const initial = ctl.initial(detail, 80, ctl.next());
  ctl.next();
  requests[0].resolve({ urls: ['old'], lastPlayCid: 20 });
  assert.equal(await initial, null);
  assert.equal(requests.length, 1, 'stale initial response must not launch another resume request');
  const resume = ctl.initial(detail, 80, ctl.next());
  requests[1].resolve({ urls: ['first'], lastPlayCid: 20 });
  await tick();
  ctl.next();
  requests[2].resolve({ urls: ['old-resume'], lastPlayCid: 0 });
  assert.equal(await resume, null);
  const valid = ctl.initial(detail, 80, ctl.next());
  requests[3].resolve({ urls: ['first'], lastPlayCid: 20 });
  await tick();
  requests[4].resolve({ urls: ['resume'], lastPlayCid: 0 });
  assert.equal((await valid).cid, 20, 'resume response need not repeat lastPlayCid');
});

test('Playback: stale quality response must not release the new video player', async () => {
  const pending = deferred();
  const env = environment({ 'api/BiliApi': { BiliApi: { getPlayUrl: () => pending.promise } } });
  const { RequestEpoch } = env.load('common/RequestEpoch');
  const Harness = env.methodHarness('components/player/PlayerView', '  async changeQuality(', '  setPlaybackSpeed',
    "import { BiliApi } from '../../api/BiliApi'; import { PlayerQualityPreference } from '../../common/PlayerQualityPreference';");
  const view = Object.assign(new Harness(), { destroyed: false, qualityLoading: false, activeQuality: 80,
    sourceVersion: 1, cid: 10, sourceRequests: new RequestEpoch() });
  const request = view.changeQuality(64);
  view.sourceRequests.next();
  view.sourceVersion = 2;
  view.cid = 20;
  view.qualityLoading = true;
  view.player = { release() { assert.fail('stale request released a new player'); } };
  pending.resolve({ urls: ['old-quality'] });
  await request;
  assert.equal(view.qualityLoading, true, 'old finally must not clear a newer request');
});

test('Playback: a source change during release prevents obsolete player recreation', async () => {
  const release = deferred();
  const env = environment({ 'api/BiliApi': { BiliApi: { getPlayUrl: async () => ({ urls: ['quality'], audioUrls: [], qualities: [], quality: 64 }) } } });
  const { RequestEpoch } = env.load('common/RequestEpoch');
  const Harness = env.methodHarness('components/player/PlayerView', '  async changeQuality(', '  setPlaybackSpeed',
    "import { BiliApi } from '../../api/BiliApi'; import { PlayerQualityPreference } from '../../common/PlayerQualityPreference';");
  let audioReleased = 0;
  const view = Object.assign(new Harness(), { destroyed: false, qualityLoading: false, activeQuality: 80,
    sourceVersion: 1, cid: 10, sourceRequests: new RequestEpoch(),
    player: { release: () => release.promise }, audioPlayer: { async release() { audioReleased++; } },
    invalidatePlayerCreation() {}, cancelAudioGate() {}, cancelFirstFrameMute() {}, closeSettingPanels() {}, stopDmLoop() {},
    initPlayer() { assert.fail('obsolete source recreated a player'); } });
  const request = view.changeQuality(64);
  await tick();
  view.sourceRequests.next();
  view.sourceVersion = 2;
  release.resolve();
  await request;
  assert.equal(audioReleased, 1, 'detached audio still belongs to the old operation and must be released');
});

test('Search: new query starts immediately; old completion cannot replace results or clear loading', async () => {
  const pending = [];
  const env = environment({ 'api/SearchApi': { SearchApi: { searchAll(keyword) { const d = deferred(); pending.push({ keyword, ...d }); return d.promise; } } } });
  const { RequestEpoch } = env.load('common/RequestEpoch');
  const Harness = env.methodHarness('pages/Search', '  async doSearch(', '  /** 综合搜索翻页合并',
    "import { SearchApi } from '../api/SearchApi'; import { VIDEO_DURATION_OPTIONS, VIDEO_PUBTIME_OPTIONS } from '../model/Models';");
  const view = Object.assign(new Harness(), { keyword: 'old', searchTab: 0, videoOrder: 'totalrank', filterDuration: 0, filterPubtime: 0, filterTids: 0, destroyed: false, searchRequests: new RequestEpoch(), applyAllTotals() {} });
  const first = view.doSearch(true);
  view.keyword = 'new';
  const second = view.doSearch(true);
  assert.deepEqual(pending.map(x => x.keyword), ['old', 'new']);
  pending[0].resolve({ sections: ['old'], totals: new Map() });
  await first;
  assert.equal(view.allSections, undefined);
  assert.equal(view.loading, true);
  pending[1].resolve({ sections: ['new'], totals: new Map() });
  await second;
  assert.deepEqual(view.allSections, ['new']);
  assert.equal(view.loading, false);
});

test('History API: network/auth/malformed responses differ from a successful empty list', async () => {
  let next;
  const env = environment({ '@kit.NetworkKit': httpMock(() => next) });
  const { HttpClient } = env.load('services/network/HttpClient');
  HttpClient.setCookie('buvid3', 'real-device-id');
  const { HistoryApi } = env.load('api/HistoryApi');
  next = response({}, {}, 503);
  assert.equal((await HistoryApi.getHistory()).kind, 'network');
  next = response({ code: -101 });
  assert.equal((await HistoryApi.getHistory()).kind, 'auth');
  next = response({ code: 0, data: {} });
  assert.equal((await HistoryApi.getHistory()).kind, 'parse');
  next = response({ code: 0, data: { list: [] } });
  const result = await HistoryApi.getHistory();
  assert.equal(result.ok, true);
  assert.deepEqual(result.data.items, []);
});

test('History pager: failure preserves list and cursor, retry requests the same page', async () => {
  const calls = [];
  const replies = [];
  const env = environment({ 'api/HistoryApi': { HistoryApi: { getHistory(max, viewAt) { calls.push([max, viewAt]); return Promise.resolve(replies.shift()); } } } });
  const { HistoryPager } = env.load('services/library/HistoryPager');
  const pager = new HistoryPager();
  replies.push({ ok: true, data: { items: [{ video: { bvid: 'first' }, viewAt: 200 }], max: 17, viewAt: 200, hasMore: true } });
  await pager.load(true);
  replies.push({ ok: false, data: null, message: 'offline' });
  await pager.load(false);
  assert.equal(pager.source.totalCount(), 1);
  assert.equal(pager.hasMore, true);
  assert.equal(pager.error, 'offline');
  replies.push({ ok: true, data: { items: [], max: 0, viewAt: 0, hasMore: false } });
  await pager.retry();
  assert.deepEqual(calls, [[0, 0], [17, 200], [17, 200]]);
  assert.equal(pager.source.totalCount(), 1);
  assert.equal(pager.hasMore, false);
});

test('History pager: responses after navigation or account change cannot mutate the list', async () => {
  const pending = [];
  const env = environment({ 'api/HistoryApi': { HistoryApi: { getHistory() { const d = deferred(); pending.push(d); return d.promise; } } } });
  const { HistoryPager } = env.load('services/library/HistoryPager');
  const { AuthSession } = env.load('services/auth/AuthSession');
  const pager = new HistoryPager();
  const old = pager.load(true);
  pager.cancel();
  pending[0].resolve({ ok: true, data: { items: [{ video: { bvid: 'old' }, viewAt: 1 }], hasMore: false } });
  await old;
  assert.equal(pager.source.totalCount(), 0);
  const other = pager.load(true);
  AuthSession.advance();
  pending[1].resolve({ ok: true, data: { items: [{ video: { bvid: 'old' }, viewAt: 1 }], hasMore: false } });
  await other;
  assert.equal(pager.source.totalCount(), 0);
});

test('History pager: clearing history invalidates an in-flight page', async () => {
  const pending = deferred();
  const env = environment({ 'api/HistoryApi': { HistoryApi: { getHistory: () => pending.promise } } });
  const { HistoryPager } = env.load('services/library/HistoryPager');
  const pager = new HistoryPager();
  const loading = pager.load(true);
  pager.clear();
  pending.resolve({ ok: true, data: { items: [{ video: { bvid: 'deleted' }, viewAt: 1 }], hasMore: true } });
  await loading;
  assert.equal(pager.source.totalCount(), 0);
  assert.equal(pager.hasMore, false);
  assert.equal(pager.loading, false);
});

function assetEnvironment({ chunks, status = 200, writeFailure = false, burst = false }) {
  const files = new Map();
  const handles = new Map();
  let fd = 0, active = 0, maximumActive = 0;
  const io = {
    OpenMode: { READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
    async open(name) { const file = { fd: ++fd, name, position: 0 }; handles.set(fd, file); files.set(name, Buffer.alloc(0)); return file; },
    async write(id, data) {
      await tick();
      if (writeFailure) throw new Error('simulated disk failure');
      const file = handles.get(id);
      assert.ok(file, 'write must complete before closing the file');
      const chunk = Buffer.from(data);
      const size = Math.min(chunk.length, 7); // exercise legitimate short writes
      files.set(file.name, Buffer.concat([files.get(file.name), chunk.subarray(0, size)]));
      file.position += size;
      return size;
    },
    async read(id, target) { const source = files.get(handles.get(id).name); const size = Math.min(source.length, target.byteLength); new Uint8Array(target).set(source.subarray(0, size)); return size; },
    async close(file) { handles.delete(file.fd); },
    async rename(from, to) { files.set(to, files.get(from)); files.delete(from); },
    async unlink(name) { files.delete(name); }
  };
  const network = { http: { RequestMethod: { GET: 'GET' }, createHttp() {
    const listeners = {};
    let destroyed = false;
    return {
      on(event, handler) { listeners[event] = handler; },
      requestInStream() {
        active++;
        maximumActive = Math.max(maximumActive, active);
        // Deliberately resolve status BEFORE body completion.
        setImmediate(async () => {
          for (const chunk of chunks) {
            if (destroyed) break;
            listeners.dataReceive(chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength));
            if (!burst) await tick();
          }
          if (!destroyed) listeners.dataEnd();
        });
        return Promise.resolve(status);
      },
      destroy() { if (!destroyed) { destroyed = true; active--; } }
    };
  } } };
  const env = environment({ '@kit.NetworkKit': network, '@kit.CoreFileKit': { fileIo: io } });
  return { ...env, files, handles, maxActive: () => maximumActive };
}

test('Asset cache: stream completion and short writes finish before atomic publication', async () => {
  const chunks = [Buffer.from('GIF89a0123456789'), Buffer.from('remaining-content')];
  const env = assetEnvironment({ chunks });
  const { AssetDownload } = env.load('services/cache/AssetDownload');
  const ok = await AssetDownload.save('https://cdn.test/image.gif', '/cache/image.gif', 1024, 10000,
    header => Buffer.from(header).subarray(0, 3).toString() === 'GIF');
  assert.equal(ok, true);
  assert.deepEqual(env.files.get('/cache/image.gif'), Buffer.concat(chunks));
  assert.deepEqual([...env.files.keys()], ['/cache/image.gif']);
  assert.equal(env.handles.size, 0);
});

test('Asset cache: oversized, invalid, HTTP-error and failed writes preserve original files', async () => {
  for (const config of [
    { chunks: [Buffer.alloc(100)], limit: 20 },
    { chunks: [Buffer.alloc(20)], invalid: true },
    { chunks: [Buffer.alloc(20)], status: 503 },
    { chunks: [Buffer.alloc(20)], writeFailure: true },
    { chunks: [Buffer.alloc(5 * 1024 * 1024)], limit: 10 * 1024 * 1024, burst: true }
  ]) {
    const env = assetEnvironment(config);
    env.files.set('/cache/original', Buffer.from('original'));
    const { AssetDownload } = env.load('services/cache/AssetDownload');
    assert.equal(await AssetDownload.save('https://cdn.test/asset', '/cache/original', config.limit || 1024,
      10000, () => !config.invalid), false);
    assert.deepEqual([...env.files.keys()], ['/cache/original']);
    assert.equal(env.files.get('/cache/original').toString(), 'original');
    assert.equal(env.handles.size, 0);
  }
});

test('Asset cache: concurrent callers share a three-download bound and queued work completes', async () => {
  const env = assetEnvironment({ chunks: [Buffer.alloc(20)] });
  const { AssetDownload } = env.load('services/cache/AssetDownload');
  const results = await Promise.all(Array.from({ length: 9 }, (_, index) =>
    AssetDownload.save('https://cdn.test/' + index, '/cache/' + index, 1024, 10000, () => true)));
  assert.ok(results.every(Boolean));
  assert.equal(env.maxActive(), 3);
  assert.equal(env.files.size, 9);
  assert.equal(env.handles.size, 0);
});
