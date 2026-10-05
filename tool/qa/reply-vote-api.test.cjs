const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');
const protocol = require('./fixtures/reply-vote-protocol.json');
const clone = value => JSON.parse(JSON.stringify(value));
const response = (body, status = 200) => ({responseCode: status,
  result: typeof body === 'string' ? body : JSON.stringify(body), header: {}, cookies: ''});
const source = {oid: 116380644941208, type: 1, rpid: 0, sourceKey: 'video:BV1r6QcBvEqt'};

function fixture(options = {}) {
  const storage = new Map(), requests = [], signCalls = [];
  const load = createArktsLoader({mocks: {
    'common/WbiSign': {WbiSign: {async encWbi(params) {signCalls.push({...params}); params.w_rid = 'fake-wbi';}, invalidate() {}}},
    'common/AppSign': {},
    'services/auth/CookieRefresher': {CookieRefresher: {onAuthFailure() {}}},
    'services/auth/UserStore': {UserStore: {current: options.guest ? null : {mid: options.mid || 42}, isLogin: !options.guest}},
    '@kit.NetworkKit': {http: {RequestMethod: {GET: 'GET', POST: 'POST'}, HttpDataType: {STRING: 0, ARRAY_BUFFER: 1},
      createHttp: () => ({request(url, requestOptions) {
        const request = {url, options: requestOptions, path: new URL(url).pathname, query: new URL(url).searchParams,
          form: new URLSearchParams(typeof requestOptions.extraData === 'string' ? requestOptions.extraData : '')};
        requests.push(request);
        return Promise.resolve(options.handler ? options.handler(request) : response(protocol.headerInfo));
      }, destroy() {}})}, connection: {}},
    '@kit.ArkTS': {taskpool: {execute: (fn, ...args) => Promise.resolve(fn(...args))}},
  }, globals: {AppStorage: {get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)}}});
  const HttpClient = load('services/network/HttpClient').HttpClient;
  HttpClient.setCookie('buvid3', 'fake-device');
  if (!options.guest) {HttpClient.setCookie('SESSDATA', 'fake-account'); HttpClient.setCookie('bili_jct', 'fake-csrf');}
  const models = load('model/reply/ReplyVoteModels');
  return {load, requests, signCalls, HttpClient, ...models,
    AuthSession: load('services/auth/AuthSession').AuthSession,
    API: load('api/ReplyVoteApi').ReplyVoteApi};
}

function active(f, kind = 'dynamic', overrides = {}) {
  const raw = clone(protocol.multi.data.vote_info);
  Object.assign(raw, {end_time: Math.floor(Date.now() / 1000) + 3600,
    options: [{opt_idx: 3, opt_desc: '第一项', cnt: 5}, {opt_idx: 9, opt_desc: '第二项', cnt: 8}], ...overrides});
  return f.ReplyVoteCard.fromDynamic(raw, [], kind);
}

test('actual comment content and top-level metadata retain separate identities, choices, and clone state', () => {
  const f = fixture(), {ReplyItem, ReplyData} = f.load('model/reply/ReplyModels');
  const item = ReplyItem.from({rpid: 225825672672, content: {message: '', vote: protocol.contentVote}});
  assert.equal(item.vote.id, '11936440'); assert.equal(item.vote.kind, 'dynamic');
  assert.equal(item.vote.loaded, false); assert.equal(item.vote.count, 1156);
  const copied = item.clone(); copied.vote.title = 'changed'; assert.notEqual(item.vote.title, copied.vote.title);
  const header = ReplyData.from(protocol.header.data);
  assert.equal(header.voteCard.id, '19160335'); assert.equal(header.voteCard.kind, 'reply');
  assert.deepEqual(header.voteCard.options.map(o => [o.id, o.text, o.count]), [[1, '更多更多！', 83], [2, '目前够吃啦～', 25]]);
  assert.equal(header.needsVoteCard, false); assert.equal(header.voteCard.maxSelect, 1);
  assert.equal(ReplyData.fromLegacy({replies: []}, 1).needsVoteCard, true);
  assert.equal(ReplyData.fromLegacy({replies: []}, 2).needsVoteCard, false);
  assert.equal(ReplyData.fromLegacy(protocol.header.data, 1).needsVoteCard, false);
  const many = f.ReplyVoteCard.fromReplyCard({vote_id: 3, options: [1, 2, 3].map(idx => ({idx, desc: String(idx)}))});
  assert.equal(many.kind, 'dynamic'); assert.equal(many.maxSelect, 0, 'non-duel comments use the H5 choice_cnt');
});

test('public primary fixtures load seven options, multi-choice and expired results without credentials', async () => {
  const f = fixture({guest: true, handler: request => response(request.query.get('vote_id') === '11936440' ? protocol.single : protocol.multi)});
  const one = await f.API.load(f.ReplyVoteCard.fromContent(protocol.contentVote));
  assert.deepEqual(one.options.map(o => o.count), [52, 70, 406, 101, 21, 31, 477]);
  assert.equal(one.maxSelect, 1); assert.equal(one.ended, true); assert.equal(one.loaded, true);
  assert.deepEqual(one.selectedIds, []);
  const ref = f.ReplyVoteCard.fromContent({id: 15591912, title: 'multi'}), two = await f.API.load(ref);
  assert.equal(two.maxSelect, 2); assert.equal(two.options.length, 2); assert.equal(two.count, 1580);
  assert.equal(two.options.reduce((sum, o) => sum + o.count, 0), 1623, 'multi-choice counts differ from participants');
  assert.equal(f.requests[0].path, '/x/vote/vote_info');
  assert.equal(f.requests[0].query.get('vote_id'), '11936440');
  assert.equal(f.requests.every(r => !(r.options.header.Cookie || '').includes('SESSDATA')), true);
});

test('legacy header enrichment reads /main vote_card and fallback signs only after a failed main response', async () => {
  const f = fixture({handler: () => response(protocol.header)}), card = await f.API.loadHeader(source.oid, source.type);
  assert.equal(card.id, '19160335'); assert.equal(f.requests[0].path, '/x/v2/reply/main');
  assert.equal(f.requests[0].query.get('oid'), String(source.oid));
  assert.equal(f.requests[0].query.get('pagination_str'), '{"offset":""}');
  assert.equal(f.signCalls.length, 0);
  const fallback = fixture({handler: request => response(request.path.endsWith('/wbi/main') ? protocol.header : {code: -352})});
  assert.equal((await fallback.API.loadHeader(source.oid, 1)).id, '19160335');
  assert.equal(fallback.signCalls.length, 1); assert.equal(fallback.requests.at(-1).query.get('w_rid'), 'fake-wbi');
  const noPoll = fixture({handler: () => response({code: 0, data: {replies: []}})});
  assert.equal(await noPoll.API.loadHeader(source.oid, 1), null);
});

test('dynamic response restores exact option IDs, image URLs and account selections instead of array positions', async () => {
  const raw = clone(protocol.multi); raw.data.my_votes = [9, 9, 999];
  raw.data.vote_info.options = [{opt_idx: 3, opt_desc: 'A', cnt: 2}, {opt_idx: '9', opt_desc: 'B', cnt: 4, img_url: '//i0.hdslb.com/test.jpg'},
    {opt_idx: 0, opt_desc: 'bad'}, {opt_idx: 3, opt_desc: 'duplicate'}];
  const f = fixture({handler: () => response(raw)}), detail = await f.API.load(f.ReplyVoteCard.fromContent({id: 15591912}));
  assert.deepEqual(detail.options.map(o => o.id), [3, 9]); assert.deepEqual(detail.selectedIds, [9]);
  assert.equal(detail.options[1].imageUrl, 'https://i0.hdslb.com/test.jpg');
  const copy = detail.clone(); copy.options[1].count = 999; copy.selectedIds.push(3);
  assert.equal(detail.options[1].count, 4); assert.deepEqual(detail.selectedIds, [9]);
});

test('precise decimal IDs survive metadata but rounded numeric IDs and malformed cards are rejected', async () => {
  const f = fixture();
  assert.equal(f.ReplyVoteCard.fromContent({id: '35000000000000017'}).id, '35000000000000017');
  for (const id of [0, -1, 1.5, {}, '01', '1e3', 35000000000000017]) assert.equal(f.ReplyVoteCard.fromContent({id}), null);
  for (const value of [null, [], {vote_id: 1, options: {}}, {vote_id: 1, options: [{idx: 1, desc: 'alone'}]}]) {
    assert.equal(f.ReplyVoteCard.fromReplyCard(value), null);
  }
  const card = active(f); card.id = '35000000000000017';
  assert.equal((await f.API.submit(source, card, [3])).ok, false); assert.equal(f.requests.length, 0);
});

for (const [name, handler] of Object.entries({
  transport: () => Promise.reject({code: 2300007}), http: () => response({}, 503),
  business: () => response({code: -400, message: '投票不存在'}), malformed: () => response('{broken'),
  schema: () => response({code: 0, data: {vote_info: {vote_id: 19160335, options: {}}}}),
  wrongId: () => response(protocol.multi),
})) test('actual vote GET failure stays an error and never becomes a submit-ready empty model: ' + name, async () => {
  const f = fixture({handler}), card = f.ReplyVoteCard.fromReplyCard(protocol.header.data.vote_card);
  await assert.rejects(f.API.load(card));
});

test('dynamic JSON POST sends actual selected IDs and current voter, CSRF, no share or fabricated counts', async () => {
  let returned;
  const f = fixture({handler: request => {
    const raw = clone(protocol.multi.data.vote_info);
    Object.assign(raw, {end_time: Math.floor(Date.now() / 1000) + 3600, my_votes: [3, 9], join_num: 29,
      options: [{opt_idx: 3, opt_desc: '第一项', cnt: 10}, {opt_idx: 9, opt_desc: '第二项', cnt: 25}]});
    returned = raw; return response({code: 0, data: {vote_info: raw}});
  }}), card = active(f);
  const result = await f.API.submit(source, card, [3, 9]);
  assert.equal(result.ok, true); assert.deepEqual(result.card.selectedIds, [3, 9]);
  assert.deepEqual(result.card.options.map(o => o.count), [10, 25]); assert.equal(result.card.count, 29);
  const request = f.requests[0]; assert.equal(request.path, '/x/vote/do_vote');
  assert.equal(request.query.get('csrf'), 'fake-csrf');
  assert.equal(request.options.header['Content-Type'], 'application/json');
  assert.deepEqual(JSON.parse(request.options.extraData), {vote_id: 15591912, votes: [3, 9], voter_uid: 42, status: 0, op_bit: 0, dynamic_id: 0});
  assert.equal(f.requests.length, 1); assert.deepEqual(card.options.map(o => o.count), [5, 8]); assert.deepEqual(card.selectedIds, []);
});

test('comment-section POST uses reply vote form with header rpid0, then loads actual server results', async () => {
  let submitted = false;
  const f = fixture({handler: request => {
    if (request.options.method === 'POST') {submitted = true; return response({code: 0, data: {}});}
    const raw = clone(protocol.headerInfo);
    if (submitted) {raw.data.my_votes = [2]; raw.data.vote_info.join_num = 211; raw.data.vote_info.options[1].cnt = 128;}
    return response(raw);
  }}), card = await f.API.load(f.ReplyVoteCard.fromReplyCard(protocol.header.data.vote_card));
  const result = await f.API.submit(source, card, [2]);
  assert.equal(result.ok, true); assert.deepEqual(result.card.selectedIds, [2]); assert.equal(result.card.count, 211);
  assert.deepEqual(result.card.options.map(o => o.count), [83, 128]);
  const post = f.requests.find(r => r.options.method === 'POST'); assert.equal(post.path, '/x/v2/reply/vote/do');
  assert.deepEqual(Object.fromEntries(post.form), {option: '2', vote_id: '19160335', oid: String(source.oid), type: '1', csrf: 'fake-csrf'});
  assert.equal(post.form.has('rpid'), false); assert.equal(f.requests.at(-1).path, '/x/vote/vote_info');
});

test('explicitly deleted content metadata stays disabled and cannot be restored by a details reload', async () => {
  const f = fixture(), card = f.ReplyVoteCard.fromContent({...protocol.contentVote, deleted: true});
  assert.equal(card.deleted, true); assert.equal(card.clone().deleted, true);
  assert.equal((await f.API.load(card)).deleted, true);
  assert.equal((await f.API.submit(source, card, [1])).ok, false);
  assert.equal(f.requests.length, 0);
});

test('successful writes remain confirmed when result reload fails or lags, failures stay retryable', async () => {
  const f = fixture({handler: request => request.options.method === 'POST' ? response({code: 0}) : response({}, 503)});
  const result = await f.API.submit(source, active(f, 'reply'), [9]);
  assert.equal(result.ok, true); assert.equal(result.card, null); assert.match(result.message, /暂未刷新/);
  assert.equal(f.requests.filter(r => r.options.method === 'POST').length, 1);
  const lag = fixture({handler: request => request.options.method === 'POST' ? response({code: 0}) : response(protocol.multi)});
  const lagged = await lag.API.submit(source, active(lag), [9]); assert.equal(lagged.ok, true);
  assert.deepEqual(lagged.card.selectedIds, []); assert.deepEqual(lagged.card.options.map(o => o.count), [306, 1317]);
  const denied = fixture({handler: () => response({code: -400, message: '不可投票'})});
  const card = active(denied), failure = await denied.API.submit(source, card, [9]);
  assert.equal(failure.ok, false); assert.match(failure.message, /不可投票/); assert.deepEqual(card.selectedIds, []);
});

test('invalid choices, unfinished metadata, closed polls, duplicate participation and creators never POST', async () => {
  const f = fixture(), card = active(f);
  for (const ids of [[], [1], [3, 3], [3, 9, 12], [3.5], [NaN]]) assert.equal((await f.API.submit(source, card, ids)).ok, false);
  for (const change of [{loaded: false}, {ended: true}, {deleted: true}, {selectedIds: [3]},
    {endTime: 1}, {endTime: 0}, {maxSelect: 0}, {publisherMid: 42}]) {
    const changed = card.clone(); Object.assign(changed, change);
    assert.equal((await f.API.submit(source, changed, [3])).ok, false);
  }
  assert.equal((await f.API.submit({...source, oid: 1.5}, card, [3])).ok, false);
  const single = active(f, 'reply'); assert.equal((await f.API.submit(source, single, [3, 9])).ok, false);
  assert.equal(f.requests.length, 0);
  const guest = fixture({guest: true}); assert.equal((await guest.API.submit(source, active(guest), [3])).ok, false);
  assert.equal(guest.requests.length, 0);
});

test('old-account header, detail, POST or post-success result cannot leak into the new account', async () => {
  const pending = deferred(), f = fixture({handler: () => pending.promise});
  const get = f.API.load(f.ReplyVoteCard.fromContent({id: 15591912})); await tick(); f.AuthSession.advance();
  pending.resolve(response(protocol.multi)); await assert.rejects(get, /账号已切换/);
  const gate = deferred(), header = fixture({handler: () => gate.promise});
  const oldHeader = header.API.loadHeader(source.oid, 1); await tick(); header.AuthSession.advance();
  gate.resolve(response(protocol.header)); await assert.rejects(oldHeader, /账号已切换/);
  const postGate = deferred(), writing = fixture({handler: () => postGate.promise});
  const oldPost = writing.API.submit(source, active(writing), [3]); await tick(); writing.AuthSession.advance();
  postGate.resolve(response({code: 0, data: {}})); assert.equal((await oldPost).ok, false);
  assert.equal(writing.requests.length, 1, 'old-account success must not issue a new-account GET');
  const reloadGate = deferred(), refreshing = fixture({handler: request => request.options.method === 'POST' ? response({code: 0}) : reloadGate.promise});
  const oldReload = refreshing.API.submit(source, active(refreshing, 'reply'), [9]); await tick(); await tick();
  refreshing.AuthSession.advance(); reloadGate.resolve(response(protocol.multi)); assert.equal((await oldReload).ok, false);
});

function controller(f, card) {
  const sourceState = {source, card, states: []};
  const {ReplyVoteController} = f.load('components/reply/ReplyVoteController');
  const value = new ReplyVoteController({isDestroyed: () => false, getSource: () => sourceState.source,
    getVote: () => sourceState.card, applyState: state => sourceState.states.push(state), toast() {}});
  value.bind(source, card);
  return {value, state: () => sourceState.states.at(-1)};
}

test('complete native HTTP → API → controller chain renders all seven real answers and routes a second-answer header vote', async () => {
  let voted = false;
  const f = fixture({handler: request => {
    if (request.options.method === 'POST') {voted = true; return response({code: 0, data: {}});}
    if (request.query.get('vote_id') === '11936440') return response(protocol.single);
    const raw = clone(protocol.headerInfo);
    if (voted) {raw.data.my_votes = [2]; raw.data.vote_info.join_num = 150; raw.data.vote_info.options[1].cnt = 67;}
    return response(raw);
  }});
  const seven = controller(f, f.ReplyVoteCard.fromContent(protocol.contentVote)); await seven.value.load();
  assert.equal(seven.state().detail.options.length, 7); assert.equal(seven.state().resultsVisible, true);
  assert.equal(seven.value.toggle(2), false, 'real expired poll permits reading results only');
  const header = controller(f, f.ReplyVoteCard.fromReplyCard(protocol.header.data.vote_card)); await header.value.load();
  assert.equal(header.value.toggle(2), true); assert.equal(await header.value.submit(), true);
  assert.deepEqual(header.state().detail.options.map(o => o.count), [83, 67]);
  assert.deepEqual(header.state().detail.selectedIds, [2]); assert.equal(header.state().resultsVisible, true);
  const count = f.requests.length; assert.equal(await header.value.submit(), false); assert.equal(f.requests.length, count);
});

test('whole native chain confirms a dynamic multi-choice write even when server-result refresh fails', async () => {
  let wrote = false;
  const f = fixture({handler: request => {
    if (request.options.method === 'POST') {wrote = true; return response({code: 0});}
    if (wrote) return response({}, 503);
    const raw = clone(protocol.multi); raw.data.vote_info.end_time = Math.floor(Date.now() / 1000) + 3600;
    return response(raw);
  }}), ui = controller(f, f.ReplyVoteCard.fromContent({id: 15591912}));
  await ui.value.load(); assert.equal(ui.state().detail.maxSelect, 2);
  assert.equal(ui.value.toggle(1), true); assert.equal(ui.value.toggle(2), true);
  assert.equal(await ui.value.submit(), true); assert.deepEqual(ui.state().detail.selectedIds, [1, 2]);
  assert.deepEqual(ui.state().detail.options.map(o => o.count), [306, 1317], 'refresh failure never fabricates counts');
  await ui.value.load(); assert.match(ui.state().message, /已投票.*刷新失败/);
  assert.equal(ui.value.toggle(1), false); assert.equal(await ui.value.submit(), false);
  assert.equal(f.requests.filter(r => r.options.method === 'POST').length, 1);
});
