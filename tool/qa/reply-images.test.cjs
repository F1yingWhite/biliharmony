const test = require('node:test');
const assert = require('node:assert/strict');
const {environment, read, deferred, tick} = require('./dynamic-test-env.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function productionMethods(file, start, end, bindings = {}) {
  const source = read(file), begin = source.indexOf(start), finish = source.indexOf(end, begin);
  assert.ok(begin >= 0 && finish > begin, 'production method boundaries must exist in ' + file);
  const code = ts.transpileModule('export class Harness {\n' + source.slice(begin, finish) + '\n}', {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS},
  }).outputText;
  const module = {exports: {}};
  new Function('module', 'exports', ...Object.keys(bindings), code)(module, module.exports, ...Object.values(bindings));
  return module.exports.Harness;
}

function fixture(options = {}) {
  const requests = [], notices = [], cleaned = [], states = [], accepted = [], sending = [];
  const page = {alive: true, draft: '图文评论', target: {oid: 100, type: 1, root: 0, parent: 0, scope: 'main', active: true}};
  const request = (kind, args) => {
    const pending = deferred(); requests.push({kind, args, ...pending}); return pending.promise;
  };
  const env = environment({
    'api/CommentApi': {CommentApi: {
      uploadReplyImage: (...args) => request('upload', args),
      addReply: (...args) => request('reply', args),
    }},
    'common/DynImagePreparer': {DynImagePreparer: {
      prepare: async (_context, uri) => ({key: uri, cachePath: uri, fileName: uri + '.jpg', mimeType: 'image/jpeg'}),
      readBytes: async () => new ArrayBuffer(3), cleanup: images => cleaned.push(...images.map(image => image.key)),
      ...options.preparer,
    }},
    'services/auth/UserStore': {UserStore: {isLogin: true, current: {mid: 7, uname: '我', face: '', level: 1}}},
    'common/CommentLog': {CommentLog: {info() {}, warn() {}, error() {}}},
  });
  const {ReplySubmissionController} = env.load('components/reply/ReplySubmissionController');
  const controller = new ReplySubmissionController({
    isAlive: () => page.alive, getTarget: () => page.target, getDraft: () => page.draft,
    setImages: images => states.push(images), setSending: value => sending.push(value), toast: value => notices.push(value),
    onSuccess: (snapshot, reply, clearDraft) => {accepted.push({snapshot, reply, clearDraft}); if (clearDraft) page.draft = '';},
  });
  return {controller, page, requests, notices, cleaned, accepted, sending,
    images: () => states.at(-1) || [], auth: env.load('services/auth/AuthSession').AuthSession};
}
const uploaded = key => ({ok: true, picture: {url: 'https://i0.hdslb.com/' + key + '.jpg', width: 640, height: 480}});
const success = {ok: true, message: '', data: {rpid: 900}};

test('reply images: selection appends thumbnails; removal frees only the removed cached image', async () => {
  const f = fixture(); await f.controller.pick({}, async remaining => {assert.equal(remaining, 9); return ['a', 'b'];});
  assert.deepEqual(f.images().map(image => image.key), ['a', 'b']);
  f.controller.removeImage('a'); assert.deepEqual(f.images().map(image => image.key), ['b']);
  assert.deepEqual(f.cleaned, ['a']);
  f.controller.dispose(); assert.deepEqual(f.cleaned, ['a', 'b']);
});

test('reply images: text with images uploads sequentially and clears accepted attachments', async () => {
  const f = fixture(); await f.controller.pick({}, async () => ['a', 'b']);
  const pending = f.controller.send(); await tick();
  assert.equal(f.requests[0].kind, 'upload'); assert.equal(f.requests.length, 1);
  f.requests[0].resolve(uploaded('a')); await tick();
  assert.equal(f.requests[1].kind, 'upload');
  f.requests[1].resolve(uploaded('b')); await tick();
  assert.equal(f.requests[2].kind, 'reply');
  assert.deepEqual(f.requests[2].args, [100, 1, '图文评论', 0, 0, [uploaded('a').picture, uploaded('b').picture]]);
  f.requests[2].resolve(success); await pending;
  assert.deepEqual(f.images(), []); assert.deepEqual(f.cleaned, ['a', 'b']);
  assert.deepEqual(f.accepted[0].reply.pictures, [uploaded('a').picture.url, uploaded('b').picture.url]);
  assert.equal(f.sending.at(-1), false);
});

test('reply images: images without comment text stay in the draft and send no API request', async () => {
  const f = fixture(); f.page.draft = ' '; await f.controller.pick({}, async () => ['a']);
  await f.controller.send(); assert.deepEqual(f.requests, []); assert.equal(f.images().length, 1);
  assert.deepEqual(f.cleaned, []); assert.deepEqual(f.accepted, []);
});

test('reply images: subreply composers cannot open a picture picker', async () => {
  const f = fixture(); f.page.target.root = 20; f.page.target.parent = 20;
  await f.controller.pick({}, async () => {throw Error('subreply must not open the picker');});
  assert.deepEqual(f.images(), []); assert.deepEqual(f.requests, []);
});

test('reply images: upload failure retains both text and image draft and permits retry', async () => {
  const f = fixture(); f.page.draft = '  原草稿  '; await f.controller.pick({}, async () => ['a']);
  const pending = f.controller.send(); await tick();
  f.requests[0].resolve({ok: false, message: '图片上传失败', picture: null}); await pending;
  assert.equal(f.requests.length, 1); assert.equal(f.page.draft, '  原草稿  ');
  assert.equal(f.images()[0].key, 'a'); assert.deepEqual(f.cleaned, []); assert.deepEqual(f.accepted, []);
  assert.equal(f.notices.at(-1), '图片上传失败');
  const retry = f.controller.send(); await tick(); assert.equal(f.requests[1].kind, 'upload');
  f.requests[1].resolve(uploaded('a')); await tick();
  f.requests[2].resolve({ok: false, message: '评论失败', data: {}}); await retry;
  assert.equal(f.images().length, 1); assert.equal(f.page.draft, '  原草稿  '); assert.deepEqual(f.cleaned, []);
});

for (const reason of ['account', 'closed', 'target']) {
  test('reply images: ' + reason + ' change during upload prevents the subsequent comment write', async () => {
    const f = fixture(); await f.controller.pick({}, async () => ['a']);
    const pending = f.controller.send(); await tick();
    if (reason === 'account') f.auth.advance();
    else if (reason === 'closed') {f.page.alive = false; f.controller.dispose();}
    else f.page.target.oid = 101;
    f.requests[0].resolve(uploaded('a')); await pending;
    assert.equal(f.requests.length, 1); assert.deepEqual(f.accepted, []); assert.deepEqual(f.notices, []);
  });
}

test('reply images: account change during cached file read does not start an upload', async () => {
  const reading = deferred(), f = fixture({preparer: {readBytes: () => reading.promise}});
  await f.controller.pick({}, async () => ['a']); const pending = f.controller.send();
  f.auth.advance(); reading.resolve(new ArrayBuffer(2)); await pending;
  assert.deepEqual(f.requests, []); assert.deepEqual(f.accepted, []);
});

test('reply images: a late picker result after reset releases resources without changing the new draft', async () => {
  const preparing = deferred(), f = fixture({preparer: {prepare: () => preparing.promise}});
  const pending = f.controller.pick({}, async () => ['a']); await tick();
  f.controller.reset(); preparing.resolve({key: 'a', cachePath: 'a'}); await pending;
  assert.deepEqual(f.images(), []); assert.deepEqual(f.cleaned, ['a']);
});

test('reply images: no editing attachments or duplicate operation while uploading', async () => {
  const f = fixture(); await f.controller.pick({}, async () => ['a']);
  const pending = f.controller.send(); await tick();
  f.controller.removeImage('a'); await f.controller.pick({}, async () => {throw Error('must stay locked');});
  await f.controller.send(); assert.equal(f.images().length, 1); assert.equal(f.requests.length, 1);
  f.requests[0].resolve({ok: false, message: 'retry', picture: null}); await pending;
});

test('reply composer: real picker, remove and preview methods share the page transaction', async () => {
  const selected = [], f = fixture();
  const Harness = productionMethods('components/reply/ReplyComposer', '  private hasContent()',
    '  private onFocusTick()', {picker: {PhotoViewMIMETypes: {IMAGE_TYPE: 'image/*'}, PhotoViewPicker: class {
      async select(options) {selected.push(options); return {photoUris: ['a', 'b']};}
    }}});
  const view = new Harness(); Object.assign(view, {text: '', images: [], sending: false, submission: f.controller,
    allowImages: true, getUIContext: () => ({getHostContext: () => ({})}), previewOpen: false, previewIndex: 0});
  assert.equal(view.hasContent(), false); view.pickImages(); await tick();
  assert.deepEqual(selected, [{MIMEType: 'image/*', maxSelectNumber: 9}]);
  view.images = f.images(); assert.equal(view.hasContent(), false);
  view.text = '说明'; assert.equal(view.hasContent(), true);
  view.previewImage(1); assert.equal(view.previewOpen, true); assert.equal(view.previewIndex, 1);
  view.removeImage('a'); assert.deepEqual(f.images().map(image => image.key), ['b']);
  view.sending = true; view.removeImage('b'); view.pickImages(); await tick();
  assert.equal(f.images().length, 1); assert.equal(selected.length, 1);
});

test('reply images: selecting a video subreply through the real page method clears main-comment attachments', async () => {
  const f = fixture(); await f.controller.pick({}, async () => ['a']);
  const Harness = productionMethods('pages/VideoDetail', '  private selectReplyForComposer(',
    '  @Builder\n  VideoThreadEmotePanel()', {CommentLog: {info() {}}});
  const view = new Harness(); Object.assign(view, {replySubmit: f.controller, findReplyItem: () => null,
    replies: {updateThreadRoot() {}}, replyFocusTick: 0});
  Object.defineProperty(view, 'replyTargetRootRpid', {set: value => f.page.target.root = value});
  Object.defineProperty(view, 'replyTargetRpid', {set: value => f.page.target.parent = value});
  view.selectReplyForComposer({rpid: 20, uname: '楼主'});
  assert.deepEqual(f.images(), []); assert.deepEqual(f.cleaned, ['a']);
  const pending = f.controller.send(); assert.equal(f.requests[0].kind, 'reply');
  assert.deepEqual(f.requests[0].args, [100, 1, '图文评论', 20, 20]);
  f.requests[0].resolve(success); await pending;
});

for (const [page, start, end] of [
  ['VideoDetail', '  async sendReply()', '  private applySubmittedReply('],
  ['DynamicDetail', '  private async sendReply()', '  build()'],
  ['BangumiDetail', '  private async sendReply()', '  private introMeta()'],
]) {
  test('reply images: real ' + page + ' send guard requires comment text even with images', async () => {
    const Harness = productionMethods('pages/' + page, start, end, {
      UserStore: {isLogin: true}, AppNavStack: {pushPathByName() {throw Error('must not navigate');}}, NAV_LOGIN: 'login',
    });
    let sends = 0; const view = new Harness();
    Object.assign(view, {replyDraft: ' ', replyImages: [{key: 'a'}], replySending: false, ensureLogin: () => true,
      replySubmit: {async send() {sends++;}}});
    await view.sendReply(); assert.equal(sends, 0);
    view.replyDraft = '说明'; await view.sendReply(); assert.equal(sends, 1);
    view.replyImages = []; view.replyDraft = ' '; await view.sendReply(); assert.equal(sends, 1);
  });
}
