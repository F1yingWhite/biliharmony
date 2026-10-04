const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

// Execute the page's production hooks so a wrong option at the UI/domain
// boundary cannot be hidden by hand-selecting a corrected test option.
function productionReactionHooks(kind, controller) {
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const pageFile = kind === 'dynamic' ? 'DynamicDetail.ets' : 'BangumiDetail.ets';
  const source = fs.readFileSync(path.join(root, 'pages', pageFile), 'utf8');
  const start = source.indexOf('  private replyReactionHooks(');
  const end = source.indexOf(kind === 'dynamic' ? '  private async likeReply(' : '  private closeReplyThread(', start);
  assert.ok(start >= 0 && end > start, 'production reaction hooks are present in ' + pageFile);
  const code = ts.transpileModule('class PageHarness {\n' + source.slice(start, end) + '\n}; return PageHarness;', {
    compilerOptions: {target: ts.ScriptTarget.ES2020}
  }).outputText;
  const PageHarness = new Function('UserStore', 'AppNavStack', 'NAV_LOGIN', code)(
    {isLogin: true}, {pushPathByName() {}}, 'login');
  const page = new PageHarness();
  Object.assign(page, {replies: controller, item: {commentId: 1, commentType: 17},
    ensureReplyLogin: () => true, toast() {}, replyOid: () => 1});
  return page.replyReactionHooks(true);
}

function fixture(kind = 'dynamic') {
  const requests = [], threads = [], reactions = [], logs = [];
  const fetch = calls => (...args) => {const d = deferred(); calls.push({args, ...d}); return d.promise;};
  const page = {destroyed: false, subject: {oid: 1, type: kind === 'dynamic' ? 17 : 1},
    main: null, thread: null, loaded: 0, sorts: 0, threadErrors: 0, shareDisposals: 0};
  const load = createArktsLoader({mocks: {
    'common/DynImagePreparer': {DynImagePreparer: {cleanup() {}}},
    'api/BiliApi': {BiliApi: {}},
    'api/CommentApi': {CommentApi: {getReplies: fetch(requests), getReplyReplies: fetch(threads),
      likeReply: fetch(reactions), hateReply: fetch(reactions)}},
    'common/CommentLog': {CommentLog: {info: (...args) => logs.push(args), warn: (...args) => logs.push(args),
      error: (...args) => logs.push(args), elapsed: () => 0, errorText: error => String(error)}},
    'services/auth/UserStore': {UserStore: {current: null, isLogin: false}}
  }});
  const {RepliesController} = load('components/reply/RepliesController');
  const controller = new RepliesController({
    isDestroyed: () => page.destroyed, getSubject: () => page.subject,
    publishMain: state => page.main = state, publishThread: state => page.thread = state,
    afterMainLoaded: () => page.loaded++, onThreadError: () => page.threadErrors++, onSortApplied: () => page.sorts++
  }, {clearOnSort: kind !== 'dynamic', video: kind === 'video'}, {dispose: () => page.shareDisposals++});
  const {ReplyItem} = load('model/Models');
  const item = (rpid, extra = {}) => Object.assign(new ReplyItem(), {rpid, content: 'reply ' + rpid}, extra);
  const finish = (request, replies = [], cursor = '', hasMore = false) => request.resolve({replies, cursor, hasMore});
  async function seed(replies = [item(1)], cursor = 'next', hasMore = true) {
    const pending = controller.load(true); finish(requests.at(-1), replies, cursor, hasMore);
    // Video prefetch is intentionally satisfied by a full first screen when pagination is needed.
    await pending;
  }
  return {controller, page, item, finish, seed, requests, threads, reactions, logs, load,
    auth: load('services/auth/AuthSession').AuthSession};
}

for (const kind of ['video', 'dynamic', 'bangumi']) {
  test(`${kind}: a new root supersedes the old thread response and finalizer`, async () => {
    const f = fixture(kind); f.controller.beginThread(f.item(100, {count: 2}), []);
    const old = f.controller.loadThread(true, false);
    f.controller.beginThread(f.item(200, {count: 2}), []); const fresh = f.controller.loadThread(true, false);
    f.finish(f.threads[0], [f.item(101, {rootRpid: 100})], 'old'); await old;
    assert.equal(f.page.thread.loading, true); assert.equal(f.page.thread.root.rpid, 200);
    f.finish(f.threads[1], [f.item(201, {rootRpid: 200})], 'new'); await fresh;
    assert.deepEqual(f.page.thread.replies.map(item => item.rpid), [201]); assert.equal(f.page.thread.loading, false);
  });

  test(`${kind}: fresh server replies outrank local mutation revisions in every visible location`, async () => {
    const f = fixture(kind); const original = f.item(11, {like: 5}); await f.seed([original], '', false);
    const firstRev = f.controller.source.getData(0).rev;
    f.controller.beginThread(original.clone(), [original.clone()]);
    f.controller.mutate(11, item => {item.liked = true; item.like = 6;});
    const localRev = f.controller.source.getData(0).rev;
    assert.equal(localRev, firstRev + 1); assert.equal(f.page.thread.root.liked, true);
    assert.equal(f.page.thread.replies[0].liked, true);
    const pending = f.controller.load(true); f.finish(f.requests.at(-1), [f.item(11, {liked: true, like: 6})]); await pending;
    const updated = f.controller.source.getData(0);
    assert.equal(updated.liked, true); assert.ok(updated.rev > localRev);
  });

  test(`${kind}: failed pagination keeps visible rows and retries exactly the same cursor`, async () => {
    const f = fixture(kind); const rows = Array.from({length: kind === 'video' ? 20 : 1}, (_, i) => f.item(i + 1));
    await f.seed(rows); const failed = f.controller.load(false); f.requests.at(-1).reject(Error('offline')); await failed;
    assert.equal(f.page.main.moreFailed, true); assert.equal(f.page.main.failed, false);
    assert.equal(f.controller.getReplyCursor(), 'next'); assert.equal(f.controller.source.totalCount(), rows.length);
    const retry = f.controller.load(false); f.finish(f.requests.at(-1), [f.item(99)], 'end'); await retry;
    assert.deepEqual(f.requests.slice(-2).map(x => x.args[2]), ['next', 'next']);
    assert.equal(f.page.main.moreFailed, false); assert.equal(f.page.main.hasMore, false);
  });

  test(`${kind}: sorting supersedes an in-flight page and preserves the page-specific reset strategy`, async () => {
    const f = fixture(kind); const rows = Array.from({length: kind === 'video' ? 20 : 1}, (_, i) => f.item(i + 1));
    await f.seed(rows); const old = f.controller.load(false); f.controller.changeReplySort(2);
    assert.equal(f.controller.source.totalCount(), kind === 'dynamic' ? rows.length : 0);
    f.requests.at(-2).reject(Error('old')); await old;
    assert.equal(f.page.main.loading, true); assert.equal(f.page.main.error, '');
    f.finish(f.requests.at(-1), [f.item(100)], 'new'); await tick();
    assert.deepEqual(f.controller.source.getAll().map(x => x.rpid), [100]);
    assert.equal(f.page.main.sort, 2); assert.equal(f.page.sorts, 1);
  });
}

test('dynamic sort failure preserves old rows and retries the requested first page instead of its old cursor', async () => {
  const f = fixture(); await f.seed([f.item(9)], 'old', false); f.controller.changeReplySort(2);
  f.requests.at(-1).reject(Error('offline')); await tick();
  assert.equal(f.controller.source.getData(0).rpid, 9); assert.equal(f.controller.getReplyCursor(), 'old');
  assert.equal(f.controller.getRepliesRetryReset(), true); assert.equal(f.page.main.moreFailed, true);
  const retry = f.controller.load(f.controller.getRepliesRetryReset()); f.finish(f.requests.at(-1), [f.item(10)], 'new'); await retry;
  assert.deepEqual(f.requests.slice(-2).map(x => [x.args[2], x.args[3]]), [['', 2], ['', 2]]);
  assert.equal(f.controller.source.getData(0).rpid, 10);
});

test('episode/subject changes reset the source and reject old content, cursor and errors', async () => {
  const f = fixture('bangumi'); const old = f.controller.load(true);
  f.page.subject.oid = 2; f.controller.changeReplySort(2);
  f.finish(f.requests[0], [f.item(11)], 'old'); await old;
  assert.equal(f.page.main.loading, true); assert.equal(f.controller.source.totalCount(), 0);
  f.finish(f.requests[1], [f.item(22)], 'new'); await tick();
  assert.deepEqual(f.requests.map(x => [x.args[0], x.args[3]]), [[1, 3], [2, 2]]);
  assert.equal(f.controller.source.getData(0).rpid, 22); assert.equal(f.controller.getReplyCursor(), 'new');
});

test('main auth/target changes reject responses even before lifecycle watchers start another request', async () => {
  for (const change of [f => f.auth.advance(), f => f.page.subject.type++, f => f.page.subject.oid++]) {
    const f = fixture(); const pending = f.controller.load(true); change(f);
    f.finish(f.requests[0], [f.item(11)]); await pending;
    assert.equal(f.controller.source.totalCount(), 0); assert.equal(f.page.loaded, 0);
  }
});

test('close and reopen of the same root blocks late success, failure and lock release', async () => {
  const f = fixture(); f.controller.beginThread(f.item(1), []); const old = f.controller.loadThread(true);
  f.controller.cancelThread(); f.controller.beginThread(f.item(1), []); const fresh = f.controller.loadThread(true);
  f.threads[0].reject(Error('old')); await old; assert.equal(f.page.thread.loading, true); assert.equal(f.page.threadErrors, 0);
  f.finish(f.threads[1], [f.item(2)]); await fresh; assert.equal(f.page.thread.loading, false);
});

test('thread account/type changes and disposal suppress stale notifications and continuation', async () => {
  for (const change of [f => f.auth.advance(), f => f.page.subject.type++, f => f.controller.dispose()]) {
    const f = fixture(); f.controller.beginThread(f.item(1), []); const pending = f.controller.loadThread(true); change(f);
    f.threads[0].reject(Error('old')); await pending;
    assert.equal(f.page.threadErrors, 0); assert.equal(f.page.thread.replies.length, 0);
  }
});

test('video sanitizes all pages, retains unindexed sent comments and adopts complete server objects', async () => {
  const f = fixture('video'); await f.seed([], '', false);
  const sent = f.item(7, {uname: 'local'}); f.controller.addSentMain(sent);
  const pending = f.controller.load(true);
  f.finish(f.requests.at(-1), [f.item(0), f.item(2), f.item(2), f.item(3, {content: ''})]); await pending;
  assert.deepEqual(f.controller.source.getAll().map(x => x.rpid), [7, 2]);
  const indexed = f.controller.load(true); f.finish(f.requests.at(-1), [f.item(7, {uname: 'server'}), f.item(2)]); await indexed;
  assert.equal(f.controller.source.getData(0).uname, 'server');
  f.controller.removeMain(7); const refresh = f.controller.load(true); f.finish(f.requests.at(-1), []); await refresh;
  assert.equal(f.controller.source.totalCount(), 0);
});

test('sent replies synchronize root count/revision and previews without double insertion', async () => {
  const f = fixture('video'); const root = f.item(1, {count: 0}); await f.seed([root], '', false);
  f.controller.beginThread(root, []); const sent = f.item(2, {rootRpid: 1, parentRpid: 1});
  f.controller.addSentThread(sent); f.controller.addSentThread(sent);
  assert.equal(f.page.thread.root.count, 1); assert.equal(f.page.thread.replies.length, 1);
  assert.equal(f.controller.source.getData(0).count, 1); assert.ok(f.page.thread.root.rev > 0);
  const next = f.item(3, {rootRpid: 1, parentRpid: 2}); f.controller.addSentInline(next, 1);
  assert.equal(f.controller.source.getData(0).count, 2); assert.equal(f.page.thread.root.count, 2);
});

test('video first screen and thread prefetch are bounded at five additional pages and preserve logs', async () => {
  const f = fixture('video'); const main = f.controller.load(true);
  for (let i = 0; i < 6; i++) {f.finish(f.requests[i], [f.item(i + 1)], String(i), true); await tick();}
  await main; assert.equal(f.requests.length, 6); assert.equal(f.controller.source.totalCount(), 6);
  f.controller.beginThread(f.item(50, {count: 30}), []); const thread = f.controller.loadThread(true);
  for (let i = 0; i < 6; i++) {f.finish(f.threads[i], [f.item(i + 60)], String(i), true); await tick();}
  await thread; assert.equal(f.threads.length, 6);
  assert.equal(f.logs.filter(x => x[0] === 'ui.replies.prefetch').length, 5);
  assert.equal(f.logs.filter(x => x[0] === 'ui.thread.prefetch').length, 5);
});

test('video thread refresh replaces preview objects and empty results preserve previews; deletion prunes descendants', async () => {
  const f = fixture('video'); f.controller.beginThread(f.item(1), [f.item(2, {uname: 'preview'}),
    f.item(3, {parentRpid: 2}), f.item(4, {parentRpid: 3})]);
  const pending = f.controller.loadThread(true, false); f.finish(f.threads[0], [f.item(2, {uname: 'complete'})]); await pending;
  assert.equal(f.page.thread.replies[0].uname, 'complete'); assert.equal(f.page.thread.replies.length, 3);
  const empty = f.controller.loadThread(true, false); f.finish(f.threads[1], []); await empty;
  assert.equal(f.page.thread.replies.length, 3); f.controller.removeThread(2, true); assert.equal(f.page.thread.replies.length, 0);
});

test('published arrays cannot mutate the controller and disposal invalidates both lists and sharing', async () => {
  const f = fixture(); f.controller.beginThread(f.item(1), [f.item(2)]);
  f.page.thread.replies.push(f.item(99)); assert.equal(f.controller.thread.replies.length, 1);
  const main = f.controller.load(true), thread = f.controller.loadThread(true);
  f.controller.dispose(); f.page.destroyed = true; f.page.destroyed = false;
  f.finish(f.requests[0], [f.item(3)]); f.finish(f.threads[0], [f.item(4)]); await Promise.all([main, thread]);
  assert.equal(f.controller.source.totalCount(), 0); assert.equal(f.controller.thread.replies[0].rpid, 2);
  assert.equal(f.page.shareDisposals, 1); assert.equal(f.page.main.loading, false); assert.equal(f.page.thread.loading, false);
});

test('shared root references receive each mutation once and locally sent snapshots retain the update on refresh', async () => {
  const f = fixture('video'); await f.seed([], '', false);
  const same = f.item(7, {like: 5}); f.controller.addSentMain(same); f.controller.beginThread(same, [same]);
  f.controller.mutate(7, item => item.like++);
  assert.equal(f.controller.source.getData(0).like, 6); assert.equal(f.page.thread.root.like, 6);
  assert.equal(f.page.thread.replies[0].like, 6); assert.equal(same.like, 5);
  const pending = f.controller.load(true); f.finish(f.requests.at(-1), []); await pending;
  assert.equal(f.controller.source.getData(0).like, 6);
});

for (const action of ['runReplyLike', 'runReplyDislike']) {
  test(`${action}: captured lifecycle guard prevents an old account rollback into refreshed comments`, async () => {
    const f = fixture(); await f.seed([f.item(1, {like: 5})], '', false);
    const current = f.controller.captureGuard(), notices = [];
    const pending = f.load('common/ReplyMutation')[action](f.controller.source.getData(0), new Set(),
      (rpid, mutate) => f.controller.mutate(rpid, mutate), {ensureLogin: () => true,
        isDestroyed: () => !current(), toast: text => notices.push(text), clearDislikeOnLike: true,
        resolveOid: () => 1, resolveType: () => 17});
    await tick(); f.auth.advance(); f.controller.dispose();
    await f.seed([f.item(1, {liked: true, like: 10})], '', false);
    f.reactions[0].resolve({ok: false, message: 'old failure'}); await pending;
    assert.equal(f.controller.source.getData(0).like, 10); assert.equal(f.controller.source.getData(0).liked, true);
    assert.deepEqual(notices, []);
    const reused = f.controller.captureGuard(); f.controller.dispose(); assert.equal(reused(), false);
  });
}

for (const kind of ['dynamic', 'bangumi']) {
  test(`${kind}: production page hooks keep dislike then like mutually exclusive`, async () => {
    const f = fixture(kind); await f.seed([f.item(10, {like: 1})], '', false);
    f.controller.beginThread(f.controller.source.getData(0).clone(), []);
    const {runReplyLike, runReplyDislike} = f.load('common/ReplyMutation');
    const busy = new Set(), hooks = productionReactionHooks(kind, f.controller);
    const mutate = (rpid, operation) => f.controller.mutate(rpid, operation);
    const down = runReplyDislike(f.controller.source.getData(0).clone(), busy, mutate, hooks);
    await tick(); f.reactions.at(-1).resolve({ok: true}); await down;
    assert.deepEqual([f.controller.source.getData(0).liked, f.controller.source.getData(0).disliked], [false, true]);

    // ReplyCard immediately clears its visual dislike before invoking the page.
    // The authoritative controller state must preserve that mutual exclusion.
    const clicked = f.controller.source.getData(0).clone();
    clicked.liked = true; clicked.disliked = false; clicked.like++;
    const up = runReplyLike(clicked, busy, mutate, hooks);
    await tick(); f.reactions.at(-1).resolve({ok: true}); await up;
    const main = f.controller.source.getData(0), threadRoot = f.controller.thread.root;
    assert.deepEqual([main.liked, main.disliked, main.like], [true, false, 2]);
    assert.deepEqual([threadRoot.liked, threadRoot.disliked, threadRoot.like], [true, false, 2]);
  });
}

test('thread results started before a send retain the new reply until server indexing catches up', async () => {
  const f = fixture(); f.controller.beginThread(f.item(1), []);
  const old = f.controller.loadThread(true); f.controller.addSentThread(f.item(8, {rootRpid: 1, uname: 'local'}));
  f.finish(f.threads[0], [f.item(2, {rootRpid: 1})]); await old;
  assert.deepEqual(f.page.thread.replies.map(item => item.rpid), [8, 2]);
  const indexed = f.controller.loadThread(true); f.finish(f.threads[1], [f.item(8, {rootRpid: 1, uname: 'server'})]); await indexed;
  assert.equal(f.page.thread.replies.length, 1); assert.equal(f.page.thread.replies[0].uname, 'server');
});
