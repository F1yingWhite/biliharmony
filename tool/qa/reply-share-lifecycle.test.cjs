const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const sourceRoot = path.resolve(__dirname, '../../entry/src/main/ets');
const tick = () => new Promise(resolve => setImmediate(resolve));

function read(name) {
  const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, name + '.ets');
  return fs.readFileSync(override && fs.existsSync(override) ? override : path.join(sourceRoot, name + '.ets'), 'utf8')
    .replace(/\r\n/g, '\n');
}

function fixture({ fontScale = 1, failSnapshot = false } = {}) {
  const cache = new Map(), pages = [], files = new Set(), toasts = [], errors = [], previews = [];
  const releases = [];
  let destroyed = false, rejectSnapshot, view;
  function compile(source, name, globals = {}) {
    const module = { exports: {} };
    const output = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    }).outputText;
    const requireLocal = dependency => {
      const resolved = dependency.startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(name), dependency)) : dependency;
      if (resolved === 'common/CommentLog') return { CommentLog: { info() {}, warn() {}, errorText: String } };
      if (dependency.startsWith('.')) return load(resolved);
      throw new Error('Unexpected platform dependency ' + dependency);
    };
    new Function('require', 'module', 'exports', ...Object.keys(globals), output)(
      requireLocal, module, module.exports, ...Object.values(globals));
    return module.exports;
  }
  function load(name) {
    if (!cache.has(name)) cache.set(name, compile(read(name), name));
    return cache.get(name);
  }
  const layout = load('components/reply/ReplyShareLayout');
  const source = read('components/reply/RepliesController');
  const start = source.indexOf('  share(item: ReplyItem): void {');
  const end = source.indexOf('  /** 打开楼中楼', start);
  assert.ok(start >= 0 && end > start);
  const globals = {
    planReplySharePages: layout.planReplySharePages,
    resolveReplyShareEmotes: layout.resolveReplyShareEmotes,
    EmoteImageCache: { ensure: async url => url },
    makeReplyQr: async () => ({ release: async () => releases.push('qr') }),
    getReplyShareBounds: async () => ({ width: 340, height: 720 }),
    makeReplyShareSnapshot: async (_ui, builder) => {
      builder();
      if (failSnapshot && pages.length === 2) return new Promise((_resolve, reject) => { rejectSnapshot = reject; });
      return { release: async () => releases.push('page') };
    },
    saveReplyShareImage: async (_context, pixel, name) => {
      files.add(name); await pixel.release(); return { path: name, uri: name };
    },
    showReplyShareImages: async (_context, value) => previews.push(value.slice()),
    removeReplyShareImages: value => value.forEach(file => files.delete(file.path)),
  };
  const { Harness } = compile('let replyShareSequence = 0; export class Harness {\n' + source.slice(start, end) + '\n}',
    'components/reply/RepliesController', globals);
  const ui = {
    getHostContext: () => ({ cacheDir: '/cache' }), px2vp: value => value,
    // SDK MeasureOptions: a numeric fontSize is fp from API 12; an explicit vp string is unscaled.
    getMeasureUtils: () => ({ measureTextSize: ({ textContent, fontSize }) => {
      const size = typeof fontSize === 'number' ? fontSize * fontScale : parseFloat(fontSize);
      return { width: Array.from(textContent).length * size };
    } }),
  };
  view = Object.assign(new Harness(), { shareCardBusy: false, shareCardQr: null, access: {
    toast: value => toasts.push(value),
    buildShareLink: () => 'https://www.bilibili.com/video/BV1ynhB6wEm6#reply318666621664',
    getUIContext: () => ui, ensureShareContext: () => true, isDestroyed: () => destroyed,
    onShareFailed: (_item, _link, error) => errors.push(error),
    renderShareCard: () => pages.push(view.sharePage()),
  } });
  return { view, pages, files, toasts, errors, previews, releases,
    destroy: () => { destroyed = true; view.releaseShareCard(); },
    rejectPendingSnapshot: message => { assert.ok(rejectSnapshot); rejectSnapshot(new Error(message)); },
  };
}

const reply = { rpid: 318666621664, content: '完整评论'.repeat(400), pictures: [], upLiked: false,
  emotes: [], mentions: [], jumps: [] };
async function settle(view) {
  for (let i = 0; i < 40 && view.shareCardBusy; i++) await tick();
  assert.equal(view.shareCardBusy, false);
}

test('share text stays inside its rendered line when the system font scale is smaller', async () => {
  const f = fixture({ fontScale: 0.85 });
  f.view.share(reply);
  await settle(f.view);
  assert.equal(f.errors.length, 0);
  assert.ok(f.pages.length > 1);
  for (const page of f.pages) {
    for (const line of page.lines) {
      // ReplyShareCard clamps body Text to minFontScale=maxFontScale=1 at 19 fp.
      const renderedWidth = line.runs.reduce((sum, run) => sum + Array.from(run.text).length * 19, 0);
      assert.ok(renderedWidth <= page.width - 48,
        `rendered ${renderedWidth} vp exceeds ${page.width - 48} vp despite planned ${line.width} vp`);
    }
  }
  assert.equal(f.pages.flatMap(page => page.lines.flatMap(line => line.runs)).map(run => run.text).join(''), reply.content);
});

test('a late snapshot error after leaving the page only cleans resources and never invokes failure UI', async () => {
  for (const message of ['native builder destroyed', '评论图片未加载完整，请稍后重试']) {
    const f = fixture({ failSnapshot: true });
    f.view.share(reply);
    for (let i = 0; i < 20 && f.pages.length < 2; i++) await tick();
    assert.equal(f.pages.length, 2);
    assert.equal(f.files.size, 1, 'one page has already been packed when navigation occurs');
    f.destroy();
    f.rejectPendingSnapshot(message);
    await settle(f.view);
    assert.equal(f.files.size, 0);
    assert.equal(f.previews.length, 0);
    assert.deepEqual(f.releases, ['page', 'qr']);
    assert.deepEqual(f.errors, [], 'late errors must not reach the video-page clipboard fallback');
    assert.deepEqual(f.toasts, ['正在生成分享图片…']);
  }
});

test('a queued share action does nothing after its page is destroyed', async () => {
  const f = fixture();
  f.destroy();
  f.view.share(reply);
  await tick();
  assert.equal(f.view.shareCardBusy, false);
  assert.deepEqual(f.toasts, []);
  assert.deepEqual(f.pages, []);
  assert.deepEqual(f.previews, []);
});
