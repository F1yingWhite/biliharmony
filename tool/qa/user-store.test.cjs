// Load UserStore, UserApi, HttpClient and models whole; defer only native Preferences/HTTP.
// Credentials below are fabricated account labels, never real user data.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

const cookie = account => JSON.stringify({ buvid3: 'test-device', SESSDATA: 'account-' + account,
  bili_jct: 'csrf-' + account, DedeUserID: account === 'A' ? '1' : '2' });
const loginCookies = account => Object.entries(JSON.parse(cookie(account)))
  .map(([name, value]) => ({ name, value }));
const saved = account => ({ loginCookieJar: cookie(account), loginAccessToken: 'access-' + account,
  webRefreshToken: 'refresh-' + account });
function fixture({ legacy = {}, disk = saved('A'), delayOpen = true, nav, flush } = {}) {
  const opening = deferred(), storage = new Map(Object.entries(legacy)), values = new Map(Object.entries(disk));
  const requests = [], writes = [], flushes = [];
  let persistRefresh;
  const store = {
    getSync: (key, fallback) => values.get(key) ?? fallback,
    putSync(key, value) { values.set(key, value); writes.push({ key, value }); },
    async flush() { flushes.push(new Map(values)); if (flush) await flush(); }
  };
  const load = createArktsLoader({ mocks: {
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': {},
    '@kit.ArkData': { preferences: { getPreferences: () => delayOpen ? opening.promise : Promise.resolve(store) } },
    '@kit.ArkTS': { collections: { Array }, util: {}, taskpool: { execute: async (fn, ...args) => fn(...args) } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { debug() {}, info() {}, warn() {}, error() {} } },
    'services/message/MsgUnreadStore': { MsgUnreadStore: { resetSession() {} } },
    'services/auth/CookieRefresher': { CookieRefresher: {
      registerPersister(callback) { persistRefresh = callback; }, noteLogin() {}, logout() {}, onAuthFailure() {}
    } },
    '@kit.NetworkKit': { connection: {}, http: {
      RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0, ARRAY_BUFFER: 1 },
      createHttp: () => ({
        async request(url, options) {
          assert.ok(url.endsWith('/nav'), 'unexpected native HTTP request: ' + url);
          requests.push({ url, options });
          if (nav) return nav(url, options);
          const sess = /(?:^|;\s*)SESSDATA=([^;]+)/.exec(options.header.Cookie || '')?.[1] || '';
          return { responseCode: 200, header: {}, result: JSON.stringify({ code: 0, data: {
            isLogin: !!sess, mid: sess === 'account-A' ? 1 : 2, uname: sess,
            face: 'https://example.invalid/avatar.png', pendant: { image: 'https://example.invalid/pendant.png' }
          } }) };
        }, destroy() {}
      })
    } }
  }, globals: {
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    PersistentStorage: { persistProp(key, value) { if (!storage.has(key)) storage.set(key, value); } }
  } });
  const { HttpClient } = load('services/network/HttpClient');
  const { AuthSession } = load('services/auth/AuthSession');
  const { UserStore } = load('services/auth/UserStore');
  HttpClient.setCookie('buvid3', 'test-device');
  UserStore.initPersistence({});
  return { UserStore, HttpClient, AuthSession, storage, values, requests, writes, flushes,
    release: () => opening.resolve(store), persistRefresh: (...args) => persistRefresh(...args) };
}

test('direct refresh waits for disk credentials before its first nav request', async () => {
  const f = fixture(); const refreshing = f.UserStore.refresh();
  await tick();
  assert.equal(f.requests.length, 0, 'MineView.refresh must not send a guest nav while restore is pending');
  f.release(); const user = await refreshing;
  assert.equal(user.uname, 'account-A'); assert.equal(user.isLogin, true);
  assert.equal(f.UserStore.current, user);
  assert.match(f.requests[0].options.header.Cookie, /SESSDATA=account-A/);
});

test('normal startup restores the disk account and access token over its legacy mirror', async () => {
  const f = fixture({ legacy: saved('A'), disk: saved('B'), delayOpen: false });
  const user = await f.UserStore.ensureLoaded();
  assert.equal(user.uname, 'account-B'); assert.equal(f.UserStore.isLogin, true);
  assert.equal(f.HttpClient.getAppAccessToken(), 'access-B');
  assert.equal(f.UserStore.refreshToken, 'refresh-B');
});

test('logout during delayed restore stays logged out in memory, mirrors and disk', async () => {
  const f = fixture({ legacy: saved('A') });
  const loggingOut = f.UserStore.logout(); f.release(); await loggingOut;
  assert.equal(f.HttpClient.getCookie('SESSDATA'), '');
  assert.equal(f.HttpClient.getCookie('bili_jct'), '');
  assert.equal(f.HttpClient.getAppAccessToken(), '');
  assert.equal(f.UserStore.refreshToken, ''); assert.equal(f.UserStore.isLogin, false);
  for (const key of ['loginCookieJar', 'loginAccessToken', 'webRefreshToken']) {
    assert.equal(f.values.get(key), ''); assert.equal(f.storage.get(key), '');
  }
  assert.equal(f.requests.length, 0);
});

test('new login during restore replaces old credentials and verifies the new account', async () => {
  const f = fixture({ legacy: saved('A') });
  const login = f.UserStore.applyLoginCookies(loginCookies('B'), 'access-B', 'refresh-B');
  f.release(); await login;
  assert.equal(f.HttpClient.getCookie('SESSDATA'), 'account-B');
  assert.equal(f.HttpClient.getAppAccessToken(), 'access-B');
  assert.equal(f.UserStore.refreshToken, 'refresh-B');
  assert.equal(f.UserStore.current.uname, 'account-B');
  assert.equal(JSON.parse(f.values.get('loginCookieJar')).SESSDATA, 'account-B');
  assert.equal(f.values.get('loginAccessToken'), 'access-B');
  assert.equal(f.values.get('webRefreshToken'), 'refresh-B');
  assert.equal(f.requests.length, 1);
});

for (const tokenArgument of ['omitted', 'empty']) {
  test(`password/SMS-style login with ${tokenArgument} Web refresh token clears the previous account token`, async () => {
    const f = fixture({ legacy: saved('A'), delayOpen: false });
    await f.UserStore.ensureLoaded();
    assert.equal(f.UserStore.refreshToken, 'refresh-A');
    if (tokenArgument === 'omitted') await f.UserStore.applyLoginCookies(loginCookies('B'), 'access-B');
    else await f.UserStore.applyLoginCookies(loginCookies('B'), 'access-B', '');
    assert.equal(f.UserStore.current.uname, 'account-B');
    assert.equal(f.HttpClient.getAppAccessToken(), 'access-B');
    assert.equal(f.UserStore.refreshToken, '', 'new account must not reuse the old Web refresh token');
    assert.equal(f.values.get('webRefreshToken'), '', 'the cleared token must survive restart');
    assert.equal(f.storage.get('webRefreshToken'), '', 'the reactive mirror must belong to the new account');
  });
}

test('a login with an explicit new Web refresh token replaces and persists the old account token', async () => {
  const f = fixture({ legacy: saved('A'), delayOpen: false });
  await f.UserStore.ensureLoaded();
  await f.UserStore.applyLoginCookies(loginCookies('B'), 'access-B', 'refresh-B');
  assert.equal(f.UserStore.current.uname, 'account-B');
  assert.equal(f.UserStore.refreshToken, 'refresh-B');
  assert.equal(f.values.get('webRefreshToken'), 'refresh-B');
  assert.equal(f.storage.get('webRefreshToken'), 'refresh-B');
});

test('a nav queued before logout cannot start when delayed restoration finishes', async () => {
  const f = fixture({ legacy: saved('A') });
  const obsolete = f.UserStore.refresh(), logout = f.UserStore.logout();
  f.release(); await Promise.all([obsolete, logout]);
  assert.equal(f.requests.length, 0);
  assert.equal(f.UserStore.current, null); assert.equal(f.UserStore.isLogin, false);
});

test('an obsolete refreshed-cookie callback cannot persist its token after logout during restore', async () => {
  const f = fixture({ legacy: saved('A') });
  const refreshed = f.persistRefresh('refreshed-A');
  const logout = f.UserStore.logout();
  f.release(); await Promise.all([refreshed, logout]); await tick();
  assert.equal(f.storage.get('webRefreshToken'), '');
  assert.equal(f.values.get('webRefreshToken'), '');
  assert.equal(f.UserStore.refreshToken, '');
  assert.equal(f.requests.length, 0, 'old refresh completion must not schedule another nav');
});

test('cookie refresh finishing a disk flush cannot overwrite a newer logout mirror', async () => {
  const pending = deferred(); let flushCount = 0;
  const f = fixture({ delayOpen: false, legacy: saved('A'), flush: () => ++flushCount === 1 ? pending.promise : Promise.resolve() });
  await f.UserStore.ensureLoaded();
  const count = f.requests.length;
  const refreshed = f.persistRefresh('refreshed-A');
  await tick(); const logout = f.UserStore.logout();
  await logout; pending.resolve(); await refreshed; await tick();
  assert.equal(f.storage.get('webRefreshToken'), '');
  assert.equal(f.UserStore.refreshToken, ''); assert.equal(f.UserStore.isLogin, false);
  assert.equal(f.requests.length, count, 'old callback must not refresh nav after newer logout');
});

test('a current cookie refresh persists renewed credentials and refreshes nav', async () => {
  const f = fixture({ delayOpen: false });
  await f.UserStore.ensureLoaded();
  f.HttpClient.setCookie('bili_jct', 'renewed-csrf-A');
  await f.persistRefresh('renewed-refresh-A'); await tick();
  assert.equal(f.UserStore.refreshToken, 'renewed-refresh-A');
  assert.equal(f.storage.get('webRefreshToken'), 'renewed-refresh-A');
  assert.equal(f.values.get('webRefreshToken'), 'renewed-refresh-A');
  assert.equal(JSON.parse(f.values.get('loginCookieJar')).bili_jct, 'renewed-csrf-A');
  assert.equal(f.UserStore.current.uname, 'account-A'); assert.equal(f.requests.length, 2);
});
