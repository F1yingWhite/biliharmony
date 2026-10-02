const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, tick } = require('./arkts-module.cjs');

function fixture({ fontScale = 1, failSnapshot = false } = {}) {
  const pages = [], files = new Set(), toasts = [], errors = [], previews = [], releases = [];
  let destroyed = false, rejectSnapshot, view;
  const load = createArktsLoader({mocks: {
    'common/CommentLog': {CommentLog: {info() {}, warn() {}, errorText: String}},
    'common/EmoteImageCache': {EmoteImageCache: {ensure: async url => url}},
    'components/reply/ReplyShareCard': {
      makeReplyQr: async () => ({release: async () => releases.push('qr')}),
      getReplyShareBounds: async () => ({width: 340, height: 720}),
      makeReplyShareSnapshot: async (_ui, builder) => {
        builder();
        if (failSnapshot && pages.length === 2) return new Promise((_resolve, reject) => {rejectSnapshot = reject;});
        return {release: async () => releases.push('page')};
      }
    },
    'components/reply/ReplyShareExport': {
      saveReplyShareImage: async (_context, pixel, name) => {
        files.add(name); await pixel.release(); return {path: name, uri: name};
      },
      showReplyShareImages: async (_context, value) => previews.push(value.slice()),
      removeReplyShareImages: value => value.forEach(file => files.delete(file.path))
    }
  }});
  const {ReplyShareController} = load('components/reply/ReplyShareController');
  const ui = {
    getHostContext: () => ({ cacheDir: '/cache' }), px2vp: value => value,
    // SDK MeasureOptions: a numeric fontSize is fp from API 12; an explicit vp string is unscaled.
    getMeasureUtils: () => ({ measureTextSize: ({ textContent, fontSize }) => {
      const size = typeof fontSize === 'number' ? fontSize * fontScale : parseFloat(fontSize);
      return { width: Array.from(textContent).length * size };
    } }),
  };
  view = new ReplyShareController({
    getSubject: () => ({oid: 1, type: 1}),
    toast: value => toasts.push(value),
    buildShareLink: () => 'https://www.bilibili.com/video/BV1ynhB6wEm6#reply318666621664',
    getUIContext: () => ui, ensureShareContext: () => true, isDestroyed: () => destroyed,
    onShareFailed: (_item, _link, error) => errors.push(error),
    renderShareCard: () => pages.push(view.sharePage()),
  });
  return { view, pages, files, toasts, errors, previews, releases,
    reply: Object.assign(new (load('model/Models').ReplyItem)(), reply),
    destroy: () => { destroyed = true; view.dispose(); },
    rejectPendingSnapshot: message => { assert.ok(rejectSnapshot); rejectSnapshot(new Error(message)); },
  };
}

const reply = { rpid: 318666621664, content: '完整评论'.repeat(400), pictures: [], upLiked: false,
  emotes: [], mentions: [], jumps: [] };
test('share text stays inside its rendered line when the system font scale is smaller', async () => {
  const f = fixture({ fontScale: 0.85 });
  await f.view.share(f.reply);
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
    const pending = f.view.share(f.reply);
    for (let i = 0; i < 20 && f.pages.length < 2; i++) await tick();
    assert.equal(f.pages.length, 2);
    assert.equal(f.files.size, 1, 'one page has already been packed when navigation occurs');
    f.destroy();
    f.rejectPendingSnapshot(message);
    await pending;
    assert.equal(f.view.busy, false);
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
  await f.view.share(f.reply);
  await tick();
  assert.equal(f.view.busy, false);
  assert.deepEqual(f.toasts, []);
  assert.deepEqual(f.pages, []);
  assert.deepEqual(f.previews, []);
});
