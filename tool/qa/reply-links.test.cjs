const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function parserFixture() {
  const load = createArktsLoader({mocks: {'common/CommentLog': {CommentLog: {info() {}}}}});
  const {ReplyItem} = load('model/Models');
  return {load, parse: content => load('common/ReplyContentParser').parseReplyContent(
    Object.assign(new ReplyItem(), {rpid: 9, content}))};
}

test('video comment keeps the entire linked URL including page and playback time', () => {
  const f = parserFixture(), url = 'https://www.bilibili.com/video/BV17x411w7KC?p=2&t=90';
  const parts = f.parse('这里看 ' + url + '。');
  assert.equal(parts.find(part => part.url).url, url);
  assert.equal(parts.find(part => part.url).text, url);
  assert.equal(parts.filter(part => part.text.includes('?p=')).length, 1);
});

test('comment URLs keep all common internal destinations and never extract a video ID from an external host', () => {
  const f = parserFixture();
  for (const url of ['https://b23.tv/av170001', 'https://m.bilibili.com/video/BV17x411w7KC?t=9',
    'https://www.bilibili.com/bangumi/play/ep123', 'https://space.bilibili.com/456',
    'https://t.bilibili.com/1000000000000000099', 'https://live.bilibili.com/789', 'b23.tv/av170001']) {
    const parts = f.parse('链接 ' + url + '。');
    assert.equal(parts.find(part => part.url).url, url.startsWith('http') ? url : 'https://' + url);
  }
  const external = f.parse('https://example.invalid/video/BV17x411w7KC')[0];
  assert.equal(external.bvid, ''); assert.equal(external.aid, 0);
  assert.equal(f.parse('BV17x411w7KC')[0].bvid, 'BV17x411w7KC', 'bare video IDs remain supported');
});

function fixture(handler) {
  const requests = [], destroyed = [], navigations = [], external = [], toasts = [], state = {alive: true, key: 'video:1/reply:9', stops: 0};
  const storage = new Map();
  const response = (status, header = {}, result = '') => ({responseCode: status, header, result, cookies: ''});
  const detail = {code: 0, data: {aid: 170001, bvid: 'BV17x411w7KC', cid: 100,
    pages: [{page: 1, cid: 100, duration: 199}, {page: 2, cid: 200, duration: 180}]}};
  const load = createArktsLoader({mocks: {
    'common/CommentLog': {CommentLog: {info() {}, warn() {}}},
    'common/WbiSign': {WbiSign: {}}, 'common/AppSign': {},
    'services/auth/CookieRefresher': {CookieRefresher: {onAuthFailure() {}}},
    '@kit.ArkTS': {taskpool: {execute: (fn, ...args) => Promise.resolve(fn(...args))},
      util: {TextDecoder: {create: () => ({decodeToString: bytes => new TextDecoder().decode(bytes)})}}},
    '@kit.NetworkKit': {connection: {}, http: {RequestMethod: {GET: 'GET', POST: 'POST'}, HttpDataType: {STRING: 0, ARRAY_BUFFER: 1},
      createHttp: () => {const id = requests.length; return {request(url, options) {
        const request = {url, options}; requests.push(request);
        return handler ? handler(request, response, detail) : Promise.resolve(url.startsWith('https://b23.tv') ?
          response(302, {Location: 'https://www.bilibili.com/video/av170001'}) : response(200, {}, JSON.stringify(detail)));
      }, destroy() {destroyed.push(id);}};}}},
  }, globals: {NavPathStack: class {}, AppStorage: {get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)}}});
  const HttpClient = load('services/network/HttpClient').HttpClient;
  HttpClient.setCookie('buvid3', 'fake-device'); HttpClient.setCookie('SESSDATA', 'fake-session'); HttpClient.setCookie('bili_jct', 'fake-csrf');
  const {ReplyLinkController} = load('components/reply/ReplyLinkController');
  const controller = new ReplyLinkController({isAlive: () => state.alive, getSourceKey: () => state.key,
    navigate: value => navigations.push(value), openExternal: value => external.push(value),
    stopPlayer: () => state.stops++, toast: value => toasts.push(value)});
  return {load, requests, destroyed, navigations, external, toasts, state, controller, response,
    AuthSession: load('services/auth/AuthSession').AuthSession};
}

test('whole production routing maps video, bangumi, user, dynamic, live and article links to existing pages', async () => {
  const f = fixture();
  for (const [url, name, key, expected] of [
    ['https://www.bilibili.com/video/av170001', 'VideoDetail', 'aid', 170001],
    ['https://m.bilibili.com/video/BV17x411w7KC', 'VideoDetail', 'bvid', 'BV17x411w7KC'],
    ['https://www.bilibili.com/bangumi/play/ep123', 'BangumiDetail', 'epId', 123],
    ['https://www.bilibili.com/bangumi/play/ss456', 'BangumiDetail', 'seasonId', 456],
    ['https://space.bilibili.com/789/video', 'UserSpace', 'mid', 789],
    ['https://t.bilibili.com/1000000000000000099', 'DynamicDetail', 'dynId', '1000000000000000099'],
    ['https://www.bilibili.com/opus/1000000000000000099', 'DynamicDetail', 'dynId', '1000000000000000099'],
    ['https://live.bilibili.com/blanc/123', 'LiveRoom', 'roomId', 123],
    ['https://www.bilibili.com/read/cv123', 'Article', 'id', 123],
    ['https://m.bilibili.com/read/mobile?id=456', 'Article', 'id', 456],
  ]) {
    assert.equal(await f.controller.open(url, '评论链接'), true);
    const navigation = f.navigations.at(-1); assert.equal(navigation.name, name);
    assert.equal(key === 'dynId' ? navigation.param.item.dynId : navigation.param[key], expected);
  }
  assert.deepEqual(f.external, []); assert.equal(f.requests.length, 0, 'direct supported links need no resolution network');
});

test('real comment search keywords retain their labels and open the app search with the decoded keyword', async () => {
  const f = fixture();
  const {ReplyItem} = f.load('model/Models');
  const {parseReplyContent} = f.load('common/ReplyContentParser');
  const jumps = Object.fromEntries(['oto', 'openutau'].map(keyword => [keyword, {
    pc_url: '//search.bilibili.com/all?from_source=webcommentline_search&keyword=' + keyword +
      '&seid=5391055258723124908&from_avid=116380644941208&from_comid=295782996513&search_half_screen=0',
    app_url_schema: 'bilibili://search?from=appcommentline_search&keyword=' + keyword,
  }]));
  const reply = ReplyItem.from({rpid: 295782996513, oid: 116380644941208, type: 1,
    content: {message: '修剪了一遍oto，放进openutau里一个一个地听了再修', jump_url: jumps}});
  const parts = parseReplyContent(reply).filter(part => part.url);
  assert.deepEqual(parts.map(part => part.text), ['oto', 'openutau']);
  for (const part of parts) {
    assert.equal(await f.controller.open(part.url, part.text), true);
    assert.equal(f.external.length, 0, 'a blue comment keyword must stay in the app');
    assert.ok(f.navigations.length > 0, 'the actual production link controller must navigate');
    assert.equal(f.navigations.at(-1).name, 'Search');
    assert.deepEqual(f.navigations.at(-1).param, {keyword: part.text});
  }
  assert.deepEqual(f.external, []);
  assert.equal(f.requests.length, 0, 'search keywords should not need a redirect or detail lookup');
});

test('search URLs decode Chinese, spaces and literal plus once and match only the supported search host and path', async () => {
  const f = fixture();
  for (const [url, keyword] of [
    ['https://search.bilibili.com/all?keyword=%E8%99%9A%E6%8B%9F%E6%AD%8C%E6%89%8B+OpenUTAU', '虚拟歌手 OpenUTAU'],
    ['//search.bilibili.com/all/?keyword=C%2B%2B%20%252F', 'C++ %2F'],
    ['search.bilibili.com/all?keyword=BV17x411w7KC', 'BV17x411w7KC'],
  ]) {
    assert.equal(await f.controller.open(url, '蓝色词'), true);
    assert.equal(f.external.length, 0, 'search links must not invoke an external browser');
    assert.equal(f.navigations.at(-1).name, 'Search');
    assert.deepEqual(f.navigations.at(-1).param, {keyword});
  }
  const {parseBiliLink} = f.load('common/BiliLinkParser');
  for (const url of ['https://search.bilibili.com.evil.invalid/all?keyword=oto',
    'https://search.bilibili.com@evil.invalid/all?keyword=oto',
    'https://example.invalid/all?keyword=oto', 'https://search.bilibili.com/unknown?keyword=oto',
    'https://search.bilibili.com/all?keyword=', 'https://search.bilibili.com/all?keyword=%20%20',
    'https://search.bilibili.com/all?keyword=%E8%ZZ', 'https://search.bilibili.com/all?keyword=%00oto']) {
    assert.equal(parseBiliLink(url), null, url);
  }
  const searchPart = parserFixture().parse('试试 search.bilibili.com/all?keyword=oto。').find(part => part.url);
  assert.equal(searchPart.url, 'https://search.bilibili.com/all?keyword=oto');
  for (const prefix of ['evil.', 'x-', 'x_', 'x@']) {
    const text = prefix + 'search.bilibili.com/all?keyword=oto';
    const parts = parserFixture().parse(text);
    assert.equal(parts.some(part => part.url), false, 'a bare URL must not extract a trusted domain suffix');
    assert.equal(parts.map(part => part.text).join(''), text);
  }
  assert.deepEqual(f.external, []); assert.equal(f.requests.length, 0);
});

test('page/time links use actual video detail HTTP and existing CID continuation contract', async () => {
  const f = fixture();
  assert.equal(await f.controller.open('https://www.bilibili.com/video/BV17x411w7KC?p=2&t=90', '分P链接'), true);
  assert.deepEqual(f.navigations[0].param, {aid: 0, bvid: 'BV17x411w7KC', title: '分P链接', cid: 200, resumePosition: 90});
  assert.equal(new URL(f.requests[0].url).searchParams.get('bvid'), 'BV17x411w7KC');
  assert.equal(await f.controller.open('https://www.bilibili.com/video/av170001?p=2', '第二P'), true);
  assert.equal(f.navigations.at(-1).param.cid, 200); assert.equal(f.navigations.at(-1).param.resumePosition, 0);
  assert.equal(await f.controller.open('https://www.bilibili.com/video/av170001?p=99', '不存在'), false);
  assert.equal(f.navigations.length, 2); assert.equal(f.toasts.length, 1);
});

test('b23 resolves its real redirect protocol without credentials or automatic redirects', async () => {
  const f = fixture((_request, response) => Promise.resolve(response(302, {location: ['https://www.bilibili.com/video/av170001']})));
  assert.equal(await f.controller.open('http://b23.tv/av170001', '短链'), true);
  assert.equal(f.navigations[0].name, 'VideoDetail'); assert.equal(f.navigations[0].param.aid, 170001);
  assert.equal(f.requests[0].url, 'https://b23.tv/av170001');
  assert.equal(f.requests[0].options.maxRedirects, 0);
  assert.ok(!Object.keys(f.requests[0].options.header).some(key => /cookie|authorization/i.test(key)));
  assert.equal(f.destroyed.length, 1); assert.deepEqual(f.external, []);
});

test('a b23 redirect to a comment keyword search uses the same app search destination', async () => {
  const f = fixture((_request, response) => Promise.resolve(response(302, {
    Location: '//search.bilibili.com/all?keyword=openutau&from_source=webcommentline_search',
  })));
  assert.equal(await f.controller.open('https://b23.tv/keyword123', '关键词'), true);
  assert.equal(f.navigations[0].name, 'Search');
  assert.deepEqual(f.navigations[0].param, {keyword: 'openutau'});
  assert.equal(f.requests.length, 1); assert.equal(f.destroyed.length, 1);
  assert.deepEqual(f.external, []);
});

test('unsupported direct HTTP destinations open externally while unresolvable short links stay inside the app', async () => {
  const f = fixture((_request, response) => Promise.resolve(response(302, {Location: 'bilibili://video/170001'})));
  for (const url of ['https://www.bilibili.com/festival/2026', 'https://example.invalid/video/BV17x411w7KC',
    'https://www.bilibili.com.evil.invalid/video/av170001']) {
    assert.equal(await f.controller.open(url, '网页'), true); assert.equal(f.external.at(-1), url);
  }
  assert.equal(await f.controller.open('https://b23.tv/av170001', '不支持的短链目标'), false);
  assert.match(f.toasts.at(-1), /短链接.*重试/);
  for (const url of ['javascript:alert(1)', 'file:///data/private', 'bilibili://video/170001', 'https://www.bilibili.com/\nvideo/av170001']) {
    assert.equal(await f.controller.open(url, '危险链接'), false);
  }
  assert.equal(f.navigations.length, 0); assert.equal(f.external.length, 3); assert.equal(f.requests.length, 1);
});

test('short-link loops stop after three anonymous hops and each request is released', async () => {
  const f = fixture((_request, response) => Promise.resolve(response(302, {Location: '/av170001'})));
  assert.equal(await f.controller.open('https://b23.tv/av170001', '循环'), false);
  assert.equal(f.requests.length, 3); assert.equal(f.destroyed.length, 3);
  assert.deepEqual(f.navigations, []); assert.deepEqual(f.external, []); assert.equal(f.state.stops, 0);
  assert.match(f.toasts[0], /短链接.*重试/);
});

test('network and unsupported-target failures of short links only show retry and never invoke another app', async () => {
  for (const handler of [() => Promise.reject(Error('offline')),
    (_request, response) => Promise.resolve(response(200, {}, '<html>unexpected page</html>')),
    (_request, response) => Promise.resolve(response(302, {Location: 'https://www.bilibili.com/festival/2026'}))]) {
    const f = fixture(handler);
    assert.equal(await f.controller.open('https://b23.tv/av170001', '短链'), false);
    assert.deepEqual(f.navigations, []); assert.deepEqual(f.external, []); assert.equal(f.state.stops, 0);
    assert.match(f.toasts[0], /短链接.*重试/); assert.equal(f.destroyed.length, 1);
  }
});

for (const change of ['source', 'dispose', 'destroy', 'account', 'later-click']) {
  test('a delayed b23 resolution after ' + change + ' cannot navigate, stop playback or open another app', async () => {
    const pending = deferred(), f = fixture(() => pending.promise);
    const work = f.controller.open('https://b23.tv/av170001', '迟到'); await tick();
    if (change === 'source') f.state.key = 'video:2/reply:9';
    if (change === 'dispose') f.controller.dispose();
    if (change === 'destroy') f.state.alive = false;
    if (change === 'account') f.AuthSession.advance();
    if (change === 'later-click') await f.controller.open('https://space.bilibili.com/123', '最新链接');
    const navs = f.navigations.length, stops = f.state.stops;
    pending.resolve(f.response(302, {Location: 'https://www.bilibili.com/video/av170001'}));
    assert.equal(await work, false); assert.equal(f.navigations.length, navs); assert.equal(f.state.stops, stops);
    assert.deepEqual(f.external, []); assert.deepEqual(f.toasts, []); assert.equal(f.destroyed.length, 1);
  });
}

test('a delayed page lookup is also rejected when its comment source changes', async () => {
  const pending = deferred(), f = fixture(() => pending.promise);
  const work = f.controller.open('https://www.bilibili.com/video/av170001?p=2&t=9', '旧分P'); await tick();
  f.state.key = 'video:2/reply:9';
  pending.resolve(f.response(200, {}, JSON.stringify({code: 0, data: {aid: 170001, cid: 100,
    pages: [{page: 1, cid: 100}, {page: 2, cid: 200}]}})));
  assert.equal(await work, false); assert.deepEqual(f.navigations, []); assert.equal(f.state.stops, 0);
});

test('actual ReplyCard click routes full URLs through its production controller and onNavigate wrapper', async () => {
  const f = fixture();
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'components/reply/ReplyCard.ets'), 'utf8');
  const field = source.slice(source.indexOf('  private links:'), source.indexOf('  private likeTimers:'));
  const methods = source.slice(source.indexOf('  private openPart('), source.indexOf('  private openUser('));
  const code = ts.transpileModule('class Card {\n' + field + methods + '\n}; return Card;', {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}}).outputText;
  const stopped = [], pushed = [], wrapped = [], opened = [];
  const Card = new Function('ReplyLinkController', 'PlayerCommandBus', 'AppNavStack', 'NAV_VIDEO_DETAIL',
    'NAV_USER_SPACE', 'formatDuration', code)(f.load('components/reply/ReplyLinkController').ReplyLinkController,
    {stop: () => stopped.push(true)}, {pushPathByName: (...args) => pushed.push(args)}, 'VideoDetail', 'UserSpace', String);
  const card = new Card(); Object.assign(card, {destroyed: false, item: {oid: 1, type: 1, rpid: 9, content: '链接'},
    toast: message => f.toasts.push(message), onNavigate: action => {wrapped.push(action);},
    getUIContext: () => ({getHostContext: () => ({openLink: url => {opened.push(url); return Promise.resolve();}})})});
  const part = parserFixture().parse('https://m.bilibili.com/video/BV17x411w7KC?p=2&t=90')[0];
  card.openPart(part); for (let i = 0; i < 5 && wrapped.length === 0; i++) await tick();
  assert.equal(wrapped.length, 1); assert.equal(pushed.length, 0);
  card.destroyed = true; wrapped[0](); // The host may close the full-screen sheet before executing navigation.
  assert.equal(pushed[0][0], 'VideoDetail'); assert.equal(pushed[0][1].cid, 200); assert.equal(pushed[0][1].resumePosition, 90);
  assert.deepEqual(opened, []); assert.equal(stopped.length, 1);
  card.destroyed = false;
  card.openPart(parserFixture().parse('https://search.bilibili.com/all?keyword=openutau')[0]);
  for (let i = 0; i < 5 && wrapped.length < 2; i++) await tick();
  assert.equal(wrapped.length, 2); assert.equal(pushed.length, 1);
  wrapped[1]();
  assert.equal(opened.length, 0, 'the actual search click must not invoke UIAbilityContext.openLink');
  assert.equal(pushed.length, 2, 'the search click must reach the production navigation wrapper');
  assert.equal(pushed[1][0], 'Search'); assert.deepEqual(pushed[1][1], {keyword: 'openutau'});
  assert.deepEqual(opened, []); assert.equal(stopped.length, 2);
});
