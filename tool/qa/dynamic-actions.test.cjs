// Production DynCard action/lifecycle methods, model defaults, AuthSession and feed writeback.
// Controlled API promises and ArkUI's prop rebinding/prompt boundary make races deterministic.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
function read(file) {
  const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, file + '.ets');
  return fs.readFileSync(override && fs.existsSync(override) ? override : path.join(root, file + '.ets'), 'utf8')
    .replace(/\r\n/g, '\n');
}
function section(source, start, end) {
  const first = source.indexOf(start), last = source.indexOf(end, first);
  assert.ok(first >= 0 && last > first, 'production anchors: ' + start + ' -> ' + end);
  return source.slice(first, last);
}
function compile(source, globals = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
  } }).outputText;
  new Function('module', 'exports', ...Object.keys(globals), code)(module, module.exports, ...Object.values(globals));
  return module.exports;
}
function fixture() {
  const source = read('views/DynamicView');
  const { AuthSession } = compile(read('services/auth/AuthSession'));
  const { BasicDataSource } = compile(read('common/BasicDataSource'));
  // Parsing a server response is outside this test; use the production model's actual field initializers.
  const { DynamicItem } = compile(section(read('model/dynamic/DynamicModels'), 'export class DynamicItem {', '  static from(') + '\n}');
  const notices = [], requests = [];
  const pending = (kind, args) => {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    requests.push({ kind, args, resolve, reject });
    return promise;
  };
  const DynamicApi = {
    likeDynamic: (...args) => pending('like', args), repostDynamic: (...args) => pending('forward', args),
    getDynamicDetail() { throw Error('plain-text action fixture should not fetch rich emotes'); },
  };
  const prelude = section(source, 'class DynamicContentPart {', '/** 单条动态卡片');
  const cardCode = section(source, 'export struct DynCard {', '  /** 宫格单元边长')
    .replace('export struct DynCard', 'export class Card')
    .replace(/@(?:State|Prop|StorageProp|Watch)\s*(?:\([^)]*\))?\s*/g, '');
  const { Card } = compile(prelude + cardCode + '\n}', { AuthSession, DynamicItem, DynamicApi,
    UserStore: { isLogin: true }, EmoteResolver: { ensureLoaded() {} } });
  const { Feed } = compile('export class Feed {\n' +
    section(source, '  private handleLikeResult(', '  /** 并行拉取') + '\n}', { BasicDataSource });
  const item = (liked, like, dynId = 'same') => Object.assign(new DynamicItem(), { dynId, liked, like });
  function feed(liked, like) {
    const view = new Feed(); view.dynSource = new BasicDataSource();
    view.dynSource.reset([item(liked, like)]);
    const cached = new BasicDataSource(); cached.reset([item(liked, like)]);
    view.typeSources = new Map([['video', cached]]);
    const callbacks = [];
    return { view, callbacks, cached, callback: (...args) => { callbacks.push(args); view.handleLikeResult(...args); } };
  }
  const origin = feed(true, 20), destination = feed(false, 19), card = new Card();
  card.getUIContext = () => ({ getPromptAction: () => ({ showToast: ({ message }) => notices.push(message) }) });
  // Model the native @Prop copy when a LazyForEach row is mounted/rebound.
  card.item = item(true, 20); card.onLikeResult = origin.callback; card.aboutToAppear();
  function reuse(liked = false, like = 19, callback = destination.callback) {
    card.aboutToReuse({ item: item(liked, like), onLikeResult: callback });
  }
  return { card, AuthSession, origin, destination, requests, notices, reuse, item };
}

for (const result of ['failure', 'success', 'rejection']) {
  test(`late dynamic like ${result} from a replaced account cannot change its same-id card or feed`, async () => {
    const f = fixture(), old = f.card.toggleLike();
    assert.equal(f.card.liked, false, 'first account optimistically unlikes');
    f.AuthSession.advance(); f.reuse();
    if (result === 'rejection') f.requests[0].reject(Error('old account offline'));
    else f.requests[0].resolve({ ok: result === 'success', message: 'old account result' });
    await old;
    assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like], [false, 19, false, 19]);
    assert.equal(f.destination.view.dynSource.getData(0).liked, false);
    assert.deepEqual(f.origin.callbacks, []); assert.deepEqual(f.destination.callbacks, []);
    assert.deepEqual(f.notices, []); assert.equal(f.card.actionBusy, false);
  });
}

test('an account change without prop rebinding releases the completed request own busy flag while ignoring its result', async () => {
  for (const action of ['toggleLike', 'forwardDynamic']) {
    for (const outcome of ['failure', 'success', 'rejection']) {
      const f = fixture(), pending = f.card[action]();
      const originalItem = f.card.item;
      const expected = [f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like, f.card.forwardCount];
      f.AuthSession.advance();
      if (outcome === 'rejection') f.requests[0].reject(Error('old account offline'));
      else f.requests[0].resolve({ ok: outcome === 'success', message: 'old account result' });
      await pending;
      assert.equal(f.card.item, originalItem, 'no native rebind/disappear has occurred yet');
      assert.equal(f.card.actionBusy, false, action + '/' + outcome + ': the completed request must release its own lock');
      assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like, f.card.forwardCount], expected);
      assert.deepEqual(f.origin.callbacks, []); assert.deepEqual(f.destination.callbacks, []);
      assert.deepEqual(f.notices, []);
    }
  }
});

test('same-id reuse: an old like failure and finally cannot roll back or unlock a newer action', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.reuse(false, 50);
  const current = f.card.toggleLike();
  assert.equal(f.requests.length, 2); assert.equal(f.card.actionBusy, true);
  f.requests[0].resolve({ ok: false, message: 'first request failed' }); await old;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.like], [true, 51, 51]);
  assert.equal(f.card.actionBusy, true); assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.equal(f.card.actionBusy, false); assert.deepEqual(f.destination.callbacks, [['same', true, 51]]);
});

test('same account late success writes the originating callback and all its cached categories after reuse', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.reuse(false, 50);
  const current = f.card.toggleLike();
  f.requests[0].resolve({ ok: true }); await old;
  assert.deepEqual(f.origin.callbacks, [['same', false, 19]]);
  assert.deepEqual([f.origin.view.dynSource.getData(0).liked, f.origin.cached.getData(0).liked], [false, false]);
  assert.deepEqual(f.destination.callbacks, [], 'the reused card callback belongs to its new host');
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [true, 51, true]);
  assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.deepEqual(f.destination.callbacks, [['same', true, 51]]);
  assert.equal(f.card.actionBusy, false);
});

test('prop rebinding invalidates an old like failure even when the dynamic id is unchanged', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.card.item = f.item(false, 60); f.card.onItemChanged();
  const current = f.card.toggleLike();
  assert.equal(f.requests.length, 2, 'rebinding must release the old row action lock');
  f.requests[0].reject(Error('old row offline')); await old;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [true, 61, true]);
  assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.equal(f.card.actionBusy, false);
});

test('a disappeared like row can update its same-account feed but cannot show a stale toast or mutate its old UI', async () => {
  const f = fixture(), old = f.card.toggleLike();
  f.card.aboutToDisappear();
  assert.equal(f.card.actionBusy, false);
  f.requests[0].resolve({ ok: true }); await old;
  assert.deepEqual(f.origin.callbacks, [['same', false, 19]]);
  assert.deepEqual(f.notices, []);
});

test('current like failures still roll back, show the error and allow retry; success commits once', async () => {
  const f = fixture(), failed = f.card.toggleLike();
  f.requests[0].resolve({ ok: false, message: 'server refused' }); await failed;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.item.liked, f.card.item.like], [true, 20, true, 20]);
  assert.equal(f.card.actionBusy, false); assert.deepEqual(f.notices, ['server refused']);
  const success = f.card.toggleLike();
  await f.card.toggleLike(); assert.equal(f.requests.length, 2, 'busy guard blocks a duplicate request');
  f.requests[1].resolve({ ok: true }); await success;
  assert.deepEqual(f.origin.callbacks, [['same', false, 19]]);
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [false, 19, false]);
});

test('an optimistic field-change watch on the same item does not invalidate or unlock its own request', async () => {
  const f = fixture(), current = f.card.toggleLike();
  f.card.onItemChanged(); // ArkUI @Watch may run for the optimistic item.liked/item.like writes.
  assert.equal(f.card.actionBusy, true);
  await f.card.toggleLike(); assert.equal(f.requests.length, 1);
  f.requests[0].resolve({ ok: false, message: 'server refused' }); await current;
  assert.deepEqual([f.card.liked, f.card.likeCount, f.card.actionBusy], [true, 20, false]);
  assert.deepEqual(f.notices, ['server refused']);
});

test('an old forward result cannot mutate a reused card or unlock its pending like request', async () => {
  const f = fixture(), old = f.card.forwardDynamic();
  f.reuse(false, 50); const current = f.card.toggleLike();
  f.requests[0].resolve({ ok: true }); await old;
  assert.equal(f.card.forwardCount, 0); assert.equal(f.card.item.forward, 0);
  assert.equal(f.card.actionBusy, true); assert.deepEqual(f.notices, []);
  f.requests[1].resolve({ ok: true }); await current;
  assert.equal(f.card.actionBusy, false);
});
