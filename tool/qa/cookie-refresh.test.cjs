const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

const INFO = 'https://passport.bilibili.com/x/passport-login/web/cookie/info';
const CORRESPOND = 'https://www.bilibili.com/correspond/1/';
const REFRESH = 'https://passport.bilibili.com/x/passport-login/web/cookie/refresh';
const CONFIRM = 'https://passport.bilibili.com/x/passport-login/web/confirm/refresh';
// Public key modulus embedded in Bilibili's official wasm_rsa_encrypt_bg.wasm.
const MODULUS = 'cb81dd8e02470656da04dd38544446e2a3412051cfe9adc6a330a5ef90228509684960970b91c3360ca29c49e1690ff8fa068cb9dfc6179d1e9585cb9424e847db1ef59f33e37dd4dca8ccfb7631ee9b4a92640d00c8204300152a0ab7cd802889d3445aec69918fe6022b534912e7b095be3424dad1ba81145e969b533181f1';

function fixture(options = {}) {
  const calls = [], encrypted = [], persisted = [], algorithms = [];
  const cookies = new Map([['SESSDATA', 'session-A'], ['bili_jct', 'csrf-A']]);
  let token = 'token-A', refreshOldToken = '', load;
  const json = (data, code = 0) => new (load('services/network/HttpResponse').HttpResponse)(
    200, JSON.stringify({ code, data }), {});
  const boundary = async (stage, value) => {
    calls.push(stage);
    if (options.gate && options.gate.stage === stage) await options.gate.promise;
    if (options.onStage) await options.onStage(stage, calls.filter(value => value === stage).length);
    return value;
  };
  const client = {
    getCookie: name => cookies.get(name) || '',
    buildQuery: params => new URLSearchParams(params).toString(),
    async get(url) {
      if (url === INFO) return boundary('info', json(options.info || { refresh: true, timestamp: 1700000123456 }));
      if (url.startsWith(CORRESPOND)) {
        assert.match(url.slice(CORRESPOND.length), /^[0-9a-f]{256}$/);
        return boundary('correspond', new (load('services/network/HttpResponse').HttpResponse)(
          200, options.html || '<html><div id="1-name">refresh-csrf-A</div></html>', {}));
      }
      // Unexpected endpoints are real request failures, not a mock implementation of the protocol.
      calls.push('unexpected:' + url);
      return new (load('services/network/HttpResponse').HttpResponse)(404, 'not found', {});
    },
    async post(url, body) {
      const params = Object.fromEntries(new URLSearchParams(body));
      if (url === REFRESH) {
        assert.deepEqual(params, { csrf: token === 'token-B' ? 'csrf-B' : 'csrf-A',
          refresh_csrf: 'refresh-csrf-A', refresh_token: token, source: 'main_web' });
        refreshOldToken = token;
        const account = load('services/auth/AuthSession').AuthSession.version;
        const response = await boundary('refresh', json(options.refreshData || { refresh_token: 'token-new' }));
        // HttpClient also rejects old-account Set-Cookie. Model that IO boundary here.
        if (account === load('services/auth/AuthSession').AuthSession.version) cookies.set('bili_jct', 'csrf-new');
        return response;
      }
      assert.equal(url, CONFIRM);
      assert.deepEqual(params, { csrf: 'csrf-new', refresh_token: refreshOldToken });
      return boundary('confirm', json({}, options.confirmCode || 0));
    }
  };
  load = createArktsLoader({ mocks: {
    'services/network/HttpClient': { HttpClient: client },
    "@kit.ArkTS": { util: {
      Base64Helper: class {
        decodeSync(body) { return new Uint8Array(Buffer.from(body, 'base64')); }
        encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      },
      TextEncoder: class { encodeInto(value) { return new Uint8Array(Buffer.from(value)); } }
    } },
    "@kit.CryptoArchitectureKit": { cryptoFramework: {
      CryptoMode: { ENCRYPT_MODE: 1 },
      createAsyKeyGenerator(alg) {
        assert.equal(alg, 'RSA1024|PRIMES_2');
        return { async convertKey(blob) {
          const key = crypto.createPublicKey({ key: Buffer.from(blob.data), format: 'der', type: 'spki' });
          const jwk = key.export({ format: 'jwk' });
          assert.equal(Buffer.from(jwk.n, 'base64url').toString('hex'), MODULUS);
          assert.equal(jwk.e, 'AQAB');
          return { pubKey: key };
        } };
      },
      createCipher(algorithm) {
        algorithms.push(algorithm);
        assert.equal(algorithm, 'RSA1024|PKCS1_OAEP|SHA256|MGF1_SHA256');
        let key;
        return {
          async init(mode, publicKey) { assert.equal(mode, 1); key = publicKey; },
          async doFinal(blob) {
            encrypted.push(Buffer.from(blob.data).toString());
            if (options.cryptoGate) await options.cryptoGate.promise;
            if (options.cryptoFailure) throw Error('platform encryption failed');
            return { data: new Uint8Array(crypto.publicEncrypt({ key,
              padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, Buffer.from(blob.data))) };
          }
        };
      }
    } }
  } });
  const { CookieRefresher } = load('services/auth/CookieRefresher');
  const { AuthSession } = load('services/auth/AuthSession');
  CookieRefresher.registerPersister(async value => {
    persisted.push(value);
    await boundary('persist', undefined);
    token = value;
  }, () => token);
  return { load, CookieRefresher, AuthSession, cookies, calls, encrypted, persisted, algorithms,
    readToken: () => token,
    changeAccount() { AuthSession.advance(); CookieRefresher.logout(); cookies.set('SESSDATA', 'session-B'); cookies.set('bili_jct', 'csrf-B'); token = 'token-B'; } };
}

test('cookie renewal follows official endpoints and encrypts refresh_serverTimestamp with the official key', async () => {
  const f = fixture();
  assert.equal(await f.CookieRefresher.maybeRefresh(), true);
  assert.deepEqual(f.calls, ['info', 'correspond', 'refresh', 'persist', 'confirm']);
  assert.deepEqual(f.encrypted, ['refresh_1700000123456']);
  assert.deepEqual(f.persisted, ['token-new']);
});

test('concurrent checks share the active task even after its throttle starts', async () => {
  const gate = deferred(); gate.stage = 'info'; const f = fixture({ gate });
  const first = f.CookieRefresher.maybeRefresh();
  assert.equal(f.CookieRefresher.maybeRefresh(), first);
  gate.resolve(); assert.equal(await first, true);
  assert.equal(await f.CookieRefresher.maybeRefresh(), false);
  assert.equal(f.calls.filter(value => value === 'info').length, 1);
});

test('authentication failure can trigger one immediate renewal despite the routine login throttle', async () => {
  const gate = deferred(); gate.stage = 'info'; const f = fixture({ gate });
  f.CookieRefresher.noteLogin(); assert.equal(await f.CookieRefresher.maybeRefresh(), false);
  f.CookieRefresher.onAuthFailure(); f.CookieRefresher.onAuthFailure();
  assert.deepEqual(f.calls, ['info']);
  const task = f.CookieRefresher.maybeRefresh(); gate.resolve(); assert.equal(await task, true);
  f.CookieRefresher.onAuthFailure(); await tick();
  assert.equal(f.calls.filter(value => value === 'info').length, 1);
});

for (const info of [{ refresh: false }, { refresh: true }, { refresh: true, timestamp: -1 }]) {
  test('non-refreshable or malformed cookie info performs no encryption or renewal: ' + JSON.stringify(info), async () => {
    const f = fixture({ info }); assert.equal(await f.CookieRefresher.maybeRefresh(), false);
    assert.deepEqual(f.calls, ['info']); assert.deepEqual(f.encrypted, []);
  });
}

test('correspond page failure does not retry with an incompatible base64 path', async () => {
  const f = fixture({ html: '<html>expired</html>' });
  assert.equal(await f.CookieRefresher.maybeRefresh(), false);
  assert.deepEqual(f.calls, ['info', 'correspond']); assert.deepEqual(f.persisted, []);
});

test('platform SHA256 failure does not fall back to a different MGF digest', async () => {
  const f = fixture({ cryptoFailure: true }); assert.equal(await f.CookieRefresher.maybeRefresh(), false);
  assert.deepEqual(f.algorithms, ['RSA1024|PKCS1_OAEP|SHA256|MGF1_SHA256']);
  assert.deepEqual(f.calls, ['info']);
});

test('a refresh response missing its replacement token is rejected before confirmation', async () => {
  const f = fixture({ refreshData: {} }); assert.equal(await f.CookieRefresher.maybeRefresh(), false);
  assert.deepEqual(f.calls, ['info', 'correspond', 'refresh']); assert.deepEqual(f.persisted, []);
});

test('confirmation failure still retains the new cookie and replacement token together', async () => {
  const f = fixture({ confirmCode: 500 });
  assert.equal(await f.CookieRefresher.maybeRefresh(), false);
  assert.equal(f.cookies.get('bili_jct'), 'csrf-new');
  assert.equal(f.readToken(), 'token-new');
  assert.deepEqual(f.persisted, ['token-new']);
});

test('confirmation is sent only after replacement credentials have finished persisting', async () => {
  const gate = deferred(); gate.stage = 'persist'; const f = fixture({ gate });
  const task = f.CookieRefresher.maybeRefresh();
  for (let i = 0; i < 15 && !f.calls.includes('persist'); i++) await tick();
  assert.ok(f.calls.includes('persist'));
  assert.equal(f.calls.includes('confirm'), false);
  gate.resolve(); assert.equal(await task, true);
});

for (const stage of ['info', 'correspond', 'refresh', 'confirm', 'persist']) {
  test('account change during ' + stage + ' aborts subsequent cookie renewal stages', async () => {
    const gate = deferred(); gate.stage = stage; const f = fixture({ gate });
    const task = f.CookieRefresher.maybeRefresh();
    for (let i = 0; i < 15 && !f.calls.includes(stage); i++) await tick();
    assert.ok(f.calls.includes(stage), 'production flow must reach tested stage');
    f.changeAccount(); gate.resolve(); assert.equal(await task, false);
    assert.equal(f.calls.at(-1), stage);
    if (['info', 'correspond', 'refresh'].includes(stage)) assert.deepEqual(f.persisted, []);
  });
}

test('account change during RSA encryption sends no old-account correspond request', async () => {
  const cryptoGate = deferred(); const f = fixture({ cryptoGate }); const task = f.CookieRefresher.maybeRefresh();
  for (let i = 0; i < 15 && f.encrypted.length === 0; i++) await tick();
  assert.equal(f.encrypted.length, 1); f.changeAccount(); cryptoGate.resolve();
  assert.equal(await task, false); assert.deepEqual(f.calls, ['info']);
});

test('completion of an old account task cannot clear its replacement active task', async () => {
  const oldGate = deferred(), newGate = deferred();
  const f = fixture({ onStage: (stage, count) => stage === 'info' ?
    (count === 1 ? oldGate.promise : newGate.promise) : Promise.resolve() });
  const old = f.CookieRefresher.maybeRefresh(); f.changeAccount();
  const current = f.CookieRefresher.maybeRefresh();
  assert.notEqual(current, old); oldGate.resolve();
  assert.equal(await old, false);
  assert.equal(f.CookieRefresher.maybeRefresh(), current);
  newGate.resolve(); assert.equal(await current, true);
  assert.deepEqual(f.persisted, ['token-new']);
  assert.equal(f.calls.filter(value => value === 'info').length, 2);
});
