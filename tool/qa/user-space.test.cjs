const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');

// Execute complete controllers/models; only API and platform inputs are replaced.
function loader(overrides = {}) {
  const cache = new Map();
  function load(name) {
    if (Object.hasOwn(overrides, name)) return overrides[name];
    if (cache.has(name)) return cache.get(name).exports;
    const module = {exports: {}};
    cache.set(name, module);
    const code = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
      compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
    }).outputText;
    new Function('require', 'module', 'exports', code)(specifier => {
      assert.ok(specifier.startsWith('.'), 'unexpected platform dependency: ' + specifier);
      return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), specifier)));
    }, module, module.exports);
    return module.exports;
  }
  return load;
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
}
const video = aid => ({aid, bvid: 'BV' + aid});

function feedFixture() {
  const requests = [], states = [];
  const load = loader({'api/UserApi': {UserApi: {
    getUserSpaceArcs(mid, page, order) {
      const request = deferred(); requests.push({mid, page, order, ...request}); return request.promise;
    }
  }}});
  const {UserSpaceFeedController} = load('components/user/UserSpaceFeedController');
  const feed = new UserSpaceFeedController(state => states.push(state));
  feed.activate(123);
  return {feed, requests, states, state: () => states.at(-1), auth: load('services/auth/AuthSession').AuthSession};
}

test('user space: sorting supersedes an in-flight first page and owns its loading state', async () => {
  const f = feedFixture();
  const old = f.feed.load(true);
  const fresh = f.feed.changeOrder('click');
  assert.deepEqual(f.requests.map(r => [r.page, r.order]), [[1, 'pubdate'], [1, 'click']]);
  f.requests[0].resolve({total: 20, videos: [video(1)]}); await old;
  assert.equal(f.state().loading, true);
  assert.equal(f.feed.source.totalCount(), 0);
  f.requests[1].resolve({total: 20, videos: [video(2)]}); await fresh;
  assert.equal(f.state().order, 'click');
  assert.equal(f.state().loading, false);
  assert.deepEqual(f.feed.source.getAll().map(v => v.aid), [2]);
});

test('user space: changed sort clears old rows and ignores stale page failures', async () => {
  const f = feedFixture();
  const initial = f.feed.load(true);
  f.requests[0].resolve({total: 30, videos: [video(1)]}); await initial;
  const page = f.feed.load(false);
  const sort = f.feed.changeOrder('stow');
  assert.equal(f.feed.source.totalCount(), 0);
  f.requests[1].reject(Error('old page failed')); await page;
  assert.equal(f.state().loading, true);
  assert.equal(f.state().error, '');
  f.requests[2].resolve({total: 1, videos: [video(3)]}); await sort;
  assert.equal(f.state().hasMore, false);
  assert.deepEqual(f.feed.source.getAll().map(v => v.aid), [3]);
});

test('user space: failed pagination keeps its cursor and retry deduplicates the page boundary', async () => {
  const f = feedFixture();
  const initial = f.feed.load(true);
  f.requests[0].resolve({total: 3, videos: [video(1)]}); await initial;
  const next = f.feed.retry();
  assert.equal(f.requests[1].page, 2, 'footer after success requests the next page');
  f.requests[1].reject(Error('offline')); await next;
  assert.equal(f.state().error, 'offline');
  assert.equal(f.state().hasMore, true);
  const retry = f.feed.retry();
  assert.equal(f.requests[2].page, 2);
  f.requests[2].resolve({total: 3, videos: [video(1), video(2), video(2)]}); await retry;
  assert.deepEqual(f.feed.source.getAll().map(v => v.aid), [1, 2]);
  assert.equal(f.state().error, '');
  const last = f.feed.load(false);
  f.requests[3].resolve({total: 3, videos: []}); await last;
  assert.equal(f.state().hasMore, false, 'an empty terminal page must not trigger an endless request loop');
});

test('user space: refresh replaces pagination; failure preserves old content and retries page one', async () => {
  const f = feedFixture();
  const first = f.feed.load(true);
  f.requests[0].resolve({total: 9, videos: [video(1)]}); await first;
  const page = f.feed.load(false);
  const reset = f.feed.load(true);
  f.requests[1].resolve({total: 9, videos: [video(2)]}); await page;
  assert.equal(f.state().loading, true);
  f.requests[2].reject(Error('failed refresh')); await reset;
  assert.deepEqual(f.feed.source.getAll().map(v => v.aid), [1]);
  const retry = f.feed.retry();
  assert.equal(f.requests[3].page, 1);
  f.requests[3].resolve({total: 1, videos: [video(3)]}); await retry;
  assert.deepEqual(f.feed.source.getAll().map(v => v.aid), [3]);
});

test('user space: leaving and reopening invalidate pending requests, including their finalizers', async () => {
  const f = feedFixture();
  const old = f.feed.load(true);
  f.feed.dispose();
  const afterDispose = f.states.length;
  f.requests[0].reject(Error('late')); await old;
  assert.equal(f.states.length, afterDispose);
  f.feed.activate(456);
  const newer = f.feed.load(true);
  assert.equal(f.requests[1].mid, 456);
  f.requests[1].resolve({total: 1, videos: [video(4)]}); await newer;
  assert.deepEqual(f.feed.source.getAll().map(v => v.aid), [4]);
});

test('user space: account changes discard old responses and start a fresh first page', async () => {
  const f = feedFixture();
  const old = f.feed.load(true);
  f.auth.advance();
  const fresh = f.feed.load(false);
  assert.equal(f.requests[1].page, 1);
  f.requests[0].resolve({total: 20, videos: [video(1)]}); await old;
  assert.equal(f.state().loading, true);
  f.requests[1].resolve({total: 1, videos: [video(2)]}); await fresh;
  assert.deepEqual(f.feed.source.getAll().map(v => v.aid), [2]);
});

function groupsFixture() {
  const calls = {load: [], create: [], rename: [], remove: [], save: []};
  function call(kind, args) {
    const pending = deferred(); calls[kind].push({args, ...pending}); return pending.promise;
  }
  const load = loader({'api/UserApi': {UserApi: {
    getFollowTags: () => call('load', []), createFollowTag: name => call('create', [name]),
    renameFollowTag: (...args) => call('rename', args), deleteFollowTag: (...args) => call('remove', args),
    addToFollowTags: (...args) => call('save', args)
  }}});
  const states = [], notices = [];
  const {FollowGroupController} = load('components/user/FollowGroupController');
  const groups = new FollowGroupController(state => states.push(state), message => notices.push(message));
  async function open(mid = 123) {
    const pending = groups.open(mid);
    calls.load.at(-1).resolve([{tagid: 1, name: '一', count: 2}, {tagid: 2, name: '二', count: 3}]);
    await pending;
  }
  return {groups, calls, states, notices, open, state: () => states.at(-1), auth: load('services/auth/AuthSession').AuthSession};
}

test('follow groups: loading and failed loads cannot submit an empty selection; successful empty lists can', async () => {
  const f = groupsFixture();
  const initial = f.groups.open(123);
  await f.groups.save();
  assert.equal(f.calls.save.length, 0);
  f.calls.load[0].reject(Error('network failure')); await initial;
  assert.equal(f.state().error, 'network failure');
  await f.groups.save(); assert.equal(f.calls.save.length, 0);
  const retry = f.groups.retryLoad();
  f.calls.load[1].resolve([]); await retry;
  const saved = f.groups.save();
  assert.deepEqual(f.calls.save[0].args, [123, []]);
  f.calls.save[0].resolve({ok: true, message: ''}); await saved;
  assert.equal(f.state().open, false);
});

test('follow groups: save freezes a private selection snapshot and failure retains the form', async () => {
  const f = groupsFixture(); await f.open();
  f.groups.toggle(1);
  const published = f.state();
  published.checked.push(999);
  published.tags[0].name = 'external mutation';
  const saving = f.groups.save();
  f.groups.toggle(2); f.groups.setNewName('must not mutate');
  await f.groups.save();
  assert.equal(f.calls.save.length, 1);
  assert.deepEqual(f.calls.save[0].args, [123, [1]]);
  assert.equal(f.state().tags[0].name, '一');
  f.calls.save[0].resolve({ok: false, message: '保存失败'}); await saving;
  assert.equal(f.state().open, true);
  assert.equal(f.state().busy, false);
  assert.deepEqual(f.state().checked, [1]);
  assert.equal(f.state().newName, '');
  assert.deepEqual(f.notices, ['保存失败']);
  const retry = f.groups.save();
  f.calls.save[1].resolve({ok: true, message: ''}); await retry;
  assert.equal(f.state().open, false);
  assert.equal(f.notices.at(-1), '分组已保存');
});

test('follow groups: network errors retain selections and release the busy lock', async () => {
  const f = groupsFixture(); await f.open(); f.groups.toggle(2);
  const pending = f.groups.save(); f.calls.save[0].reject(Error('offline')); await pending;
  assert.equal(f.state().open, true);
  assert.equal(f.state().busy, false);
  assert.deepEqual(f.state().checked, [2]);
  assert.match(f.notices.at(-1), /失败/);
});

test('follow groups: a closed submission cannot close or modify a newer editor', async () => {
  const f = groupsFixture(); await f.open();
  const session = f.groups.sessionVersion;
  f.groups.toggle(1);
  const old = f.groups.save();
  f.groups.close(); await f.open(456); f.groups.toggle(2);
  assert.equal(f.groups.isSessionCurrent(session), false, 'old native menus must be ignored too');
  f.calls.save[0].resolve({ok: true, message: ''}); await old;
  assert.equal(f.state().open, true);
  assert.deepEqual(f.state().checked, [2]);
  assert.deepEqual(f.notices, []);
});

test('follow groups: leaving and changing accounts discard mutation results', async () => {
  for (const transition of ['dispose', 'account']) {
    const f = groupsFixture(); await f.open();
    f.groups.setNewName('新增'); const pending = f.groups.create();
    const count = f.states.length;
    if (transition === 'dispose') f.groups.dispose(); else f.auth.advance();
    f.calls.create[0].resolve(7); await pending;
    assert.equal(f.states.length, count);
    assert.deepEqual(f.notices, []);
    await f.groups.save(); assert.equal(f.calls.save.length, 0);
    await f.open(456); assert.equal(f.state().busy, false);
  }
});

test('follow groups: old load completion cannot clear a newer loading state', async () => {
  const f = groupsFixture();
  const old = f.groups.open(123); const fresh = f.groups.open(456);
  f.calls.load[0].resolve([{tagid: 99, name: 'old', count: 0}]); await old;
  assert.equal(f.state().loading, true); assert.deepEqual(f.state().tags, []);
  f.calls.load[1].resolve([]); await fresh; assert.equal(f.state().loading, false);
});

test('follow groups: create, rename and delete preserve drafts on failure and update only after success', async () => {
  const f = groupsFixture(); await f.open();
  f.groups.setNewName('新分组');
  const failedCreate = f.groups.create(); f.calls.create[0].resolve(0); await failedCreate;
  assert.equal(f.state().newName, '新分组'); assert.equal(f.state().busy, false);
  const create = f.groups.create(); f.calls.create[1].resolve(3); await create;
  assert.deepEqual(f.state().checked, [3]); assert.equal(f.state().newName, '');
  f.groups.beginRename(f.state().tags[2]); f.groups.setRenameDraft('重命名');
  const renameFail = f.groups.rename(); f.calls.rename[0].resolve({ok: false, message: '失败'}); await renameFail;
  assert.equal(f.state().renameDraft, '重命名'); assert.equal(f.state().tags[2].name, '新分组');
  const rename = f.groups.rename(); f.calls.rename[1].resolve({ok: true, message: '成功'}); await rename;
  assert.equal(f.state().tags[2].name, '重命名'); assert.equal(f.state().renameId, 0);
  const removeFail = f.groups.remove(3); f.calls.remove[0].reject(Error('offline')); await removeFail;
  assert.deepEqual(f.state().checked, [3]); assert.equal(f.state().tags.length, 3);
  const remove = f.groups.remove(3); f.calls.remove[1].resolve({ok: true, message: '成功'}); await remove;
  assert.deepEqual(f.state().checked, []); assert.deepEqual(f.state().tags.map(t => t.tagid), [1, 2]);
});

function apiFixture() {
  let response;
  const overrides = {
    'services/network/HttpClient': {RequestPriority: {LOW: 1}, HttpClient: {
      get: async () => response,
      buildQuery: params => new URLSearchParams(params).toString(), merge: (a, b) => ({...a, ...b})
    }},
    'common/AppSign': {appSign() {}},
    'common/WbiSign': {WbiSign: {encWbi: async () => {}, invalidate() {}}},
    'services/auth/CookieRefresher': {CookieRefresher: {onAuthFailure() {}}}
  };
  const load = loader(overrides);
  const {HttpResponse} = load('services/network/HttpResponse');
  const {UserApi} = load('api/UserApi');
  return {api: UserApi, respond(payload, status = 200) {response = new HttpResponse(status, JSON.stringify(payload), {});}};
}

test('user API: space archives distinguish successful emptiness, failures and malformed responses', async () => {
  const f = apiFixture();
  f.respond({code: 0, data: {page: {count: 0}, list: {vlist: []}}});
  assert.deepEqual((await f.api.getUserSpaceArcs(1, 1, 'pubdate')).videos, []);
  for (const [payload, status] of [[{code: -101, message: '需登录'}, 200], [{}, 503],
    [{code: 0, data: {}}, 200], [{code: 0, data: {page: {count: 1}, list: {vlist: {}}}}, 200]]) {
    f.respond(payload, status);
    await assert.rejects(f.api.getUserSpaceArcs(1, 1, 'pubdate'));
  }
});

test('user API: follow groups parse direct and legacy arrays while rejecting failures', async () => {
  const f = apiFixture();
  for (const data of [[{tagid: 2, name: '收藏', count: 3}], {data: [{tagid: 2, name: '收藏', count: 3}]}]) {
    f.respond({code: 0, data});
    const tags = await f.api.getFollowTags();
    assert.equal(tags.length, 1); assert.equal(tags[0].tagid, 2); assert.equal(tags[0].name, '收藏');
  }
  f.respond({code: 0, data: []}); assert.deepEqual(await f.api.getFollowTags(), []);
  for (const [payload, status] of [[{code: -101, message: '需登录'}, 200], [{}, 503],
    [{code: 0, data: {}}, 200], [{code: 0}, 200]]) {
    f.respond(payload, status); await assert.rejects(f.api.getFollowTags());
  }
});
