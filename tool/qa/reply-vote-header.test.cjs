const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');

function fixture(video = false) {
  const rows = [], headers = [], published = [];
  const io = calls => (...args) => {const request = deferred(); calls.push({args, ...request}); return request.promise;};
  const load = createArktsLoader({mocks: {
    'api/CommentApi': {CommentApi: {getReplies: io(rows), loadVoteCard: io(headers)}},
    'common/CommentLog': {CommentLog: {info() {}, warn() {}, elapsed: () => 0, errorText: String}},
  }});
  const {MainRepliesController} = load('components/reply/MainRepliesController');
  const {ReplyRevisionClock, sanitizeReplies} = load('components/reply/ReplyState');
  const {ReplyItem} = load('model/Models');
  const {ReplyVoteCard, ReplyVoteOption} = load('model/reply/ReplyVoteModels');
  const page = {subject: {oid: 1, type: 1}, destroyed: false, state: null};
  const main = new MainRepliesController({getSubject: () => page.subject, isDestroyed: () => page.destroyed,
    publish: state => {page.state = state; published.push(state);}}, new ReplyRevisionClock(() => []), true, video);
  const card = (id = '19160335') => Object.assign(new ReplyVoteCard(), {kind: 'reply', id,
    title: '需不需要再额外补充设定呢', count: 108, loaded: true,
    options: [Object.assign(new ReplyVoteOption(), {id: 1, text: '更多更多！', count: 83}),
      Object.assign(new ReplyVoteOption(), {id: 2, text: '目前够吃啦～', count: 25})]});
  const finish = (i = rows.length - 1, extra = {}) => rows[i].resolve({replies: [], cursor: '', hasMore: false, ...extra});
  return {main, page, rows, headers, published, card, finish, sanitizeReplies, ReplyItem,
    auth: load('services/auth/AuthSession').AuthSession};
}

test('legacy first page publishes comments immediately and merges the independent header metadata', async () => {
  const f = fixture(); const pending = f.main.load(true);
  f.finish(0, {needsVoteCard: true, replies: [Object.assign(new f.ReplyItem(), {rpid: 8, content: 'comment'})],
    cursor: '2', hasMore: true}); await pending;
  assert.equal(f.page.state.loading, false); assert.equal(f.page.state.count, 1);
  assert.equal(f.page.state.voteCard, null); assert.deepEqual(f.headers[0].args, [1, 1]);
  const vote = f.card(); f.headers[0].resolve(vote); await tick();
  assert.equal(f.page.state.voteCard.options.length, 2); assert.equal(f.main.cursor, '2');
  assert.equal(f.page.state.hasMore, true); assert.equal(f.page.state.count, 1);
  assert.notEqual(f.page.state.voteCard, vote); f.page.state.voteCard.options[0].text = 'outside';
  f.main.publish(); assert.equal(f.page.state.voteCard.options[0].text, '更多更多！');
});

test('a header carried by the main response is used without a duplicate request, including an empty comment list', async () => {
  const f = fixture(); const pending = f.main.load(true); f.finish(0, {voteCard: f.card(), needsVoteCard: false});
  await pending; assert.equal(f.headers.length, 0); assert.equal(f.page.state.count, 0);
  assert.equal(f.page.state.voteCard.id, '19160335');
});

test('video prefetch and later pagination cannot discard a slow legacy header or fetch it repeatedly', async () => {
  const f = fixture(true); const pending = f.main.load(true);
  f.finish(0, {needsVoteCard: true, cursor: '2', hasMore: true}); await tick();
  assert.equal(f.rows.length, 2); assert.equal(f.headers.length, 1);
  f.headers[0].resolve(f.card()); await tick();
  f.finish(1, {needsVoteCard: true, cursor: '3', hasMore: false}); await pending;
  assert.ok(f.page.state.voteCard, 'pagination must retain the independently loaded header');
  assert.equal(f.page.state.voteCard.options[1].count, 25); assert.equal(f.headers.length, 1);
});

for (const boundary of ['source', 'type', 'account', 'clear', 'dispose', 'destroy']) {
  test(`a late header response is rejected after ${boundary}`, async () => {
    const f = fixture(); const pending = f.main.load(true); f.finish(0, {needsVoteCard: true}); await pending;
    if (boundary === 'source') f.page.subject.oid++;
    if (boundary === 'type') f.page.subject.type++;
    if (boundary === 'account') f.auth.advance();
    if (boundary === 'clear') f.main.clear();
    if (boundary === 'dispose') f.main.dispose();
    if (boundary === 'destroy') f.page.destroyed = true;
    const before = f.published.length; f.headers[0].resolve(f.card()); await tick();
    assert.equal(f.published.length, before); assert.equal(f.page.state.voteCard, null);
  });
}

test('same-subject refresh and source ABA preserve the latest header ownership', async () => {
  for (const aba of [false, true]) {
    const f = fixture(); const old = f.main.load(true); f.finish(0, {needsVoteCard: true}); await old;
    if (aba) {f.page.subject.oid = 2; const middle = f.main.load(true); f.finish(1); await middle; f.page.subject.oid = 1;}
    const fresh = f.main.load(true); f.finish(f.rows.length - 1, {voteCard: f.card('99')}); await fresh;
    f.headers[0].resolve(f.card('old')); await tick(); assert.equal(f.page.state.voteCard.id, '99');
  }
});

test('metadata failure preserves working comments and first-page retry fetches it again', async () => {
  const f = fixture(); const pending = f.main.load(true); f.finish(0, {needsVoteCard: true}); await pending;
  f.headers[0].reject(Error('offline')); await tick(); assert.equal(f.page.state.failed, false);
  assert.equal(f.page.state.error, ''); const retry = f.main.load(true); f.finish(1, {needsVoteCard: true}); await retry;
  f.headers[1].resolve(f.card()); await tick(); assert.equal(f.page.state.voteCard.count, 108);
});

test('vote-only comments survive sanitation while genuinely empty comments are removed', () => {
  const f = fixture(); const poll = Object.assign(new f.ReplyItem(), {rpid: 8, vote: f.card()});
  const empty = Object.assign(new f.ReplyItem(), {rpid: 9});
  assert.deepEqual(f.sanitizeReplies([poll, empty], false).map(item => item.rpid), [8]);
});

test('the production video reply tab renders its header in the scrolling list with zero or many comments', () => {
  const f = fixture();
  for (const count of [0, 1]) {
    const ui = createNativeComponent('components/video/VideoReplyTab', {props: {voteCard: f.card(), voteOid: 123,
      itemCount: count, source: {getAll: () => []}},
      recordComponents: {
        'components/reply/ReplyVotePanel': ['ReplyVotePanel'], 'components/reply/ReplyCard': ['ReplyCard'],
        'components/reply/ReplyComposer': ['ReplyComposer'], 'components/reply/ReplySortChips': ['ReplySortChips'],
        'components/reply/ReplyEmotePanel': ['ReplyEmotePanel'], 'components/LoadingView': ['LoadingView']},
      mocks: {'components/reply/ReplySubmissionController': {ReplySubmissionController: class {}},
        'common/DynImagePreparer': {}, 'common/Utils': {formatCount: String}},
      globals: {Scroller: class {}, LazyForEach: (source, render) => source.getAll().forEach(render)}});
    ui.build(); const panels = ui.nodes.filter(node => node.type === 'ReplyVotePanel');
    assert.equal(panels.length, 1); assert.equal(panels[0].parent.type, 'ListItem');
    assert.equal(panels[0].parent.parent.type, 'List'); assert.equal(panels[0].args[0].vote.options.length, 2);
    assert.deepEqual(panels[0].args[0].source, {oid: 123, type: 1, rpid: 0, sourceKey: 'header:123'});
    assert.equal(ui.nodes.filter(node => node.type === 'LoadingView').length, count === 0 ? 1 : 0);
  }
});

// Read the page's real closures and component arguments using its TypeScript AST.
// Only UI dependencies are absent; no page-to-controller wiring is rewritten by the fixture.
function pageAst(name) {
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'pages', name + '.ets'), 'utf8').replace(/\bstruct\b/g, 'class');
  return ts.createSourceFile(name + '.ts', source, ts.ScriptTarget.Latest, true);
}
function evaluate(node, ast, page) {
  const code = ts.transpileModule('return (' + node.getText(ast) + ');', {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  return new Function(code).call(page);
}
for (const name of ['VideoDetail', 'BangumiDetail', 'DynamicDetail']) {
  test(`${name}: production publication and component props carry the poll and current subject`, () => {
    const f = fixture(); const ast = pageAst(name); let publish, args;
    function visit(node) {
      if (ts.isPropertyAssignment(node) && node.name.getText(ast) === 'publishMain') publish = node.initializer;
      if (ts.isCallExpression(node) && node.expression.getText(ast) === (name === 'VideoDetail' ? 'VideoReplyTab' : 'ReplyVotePanel')) args = node.arguments[0];
      ts.forEachChild(node, visit);
    }
    visit(ast); assert.ok(publish); assert.ok(args);
    const page = {detail: {aid: 123}, item: {commentId: 456, commentType: 17}, replyOid: () => 789,
      emoteKeyboardHeight: () => 300, replies: {source: {}}};
    evaluate(publish, ast, page)({voteCard: f.card()}); assert.equal(page.replyVoteCard.id, '19160335');
    const props = evaluate(args, ast, page);
    if (name === 'VideoDetail') {assert.equal(props.voteCard, page.replyVoteCard); assert.equal(props.voteOid, 123);}
    else {assert.equal(props.vote, page.replyVoteCard); assert.equal(props.source.rpid, 0);
      assert.equal(props.source.oid, name === 'DynamicDetail' ? 456 : 789);
      assert.equal(props.source.type, name === 'DynamicDetail' ? 17 : 1);}
  });
}
