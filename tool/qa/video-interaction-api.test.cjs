const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

// Wire numbers and fields come from the official player 4.10.4 and DmWebViewReply/CommandDm schema.
const source = {aid: 100, bvid: 'BV17x411w7KC', cid: 200, duration: 0};
const varint = value => {let n = BigInt(value), out = []; do {out.push(Number(n & 127n) | (n > 127n ? 128 : 0)); n >>= 7n;} while(n); return Buffer.from(out);};
const number = (field, value) => Buffer.concat([varint(field * 8), varint(value)]);
const bytes = (field, value) => {const buffer = Buffer.isBuffer(value) ? value : Buffer.from(value); return Buffer.concat([varint(field * 8 + 2), varint(buffer.length), buffer]);};
function command(kind, extra, options = {}) {
  return Buffer.concat([number(1, options.id || '35000000000000017'), number(2, 200), number(3, 7),
    bytes(4, kind), bytes(5, options.title || 'UP互动'), number(6, options.progress ?? 1500),
    bytes(9, typeof extra === 'string' ? extra : JSON.stringify(extra)),
    ...(options.idstr ? [bytes(10, options.idstr)] : []), bytes(21, 'unknown command field')]);
}
const grade = (extra = {}, options = {}) => command('#GRADE#', {grade_id: '91', msg: '请评分', duration: 6000,
  mid_score: 0, count: 50, avg_score: 8.25, ...extra}, options);
const vote = (extra = {}, options = {}) => command('#VOTE#', {vote_id: '92', question: '请选择', duration: 10000,
  vote_type: 1, my_vote: 0, options: [{idx: 3, desc: '第一项', cnt: 4}, {idx: 9, desc: '第二项', cnt: 8},
    {idx: 12, desc: '其他', cnt: 1, has_self_def: 1}], ...extra}, options);
const link = (extra = {}, options = {}) => command('#LINK#', {aid: 901, bvid: 'BV1test', arc_pic: '//i0.hdslb.com/test.jpg',
  duration: 5000, arc_type: 1, ...extra}, options);
const view = (...commands) => Buffer.concat([number(1, 0), bytes(2, 'view text'),
  bytes(31, 'unknown root field'), ...commands.map(value => bytes(9, value))]);
const arrayBuffer = buffer => buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
const response = (data, status = 200) => ({responseCode: status, result: data, header: {}, cookies: ''});

function fixture(options = {}) {
  const storage = new Map(), requests = [];
  const load = createArktsLoader({mocks: {
    'common/WbiSign': {WbiSign: {}}, 'common/AppSign': {},
    'services/auth/CookieRefresher': {CookieRefresher: {onAuthFailure() {}}},
    '@kit.ArkTS': {taskpool: {execute: (fn, ...args) => options.decodeGate ?
      options.decodeGate.promise.then(() => fn(...args)) : Promise.resolve(fn(...args))},
      util: {TextDecoder: {create: () => ({decodeToString: data => new TextDecoder().decode(data)})}}},
    '@kit.NetworkKit': {http: {RequestMethod: {GET: 'GET', POST: 'POST'}, HttpDataType: {STRING: 0, ARRAY_BUFFER: 1},
      createHttp: () => ({request(url, requestOptions) {
        const request = {url, options: requestOptions, query: new URL(url).searchParams,
          form: new URLSearchParams(typeof requestOptions.extraData === 'string' ? requestOptions.extraData : '')};
        requests.push(request);
        return options.handler ? options.handler(request) : Promise.resolve(url.includes('/web/view') ?
          response(arrayBuffer(view(grade(), vote({}, {id: '35000000000000019', progress: 10000}),
            link({}, {id: '35000000000000021', progress: 30000})))) : response(JSON.stringify({code: 0, data: {dmidStr: '999'}})));
      }, destroy() {}})}, connection: {}},
  }, globals: {AppStorage: {get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)}}});
  const HttpClient = load('services/network/HttpClient').HttpClient;
  HttpClient.setCookie('buvid3', 'fake-device');
  if (options.loggedIn !== false) {HttpClient.setCookie('SESSDATA', 'fake-account'); HttpClient.setCookie('bili_jct', 'fake-csrf');}
  return {load, requests, HttpClient, API: load('api/VideoInteractionApi').VideoInteractionApi,
    AuthSession: load('services/auth/AuthSession').AuthSession,
    parse: load('common/VideoInteractionProtoCore').decodeVideoInteractionViewBuffer};
}

test('actual view GET, taskpool protobuf and model preserve command IDs, playback windows and card kinds', async () => {
  const f = fixture(), cards = await f.API.load(source), query = f.requests[0].query;
  assert.equal(new URL(f.requests[0].url).pathname, '/x/v2/dm/web/view');
  assert.deepEqual(Object.fromEntries(query), {duration: '0', oid: '200', pid: '100', type: '1', without_subtitle: 'true'});
  assert.deepEqual(cards.map(card => [card.id, card.kind, card.start, card.end]), [
    ['35000000000000017', 'grade', 1.5, 7.5], ['35000000000000019', 'vote', 10, 20], ['35000000000000021', 'link', 30, 35]]);
  assert.equal(cards[0].maxStars, 5); assert.equal(cards[0].averageScore, 8.25);
  assert.deepEqual(cards[1].options.map(option => [option.id, option.text, option.votes, option.hasSelfDef]),
    [[3, '第一项', 4, false], [9, '第二项', 8, false], [12, '其他', 1, true]]);
  assert.equal(cards[2].link.aid, 901); assert.equal(cards[2].link.cover, 'https://i0.hdslb.com/test.jpg');
});

test('protobuf idstr wins over int64, unknown fields are skipped, bad extras and unknown commands are ignored', async () => {
  const f = fixture({handler: () => response(arrayBuffer(view(grade({}, {idstr: '35000000000000999'}),
    command('#UNKNOWN#', {}), command('#GRADE#', '{broken'), command('#GRADE#', []))))});
  assert.deepEqual((await f.API.load(source)).map(card => card.id), ['35000000000000999']);
});

test('server selections restore actual stars and option IDs while malformed option indices are excluded', async () => {
  const f = fixture({handler: () => response(arrayBuffer(view(grade({mid_score: 8}), vote({my_vote: 9,
    options: [{idx: '9', desc: '已选', cnt: 5}, {idx: 0, desc: 'bad'}, {idx: 1.5, desc: 'fraction'},
      {idx: {}, desc: 'object'}, {idx: 9, desc: 'duplicate'}, {idx: 21, desc: '', cnt: Infinity}]}, {id: '19'}))))});
  const cards = await f.API.load(source);
  assert.equal(cards[0].selectedStars, 4); assert.equal(cards[1].selectedOptionId, 9);
  assert.deepEqual(cards[1].options.map(option => option.id), [9]);
  const copy = cards[1].clone(); copy.options[0].votes++; assert.equal(cards[1].options[0].votes, 5);
});

test('link uses official epid navigation and ignores paid classroom destinations', async () => {
  const f = fixture({handler: () => response(arrayBuffer(view(link({aid: 0, bvid: '', epid: 'ep123'}),
    link({arc_type: 2, epid: '456'}, {id: '22'}))))});
  const cards = await f.API.load(source); assert.equal(cards.length, 1); assert.equal(cards[0].link.epId, 123);
});

for (const [name, handler] of Object.entries({
  transport: () => Promise.reject({code: 2300007}), http: () => response(new ArrayBuffer(0), 503),
  json: () => response(arrayBuffer(Buffer.from('{"code":-352,"message":"blocked"}'))),
  html: () => response(arrayBuffer(Buffer.from('<html>blocked</html>'))),
  truncated: () => response(arrayBuffer(Buffer.from([74, 100, 8, 1]))),
})) test('view failure stays an error instead of empty commands (' + name + ')', async () => {
  const f = fixture({handler}); await assert.rejects(f.API.load(source));
});

test('valid view without commands is empty and duration need not be known yet', async () => {
  const f = fixture({handler: () => response(arrayBuffer(view()))});
  assert.deepEqual(await f.API.load({...source, duration: NaN}), []); assert.equal(f.requests[0].query.get('duration'), '0');
});

test('late old-account binary or taskpool results cannot restore selected cards', async () => {
  const pending = deferred(), f = fixture({handler: () => pending.promise});
  const old = f.API.load(source); await tick(); f.AuthSession.advance();
  pending.resolve(response(arrayBuffer(view(grade({mid_score: 10}))))); assert.deepEqual(await old, []);
  const gate = deferred(), g = fixture({decodeGate: gate}); const delayed = g.API.load(source);
  await tick(); g.AuthSession.advance(); gate.resolve(); assert.deepEqual(await delayed, []);
  const parseGate = deferred(), broken = fixture({decodeGate: parseGate,
    handler: () => response(arrayBuffer(Buffer.from('{"code":-352}')))});
  const obsoleteFailure = broken.API.load(source); await tick(); broken.AuthSession.advance(); parseGate.resolve();
  assert.deepEqual(await obsoleteFailure, []);
});

test('actual grade POST sends doubled star score, official progress, source and CSRF', async () => {
  const f = fixture(), card = (await f.API.load(source))[0];
  assert.equal((await f.API.submitGrade(source, card, 3, 3.4)).ok, true);
  const request = f.requests.at(-1);
  assert.equal(new URL(request.url).pathname, '/x/v2/dm/command/grade/post');
  assert.deepEqual(Object.fromEntries(request.form), {aid: '100', cid: '200', progress: '3000',
    grade_id: '91', grade_score: '6', polaris_app_id: '100', polaris_platform: '5', csrf: 'fake-csrf'});
  assert.equal(request.options.header['Cookie'].includes('SESSDATA=fake-account'), true);
});

test('actual vote POST uses option idx, not display order, and precise command id', async () => {
  const f = fixture(), card = (await f.API.load(source))[1];
  assert.equal((await f.API.submitVote(source, card, 9, 12.345)).ok, true);
  const request = f.requests.at(-1);
  assert.equal(new URL(request.url).pathname, '/x/v2/dm/command/vote/post');
  assert.deepEqual(Object.fromEntries(request.form), {aid: '100', cid: '200', progress: '12345',
    vote_id: '92', vote_type: '1', cmd_id_str: '35000000000000019', option_id: '9', has_self_def: '0',
    polaris_app_id: '100', polaris_platform: '5', csrf: 'fake-csrf'});
});

test('out-of-range, already submitted and self-defined choices never write a request', async () => {
  const f = fixture(), cards = await f.API.load(source), count = f.requests.length;
  for (const stars of [0, 6, 2.5, NaN]) assert.equal((await f.API.submitGrade(source, cards[0], stars, 3)).ok, false);
  cards[0].selectedStars = 2; assert.equal((await f.API.submitGrade(source, cards[0], 3, 3)).ok, false);
  for (const id of [1, 12, 3.5, NaN]) assert.equal((await f.API.submitVote(source, cards[1], id, 12)).ok, false);
  cards[1].selectedOptionId = 9; assert.equal((await f.API.submitVote(source, cards[1], 3, 12)).ok, false);
  assert.equal(f.requests.length, count);
});

test('guest submissions stay local and server business failure remains unsuccessful', async () => {
  const guest = fixture({loggedIn: false}), card = (await guest.API.load(source))[0];
  assert.equal((await guest.API.submitGrade(source, card, 2, 3)).ok, false); assert.equal(guest.requests.length, 1);
  const f = fixture({handler: request => request.url.includes('/web/view') ? response(arrayBuffer(view(grade()))) :
    response(JSON.stringify({code: -400, message: '评分已结束'}))});
  const gradeCard = (await f.API.load(source))[0], result = await f.API.submitGrade(source, gradeCard, 2, 3);
  assert.equal(result.ok, false); assert.match(result.message, /评分已结束/); assert.equal(gradeCard.selectedStars, 0);
});
