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

test('private messages preserve full text without classifying it as a share card', () => {
  const { PrivateMessageItem } = environment().load('model/message/MessageModels');
  const text = '第一行\n' + '这是一条需要完整显示的长私信。'.repeat(30);
  const item = PrivateMessageItem.from({ msg_type: 1, content: JSON.stringify({ content: text }) });
  assert.equal(item.text, text);
  assert.equal(item.richTitle, '');
  assert.equal(item.richCover, '');
  assert.equal(item.richUrl, '');
});

test('private notification cards retain body and image messages retain dimensions', () => {
  const { PrivateMessageItem } = environment().load('model/message/MessageModels');
  const notice = PrivateMessageItem.from({ msg_type: 10,
    content: JSON.stringify({ title: '登录操作通知', text: '这是通知的完整正文。' }) });
  assert.equal(notice.richTitle, '登录操作通知');
  assert.equal(notice.richDesc, '这是通知的完整正文。');
  const image = PrivateMessageItem.from({ msg_type: 2,
    content: JSON.stringify({ url: 'https://example.com/image.jpg', width: 600, height: 900 }) });
  assert.equal(image.imageUrl, 'https://example.com/image.jpg');
  assert.equal(image.imageWidth, 600);
  assert.equal(image.imageHeight, 900);
  assert.equal(image.richUrl, '');
  const video = PrivateMessageItem.from({ msg_type: 7,
    content: JSON.stringify({ title: '视频', aid: 123, cover: 'https://example.com/cover.jpg' }) });
  assert.equal(video.richAid, 123);
  assert.equal(video.richTitle, '视频');
});

/** AppTheme 依赖的平台边界：只用到命名空间里的少量成员，空壳即可。 */
function themeMocks() {
  return {'@kit.ArkUI':{uiMaterial:{}},'@kit.AbilityKit':{common:{}},
    '@kit.ArkData':{preferences:{}},'@kit.BasicServicesKit':{deviceInfo:{}}};
}

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
    // .ets 是 CRLF 检出，锚点按 \n 书写：统一归一为 LF，避免跨行锚点静默失配。
    const source = fs.readFileSync(path.join(root, file + '.ets'), 'utf8').replace(/\r\n/g, '\n');
    const begin = source.indexOf(start);
    const finish = source.indexOf(end, begin);
    // 失败时指出漂了哪个锚点：裸断言看起来像功能回归，实际是夹具失效。
    assert.ok(begin >= 0, `锚点未命中 start（${file}.ets）：${JSON.stringify(start)}`);
    assert.ok(finish > begin, `锚点未命中 end（${file}.ets）：${JSON.stringify(end)}`);
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

test('PGC: episode metadata uses the selected episode identity rather than the first episode', async () => {
  const env = environment({'services/network/HttpClient': {HttpClient:{buildQuery:p=>new URLSearchParams(p).toString()}},
    'api/internal/ApiCommon': {webGet: async () => ({
    ok:true,json:()=>({code:0,result:{title:'Series',episodes:[
      {id:10,aid:1,bvid:'first',cid:100,title:'1',duration:1000},
      {id:20,aid:2,bvid:'selected',cid:200,title:'2',long_title:'Episode',duration:120000}
    ]}})
  })}});
  const {BangumiApi} = env.load('api/BangumiApi');
  const detail = await BangumiApi.getEpisodeVideoDetail(20);
  assert.equal(detail.epId,20);assert.equal(detail.cid,200);assert.equal(detail.aid,2);
  assert.equal(detail.bvid,'selected');assert.equal(detail.duration,120);
  assert.equal(detail.pages.length,1);assert.equal(detail.pages[0].cid,200);
  assert.equal(await BangumiApi.getEpisodeVideoDetail(99),null);
});

test('PGC: authenticated endpoint preserves preview and rejects denied, DRM and segmented results', async () => {
  const calls=[];let payload={code:0,result:{quality:32,is_preview:1,
    durl:[{url:'https://cdn.example.test/preview.mp4',backup_url:[]}]}};
  const env=environment({'services/network/HttpClient':{},'api/internal/ApiCommon':{
    webGet:async(...args)=>{calls.push(args);return {ok:true,json:()=>payload};}
  }});
  const {BangumiApi}=env.load('api/BangumiApi');
  const info=await BangumiApi.getPlayUrl(20,200,80);
  assert.equal(info.isPreview,true);assert.equal(info.quality,32);
  assert.match(calls[0][0],/\/pgc\/player\/web\/playurl$/);
  assert.equal(calls[0][1].ep_id,'20');assert.equal(calls[0][1].cid,'200');assert.equal(calls[0][1].qn,'80');
  assert.equal(calls[0][2],'https://www.bilibili.com/bangumi/play/ep20');
  payload={code:-10403,message:'大会员专享限制'};
  await assert.rejects(()=>BangumiApi.getPlayUrl(20,200,80),/大会员/);
  payload={code:0,result:{is_drm:1}};
  await assert.rejects(()=>BangumiApi.getPlayUrl(20,200,80),/受保护/);
  payload={code:0,result:{durl:[{url:'segment1'},{url:'segment2'}]}};
  await assert.rejects(()=>BangumiApi.getPlayUrl(20,200,80),/分段格式/);
});

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

test('HTTP: concurrent transport failures retain their own platform code and release requests', async () => {
  const first = deferred(), second = deferred(); let destroyed = 0, calls = 0;
  const net = httpMock(() => ++calls === 1 ? first.promise : second.promise);
  const create = net.http.createHttp;
  net.http.createHttp = () => Object.assign(create(), {destroy() { destroyed++; }});
  const {HttpClient} = environment({'@kit.NetworkKit': net}).load('services/network/HttpClient');
  HttpClient.setCookie('buvid3', 'real-device-id');
  const a = HttpClient.get('https://api.bilibili.com/first');
  const b = HttpClient.get('https://api.bilibili.com/second');
  await tick();
  second.reject({code:2300063, message:'sensitive URL and cookie must not be logged'});
  first.reject({code:2300028});
  const [timeout, oversized] = await Promise.all([a,b]);
  assert.equal(timeout.status,-1); assert.equal(timeout.transportCode,2300028);
  assert.match(timeout.transportMessage,/超时/);
  assert.equal(oversized.transportCode,2300063); assert.match(oversized.transportMessage,/过大/);
  assert.equal(destroyed,2);
});

test('HTTP: business errors and session invalidation are distinct from transport failure', async () => {
  const net = httpMock(() => response({code:-101}));
  const env = environment({'@kit.NetworkKit':net});
  const {HttpClient} = env.load('services/network/HttpClient');
  HttpClient.setCookie('buvid3','real-device-id');
  const result = await HttpClient.get('https://api.bilibili.com/test');
  assert.equal(result.status,200); assert.equal(result.json().code,-101); assert.equal(result.transportCode,0);
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

function assetEnvironment({ chunks, status = 200, writeFailure = false, burst = false }, proxy = null) {
  const files = new Map();
  const handles = new Map();
  const optionsSeen = [];
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
      requestInStream(url, options) {
        optionsSeen.push(options);
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
  const env = environment({ '@kit.NetworkKit': network, '@kit.CoreFileKit': { fileIo: io },
    'services/network/HttpClient': { HttpClient: { proxyConfig: () => proxy } } });
  return { ...env, files, handles, optionsSeen, maxActive: () => maximumActive };
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

test('Asset cache: streaming downloads use the configured proxy and stay direct by default', async () => {
  // 回归背景：AssetDownload 自己 createHttp + requestInStream，不经过 HttpClient.execute。
  // 漏掉 usingProxy 时，只能靠代理出网的环境里缓存图片会安静地全部失败（0 字节 .part），
  // 表现为列表封面整片空白而不是报错。
  const direct = assetEnvironment({ chunks: [Buffer.from('GIF89a0123456789')] });
  const { AssetDownload: Direct } = direct.load('services/cache/AssetDownload');
  assert.equal(await Direct.save('https://cdn.test/a.gif', '/cache/a.gif', 1024, 10000, () => true), true);
  // 默认空值不写 usingProxy，行为与历史版本一致。
  assert.equal(direct.optionsSeen[0].usingProxy, undefined);

  const proxy = { host: '127.0.0.1', port: 7890, exclusionList: [] };
  const proxied = assetEnvironment({ chunks: [Buffer.from('GIF89a0123456789')] }, proxy);
  const { AssetDownload } = proxied.load('services/cache/AssetDownload');
  assert.equal(await AssetDownload.save('https://cdn.test/a.gif', '/cache/a.gif', 1024, 10000, () => true), true);
  assert.deepEqual(proxied.optionsSeen[0].usingProxy, proxy);
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

test('YouTube: search parses bounded JSON without executing scripts and deduplicates videos', () => {
  const {YouTubeApi}=environment({'services/network/HttpClient':{}}).load('api/YouTubeApi');
  const renderer={videoRenderer:{videoId:'aqz-KE-bpKQ',title:{runs:[{text:'title }; " '},{text:'end'}]},
    ownerText:{runs:[{text:'Blender'}]},lengthText:{simpleText:'10:35'},viewCountText:{simpleText:'100 views'}}};
  const data={contents:{sections:[renderer,renderer,{videoRenderer:{videoId:'bad',title:{simpleText:'wrong'}}},
    {adSlotRenderer:{slot:renderer}}]}};
  const html='before<script>var ytInitialData = '+JSON.stringify(data)+';throw new Error("never execute");</script>';
  const items=YouTubeApi.parseSearch(html);
  assert.equal(items.length,1);assert.equal(items[0].title,'title }; " end');
  assert.equal(items[0].channel,'Blender');assert.equal(items[0].duration,'10:35');
  assert.equal(YouTubeApi.parseSearch('window["ytInitialData"] = {"contents":{}};').length,0);
  assert.throws(()=>YouTubeApi.parseSearch('<html>consent required</html>'),/验证页/);
  assert.equal(YouTubeApi.initialObject('var ytInitialData = {"x":"unfinished','ytInitialData'),null);
});

test('YouTube: only recognized YouTube hosts and valid IDs can reach playback', () => {
  const {YouTubeApi}=environment({'services/network/HttpClient':{}}).load('api/YouTubeApi');
  for(const value of ['aqz-KE-bpKQ','https://youtu.be/aqz-KE-bpKQ?si=test',
    'https://www.youtube.com/watch?foo=1&v=aqz-KE-bpKQ&t=20','https://m.youtube.com/shorts/aqz-KE-bpKQ']) {
    assert.equal(YouTubeApi.videoId(value),'aqz-KE-bpKQ');
  }
  for(const value of ['https://youtube.com.evil.test/watch?v=aqz-KE-bpKQ',
    'https://evil.test/youtube.com/watch?v=aqz-KE-bpKQ','javascript:alert(1)',"aqz-KE-bpKQ'",'https://youtu.be/aqz-KE-bpKQextra']) {
    assert.equal(YouTubeApi.videoId(value),'');
  }
  // 分享/打开链接只由校验过的 ID 拼出：非法输入返回空串，绝不把用户输入塞进 URL。
  assert.equal(YouTubeApi.watchUrl('aqz-KE-bpKQ'),'https://youtu.be/aqz-KE-bpKQ');
  assert.equal(YouTubeApi.videoId(YouTubeApi.watchUrl('aqz-KE-bpKQ')),'aqz-KE-bpKQ');
  for(const value of ["aqz-KE-bpKQ'",'javascript:alert(1)','','aqz-KE-bpKQextra','https://evil.test/x']) {
    assert.equal(YouTubeApi.watchUrl(value),'');
  }
});

test('YouTube: network failures, verification pages and restricted metadata stay explicit', async () => {
  let response={ok:false,status:-1,transportMessage:'timeout'};
  const calls=[];
  const {YouTubeApi}=environment({'services/network/HttpClient':{HttpClient:{get:async(...args)=>{
    calls.push(args);return response;
  }}}}).load('api/YouTubeApi');
  await assert.rejects(()=>YouTubeApi.search('a & b'),/连接失败/);
  assert.match(calls[0][0],/search_query=a%20%26%20b/);
  assert.equal(calls[0][1].Cookie,undefined);assert.equal(calls[0][1].Referer,undefined);
  response={ok:true,body:'var ytInitialPlayerResponse = '+JSON.stringify({playabilityStatus:{reason:'请登录'}})+';'};
  await assert.rejects(()=>YouTubeApi.detail('aqz-KE-bpKQ'),/请登录/);
  response={ok:true,body:'var ytInitialPlayerResponse = '+JSON.stringify({videoDetails:{title:'Bunny',author:'Blender',
    shortDescription:'Full description\nline 2',lengthSeconds:'635',viewCount:'200'}})+';'};
  const detail=await YouTubeApi.detail('aqz-KE-bpKQ');
  assert.equal(detail.title,'Bunny');assert.equal(detail.description,'Full description\nline 2');
  assert.equal(detail.duration,'10:35');
  await assert.rejects(()=>YouTubeApi.detail('invalid'),/无效/);
  response={ok:true,body:'var ytInitialPlayerResponse = {"playabilityStatus":{"reason":"请登录"}};'+
    'var ytInitialData = '+JSON.stringify({contents:{twoColumnWatchNextResults:{results:{results:{contents:[
      {videoPrimaryInfoRenderer:{title:{runs:[{text:'Public title'}]},dateText:{simpleText:'2026年9月11日'}}},
      {videoSecondaryInfoRenderer:{owner:{videoOwnerRenderer:{title:{runs:[{text:'Creator'}]}}},
        attributedDescription:{content:'Public full description'}}}
    ]}}}}})+';'};
  const publicDetail=await YouTubeApi.detail('aqz-KE-bpKQ');
  assert.equal(publicDetail.title,'Public title');assert.equal(publicDetail.channel,'Creator');
  assert.equal(publicDetail.description,'Public full description');assert.equal(publicDetail.published,'2026年9月11日');

});

test('YouTube: iframe identifies the actual app and cannot interpolate an arbitrary video ID', () => {
  const {youtubePlayerHtml,youtubePlaybackError}=environment({'services/network/HttpClient':{}}).load('common/YouTubePlayerHtml');
  const html=youtubePlayerHtml('aqz-KE-bpKQ');
  assert.match(html,/https:\/\/com\.piliplus\.harmony/);
  assert.match(html,/visibilitychange/);assert.match(html,/pauseVideo/);
  assert.equal(youtubePlayerHtml("';alert(1)//"),'');
  assert.match(youtubePlaybackError('YT_ERROR_153'),/验证/);
  assert.match(youtubePlaybackError('YT_ERROR_150'),/嵌入/);
  assert.equal(youtubePlaybackError('YT_READY'),'');
});

test('YouTube: the fullscreen probe stays offline and never interpolates page data', () => {
  // QA 探针页只在 ytPlayerProbe 打开时加载，用来验证全屏/返回联动（播放层被风控挡住时）。
  // 它必须完全离线：任何远端请求都会让"验证应用侧管线"这件事本身失真。
  const {youtubeFullscreenProbeHtml}=environment({'services/network/HttpClient':{}}).load('common/YouTubePlayerHtml');
  const html=youtubeFullscreenProbeHtml();
  assert.match(html,/requestFullscreen/);
  assert.doesNotMatch(html,/https?:\/\//);
  assert.doesNotMatch(html,/videoId|ytimg|youtube\.com/);
});
test('YouTube: the watch page yields related videos and a comment entry', () => {
  // 回归背景：相关推荐已从 compactVideoRenderer 换成 lockupViewModel；评论入口是 watch 页
  // 里一个 continuation token（正文要再请求一次）。两者都与 B 站数据模型无关，单独解析。
  const lockup={lockupViewModel:{contentId:'xOXolSQcEb4',
    metadata:{lockupMetadataViewModel:{title:{content:'SNOW BEAR'},
      metadata:{contentMetadataViewModel:{metadataRows:[
        {metadataParts:[{text:{content:'The Art of Aaron Blaise'}}]},
        {metadataParts:[{text:{content:'741万次观看'}},{text:{content:'9个月前'}}]}]}}}},
    contentImage:{thumbnailViewModel:{overlays:[{thumbnailBottomOverlayViewModel:
      {badges:[{thumbnailBadgeViewModel:{text:'11:46'}}]}}]}}}};
  const initial={contents:{twoColumnWatchNextResults:{
    results:{results:{contents:[{itemSectionRenderer:{sectionIdentifier:'comment-item-section',
      contents:[{continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token:'CMT_TOKEN'}}}}]}}]}},
    secondaryResults:{secondaryResults:{results:[{itemSectionRenderer:{contents:[lockup]}}]}}}}};
  const html='var ytInitialPlayerResponse = '+JSON.stringify({videoDetails:{title:'Big Buck Bunny',
    author:'Blender',viewCount:'23416129',lengthSeconds:'635'}})+';'+
    'var ytInitialData = '+JSON.stringify(initial)+';';
  const {YouTubeApi}=environment({'services/network/HttpClient':{}}).load('api/YouTubeApi');
  const page=YouTubeApi.parseDetailPage(html,'aqz-KE-bpKQ');
  assert.equal(page.video.title,'Big Buck Bunny');
  assert.equal(page.video.duration,'10:35');
  assert.equal(page.related.length,1);
  const item=page.related[0];
  assert.equal(item.id,'xOXolSQcEb4');
  assert.equal(item.title,'SNOW BEAR');
  assert.equal(item.channel,'The Art of Aaron Blaise');
  assert.equal(item.views,'741万次观看');assert.equal(item.published,'9个月前');
  assert.equal(item.duration,'11:46');
  assert.equal(item.thumbnail,'https://i.ytimg.com/vi/xOXolSQcEb4/hqdefault.jpg');
  assert.equal(page.commentToken,'CMT_TOKEN');
});

test('YouTube: comments resolve through frameworkUpdates and keep the next token', () => {
  // 评论正文不在 commentThreadRenderer 里，而在 frameworkUpdates 的 commentEntityPayload，
  // 两边靠 commentKey/key 对应；对不上的那一条必须跳过，不能猜内容。
  const json={onResponseReceivedEndpoints:[{appendContinuationItemsAction:{continuationItems:[
    {commentsHeaderRenderer:{countText:{runs:[{text:'1,234'}]}}},
    {commentThreadRenderer:{commentViewModel:{commentViewModel:{commentKey:'K1'}}}},
    {commentThreadRenderer:{commentViewModel:{commentViewModel:{commentKey:'MISSING'}}}},
    {continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token:'NEXT_CMT'}}}},
  ]}}],frameworkUpdates:{entityBatchUpdate:{mutations:[{payload:{commentEntityPayload:{key:'K1',
    properties:{commentId:'C1',content:{content:'第一条评论'},publishedTime:'7年前'},
    author:{displayName:'@BergsArt',avatarThumbnailUrl:'https://yt3.ggpht.com/a.jpg'},
    toolbar:{likeCountNotliked:'2663'}}}}]}}};
  const {YouTubeApi}=environment({'services/network/HttpClient':{}}).load('api/YouTubeApi');
  const page=YouTubeApi.parseComments(JSON.stringify(json));
  assert.equal(page.comments.length,1);
  assert.equal(page.comments[0].id,'C1');
  assert.equal(page.comments[0].text,'第一条评论');
  assert.equal(page.comments[0].author,'@BergsArt');
  assert.equal(page.comments[0].likes,'2663');assert.equal(page.comments[0].published,'7年前');
  assert.equal(page.total,'1,234');
  assert.equal(page.continuation,'NEXT_CMT');
  assert.equal(YouTubeApi.parseComments('{}').comments.length,0);
  assert.throws(()=>YouTubeApi.parseComments('<html>'),/评论数据/);
});

test('YouTube: comment requests reuse the page InnerTube config and send no credentials', async () => {
  const calls=[];
  const initial={contents:{twoColumnWatchNextResults:{
    results:{results:{contents:[{itemSectionRenderer:{sectionIdentifier:'comment-item-section',
      contents:[{continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token:'CMT_TOKEN'}}}}]}}]}}}}};
  const html='var ytInitialPlayerResponse = '+JSON.stringify({videoDetails:{title:'Bunny'}})+';'+
    'var ytInitialData = '+JSON.stringify(initial)+';'+
    '"INNERTUBE_API_KEY":"KEY123","INNERTUBE_CLIENT_VERSION":"2.2026.01.00"';
  const {YouTubeApi}=environment({'services/network/HttpClient':{HttpClient:{
    get:async()=>({ok:true,body:html}),
    post:async(...args)=>{calls.push(args);return {ok:true,body:JSON.stringify({onResponseReceivedEndpoints:[],
      frameworkUpdates:{entityBatchUpdate:{mutations:[]}}})};},
  }}}).load('api/YouTubeApi');
  const detail=await YouTubeApi.detailPage('aqz-KE-bpKQ');
  assert.equal(detail.commentToken,'CMT_TOKEN');
  const page=await YouTubeApi.comments(detail.commentToken);
  assert.equal(page.comments.length,0);assert.equal(page.continuation,'');
  const [url,body,headers]=calls[0];
  assert.match(url,/youtubei\/v1\/next\?key=KEY123/);
  assert.equal(JSON.parse(body).continuation,'CMT_TOKEN');
  assert.equal(JSON.parse(body).context.client.clientVersion,'2.2026.01.00');
  assert.equal(headers['Content-Type'],'application/json');
  assert.match(headers['User-Agent'],/Mozilla\/5\.0/);
  assert.equal(headers.Cookie,undefined);assert.equal(headers.Referer,undefined);
});
test('YouTube: public pages are requested as a desktop client or the page has no parseable results', async () => {
  // 回归背景：不带 User-Agent 时 YouTube 返回验证页/移动版页面，ytInitialData 里
  // 没有 videoRenderer，搜索会整体失败。实测同一 URL：桌面 UA 可解析 22 条，移动 UA 直接抛错。
  const calls=[];
  const body='var ytInitialData = {"contents":{}};'+
    'var ytInitialPlayerResponse = {"videoDetails":{"title":"Bunny","author":"Blender","lengthSeconds":"635"}};';
  const {YouTubeApi}=environment({'services/network/HttpClient':{HttpClient:{get:async(...args)=>{
    calls.push(args);return {ok:true,body};
  }}}}).load('api/YouTubeApi');
  await YouTubeApi.search('blender');
  await YouTubeApi.detail('aqz-KE-bpKQ');
  assert.equal(calls.length,2);
  for(const [,headers] of calls){
    assert.match(headers['User-Agent'],/Mozilla\/5\.0/);
    // 桌面版标识：缺少它 YouTube 会判定为不可信客户端。
    assert.doesNotMatch(headers['User-Agent'],/Mobile/i);
  }
  assert.match(calls[0][0],/youtube\.com\/results/);
  assert.match(calls[1][0],/youtube\.com\/watch/);
});

test('YouTube: search pages carry the continuation token and paging posts it back', async () => {
  // 回归背景：网页端「加载更多」走 InnerTube continuation（POST + 页面下发的 key），
  // 不是给结果页加 page 参数。token 必须由上一页携带，请求体与请求头都不能省。
  const id='aqz-KE-bpKQ', token='CONT_TOKEN_1';
  const initial={contents:{twoColumnSearchResultsRenderer:{primaryContents:{sectionListRenderer:{contents:[
    {itemSectionRenderer:{contents:[{videoRenderer:{videoId:id,title:{runs:[{text:'Bunny'}]},
      ownerText:{runs:[{text:'Blender'}]},lengthText:{simpleText:'10:35'}}}]}},
    {continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token}}}},
  ]}}}}};
  const html='var ytInitialData = '+JSON.stringify(initial)+';'
    +'"INNERTUBE_API_KEY":"KEY123","INNERTUBE_CLIENT_VERSION":"2.2026.01.00"';
  const page2={onResponseReceivedCommands:[{appendContinuationItemsAction:{continuationItems:[
    {itemSectionRenderer:{contents:[{videoRenderer:{videoId:'eW09jkDM9_s',title:{runs:[{text:'Second'}]}}}]}},
    {continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token:'CONT_TOKEN_2'}}}},
  ]}}]};
  const calls=[];
  const {YouTubeApi}=environment({'services/network/HttpClient':{HttpClient:{
    get:async(...args)=>{calls.push(['get',...args]);return {ok:true,body:html};},
    post:async(...args)=>{calls.push(['post',...args]);return {ok:true,body:JSON.stringify(page2)};},
  }}}).load('api/YouTubeApi');

  const first=await YouTubeApi.search('blender');
  assert.equal(first.videos.length,1);assert.equal(first.videos[0].id,id);
  assert.equal(first.continuation,token);

  const second=await YouTubeApi.searchMore(first.continuation);
  assert.equal(second.videos.length,1);assert.equal(second.videos[0].id,'eW09jkDM9_s');
  assert.equal(second.continuation,'CONT_TOKEN_2');

  const [kind,url,body,headers]=calls[1];
  assert.equal(kind,'post');
  assert.match(url,/youtubei\/v1\/search\?key=KEY123/);
  const parsed=JSON.parse(body);
  assert.equal(parsed.continuation,token);
  assert.equal(parsed.context.client.clientName,'WEB');
  assert.equal(parsed.context.client.clientVersion,'2.2026.01.00');
  assert.equal(headers['Content-Type'],'application/json');
  assert.match(headers['User-Agent'],/Mozilla\/5\.0/);
  assert.doesNotMatch(headers['User-Agent'],/Mobile/i);
  // 第三方主机不得携带任何 B 站凭证。
  assert.equal(headers.Cookie,undefined);assert.equal(headers.Referer,undefined);
});

test('YouTube: paging stops honestly when the page carries no InnerTube config', async () => {
  // 没有 key/clientVersion 时不能拿旧值或空值拼请求：宁可停在首批，也不发无效请求。
  const token='CONT_TOKEN_1';
  const initial={contents:{twoColumnSearchResultsRenderer:{primaryContents:{sectionListRenderer:{contents:[
    {itemSectionRenderer:{contents:[{videoRenderer:{videoId:'aqz-KE-bpKQ',title:{runs:[{text:'Bunny'}]}}}]}},
    {continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token}}}},
  ]}}}}};
  const calls=[];
  const {YouTubeApi}=environment({'services/network/HttpClient':{HttpClient:{
    get:async(...args)=>{calls.push(args);return {ok:true,body:'var ytInitialData = '+JSON.stringify(initial)+';'};},
    post:async(...args)=>{calls.push(args);return {ok:true,body:'{}'};},
  }}}).load('api/YouTubeApi');
  const page=await YouTubeApi.search('blender');
  assert.equal(page.videos.length,1);
  assert.equal(page.continuation,'');
  const more=await YouTubeApi.searchMore('');
  assert.equal(more.videos.length,0);assert.equal(more.continuation,'');
  assert.equal(calls.length,1);
});

test('YouTube: continuation parsing accepts both containers and rejects garbage', () => {
  const {YouTubeApi}=environment({'services/network/HttpClient':{}}).load('api/YouTubeApi');
  const legacy={continuationContents:{sectionListContinuation:{contents:[
    {itemSectionRenderer:{contents:[{videoRenderer:{videoId:'eW09jkDM9_s',title:{runs:[{text:'Legacy'}]}}}]}},
    {continuationItemRenderer:{continuationEndpoint:{continuationCommand:{token:'NEXT'}}}},
  ]}}};
  const page=YouTubeApi.parseContinuation(JSON.stringify(legacy));
  assert.equal(page.videos.length,1);assert.equal(page.videos[0].title,'Legacy');
  assert.equal(page.continuation,'NEXT');
  // 空响应不抛错（翻页调用方按空页收尾），非法 JSON 才报错。
  assert.equal(YouTubeApi.parseContinuation('{}').videos.length,0);
  assert.throws(()=>YouTubeApi.parseContinuation('<!doctype html>'),/翻页数据/);
});
test('Search history: each platform keeps its own list, deduplicated and capped', async () => {
  // 需求：YouTube 侧要有和哔哩哔哩对等的本地搜索历史，但两边不能混存。
  const disk=new Map();
  const prefs={getPreferences:async()=>({getSync:(k,d)=>disk.has(k)?disk.get(k):d,
    putSync:(k,v)=>{disk.set(k,v);},flush:async()=>{}})};
  const env=environment({'@kit.AbilityKit':{common:{}},'@kit.ArkData':{preferences:prefs}});
  const {YouTubeSearchHistoryStore}=env.load('common/YouTubeSearchHistoryStore');
  const {SearchHistoryStore}=env.load('common/SearchHistoryStore');
  YouTubeSearchHistoryStore.init({});
  SearchHistoryStore.init({});

  YouTubeSearchHistoryStore.add('blender');
  YouTubeSearchHistoryStore.add('音乐');
  YouTubeSearchHistoryStore.add('blender');
  // 重复项提到最前而不是新增一条。
  assert.deepEqual(YouTubeSearchHistoryStore.items(),['blender','音乐']);
  SearchHistoryStore.add('bad apple');
  assert.deepEqual(SearchHistoryStore.items(),['bad apple']);

  // 两个平台各自写自己的键：清空一边不影响另一边。
  assert.equal(env.storage.get('youtubeSearchHistoryJson'),'["blender","音乐"]');
  assert.equal(env.storage.get('searchHistoryJson'),'["bad apple"]');
  YouTubeSearchHistoryStore.clear();
  assert.deepEqual(YouTubeSearchHistoryStore.items(),[]);
  assert.deepEqual(SearchHistoryStore.items(),['bad apple']);

  for(let i=0;i<25;i++) YouTubeSearchHistoryStore.add('kw'+String(i));
  assert.equal(YouTubeSearchHistoryStore.items().length,20);
  assert.equal(YouTubeSearchHistoryStore.items()[0],'kw24');
  assert.deepEqual(YouTubeSearchHistoryStore.remove('kw24')[0],'kw23');
  // 落盘的是同一份内容，重启后能读回来。
  assert.deepEqual(await YouTubeSearchHistoryStore.ensureLoaded(),YouTubeSearchHistoryStore.items());
});

test('YouTube: search suggestions come from the public JSON endpoint and fail soft', async () => {
  const calls=[];
  const body='["blender",["blender","blender教程","blender","",42],"x"]';
  const {YouTubeApi}=environment({'services/network/HttpClient':{HttpClient:{get:async(...args)=>{
    calls.push(args);return {ok:true,body};
  }}}}).load('api/YouTubeApi');
  // 非字符串项与重复项都要丢掉。
  assert.deepEqual(YouTubeApi.parseSuggest(body),['blender','blender教程']);
  assert.deepEqual(YouTubeApi.parseSuggest('not json'),[]);
  assert.deepEqual(YouTubeApi.parseSuggest('["only-key"]'),[]);
  // 建议条数封顶 8：输入联想是辅助，不该占满整屏（实测 10 条会被悬浮 Dock 压住）。
  const many='["q",'+JSON.stringify(Array.from({length:12},(_,i)=>'s'+String(i))) + ']';
  assert.equal(YouTubeApi.parseSuggest(many).length,8);
  assert.deepEqual(await YouTubeApi.suggest('blender'),['blender','blender教程']);
  const [url,headers]=calls[0];
  assert.match(url,/^https:\/\/suggestqueries\.google\.com\/complete\/search/);
  assert.match(url,/ds=yt/);assert.match(url,/q=blender/);
  assert.match(headers['User-Agent'],/Mozilla\/5\.0/);
  assert.equal(headers.Cookie,undefined);assert.equal(headers.Referer,undefined);
  // 网络失败返回空数组：联想是输入辅助，不能把异常抛给调用方。
  const failing=environment({'services/network/HttpClient':{HttpClient:{get:async()=>{
    throw new Error('offline');
  }}}}).load('api/YouTubeApi');
  assert.deepEqual(await failing.YouTubeApi.suggest('x'),[]);
  assert.deepEqual(await failing.YouTubeApi.suggest('  '),[]);
});
test('Platform: switching platforms invalidates in-flight work and persists the choice', () => {
  const env=environment(themeMocks());
  const {PlatformStore}=env.load('common/PlatformStore');
  assert.equal(PlatformStore.current(),'bili');
  assert.equal(PlatformStore.isYouTube(),false);

  const token=PlatformStore.nextRequest();
  assert.equal(PlatformStore.isCurrentRequest(token),true);
  assert.equal(PlatformStore.switchTo(PlatformStore.YOUTUBE),true);
  // 切走那一刻仍在途的请求必须失效，否则旧结果会写进新平台的状态。
  assert.equal(PlatformStore.isCurrentRequest(token),false);
  assert.equal(PlatformStore.isYouTube(),true);

  // 重复切到同一平台不产生副作用，调用方据此决定是否暂停播放/退出全屏。
  assert.equal(PlatformStore.switchTo(PlatformStore.YOUTUBE),false);
  assert.equal(PlatformStore.toggle(),true);
  assert.equal(PlatformStore.current(),'bili');

  // 非白名单取值一律回落到哔哩哔哩，避免脏持久化值渲染出空白外壳。
  PlatformStore.switchTo('netflix');
  assert.equal(PlatformStore.current(),'bili');
});

test('Theme: the accent follows the platform and never overwrites the user choice', () => {
  // 需求：切到 YouTube 后全局主题色变红，切回哔哩哔哩恢复用户自选色。
  // accentColor 是持久化的用户偏好，所以「自选值」和「生效值」必须分开，
  // 否则 YouTube 的红会被写进用户偏好，重启后连哔哩哔哩也变红。
  const env=environment(themeMocks());
  const {AppTheme}=env.load('common/AppTheme');
  const {PlatformStore}=env.load('common/PlatformStore');

  AppTheme.setAccent('#008AC5');
  assert.equal(AppTheme.getAccent(),'#008AC5');
  assert.equal(env.storage.get('accentColor'),'#008AC5');

  PlatformStore.switchTo(PlatformStore.YOUTUBE);
  assert.equal(AppTheme.getAccent(),AppTheme.DANGER);
  // 自选值仍然是用户的蓝色：平台切换不能污染偏好。
  assert.equal(AppTheme.userAccent(),'#008AC5');
  assert.equal(env.storage.get('userAccentColor'),'#008AC5');

  PlatformStore.switchTo(PlatformStore.BILI);
  assert.equal(AppTheme.getAccent(),'#008AC5');

  // 冷启动路径：平台已是 YouTube 时 syncAccent 也必须给出红色。
  PlatformStore.switchTo(PlatformStore.YOUTUBE);
  AppTheme.setAccent('#43A047');
  PlatformStore.syncAccent();
  assert.equal(AppTheme.getAccent(),AppTheme.DANGER);
  assert.equal(AppTheme.userAccent(),'#43A047');
  PlatformStore.switchTo(PlatformStore.BILI);
  assert.equal(AppTheme.getAccent(),'#43A047');
});
test('Platform: the main dock owns only Bilibili tabs and Index dispatches on platform', () => {
  // 回归背景：YouTube 曾是底部 Dock 的第 4 个 Tab，使 `currentTab !== 3` 这类魔数
  // 在主框架里出现两次。提升为平台状态后，Dock 只归哔哩哔哩所有。
  const source=fs.readFileSync(path.join(root,'pages/Index.ets'),'utf8').replace(/\r\n/g,'\n');
  assert.doesNotMatch(source,/ic_youtube_tab/);
  assert.doesNotMatch(source,/currentTab\s*!==\s*3/);
  // 平台分叉必须由 PlatformStore 驱动，而不是裸字符串或下标魔数：
  // 一处渲染对应外壳，一处让哔哩哔哩侧 Tab 广播在 YouTube 激活时闭嘴。
  assert.match(source,/if \(this\.platform === PlatformStore\.YOUTUBE\) \{/);
  assert.doesNotMatch(source,/platform === 'youtube'/);
  assert.doesNotMatch(source,/platform === "youtube"/);
});

test('WebProxy: ArkWeb receives a normalized proxy rule only when the launch parameter asks for one', () => {
  // 回归背景：ArkWeb 是独立网络栈，@ohos.net.http 的 usingProxy 不会作用于它。
  // applyProxyOverride 在 webview.ProxyController 上（不在 ProxyConfig 上），且默认必须完全不下发。
  const applied=[];
  class FakeProxyConfig {
    constructor(){ this.rules=[]; }
    insertProxyRule(rule,filter){ this.rules.push({rule,filter}); }
  }
  const webview={ProxyConfig:FakeProxyConfig,ProxySchemeFilter:{MATCH_ALL_SCHEMES:0},
    ProxyController:{applyProxyOverride:(config,callback)=>{applied.push(config);callback();}}};
  const {WebProxy}=environment({'@kit.ArkWeb':{webview}}).load('services/network/WebProxy');

  // 默认（无启动参数）不得触碰 ArkWeb，否则默认路径与历史版本不一致。
  assert.equal(WebProxy.apply(''),false);
  assert.equal(WebProxy.apply('   '),false);
  assert.equal(applied.length,0);

  // ArkWeb 规则格式是 scheme://host:port，不能塞整串 URL，缺省端口与 HttpClient 保持一致。
  assert.equal(WebProxy.rule('http://127.0.0.1:7890'),'http://127.0.0.1:7890');
  assert.equal(WebProxy.rule('127.0.0.1:7890'),'http://127.0.0.1:7890');
  assert.equal(WebProxy.rule('127.0.0.1'),'http://127.0.0.1:8080');
  assert.equal(WebProxy.rule('http://127.0.0.1:7890/'),'http://127.0.0.1:7890');
  assert.equal(WebProxy.rule('socks5://127.0.0.1:1080'),'socks://127.0.0.1:1080');
  // 不支持的协议宁可不下发，也不能猜一个协议把流量发到错误的地方。
  assert.equal(WebProxy.rule('ftp://127.0.0.1:21'),'');
  assert.equal(WebProxy.rule('http://'),'');

  assert.equal(WebProxy.apply('http://127.0.0.1:7890'),true);
  assert.equal(applied.length,1);
  assert.deepEqual(applied[0].rules,[{rule:'http://127.0.0.1:7890',filter:0}]);

  // 平台接口抛错不能把启动流程带崩，只报失败。
  const failing=environment({'@kit.ArkWeb':{webview:{...webview,
    ProxyController:{applyProxyOverride:()=>{throw {code:17100001};}}}}}).load('services/network/WebProxy');
  assert.equal(failing.WebProxy.apply('http://127.0.0.1:7890'),false);
});

test('YouTube: the player document survives the initial about:blank navigation', () => {
  // 回归背景：ArkWeb 会先提交 Web 组件的初始 about:blank，并把 onControllerAttached 里
  // 已经开始的 loadData 文档 abort 掉（实测日志 ERR_ABORTED url:data:text/***）。
  // 去重标记若不在 onPageEnd 分支里复位，重试分支就是空操作，播放器会永远停在 about:blank。
  const source=fs.readFileSync(path.join(root,'pages/YouTubeDetail.ets'),'utf8').replace(/\r\n/g,'\n');
  assert.match(source,
    /if \(event\.url === 'about:blank' && !this\.initialPageLoaded\) \{[\s\S]{0,200}this\.playerLoaded = false;[\s\S]{0,120}this\.loadPlayer\(\);/);
});

