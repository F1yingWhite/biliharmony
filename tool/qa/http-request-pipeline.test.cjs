// Full HttpClient and its production policy/response/parser modules, with deferred SDK boundaries.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
}
const reply = (body = {}, extras = {}) => ({ responseCode: 200,
  result: JSON.stringify(body), header: {}, ...extras });
const spi = () => reply({ data: { b_3: 'real-device', b_4: 'real-device-4' } });
function fixture(ready = true) {
  const modules = new Map(), storage = new Map(), requests = [], parses = [];
  let now = 100000;
  class Clock extends Date { static now() { return now; } }
  const mocks = {
    '@kit.BasicServicesKit': {},
    '@kit.NetworkKit': { connection: {}, http: {
      RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0, ARRAY_BUFFER: 1 },
      createHttp() {
        let record;
        return { request(url, options) {
          record = { url, options, destroyed: false, ...deferred() };
          requests.push(record); return record.promise;
        }, destroy() { record.destroyed = true; } };
      },
    } },
    '@kit.ArkTS': { taskpool: { async execute(_fn, body) { parses.push(body); return JSON.parse(body); } } },
  };
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const filename = path.join(root, name + '.ets');
    const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, name + '.ets');
    const source = fs.readFileSync(override && fs.existsSync(override) ? override : filename, 'utf8');
    const module = { exports: {} };
    const code = ts.transpileModule(source, { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020,
    } }).outputText;
    const requireLocal = name => {
      if (name in mocks) return mocks[name];
      assert.ok(name.startsWith('.'), 'Unexpected boundary ' + name);
      return load(path.relative(root, path.resolve(path.dirname(filename), name)).replaceAll('\\', '/'));
    };
    new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage', 'Concurrent', 'Date', code)(
      requireLocal, module, module.exports,
      { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
      { persistProp() {} }, target => target, Clock);
    modules.set(name, module.exports); return module.exports;
  }
  const { HttpClient, RequestPriority } = load('services/network/HttpClient');
  const { AuthSession } = load('services/auth/AuthSession');
  if (ready) HttpClient.setCookie('buvid3', 'known-device');
  function send(method, { url = 'https://api.bilibili.com/test', body, headers, priority } = {}) {
    if (method === 'get') return HttpClient.get(url, headers, priority);
    if (method === 'post') return HttpClient.post(url, body, headers, priority);
    return HttpClient.postBinary(url, 'application/octet-stream', body ?? new ArrayBuffer(0), headers, priority);
  }
  return { HttpClient, AuthSession, RequestPriority, requests, parses, send, load,
    advance: ms => { now += ms; } };
}

for (const method of ['get', 'post', 'postBinary']) {
  test(`HTTP ${method}: session changes while SPI waits prevent the old API request from being sent`, async () => {
    const f = fixture(false); f.HttpClient.setCookie('SESSDATA', 'old'); const pending = f.send(method);
    assert.equal(f.requests.length, 1); assert.match(f.requests[0].url, /\/finger\/spi$/);
    assert.equal(f.requests[0].options.header.Cookie, undefined);
    f.AuthSession.advance(); f.HttpClient.setCookie('SESSDATA', 'new'); f.requests[0].resolve(spi());
    const response = await pending;
    assert.equal(response.status, -1); assert.equal(response.transportCode, 0); assert.equal(response.body, '');
    assert.equal(f.requests.length, 1); assert.equal(f.requests[0].destroyed, true);
    assert.equal(f.HttpClient.getCookie('SESSDATA'), 'new');
  });

  test(`HTTP ${method}: old transport response cannot merge cookies or start background parse`, async () => {
    const f = fixture(); const pending = f.send(method); await tick();
    f.AuthSession.advance(); f.HttpClient.setCookie('SESSDATA', 'new');
    f.requests[0].resolve(reply({ pad: 'x'.repeat(33000) }, {
      header: { 'Set-Cookie': ['SESSDATA=old', 'bili_jct=old'] }, cookies: 'DedeUserID=old',
    }));
    const response = await pending;
    assert.equal(response.status, -1); assert.equal(response.body, ''); assert.equal(f.parses.length, 0);
    assert.equal(f.HttpClient.getCookie('SESSDATA'), 'new'); assert.equal(f.HttpClient.getCookie('bili_jct'), '');
    assert.equal(f.HttpClient.getCookie('DedeUserID'), ''); assert.equal(f.requests[0].destroyed, true);
  });

  test(`HTTP ${method}: public requests bypass SPI and discard every credential header and response cookie`, async () => {
    const f = fixture(false); f.HttpClient.setCookie('SESSDATA', 'local');
    const pending = f.send(method, { url: 'https://example.com/public', headers: {
      cOoKiE: 'override', AUTHORIZATION: 'secret', 'Proxy-Authorization': 'secret', 'X-Public': 'ok',
    } });
    assert.equal(f.requests.length, 1); assert.equal(f.requests[0].url, 'https://example.com/public');
    const options = f.requests[0].options;
    assert.ok(Object.keys(options.header).every(key => !['cookie', 'authorization', 'proxy-authorization'].includes(key.toLowerCase())));
    assert.equal(options.header['X-Public'], 'ok'); assert.equal(options.maxRedirects, 5);
    f.AuthSession.advance(); f.requests[0].resolve(reply({ value: 1 }, {
      header: { 'set-cookie': 'SESSDATA=foreign' }, cookies: 'bili_jct=foreign',
    }));
    const response = await pending;
    assert.equal(response.json().value, 1); assert.equal(f.HttpClient.getCookie('SESSDATA'), 'local');
    assert.equal(f.HttpClient.getCookie('bili_jct'), '');
  });
}

test('HTTP: mixed-method requests coalesce SPI while a new account independently passes its own session check', async () => {
  const f = fixture(false), old = ['get', 'post', 'postBinary'].map(method => f.send(method));
  assert.equal(f.requests.length, 1); f.AuthSession.advance(); f.HttpClient.setCookie('SESSDATA', 'new');
  const current = f.send('post', { body: 'new=1' }); f.requests[0].resolve(spi()); await tick();
  assert.equal(f.requests.length, 2); assert.equal(f.requests[1].options.extraData, 'new=1');
  assert.match(f.requests[1].options.header.Cookie, /SESSDATA=new/);
  assert.match(f.requests[1].options.header.Cookie, /buvid3=real-device/);
  f.requests[1].resolve(reply({ current: true })); assert.equal((await current).json().current, true);
  assert.deepEqual((await Promise.all(old)).map(response => response.status), [-1, -1, -1]);
  assert.ok(f.requests.every(request => request.destroyed));
});

test('HTTP: failed SPI releases waiting requests and observes the existing cooldown before retrying', async () => {
  const f = fixture(false), first = f.send('get'); f.requests[0].reject({ code: 2300028 }); await tick();
  assert.equal(f.requests.length, 2); assert.match(f.requests[1].options.header.Cookie, /buvid3=in/);
  f.requests[1].resolve(reply()); await first;
  const second = f.send('post'); await tick(); assert.equal(f.requests.length, 3);
  assert.doesNotMatch(f.requests[2].url, /\/spi$/); f.requests[2].resolve(reply()); await second;
  f.advance(30001); const third = f.send('get'); assert.match(f.requests[3].url, /\/spi$/);
  f.requests[3].resolve(spi()); await tick(); f.requests[4].resolve(reply()); await third;
  assert.ok(f.requests.every(request => request.destroyed));
});

test('HTTP: body identity, default form content type, explicit overrides and priority survive the shared pipeline', async () => {
  const f = fixture(), bytes = new Uint8Array([0, 255, 128, 65]).buffer;
  const pending = [f.send('get'), f.send('post'), f.send('postBinary', {
    body: bytes, headers: { 'Content-Type': 'multipart/form-data; boundary=x' }, priority: f.RequestPriority.CRITICAL,
  })]; await tick();
  assert.equal(f.requests[0].options.method, 'GET'); assert.equal('extraData' in f.requests[0].options, false);
  assert.equal(f.requests[0].options.priority, f.RequestPriority.NORMAL);
  assert.equal(f.requests[1].options.method, 'POST'); assert.equal(f.requests[1].options.extraData, '');
  assert.equal(f.requests[1].options.header['Content-Type'], 'application/x-www-form-urlencoded; charset=utf-8');
  assert.equal(f.requests[2].options.extraData, bytes); assert.equal(f.requests[2].options.priority, f.RequestPriority.CRITICAL);
  assert.equal(f.requests[2].options.header['Content-Type'], 'multipart/form-data; boundary=x');
  for (const request of f.requests) {
    assert.equal(request.options.maxRedirects, 0); assert.equal(request.options.expectDataType, 0);
    assert.equal(request.options.connectTimeout, 12000); assert.equal(request.options.readTimeout, 20000);
    assert.equal('usingProxy' in request.options, false); request.resolve(reply());
  }
  await Promise.all(pending);
});

test('HTTP: caller headers are merged after awaited device initialization without mutation', async () => {
  const f = fixture(false), headers = { 'X-Request': 'before' };
  const pending = f.send('postBinary', { headers }); headers['X-Request'] = 'after';
  f.requests[0].resolve(spi()); await tick();
  assert.equal(f.requests[1].options.header['X-Request'], 'after');
  assert.deepEqual(headers, { 'X-Request': 'after' }); f.requests[1].resolve(reply()); await pending;
});

test('HTTP: explicit proxy applies to all methods and remains absent after clearing configuration', async () => {
  const f = fixture(); f.HttpClient.setProxy('http://127.0.0.1:7897');
  for (const method of ['get', 'post', 'postBinary']) {
    const pending = f.send(method); await tick(); const request = f.requests.at(-1);
    assert.deepEqual(request.options.usingProxy, { host: '127.0.0.1', port: 7897, exclusionList: [] });
    request.resolve(reply()); await pending;
  }
  f.HttpClient.setProxy(''); const pending = f.send('get'); await tick();
  assert.equal('usingProxy' in f.requests.at(-1).options, false); f.requests.at(-1).resolve(reply()); await pending;
});

test('HTTP: bytes and binary helpers retain their distinct HTTP status contracts and skip JSON parsing', async () => {
  const f = fixture(), bytes = new Uint8Array([10, 20]).buffer;
  const unchecked = f.HttpClient.getBytes('https://example.com/image');
  f.requests[0].resolve(reply({}, { responseCode: 403, result: bytes })); assert.equal(await unchecked, bytes);
  const checked = f.HttpClient.getBinary('https://example.com/image');
  f.requests[1].resolve(reply({}, { responseCode: 403, result: bytes })); assert.equal(await checked, null);
  assert.equal(f.parses.length, 0);
  assert.ok(f.requests.every(request => request.options.expectDataType === 1 && request.destroyed));
});

test('HTTP: a large non-JSON response never enters the parser and a large JSON array caches both views', async () => {
  const f = fixture(), html = '<html>' + 'x'.repeat(33000);
  const pendingHtml = f.send('get'); await tick(); f.requests[0].resolve(reply({}, { result: html }));
  assert.equal((await pendingHtml).body, html); assert.equal(f.parses.length, 0);
  const pendingJson = f.send('postBinary'); await tick();
  f.requests[1].resolve(reply([ { pad: 'x'.repeat(33000) } ])); const response = await pendingJson;
  assert.equal(f.parses.length, 1); assert.equal(response.jsonArray()[0].pad.length, 33000);
  assert.equal(response.json(), response.jsonArray(), 'the existing object view preserves the parsed array identity');
});
