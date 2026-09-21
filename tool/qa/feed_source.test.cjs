// 首页推荐源切换与会话链：Web feed_id/fresh_idx 协议、App idx 游标、模式分支与回退。
// Run actual ArkTS service code with fake platform boundaries. No network, credentials or device required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceOverride = process.env.ARKTS_TEST_SOURCE_ROOT;
function readSource(filename) {
  const override = sourceOverride && path.join(sourceOverride, path.relative(root, filename));
  return fs.readFileSync(override && fs.existsSync(override) ? override : filename, 'utf8')
    .replace(/\r\n/g, '\n');
}
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

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
      if (name === '@kit.PerformanceAnalysisKit') {
        const noop = () => {};
        return { hilog: { debug: noop, info: noop, warn: noop, error: noop } };
      }
      // Md5（app 签名用）：Node 原生 crypto 等价实现。
      if (name === '@kit.CryptoArchitectureKit') {
        return { cryptoFramework: {
          createMd() {
            const chunks = [];
            return {
              async update(blob) { chunks.push(Buffer.from(blob.data)); },
              async digest() {
                return { data: new Uint8Array(require('node:crypto').createHash('md5')
                  .update(Buffer.concat(chunks)).digest()) };
              },
            };
          },
        } };
      }
      if (name === '@kit.ArkTS') {
        return { util: { TextEncoder: class { encodeInto(input) { return new Uint8Array(Buffer.from(input, 'utf8')); } } } };
      }
      throw new Error('Missing platform mock: ' + name);
    };
    new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage', 'Sendable', 'Concurrent', code)(
      localRequire, module, module.exports,
      { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
      { persistProp() {} },
      (target) => target,
      (target) => target
    );
    return module.exports;
  }
  function load(name) {
    name = name.replace(/\.ets$/, '');
    if (name in mocks) return mocks[name];
    if (!cache.has(name)) {
      const filename = path.join(root, name + '.ets');
      cache.set(name, compile(readSource(filename), filename));
    }
    return cache.get(name);
  }
  return { load, storage };
}

/** HttpClient 桩：按 URL 前缀返回不同响应，记录全部 GET。 */
function httpClientStub() {
  const calls = [];
  const impl = {
    calls,
    cookies: { SESSDATA: 'sess-token', DedeUserID: '269409999', bili_jct: 'csrf-token' },
    accessToken: 'token123',
    buvid: 'buvid-x',
    handler(url) {
      if (url.includes('feed/rcmd')) {
        return { ok: true, json: () => ({ code: 0, data: { item: webItems, feed_id: 'F1', bucket_id: 'B1' } }) };
      }
      return { ok: true, json: () => ({ code: 0, data: { items: appItems } }) };
    },
    getCookie(name) { return impl.cookies[name] ?? ''; },
    getAppAccessToken() { return impl.accessToken; },
    buildQuery(params) {
      const keys = Object.keys(params).sort();
      return keys.map(k => encodeURIComponent(k) + '=' + encodeURIComponent(params[k] ?? '')).join('&');
    },
    merge(base, extra) {
      const out = Object.assign({}, base);
      for (const k of Object.keys(extra)) out[k] = extra[k];
      return out;
    },
    async get(url) {
      calls.push({ url, headers: {} });
      return impl.handler(url);
    },
  };
  return impl;
}

// 单条 web 推荐卡（goto=av + owner 完整才会被采纳）
const webAv = id => ({ goto: 'av', id, bvid: 'BV' + id, owner: { name: 'up', mid: 2 }, stat: { view: 1 } });
const webItems = [webAv(101), { goto: 'picture' }, webAv(102)];
// 单条 app 推流卡（can_play=1 + 无 ad_info 才会被采纳）
const appCard = (id, idx) => ({ card_goto: 'av', can_play: 1, idx, param: String(id), title: 't' + id });
const appItems = [appCard(201, 100), appCard(202, 101), { card_goto: 'ad_av', can_play: 1, idx: 102 }, appCard(203, 103)];

function stub(impl) {
  return { HttpClient: impl, RequestPriority: { HIGH: 600, NORMAL: 300, LOW: 100 } };
}

const wbiStubs = () => ({
  'common/WbiSign': { WbiSign: { encWbi: async (p) => p, invalidate: () => {} } },
  BuildProfile: { DEBUG: false },
});

function queryParams(url) {
  const out = {};
  for (const pair of new URLSearchParams(url.split('?')[1] ?? '')) out[pair[0]] = pair[1];
  return out;
}

test('buildWebRcmdParams: fresh_idx 从 1 起，feed_id 仅在会话中回传', async () => {
  const { FeedApi } = environment({ 'services/network/HttpClient': stub(httpClientStub()), ...wbiStubs() }).load('api/FeedApi');
  const first = FeedApi.buildWebRcmdParams(1, '', '');
  assert.equal(first.fresh_idx, '1');
  assert.equal(first.brush, '1');
  assert.equal(first.feed_version, 'V8');
  assert.equal('feed_id' in first, false);
  const next = FeedApi.buildWebRcmdParams(2, 'F1', 'B1');
  assert.equal(next.fresh_idx, '2');
  assert.equal(next.feed_id, 'F1');
  assert.equal(next.bucket_id, 'B1');
});

test('parseWebRcmd: 过滤非视频卡并取出会话标识', async () => {
  const { FeedApi } = environment({ 'services/network/HttpClient': stub(httpClientStub()), ...wbiStubs() }).load('api/FeedApi');
  const page = FeedApi.parseWebRcmd({ item: webItems, feed_id: 'F9', bucket_id: 'B9' });
  assert.equal(page.items.length, 2);
  assert.equal(page.items[0].aid, 101);
  assert.equal(page.feedId, 'F9');
  assert.equal(page.bucketId, 'B9');
});

test('parseAppFeed: 过滤广告卡，游标取最后一条有效卡的 idx', async () => {
  const { FeedApi } = environment({ 'services/network/HttpClient': stub(httpClientStub()), ...wbiStubs() }).load('api/FeedApi');
  const page = FeedApi.parseAppFeed({ items: appItems });
  assert.equal(page.items.length, 3);
  assert.equal(page.cursor, 103);
  assert.equal(page.items[0].aid, 201);
});

test('buildAppFeedParams: 携带 access_key 与设备参数', async () => {
  const { FeedApi } = environment({ 'services/network/HttpClient': stub(httpClientStub()), ...wbiStubs() }).load('api/FeedApi');
  const params = FeedApi.buildAppFeedParams(7, 'token123');
  assert.equal(params.access_key, 'token123');
  assert.equal(params.idx, '7');
  assert.ok(params.build && params.mobi_app);
});

test('App 推流模式：首帧 idx=0 签名完整，后续游标续推', async () => {
  const http = httpClientStub();
  http.accessToken = 'token123';
  const env = environment({ 'services/network/HttpClient': stub(http), ...wbiStubs() });
  env.storage.set('recommendMode', 'app');
  const { FeedApi } = env.load('api/FeedApi');
  const first = await FeedApi.getRecommend(true);
  assert.equal(first.length, 3);
  assert.equal(http.calls.length, 1);
  const p1 = queryParams(http.calls[0].url);
  assert.equal(p1.idx, '0');
  assert.equal(p1.pull, 'true');
  assert.equal(p1.access_key, 'token123');
  assert.ok(/^[0-9a-f]{32}$/.test(p1.sign), 'app 签名必须存在');
  const second = await FeedApi.getRecommend(false);
  assert.equal(second.length, 3);
  const p2 = queryParams(http.calls[1].url);
  assert.equal(p2.idx, '103');
  assert.equal(p2.pull, 'false');
});

test('Web 个性化模式：会话链回传 feed_id，刷新重置序号', async () => {
  const http = httpClientStub();
  const env = environment({ 'services/network/HttpClient': stub(http), ...wbiStubs() });
  env.storage.set('recommendMode', 'web');
  const { FeedApi } = env.load('api/FeedApi');
  const first = await FeedApi.getRecommend(true);
  assert.equal(first.length, 2);
  const p1 = queryParams(http.calls[0].url);
  assert.equal(p1.fresh_idx, '1');
  assert.equal('feed_id' in p1, false);
  await FeedApi.getRecommend(false);
  const p2 = queryParams(http.calls[1].url);
  assert.equal(p2.fresh_idx, '2');
  assert.equal(p2.feed_id, 'F1');
  assert.equal(p2.bucket_id, 'B1');
  // 下拉刷新：开新会话，序号归 1 且丢弃旧 feed_id
  await FeedApi.getRecommend(true);
  const p3 = queryParams(http.calls[2].url);
  assert.equal(p3.fresh_idx, '1');
  assert.equal('feed_id' in p3, false);
});

test('App 模式失败时回退 Web，匿名 Web 模式直接走 App', async () => {
  const http = httpClientStub();
  http.cookies = {};
  http.accessToken = '';
  let failApp = true;
  http.handler = url => {
    if (url.includes('feed/rcmd')) {
      return { ok: true, json: () => ({ code: 0, data: { item: webItems, feed_id: 'F2' } }) };
    }
    if (failApp) return { ok: false, json: () => ({}) };
    return { ok: true, json: () => ({ code: 0, data: { items: appItems } }) };
  };
  const env = environment({ 'services/network/HttpClient': stub(http), ...wbiStubs() });
  env.storage.set('recommendMode', 'app');
  const { FeedApi } = env.load('api/FeedApi');
  const list = await FeedApi.getRecommend(true);
  assert.equal(list.length, 2);
  assert.ok(http.calls[0].url.includes('feed/index'));
  assert.ok(http.calls[1].url.includes('feed/rcmd'));
  // 匿名 + Web 模式：直接走 App 公共推流，不请求 rcmd
  env.storage.set('recommendMode', 'web');
  http.calls.length = 0;
  failApp = false;
  const anon = await FeedApi.getRecommend(true);
  assert.equal(anon.length, 3);
  assert.equal(http.calls.length, 1);
  assert.ok(http.calls[0].url.includes('feed/index'));
});
