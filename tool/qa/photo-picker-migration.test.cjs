const test = require('node:test');
const assert = require('node:assert/strict');
const {environment, read, deferred, tick} = require('./dynamic-test-env.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function fixture(kind) {
  const pending = deferred(), prepared = [], selected = [], states = [], notices = [], timers = [];
  const env = environment({
    'api/DynamicApi': {DynamicApi: {}},
    'api/CommentApi': {CommentApi: {}},
    'common/DynImagePreparer': {DynImagePreparer: {
      prepare: async (_context, uri) => {prepared.push(uri); return {key: uri, cachePath: uri};}, cleanup() {},
    }},
    'services/auth/UserStore': {UserStore: {isLogin: true, current: {mid: 7, uname: '我'}}},
    'common/CommentLog': {CommentLog: {info() {}, warn() {}, error() {}}},
  }, {setTimeout: callback => {timers.push(callback); return timers.length;}});
  let controller;
  if (kind === 'dynamic') {
    const {DynamicComposerController} = env.load('components/dynamic/DynamicComposerController');
    controller = new DynamicComposerController(() => {}, message => notices.push(message));
    controller.attach(state => states.push(state));
  } else {
    const {ReplySubmissionController} = env.load('components/reply/ReplySubmissionController');
    controller = new ReplySubmissionController({isAlive: () => true,
      getTarget: () => ({oid: 100, type: 1, root: 0, parent: 0, scope: 'main', active: true}),
      getDraft: () => '草稿', setImages: images => states.push(images), setSending() {},
      toast: message => notices.push(message), onSuccess() {},
    });
  }
  const source = read('components/' + (kind === 'dynamic' ? 'dynamic/DynamicComposer' : 'reply/ReplyComposer'));
  const first = source.indexOf('  private pickImages():'), last = source.indexOf(kind === 'dynamic' ? '  build()' : '  private removeImage(', first);
  assert.ok(first >= 0 && last > first, 'real composer picker method');
  const code = ts.transpileModule('class Harness {\n' + source.slice(first, last) + '\n}; return Harness;', {
    compilerOptions: {target: ts.ScriptTarget.ES2020},
  }).outputText;
  const {PhotoPickerHandoff} = env.load('common/PhotoPickerHandoff');
  const Harness = new Function('photoAccessHelper', 'PhotoPickerHandoff', code)({PhotoViewMIMETypes: {IMAGE_TYPE: 'image/*'},
    PhotoViewPicker: class {
      constructor(...args) {assert.deepEqual(args, [], 'public SDK picker constructor has no Context argument');}
      select(options) {selected.push(options); return pending.promise;}
    },
  }, PhotoPickerHandoff);
  const page = new Harness(); Object.assign(page, {controller, submission: controller, sending: false,
    allowImages: true, getUIContext: () => ({getHostContext: () => ({cacheDir: '/cache'})})});
  function flush() {timers.splice(0).forEach(callback => callback());}
  return {page, controller, pending, prepared, selected, states, notices, flush, timers,
    session: env.load('services/auth/AuthSession').AuthSession};
}

for (const kind of ['dynamic', 'reply']) {
  test(kind + ' picker: MediaLibraryKit selection carries remaining capacity and blocks a duplicate opening', async () => {
    const f = fixture(kind); await f.controller.pick({}, async () => ['existing']); f.prepared.length = 0;
    f.page.pickImages(); f.page.pickImages();
    assert.deepEqual(f.selected, [{MIMEType: 'image/*', maxSelectNumber: 8}]);
    const photoUris = ['new']; f.pending.resolve({photoUris}); await tick();
    assert.deepEqual(f.prepared, [], 'selected URI is not opened in the picker result callback');
    assert.equal(f.timers.length, 1); photoUris.push('mutation-after-result'); f.flush(); await tick();
    assert.deepEqual(f.prepared, ['new']); assert.deepEqual(f.notices, []);
  });

  test(kind + ' picker: cancellation retains the draft and releases its selection lock', async () => {
    const f = fixture(kind); await f.controller.pick({}, async () => ['existing']); f.prepared.length = 0;
    if (kind === 'dynamic') f.controller.setText('原草稿');
    f.page.pickImages(); f.pending.reject(Error('user cancelled')); await tick();
    assert.deepEqual(f.prepared, []); assert.deepEqual(f.notices, []);
    if (kind === 'dynamic') {
      assert.equal(f.states.at(-1).text, '原草稿'); assert.equal(f.states.at(-1).busy, false);
      assert.deepEqual(f.states.at(-1).images.map(item => item.key), ['existing']);
    } else assert.deepEqual(f.states.at(-1).map(item => item.key), ['existing']);
    await f.controller.pick({}, async () => ['retry']); assert.deepEqual(f.prepared, ['retry']);
  });

  test(kind + ' picker: account replacement before URI delivery prevents opening any selected file', async () => {
    const f = fixture(kind); f.page.pickImages(); f.session.advance();
    f.pending.resolve({photoUris: ['late']}); await tick();
    f.flush(); await tick();
    assert.deepEqual(f.prepared, []); assert.deepEqual(f.notices, []);
  });

  test(kind + ' picker: operation reset before URI delivery preserves the replacement draft', async () => {
    const f = fixture(kind); f.page.pickImages(); f.controller.reset();
    if (kind === 'dynamic') f.controller.setText('新草稿');
    f.pending.resolve({photoUris: ['late']}); await tick(); f.flush(); await tick(); assert.deepEqual(f.prepared, []);
    if (kind === 'dynamic') assert.equal(f.states.at(-1).text, '新草稿');
  });

  test(kind + ' picker: account replacement during the deferred handoff still prevents file access', async () => {
    const f = fixture(kind); f.page.pickImages(); f.pending.resolve({photoUris: ['selected']}); await tick();
    assert.equal(f.timers.length, 1); f.session.advance(); f.flush(); await tick();
    assert.deepEqual(f.prepared, []); assert.deepEqual(f.notices, []);
  });
}
