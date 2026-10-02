const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader } = require('./arkts-module.cjs');

function fixture() {
  const cookies = new Map([['SESSDATA', 'test-session'], ['bili_jct', 'test-csrf']]);
  const gets = [], posts = [];
  let getResponse = { ok: true, status: 200, json: () => ({ code: 0, data: {} }) };
  let postResponse = { ok: true, status: 200, json: () => ({ code: 0 }) };
  const load = createArktsLoader({ mocks: {
    '@kit.ArkTS': { util: {} },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
    'common/WbiSign': { WbiSign: { encWbi: async () => {}, invalidate() {} } },
    'services/network/HttpClient': { RequestPriority: { NORMAL: 1 }, HttpClient: {
      getCookie: key => cookies.get(key) || '', setCookie: (key, value) => cookies.set(key, value),
      merge: (a, b) => ({ ...a, ...b }), buildQuery: p => new URLSearchParams(p).toString(),
      get: async (url, headers) => { gets.push({ url, headers }); return getResponse; },
      post: async (url, body, headers) => { posts.push({ url, body, headers }); return postResponse; },
    } },
  } });
  const { VideoReportApi: api, VideoReportReason: Reason } = load('api/VideoReportApi');
  return {
    api, Reason, cookies, gets, posts,
    tags: tags => { getResponse = { ok: true, status: 200, json: () => ({ code: 0,
      data: { author: { mid: 456 }, tags: [{ state: 1, type: 'label', sub_tag: tags }] } }) }; },
    getResponse: response => { getResponse = response; },
    postResponse: response => { postResponse = response; },
  };
}
const normal = (tid = 10040, extra = {}) => ({ tid, name: '含AI生成', type: 'normal', state: 1,
  attr: { description: '描述问题及位置' }, ...extra });
const jump = (url = 'https://www.bilibili.com/pc/community/copyright/role?pageType=1') => ({
  tid: 10027, name: '侵犯个人知识产权', type: 'jump', state: 1, attr: { url, description: '原创作品' },
});

test('video report reads current grouped v2 tags for the selected aid and retains server normal/jump IDs', async () => {
  const f = fixture(); f.tags([jump(), normal(), normal(), normal(10039, { name: '其他' })]);
  const reasons = await f.api.reasons(123);
  const url = new URL(f.gets[0].url);
  assert.equal(url.origin + url.pathname, 'https://api.bilibili.com/x/web-interface/appeal/v2/tags');
  assert.deepEqual(Object.fromEntries(url.searchParams), { from: 'web', aid: '123', version: 'v1' });
  assert.deepEqual(reasons.map(r => [r.aid, r.id, r.type]), [[123, 10027, 'jump'], [123, 10040, 'normal'], [123, 10039, 'normal']]);
  assert.equal(reasons[1].hint, '描述问题及位置');
  assert.equal(reasons[1].officialUrl, '');
  const official = new URL(reasons[0].officialUrl);
  assert.equal(official.pathname, '/pc/community/copyright/role');
  assert.deepEqual(Object.fromEntries(official.searchParams), { pageType: '1', aid: '123', mid: '456', version: 'new' });
});

test('video report ignores unknown, inactive and malformed tags rather than posting them as normal reports', async () => {
  const f = fixture(); f.tags([normal(), normal(99, { type: 'unknown' }), normal(98, { state: 0 }),
    normal(0), normal(1.5), normal(97, { name: '' })]);
  assert.deepEqual((await f.api.reasons(123)).map(r => r.id), [10040]);
  f.tags([normal(99, { type: 'unknown' })]);
  await assert.rejects(() => f.api.reasons(123), /暂无可用举报原因/);
});

test('video report rejects invalid video IDs before requesting tags', async () => {
  const f = fixture();
  for (const aid of [0, -1, 1.5, NaN, Infinity]) await assert.rejects(() => f.api.reasons(aid));
  assert.equal(f.gets.length, 0);
});

test('video report loading distinguishes transport and server failures and does not manufacture choices', async () => {
  const f = fixture();
  f.getResponse({ ok: false, status: 503, json: () => ({ code: 0 }) });
  await assert.rejects(() => f.api.reasons(123), /网络请求失败 \(503\)/);
  f.getResponse({ ok: true, status: 200, json: () => ({ code: -412, message: '请求被拦截' }) });
  await assert.rejects(() => f.api.reasons(123), /请求被拦截/);
  f.getResponse({ ok: true, status: 200, json: () => ({ code: 0 }) });
  await assert.rejects(() => f.api.reasons(123), /暂无可用举报原因/);
});

test('video report routes dedicated forms and structured source evidence to official pages without a POST', async () => {
  const f = fixture(); f.tags([jump(), normal(52), normal(8, { controls: [{ required: 1 }] })]);
  const reasons = await f.api.reasons(123);
  assert.equal(reasons[1].officialUrl, 'https://www.bilibili.com/appeal/?avid=123');
  assert.equal(reasons[2].officialUrl, 'https://www.bilibili.com/appeal/?avid=123');
  for (const reason of reasons) {
    assert.equal(reason.canSubmit('说明'), false);
    assert.equal((await f.api.submit(123, reason, '说明')).ok, false);
  }
  assert.equal(f.posts.length, 0);
});

test('video report only opens official HTTPS destinations and preserves official query/hash parameters', async () => {
  const f = fixture();
  for (const url of ['', 'javascript:alert(1)', 'http://www.bilibili.com/a',
    'https://www.bilibili.com.evil.test/a', 'https://www.bilibili.com@evil.test/a']) {
    f.tags([jump(url)]);
    assert.equal((await f.api.reasons(123))[0].officialUrl, 'https://www.bilibili.com/appeal/?avid=123');
  }
  f.tags([jump('https://www.bilibili.com/v/copyright/intro#notice')]);
  assert.equal((await f.api.reasons(123))[0].officialUrl,
    'https://www.bilibili.com/v/copyright/intro?aid=123&mid=456&version=new#notice');
});

test('normal and other video report reasons still require meaningful description without generated filler', async () => {
  const f = fixture(); f.tags([normal(), normal(10039, { name: '其他' })]);
  for (const reason of await f.api.reasons(123)) {
    for (const description of ['', ' \n\t ']) {
      assert.equal(reason.canSubmit(description), false);
      assert.equal((await f.api.submit(123, reason, description)).ok, false);
    }
    assert.equal(reason.canSubmit('01:20 具体问题'), true);
  }
  assert.equal(f.posts.length, 0);
});

test('video report rejects stale video choices, unknown type and missing login/CSRF before posting', async () => {
  const f = fixture(); f.tags([normal()]); const [reason] = await f.api.reasons(123);
  assert.equal((await f.api.submit(456, reason, '问题')).ok, false);
  const unknown = Object.assign(new f.Reason(), { aid: 123, id: 99, type: 'unknown' });
  assert.equal((await f.api.submit(123, unknown, '问题')).ok, false);
  f.cookies.delete('SESSDATA'); assert.equal((await f.api.submit(123, reason, '问题')).ok, false);
  f.cookies.set('SESSDATA', 'test-session'); f.cookies.delete('bili_jct');
  assert.equal((await f.api.submit(123, reason, '问题')).ok, false);
  assert.equal(f.posts.length, 0);
});

test('video report posts the selected server reason, trimmed user description and CSRF and only accepts server success', async () => {
  const f = fixture(); f.tags([normal()]); const [reason] = await f.api.reasons(123);
  f.postResponse({ ok: true, status: 200, json: () => ({ code: -412, message: '请求被拦截' }) });
  assert.equal((await f.api.submit(123, reason, ' 01:20 问题描述 ')).ok, false);
  assert.equal(f.posts[0].url, 'https://api.bilibili.com/x/web-interface/appeal/v2/submit');
  assert.deepEqual(Object.fromEntries(new URLSearchParams(f.posts[0].body)), {
    aid: '123', tid: '10040', desc: '01:20 问题描述', csrf: 'test-csrf', attach: '', meta: '', block_author: 'false',
  });
  assert.ok(f.cookies.get('Buid')); assert.equal(f.posts[0].headers.buid, f.cookies.get('Buid'));
  f.postResponse({ ok: false, status: 502, json: () => ({ code: 0 }) });
  assert.equal((await f.api.submit(123, reason, '说明')).ok, false);
  f.postResponse({ ok: true, status: 200, json: () => ({ code: 0 }) });
  assert.equal((await f.api.submit(123, reason, '说明')).ok, true);
});
