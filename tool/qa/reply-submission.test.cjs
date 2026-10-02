const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');

function loader(overrides) {
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
      assert.ok(specifier.startsWith('.'), 'unexpected platform boundary: ' + specifier);
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

function fixture(options = {}) {
  const requests = [], notices = [], accepted = [], sending = [];
  const user = {mid: 7, uname: '提交者', face: 'https://face', level: 6};
  const store = {current: user, isLogin: true};
  const page = {alive: true, draft: ' 内容 ', target: {oid: 100, type: 1, root: 20, parent: 21, scope: 'thread', active: true}};
  const load = loader({
    'api/CommentApi': {CommentApi: {addReply(...args) {
      const pending = deferred(); requests.push({args, ...pending}); return pending.promise;
    }}},
    'services/auth/UserStore': {UserStore: store},
    'common/CommentLog': {CommentLog: {info() {}, warn() {}, error() {}}}
  });
  const domain = load('components/reply/ReplySubmissionController');
  const controller = new domain.ReplySubmissionController({
    isAlive: () => page.alive, getTarget: () => page.target, getDraft: () => page.draft,
    setSending: value => sending.push(value), toast: message => notices.push(message),
    onSuccess: (snapshot, reply, clearDraft) => {
      if (options.failPublish) throw Error('UI publish failed');
      accepted.push({snapshot, reply, clearDraft});
      if (clearDraft) page.draft = '';
    }
  });
  return {controller, page, requests, notices, accepted, sending, user, store, domain,
    auth: load('services/auth/AuthSession').AuthSession, ReplyItem: load('model/reply/ReplyModels').ReplyItem};
}
const success = (rpid = 901) => ({ok: true, message: '', data: {rpid}});

test('reply submission: sends a fixed target and trimmed content; normalizes from the captured user', async () => {
  const f = fixture(); const pending = f.controller.send();
  assert.deepEqual(f.requests[0].args, [100, 1, '内容', 20, 21]);
  f.user.uname = '后来的名字'; f.user.face = 'new face'; f.user.level = 1;
  f.requests[0].resolve(success()); await pending;
  const {reply, snapshot, clearDraft} = f.accepted[0];
  assert.deepEqual([reply.oid, reply.type, reply.rootRpid, reply.parentRpid], [100, 1, 20, 21]);
  assert.deepEqual([reply.mid, reply.uname, reply.avatar, reply.level], [7, '提交者', 'https://face', 6]);
  assert.equal(snapshot.content, '内容'); assert.equal(reply.content, '内容');
  assert.equal(clearDraft, true); assert.equal(f.page.draft, '');
  assert.deepEqual(f.sending, [true, false]);
});

test('reply submission: rejects empty, inactive, missing-subject and logged-out sends', async () => {
  for (const change of [f => f.page.draft = ' ', f => f.page.target.active = false,
    f => f.page.target.oid = 0, f => f.page.target.type = 0, f => f.store.isLogin = false,
    f => f.store.current = null, f => f.page.alive = false]) {
    const f = fixture(); change(f); await f.controller.send();
    assert.equal(f.requests.length, 0); assert.deepEqual(f.sending, []);
  }
});

test('reply submission: controller lock prevents duplicate writes', async () => {
  const f = fixture(); const pending = f.controller.send();
  await f.controller.send(); assert.equal(f.requests.length, 1);
  f.requests[0].resolve(success()); await pending;
});

for (const [field, value] of [['oid', 101], ['type', 17], ['root', 30], ['parent', 22], ['scope', 'main'], ['active', false]]) {
  test(`reply submission: a changed ${field} discards the old result and keeps the current draft`, async () => {
    const f = fixture(); const pending = f.controller.send();
    f.page.target[field] = value; f.page.draft = '新目标草稿';
    f.requests[0].resolve(success()); await pending;
    assert.deepEqual(f.accepted, []); assert.deepEqual(f.notices, []);
    assert.equal(f.page.draft, '新目标草稿'); assert.equal(f.sending.at(-1), false);
  });
}

test('reply submission: changing text keeps the next draft while accepting the same-target reply', async () => {
  const f = fixture(); const pending = f.controller.send();
  f.controller.draftChanged(); f.page.draft = '正在写下一条';
  f.requests[0].resolve(success()); await pending;
  assert.equal(f.accepted.length, 1); assert.equal(f.accepted[0].clearDraft, false);
  assert.equal(f.page.draft, '正在写下一条');
});

test('reply submission: edit-away-and-back is still a new draft revision', async () => {
  const f = fixture(); const pending = f.controller.send();
  f.controller.draftChanged(); f.page.draft = '新内容';
  f.controller.draftChanged(); f.page.draft = ' 内容 ';
  f.requests[0].resolve(success()); await pending;
  assert.equal(f.accepted[0].clearDraft, false); assert.equal(f.page.draft, ' 内容 ');
});

test('reply submission: close/reopen of the same root invalidates old requests without unlocking the new send', async () => {
  const f = fixture(); const old = f.controller.send();
  f.controller.reset(); f.page.draft = '重新打开后的输入';
  const fresh = f.controller.send();
  f.requests[0].resolve(success(901)); await old;
  assert.equal(f.sending.at(-1), true);
  assert.deepEqual(f.accepted, []); assert.deepEqual(f.notices, []);
  f.requests[1].resolve(success(902)); await fresh;
  assert.equal(f.accepted.length, 1); assert.equal(f.accepted[0].reply.rpid, 902);
});

test('reply submission: account changes discard success and failure notifications but release the lock', async () => {
  for (const fail of [false, true]) {
    const f = fixture(); const pending = f.controller.send(); f.auth.advance();
    if (fail) f.requests[0].reject(Error('old account')); else f.requests[0].resolve(success());
    await pending;
    assert.deepEqual(f.accepted, []); assert.deepEqual(f.notices, []);
    assert.equal(f.page.draft, ' 内容 '); assert.equal(f.sending.at(-1), false);
    const fresh = f.controller.send(); assert.equal(f.requests.length, 2);
    f.requests[1].resolve(success(902)); await fresh;
    assert.equal(f.accepted.length, 1);
  }
});

test('reply submission: disposal followed by page reuse cannot revive a prior submission', async () => {
  const f = fixture(); const old = f.controller.send();
  f.page.alive = false; f.controller.dispose();
  f.page.alive = true; f.controller.reset(); const count = f.sending.length;
  f.requests[0].resolve(success()); await old;
  assert.deepEqual(f.accepted, []); assert.deepEqual(f.notices, []);
  assert.equal(f.sending.length, count);
});

test('reply submission: business and transport failures keep input and allow retry', async () => {
  const f = fixture(); const first = f.controller.send();
  f.requests[0].resolve({ok: false, message: '评论失败', data: {}}); await first;
  assert.equal(f.page.draft, ' 内容 '); assert.equal(f.notices.at(-1), '评论失败');
  const retry = f.controller.send(); f.requests[1].reject(Error('offline')); await retry;
  assert.equal(f.page.draft, ' 内容 '); assert.equal(f.sending.at(-1), false);
  assert.equal(f.accepted.length, 0); assert.match(f.notices.at(-1), /发送失败/);
});

test('reply submission: a local publish failure never claims the accepted server write failed', async () => {
  const f = fixture({failPublish: true}); const pending = f.controller.send();
  f.requests[0].resolve(success()); await pending;
  assert.equal(f.notices.at(-1), '评论已发送，请刷新查看');
  assert.equal(f.sending.at(-1), false);
});

test('reply normalization: full server metadata wins while missing identity uses the immutable snapshot', async () => {
  const f = fixture();
  const snapshot = new f.domain.ReplySubmissionSnapshot(f.page.target, '原文', f.user, 3, 4, 5, 1700000000);
  f.user.uname = '已变'; f.page.target.root = 99;
  const reply = f.domain.normalizeSentReply({ok: true, data: {reply: {rpid: 600, oid: 999, root: 888,
    member: {mid: 7, uname: '服务器名字', avatar: 'https://server', level_info: {current_level: 5}},
    content: {message: '服务器正文', emote: {'[笑]': {url: 'https://emote'}}}, ctime: 1800000000}}}, snapshot);
  assert.equal(reply.uname, '服务器名字'); assert.equal(reply.content, '服务器正文');
  assert.equal(reply.ctime, 1800000000); assert.equal(reply.emotes.length, 1);
  assert.equal(reply.oid, 100); assert.equal(reply.rootRpid, 20);
  const minimal = f.domain.normalizeSentReply({ok: true, data: {rpid_str: '601', dialog: 30}}, snapshot);
  assert.equal(minimal.uname, '提交者'); assert.equal(minimal.ctime, 1700000000);
  assert.equal(minimal.dialogRpid, 30);
  assert.equal(f.domain.normalizeSentReply({ok: true, data: {}}, snapshot), null);
});

test('reply submission: missing rpid invokes the successful refresh fallback instead of inventing a comment', async () => {
  const f = fixture(); const pending = f.controller.send();
  f.requests[0].resolve({ok: true, data: {}, message: ''}); await pending;
  assert.equal(f.accepted.length, 1); assert.equal(f.accepted[0].reply, null);
  assert.equal(f.accepted[0].clearDraft, true);
});

test('thread merge: rejects a different root, clones state, deduplicates and advances the card revision', () => {
  const f = fixture(); const root = new f.ReplyItem(); root.rpid = 20; root.count = 3; root.rev = 8;
  const sent = new f.ReplyItem(); sent.rpid = 901; sent.rootRpid = 30;
  assert.equal(f.domain.mergeSentThreadReply(root, [], sent), null);
  sent.rootRpid = 20;
  const merged = f.domain.mergeSentThreadReply(root, [], sent);
  assert.equal(root.count, 3); assert.equal(root.replies.length, 0);
  assert.equal(merged.root.count, 4); assert.equal(merged.root.rev, 9);
  assert.deepEqual(merged.replies.map(r => r.rpid), [901]);
  const duplicate = f.domain.mergeSentThreadReply(merged.root, merged.replies, sent);
  assert.equal(duplicate.root.count, 4); assert.equal(duplicate.replies.length, 1);
});
