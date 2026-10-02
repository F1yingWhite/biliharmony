const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function fixture(overrides = {}) {
  const events = {qr: [], rendered: [], saved: [], removed: [], previews: [], errors: [], notices: []};
  const page = {destroyed: false, subject: {oid: 1, type: 1}};
  const pixel = name => ({name, releases: 0, async release() {this.releases++;}});
  const boundaries = {
    makeReplyQr: async () => {const qr = pixel('qr'); events.qr.push(qr); return qr;},
    getReplyShareBounds: async () => ({width: 340, height: 720}),
    makeReplyShareSnapshot: async (_ui, builder) => {builder(); return pixel('image');},
    resolveReplyShareEmotes: async () => new Map(),
    saveReplyShareImage: async (_context, image, name) => {await image.release(); events.saved.push(name); return {path: name};},
    showReplyShareImages: async (_context, files) => events.previews.push(files.slice()),
    ...overrides
  };
  let controller;
  const load = createArktsLoader({mocks: {
    'common/CommentLog': {CommentLog: {info() {}, warn() {}}},
    'common/EmoteImageCache': {EmoteImageCache: {ensure: async url => url}},
    'components/reply/ReplyShareCard': boundaries,
    'components/reply/ReplyShareLayout': {ReplySharePage: class {},
      resolveReplyShareEmotes: boundaries.resolveReplyShareEmotes,
      planReplySharePages: () => [{width: 340, height: 600}]},
    'components/reply/ReplyShareExport': {saveReplyShareImage: boundaries.saveReplyShareImage,
      showReplyShareImages: boundaries.showReplyShareImages,
      removeReplyShareImages: files => events.removed.push(...files.map(file => file.path))}
  }});
  controller = new (load('components/reply/ReplyShareController').ReplyShareController)({
    isDestroyed: () => page.destroyed, getSubject: () => page.subject,
    toast: text => events.notices.push(text), buildShareLink: item => 'https://www.bilibili.com/video/BV' + page.subject.oid + '#reply' + item.rpid,
    getUIContext: () => ({getHostContext: () => ({cacheDir: '/cache'})}), ensureShareContext: () => true,
    renderShareCard: () => events.rendered.push({content: controller.shareItem().content, qr: controller.shareQr()}),
    onShareFailed: (...args) => events.errors.push(args)
  });
  const item = Object.assign(new (load('model/Models').ReplyItem)(), {rpid: 1, content: 'captured text'});
  return {controller, events, page, item, pixel, auth: load('services/auth/AuthSession').AuthSession};
}

test('late QR completion releases only its own session and cannot clear a new export lock', async () => {
  const requests = []; const f = fixture({makeReplyQr: () => {const d = deferred(); requests.push(d); return d.promise;}});
  const old = f.controller.share(f.item); f.controller.dispose(); const fresh = f.controller.share(f.item);
  const oldQr = f.pixel('old'), freshQr = f.pixel('fresh'); requests[0].resolve(oldQr); await old;
  assert.equal(oldQr.releases, 1); assert.equal(f.controller.busy, true);
  f.item.content = 'later edit'; requests[1].resolve(freshQr); await fresh;
  assert.equal(freshQr.releases, 1); assert.equal(f.controller.busy, false);
  assert.equal(f.events.rendered[0].content, 'captured text'); assert.equal(f.events.rendered[0].qr, freshQr);
});

test('cancelled native snapshot is released without saving or exporting it', async () => {
  const image = deferred(); const f = fixture({makeReplyShareSnapshot: async (_ui, builder) => {builder(); return image.promise;}});
  const pending = f.controller.share(f.item); await tick(); f.controller.dispose();
  const pixels = f.pixel('late image'); image.resolve(pixels); await pending;
  assert.equal(pixels.releases, 1); assert.equal(f.events.qr[0].releases, 1);
  assert.deepEqual(f.events.saved, []); assert.deepEqual(f.events.previews, []); assert.deepEqual(f.events.errors, []);
});

test('a file save that finishes after disposal is removed and never handed to the share panel', async () => {
  const write = deferred(); const f = fixture({saveReplyShareImage: async (_context, image) => {await image.release(); return write.promise;}});
  const pending = f.controller.share(f.item); await tick(); f.controller.dispose();
  write.resolve({path: 'late.png'}); await pending;
  assert.deepEqual(f.events.removed, ['late.png']); assert.deepEqual(f.events.previews, []);
});

test('account/subject changes during image resolution suppress rendering and failure notifications', async () => {
  for (const change of [f => f.auth.advance(), f => f.page.subject.oid++, f => f.page.subject.type++]) {
    const resolve = deferred(); const f = fixture({resolveReplyShareEmotes: () => resolve.promise});
    const pending = f.controller.share(f.item); await tick(); change(f); resolve.reject(Error('late'));
    await pending; assert.equal(f.events.qr[0].releases, 1); assert.deepEqual(f.events.errors, []);
    assert.deepEqual(f.events.rendered, []); assert.equal(f.controller.busy, false);
  }
});

test('files already handed to the native preview stay under export cleanup ownership', async () => {
  const preview = deferred(); const f = fixture({showReplyShareImages: () => preview.promise});
  const pending = f.controller.share(f.item); await tick(); f.controller.dispose(); preview.resolve(); await pending;
  assert.equal(f.events.saved.length, 1); assert.deepEqual(f.events.removed, []);
});

test('active export failure calls the page fallback once and permits retry', async () => {
  let fail = true; const f = fixture({getReplyShareBounds: async () => {
    if (fail) throw Error('unsupported'); return {width: 340, height: 720};
  }});
  await f.controller.share(f.item); assert.equal(f.events.errors.length, 1); assert.equal(f.controller.busy, false);
  fail = false; await f.controller.share(f.item); assert.equal(f.events.previews.length, 1);
});
