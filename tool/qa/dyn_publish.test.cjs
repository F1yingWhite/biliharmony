// 图文动态发布链路：multipart 组装、upload_bfs 响应解析、dyn_req 构建、发布请求形态。
// Run actual ArkTS service code with fake platform boundaries. No network, credentials or device required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceOverride = process.env.ARKTS_TEST_SOURCE_ROOT;
function readSource(filename) {
  const override = sourceOverride && path.join(sourceOverride, path.relative(root, filename));
  // .ets 是 CRLF 检出，锚点按 \n 书写：统一归一为 LF，避免跨行锚点静默失配。
  return fs.readFileSync(override && fs.existsSync(override) ? override : filename, 'utf8')
    .replace(/\r\n/g, '\n');
}
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

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
      if (name === '@kit.PerformanceAnalysisKit') {
        const noop = () => {};
        return { hilog: { debug: noop, info: noop, warn: noop, error: noop } };
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

/** HttpClient 桩：记录 post/postBinary 调用，预置响应。 */
function httpClientStub() {
  const calls = { post: [], postBinary: [] };
  const impl = {
    calls,
    cookies: { SESSDATA: 'sess-token', bili_jct: 'csrf-token' },
    postResponse: { ok: true, json: () => ({ code: 0, data: {} }) },
    postBinaryResponse: null,
    getCookie(name) { return impl.cookies[name] ?? ''; },
    buildQuery(params) {
      const keys = Object.keys(params).sort();
      return keys.map(k => encodeURIComponent(k) + '=' + encodeURIComponent(params[k] ?? '')).join('&');
    },
    async post(url, body, headers) {
      calls.post.push({ url, body, headers });
      return impl.postResponse;
    },
    async postBinary(url, contentType, body, headers) {
      calls.postBinary.push({ url, contentType, body, headers });
      return impl.postBinaryResponse ?? impl.postResponse;
    },
    merge(base, extra) {
      const out = Object.assign({}, base);
      for (const k of Object.keys(extra)) out[k] = extra[k];
      return out;
    },
  };
  return impl;
}

function stub(impl) {
  return { HttpClient: impl, RequestPriority: { HIGH: 600, NORMAL: 300, LOW: 100 } };
}

/** ApiCommon → webGetSigned 依赖 WbiSign（需要 CryptoArchitectureKit）；动态发布不签名，静默桩即可。 */
function apiCommonStubs() {
  return {
    'common/WbiSign': { WbiSign: { encWbi: async () => {}, invalidate: () => {} } },
    // DynamicApi 的诊断日志开关
    BuildProfile: { DEBUG: false },
  };
}

const uploaded = (src, w, h, size) => {
  // 构造正式 DynUploadedImage；环境带桩避免拉起真实网络模块。
  const M = environment({ 'services/network/HttpClient': stub(httpClientStub()), ...apiCommonStubs() })
    .load('api/DynamicApi').DynUploadedImage;
  const item = new M();
  item.imgSrc = src; item.imgWidth = w; item.imgHeight = h; item.imgSize = size;
  return item;
};

test('multipart body keeps text fields, file headers and binary bytes byte-exact', async () => {
  const Multipart = environment().load('services/network/MultipartBody');
  const { MultipartField, MultipartFile } = Multipart;
  const bytes = new Uint8Array(256);
  for (let i = 0; i < 256; i++) bytes[i] = i;
  const fileData = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const request = Multipart.buildMultipart(
    [new MultipartField('category', 'daily'), new MultipartField('csrf', '中文🌸token')],
    [new MultipartFile('file_up', 'dyn_1.jpg', 'image/jpeg', fileData)],
    'BOUNDARY');
  assert.ok(request.contentType.startsWith('multipart/form-data; boundary=BOUNDARY'));
  const body = Buffer.from(request.body);
  const text = body.toString('latin1');
  assert.ok(text.startsWith('--BOUNDARY\r\nContent-Disposition: form-data; name="category"\r\n\r\ndaily\r\n'));
  const valueStart = text.indexOf('name="csrf"\r\n\r\n') + 'name="csrf"\r\n\r\n'.length;
  const value = Buffer.from('中文🌸token', 'utf8');
  assert.deepEqual(body.subarray(valueStart, valueStart + value.length), value);
  const fileHead = '--BOUNDARY\r\nContent-Disposition: form-data; name="file_up"; filename="dyn_1.jpg"\r\n' +
    'Content-Type: image/jpeg\r\n\r\n';
  const headBuf = Buffer.from(fileHead, 'latin1');
  const headStart = body.indexOf(headBuf);
  assert.ok(headStart > 0, 'file part header should appear after text fields');
  const fileStart = headStart + headBuf.length;
  assert.deepEqual([...body.subarray(fileStart, fileStart + 256)], [...bytes]);
  assert.ok(text.endsWith('\r\n--BOUNDARY--\r\n'));
});

test('utf8Bytes matches the platform encoder for ascii, cjk and astral planes', async () => {
  const Multipart = environment().load('services/network/MultipartBody');
  for (const sample of ['hello', '中文弹幕', 'emoji 🌸🀄 pair', 'mixed 中1a🌸']) {
    assert.deepEqual([...Multipart.utf8Bytes(sample)], [...Buffer.from(sample, 'utf8')], sample);
  }
});

test('upload_bfs response parses into DynUploadedImage and surfaces server errors', async () => {
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(httpClientStub()), ...apiCommonStubs() })
    .load('api/DynamicApi');
  const ok = DynamicApi.parseUploadResponse({
    code: 0, message: '0',
    data: { image_url: 'http://i0.hdslb.com/bfs/new_dyn/x.jpg', image_width: 800, image_height: 600, img_size: 123.4 },
  });
  assert.equal(ok.ok, true);
  assert.equal(ok.image.imgSrc, 'http://i0.hdslb.com/bfs/new_dyn/x.jpg');
  assert.equal(ok.image.imgWidth, 800);
  assert.equal(ok.image.imgHeight, 600);
  assert.equal(ok.image.imgSize, 123.4);
  const bizError = DynamicApi.parseUploadResponse({ code: 1, message: '图片不可读', data: {} });
  assert.equal(bizError.ok, false);
  assert.equal(bizError.message, '图片不可读');
  const silent = DynamicApi.parseUploadResponse({ code: -6, message: '' });
  assert.equal(silent.ok, false);
  assert.ok(silent.message.includes('-6'));
  const noUrl = DynamicApi.parseUploadResponse({ code: 0, message: '0', data: {} });
  assert.equal(noUrl.ok, false);
  assert.ok(noUrl.message.length > 0);
});

test('uploadDynImage posts a multipart body carrying fields and raw bytes', async () => {
  const http = httpClientStub();
  http.postBinaryResponse = {
    ok: true,
    json: () => ({ code: 0, message: '0', data: { image_url: 'https://i0.hdslb.com/x.jpg', image_width: 10, image_height: 20, img_size: 1 } }),
  };
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(http), ...apiCommonStubs() }).load('api/DynamicApi');
  const payload = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xD8]).buffer;
  const result = await DynamicApi.uploadDynImage(payload, 'dyn_1.jpg', 'image/jpeg');
  assert.equal(result.ok, true);
  assert.equal(result.image.imgSrc, 'https://i0.hdslb.com/x.jpg');
  assert.equal(http.calls.postBinary.length, 1);
  const call = http.calls.postBinary[0];
  assert.equal(call.url, 'https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs');
  assert.ok(call.contentType.startsWith('multipart/form-data; boundary='));
  const body = Buffer.from(call.body);
  const text = body.toString('latin1');
  assert.ok(text.includes('name="category"\r\n\r\ndaily'));
  assert.ok(text.includes('name="biz"\r\n\r\nnew_dyn'));
  assert.ok(text.includes('name="csrf"\r\n\r\ncsrf-token'));
  assert.ok(text.includes('name="file_up"; filename="dyn_1.jpg"'));
  assert.ok(text.includes('Content-Type: image/jpeg'));
  assert.ok(body.includes(Buffer.from([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xD8])));
  const boundary = call.contentType.split('boundary=')[1];
  assert.ok(text.endsWith('--' + boundary + '--\r\n'));
});

test('uploadDynImage refuses to send without csrf and reports transport failures', async () => {
  const http = httpClientStub();
  http.cookies = { SESSDATA: 'sess-token' };
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(http), ...apiCommonStubs() }).load('api/DynamicApi');
  const noCsrf = await DynamicApi.uploadDynImage(new ArrayBuffer(4), 'a.jpg', 'image/jpeg');
  assert.equal(noCsrf.ok, false);
  assert.equal(http.calls.postBinary.length, 0);
  http.cookies.bili_jct = 'csrf-token';
  http.postBinaryResponse = { ok: false, status: -1, json: () => ({}) };
  const failed = await DynamicApi.uploadDynImage(new ArrayBuffer(4), 'a.jpg', 'image/jpeg');
  assert.equal(failed.ok, false);
  assert.ok(failed.message.includes('-1'));
});

test('buildImageDynReq builds scene=2 contents and pics with empty-text support', async () => {
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(httpClientStub()), ...apiCommonStubs() })
    .load('api/DynamicApi');
  const req = DynamicApi.buildImageDynReq('你好动态', [uploaded('a.jpg', 800, 600, 12), uploaded('b.gif', 400, 300, 3)], '0_123_4567');
  assert.equal(req.scene, 2);
  assert.equal(req.upload_id, '0_123_4567');
  assert.equal(req.content.contents.length, 1);
  assert.equal(req.content.contents[0].raw_text, '你好动态');
  assert.equal(req.content.contents[0].type, 1);
  assert.equal(req.content.contents[0].biz_id, '');
  assert.equal(req.pics.length, 2);
  assert.deepEqual(req.pics[0], { img_src: 'a.jpg', img_width: 800, img_height: 600, img_size: 12 });
  assert.equal(req.meta.app_meta.from, 'create.dynamic.web');
  assert.equal(req.meta.app_meta.mobi_app, 'web');
  const roundTrip = JSON.parse(JSON.stringify(req));
  assert.equal(roundTrip.pics[1].img_src, 'b.gif');
  const noText = DynamicApi.buildImageDynReq('', [uploaded('a.jpg', 1, 1, 1)], '0_1_1000');
  assert.equal(noText.content.contents.length, 0);
  assert.equal(noText.pics.length, 1);
});

test('publishWithImages posts JSON dyn_req with scene=2 and csrf in query', async () => {
  const http = httpClientStub();
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(http), ...apiCommonStubs() }).load('api/DynamicApi');
  const result = await DynamicApi.publishWithImages('正文', [uploaded('a.jpg', 800, 600, 12)]);
  assert.equal(result.ok, true);
  assert.equal(http.calls.post.length, 1);
  const call = http.calls.post[0];
  assert.ok(call.url.startsWith('https://api.bilibili.com/x/dynamic/feed/create/dyn?'));
  assert.ok(call.url.includes('platform=web'));
  assert.ok(call.url.includes(encodeURIComponent('csrf') + '=csrf-token'));
  // create/dyn 的 scene=2 分支要求 JSON body（form 会被 -400 拒绝）。
  assert.equal(call.headers['Content-Type'], 'application/json');
  const body = JSON.parse(call.body);
  const dynReq = body.dyn_req;
  assert.equal(dynReq.scene, 2);
  assert.equal(dynReq.content.contents[0].raw_text, '正文');
  assert.equal(dynReq.pics.length, 1);
  assert.equal(dynReq.pics[0].img_src, 'a.jpg');
  assert.match(dynReq.upload_id, /^0_\d+_\d{4}$/);
  assert.equal(dynReq.meta.app_meta.from, 'create.dynamic.web');
});

test('publishWithImages requires login and tolerates empty text with images', async () => {
  const http = httpClientStub();
  http.cookies = {};
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(http), ...apiCommonStubs() }).load('api/DynamicApi');
  const loggedOut = await DynamicApi.publishWithImages('正文', [uploaded('a.jpg', 1, 1, 1)]);
  assert.equal(loggedOut.ok, false);
  assert.equal(http.calls.post.length, 0);
  http.cookies = { SESSDATA: 'sess-token', bili_jct: 'csrf-token' };
  const noText = await DynamicApi.publishWithImages('   ', [uploaded('a.jpg', 1, 1, 1)]);
  assert.equal(noText.ok, true);
  const body = JSON.parse(http.calls.post[0].body);
  assert.equal(body.dyn_req.content.contents.length, 0);
  assert.equal(body.dyn_req.pics.length, 1);
});

test('publishWithImages without images delegates to the plain-text path', async () => {
  const http = httpClientStub();
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(http), ...apiCommonStubs() }).load('api/DynamicApi');
  const result = await DynamicApi.publishWithImages('纯文字', []);
  // 无图时走 publish → postVideoAction（也是 HttpClient.post），不出现在 multipart 通道。
  assert.equal(result.ok, true);
  assert.equal(http.calls.postBinary.length, 0);
  assert.equal(http.calls.post.length, 1);
});

test('publishWithImages rejects over-length text before any request', async () => {
  const http = httpClientStub();
  const { DynamicApi } = environment({ 'services/network/HttpClient': stub(http), ...apiCommonStubs() }).load('api/DynamicApi');
  const long = await DynamicApi.publishWithImages('长'.repeat(2001), [uploaded('a.jpg', 1, 1, 1)]);
  assert.equal(long.ok, false);
  assert.equal(http.calls.post.length, 0);
});
