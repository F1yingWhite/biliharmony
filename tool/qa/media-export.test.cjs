const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

// Complete production controller + document service + format modules; only OS/network/queue boundaries are fake.
function fixture(hooks = {}) {
  const calls = { menus: [], opens: [], writes: [], closes: [], queued: [], downloads: [], toasts: [], ui: [],
    playUrls: [], segments: [], subtitles: [], covers: [], captures: [], photos: [], released: [] };
  const state = { destroyed: false, video: { aid: 1, bvid: 'BVold', cid: 10, epId: 0, title: 'Old title', partTitle: 'Part two',
    cover: 'https://img/old.png?x=1', duration: 721, playhead: 17.8, quality: 80,
    qualityOptions: [{ qn: 80, label: '1080P', available: true }, { qn: 64, label: '720P', available: true }],
    subtitle: { url: 'selected-en', lan: 'en', lanDoc: 'English' } } };
  const frame = { release: async () => calls.released.push('frame') };
  const packer = { packToData: async (...args) => hooks.pack ? hooks.pack(...args) : new ArrayBuffer(3),
    release: async () => calls.released.push('packer') };
  const info = { urls: ['https://cdn/old.mp4'], downloadAudioUrls: ['https://cdn/old.m4a'], isDash: false,
    quality: 64, format: 'mp4' };
  const api = {
    getPlayUrl: async (...args) => { calls.playUrls.push(args); return hooks.playUrl ? hooks.playUrl(...args) : info; },
    getDanmakuSeg: async (...args) => { calls.segments.push(args); return hooks.segment ? hooks.segment(...args) : [dm(args[2])]; },
    getSubtitleCues: async url => { calls.subtitles.push(url); return hooks.subtitle ? hooks.subtitle(url) : [{ from: 1, to: 2, content: 'hello' }]; }
  };
  const overrides = {
    'api/BiliApi': { BiliApi: api },
    'services/network/HttpClient': { HttpClient: {
      getBytes: async url => { calls.covers.push(url); return hooks.cover ? hooks.cover(url) : new ArrayBuffer(5); },
      getDownloadHeaders: referer => ({ Referer: referer })
    } },
    'services/media/DownloadCenter': { DOWNLOAD_KIND_AUDIO: 1, DOWNLOAD_KIND_VIDEO: 0, DownloadCenter: {
      init: async () => hooks.init ? hooks.init() : undefined,
      enqueue: async (...args) => { calls.queued.push(args); return hooks.enqueue ? hooks.enqueue(...args) : 'id'; },
      hasActive: () => false
    } },
    'services/media/VideoDownloadService': { VideoDownloadService: {
      isActive: () => false, currentProgress: () => -1,
      downloadToUri: async (...args) => { calls.downloads.push(args); return hooks.download ? hooks.download(...args) : undefined; }
    } },
    'services/media/PhotoLibrarySaver': { PhotoLibrarySaver: { saveImage: async (...args) => {
      calls.photos.push(args); return hooks.photo ? hooks.photo(...args) : true;
    } } }
  };
  const kits = {
    '@kit.ImageKit': { image: { createImagePacker: () => packer } },
    '@kit.CoreFileKit': { picker: {
      DocumentSaveOptions: class {}, DocumentViewPicker: class { async save(options) {
        calls.menus.push(options); return hooks.pick ? hooks.pick(options) : ['content://save'];
      } }
    }, fileIo: {
      OpenMode: { READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
      openSync: (...args) => { calls.opens.push(args); return { fd: 7 }; },
      writeSync: (fd, bytes) => { calls.writes.push(Buffer.from(bytes)); return hooks.write ? hooks.write(fd, bytes) : bytes.byteLength; },
      closeSync: file => calls.closes.push(file.fd)
    } },
    '@kit.ArkTS': { collections: { Array }, util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } }, taskpool: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { debug() {}, info() {}, warn() {}, error() {} } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} }
  };
  const load = createArktsLoader({ mocks: { ...kits, ...overrides } });
  const context = { cacheDir: '/cache' };
  const Controller = load('components/player/PlayerMediaExportController').PlayerMediaExportController;
  const controller = new Controller({
    getContext: () => context, snapshot: () => state.video, isDestroyed: () => state.destroyed,
    closePanels() {}, toast: message => calls.toasts.push(message), publishDownload: ui => calls.ui.push(ui)
  }, async seconds => { calls.captures.push(seconds); return hooks.capture ? hooks.capture(seconds) : frame; });
  return { controller, calls, state, load, context, frame, info };
}
function dm(id) { return { time: id, mode: 1, fontsize: 25, color: 16777215, id, idStr: String(id), text: 'hello & <世界>' }; }

test('media format creates portable filenames and valid escaped XML / millisecond SRT', () => {
  const f = fixture(), format = f.load('services/media/MediaExportFormat').MediaExportFormat;
  assert.equal(format.safeName('CON'), '_CON');
  assert.equal(format.safeName(' a/b:c?. '), 'a_b_c_');
  assert.equal(format.safeName('  '), 'BiliHarmony视频');
  assert.equal(format.srtTime(3661.007), '01:01:01,007');
  assert.equal(format.srtTime(-1), '00:00:00,000');
  assert.equal(format.srtTime(Infinity), '00:00:00,000');
  assert.match(format.subtitle([{ from: 1.25, to: 2, content: 'line' }]), /^1\n00:00:01,250 --> 00:00:02,000\nline\n\n$/);
  const item = dm(1); item.idStr = '1"&';
  const xml = format.danmaku(10, [item]);
  assert.match(xml, /hello &amp; &lt;世界&gt;/);
  assert.match(xml, /1&quot;&amp;/);
  assert.equal(format.danmakuSegments(720.1), 3);
  assert.equal(format.danmakuSegments(0), 12);
});

for (const pick of [async () => [], async () => { throw { code: 13900042 }; }]) {
  test('document export cancellation returns false without opening a file', async () => {
    const f = fixture({ pick });
    const saved = await f.load('services/media/DocumentExportService').DocumentExportService
      .saveText(f.context, 'file.txt', 'text|.txt', 'hello');
    assert.equal(saved, false); assert.equal(f.calls.opens.length, 0);
  });
}

test('document export completes partial writes and closes the file when write fails', async () => {
  const partial = fixture({ write: (_fd, bytes) => Math.min(2, bytes.byteLength) });
  const service = partial.load('services/media/DocumentExportService').DocumentExportService;
  assert.equal(await service.saveText(partial.context, 'x.txt', 'text|.txt', 'hello'), true);
  assert.deepEqual(partial.calls.writes.map(bytes => bytes.toString()), ['hello', 'llo', 'o']);
  assert.deepEqual(partial.calls.closes, [7]);
  const failure = fixture({ write: () => { throw Error('disk full'); } });
  await assert.rejects(() => failure.load('services/media/DocumentExportService').DocumentExportService
    .saveText(failure.context, 'x', 'x', 'bytes'), /disk full/);
  assert.deepEqual(failure.calls.closes, [7]);
});

test('document export rechecks generation after the picker and does not open a stale target', async () => {
  const chosen = deferred(), f = fixture({ pick: () => chosen.promise });
  let current = true;
  const work = f.load('services/media/DocumentExportService').DocumentExportService
    .saveText(f.context, 'x', 'x', 'bytes', () => current);
  current = false; chosen.resolve(['content://old']);
  assert.equal(await work, false); assert.equal(f.calls.opens.length, 0);
});

test('document picker errors are not mistaken for a cancelled or successfully saved file', async () => {
  const f = fixture({ pick: async () => { throw Error('picker unavailable'); } });
  await assert.rejects(() => f.load('services/media/DocumentExportService').DocumentExportService
    .saveText(f.context, 'x', 'x', 'bytes'), /picker unavailable/);
  assert.equal(f.calls.opens.length, 0);
});

test('document picker platform errors retain their code and message as a throwable Error', async () => {
  const f = fixture({ pick: async () => { throw { code: 13900001, message: 'permission denied' }; } });
  await assert.rejects(() => f.load('services/media/DocumentExportService').DocumentExportService
    .saveText(f.context, 'x', 'x', 'bytes'), error => {
      assert.ok(error instanceof Error);
      assert.equal(error.code, 13900001);
      assert.equal(error.message, 'permission denied');
      return true;
    });
  assert.equal(f.calls.opens.length, 0);
});

test('queue submission captures identifiers, part, quality and title before initialization', async () => {
  const initialized = deferred(), f = fixture({ init: () => initialized.promise });
  const work = f.controller.enqueueCenterDownload(false);
  f.state.video.cid = 20; f.state.video.title = 'New title'; f.state.video.qualityOptions[0].label = 'changed';
  initialized.resolve(); await work;
  assert.deepEqual(f.calls.queued[0].slice(0, 6), [0, 1, 'BVold', 10, 0, 80]);
  assert.match(f.calls.queued[0][6], /Old title - Part two/);
  assert.equal(f.calls.queued[0][7], '1080P');
});

test('switching source before queue submission aborts; submitted queue work can finish after leaving', async () => {
  const init = deferred(), f = fixture({ init: () => init.promise });
  const work = f.controller.enqueueCenterDownload(false);
  f.controller.invalidate(); init.resolve(); await work;
  assert.equal(f.calls.queued.length, 0); assert.deepEqual(f.calls.toasts, []);
  const enqueued = deferred(), submitted = fixture({ enqueue: () => enqueued.promise });
  const saved = submitted.controller.enqueueCenterDownload(false); await tick();
  assert.equal(submitted.calls.queued.length, 1);
  submitted.state.destroyed = true; submitted.controller.invalidate(); enqueued.resolve('id'); await saved;
  assert.deepEqual(submitted.calls.toasts, []);
});

test('media export suppresses duplicate submits and retains its source snapshot across URL resolution', async () => {
  const playUrl = deferred(), f = fixture({ playUrl: () => playUrl.promise });
  const first = f.controller.startMediaDownload(false);
  await f.controller.startMediaDownload(false);
  assert.equal(f.calls.playUrls.length, 1);
  f.state.video.bvid = 'BVnew'; f.state.video.title = 'New title'; f.state.video.partTitle = 'New part';
  playUrl.resolve(f.info); await first;
  assert.match(f.calls.menus[0].newFileNames[0], /Old title - Part two.*BVold.*720P/);
  assert.equal(f.calls.downloads[0][4].Referer, 'https://www.bilibili.com/video/BVold');
  assert.equal(f.calls.ui.at(-1).busy, false);
});

test('changing source during media picker prevents a download and late progress cannot update a new source', async () => {
  const choice = deferred(), f = fixture({ pick: () => choice.promise });
  const work = f.controller.startMediaDownload(false); await tick();
  f.controller.invalidate(); const uiCount = f.calls.ui.length;
  choice.resolve(['content://old']); await work;
  assert.equal(f.calls.downloads.length, 0); assert.equal(f.calls.ui.length, uiCount);
  const transfer = deferred(), active = fixture({ download: () => transfer.promise });
  const download = active.controller.startMediaDownload(false); await tick();
  const callback = active.calls.downloads[0][5]; callback(50, 100);
  assert.equal(active.calls.ui.at(-1).progress, 50);
  active.controller.invalidate(); const count = active.calls.ui.length, messages = active.calls.toasts.length;
  callback(100, 100); transfer.resolve(); await download;
  assert.equal(active.calls.ui.length, count); assert.equal(active.calls.toasts.length, messages);
});

test('obsolete task cleanup cannot unlock a newer operation', async () => {
  const old = deferred(), newer = deferred(); let requests = 0;
  const f = fixture({ cover: () => ++requests === 1 ? old.promise : newer.promise });
  const first = f.controller.exportCover(); f.controller.invalidate();
  const second = f.controller.exportCover(); old.resolve(new ArrayBuffer(1)); await first;
  await f.controller.exportCover();
  assert.equal(f.calls.covers.length, 2);
  newer.resolve(new ArrayBuffer(1)); await second;
});

test('media cancellation and failure restore download UI and allow another attempt', async () => {
  const cancelled = fixture({ pick: async () => [] });
  await cancelled.controller.startMediaDownload(false);
  await cancelled.controller.startMediaDownload(false);
  assert.equal(cancelled.calls.menus.length, 2);
  assert.equal(cancelled.calls.downloads.length, 0);
  assert.deepEqual(cancelled.calls.toasts, []);
  assert.equal(cancelled.calls.ui.at(-1).busy, false);
  const failure = fixture({ download: async () => { throw Error('network failed'); } });
  await failure.controller.startMediaDownload(true);
  assert.ok(failure.calls.toasts.includes('network failed'));
  assert.ok(failure.calls.toasts.every(text => !text.includes('已保存')));
  assert.equal(failure.calls.ui.at(-1).busy, false);
});

test('source invalidation while resolving media URLs skips the picker and stale failure messages', async () => {
  for (const success of [true, false]) {
    const pending = deferred(), f = fixture({ playUrl: () => pending.promise });
    const work = f.controller.startMediaDownload(false);
    f.controller.invalidate();
    if (success) pending.resolve(f.info);
    else pending.reject(Error('old video offline'));
    await work;
    assert.equal(f.calls.menus.length, 0); assert.deepEqual(f.calls.toasts, []);
  }
});

test('danmaku exports every known segment beyond 72 minutes and continues past empty segments', async () => {
  const f = fixture({ segment: async (_cid, _aid, index) => index === 2 ? [] : [dm(index)] });
  f.state.video.duration = 13 * 360;
  await f.controller.exportDanmaku();
  assert.deepEqual(f.calls.segments.map(args => args[2]), Array.from({ length: 13 }, (_, i) => i + 1));
  const xml = Buffer.concat(f.calls.writes).toString();
  assert.match(xml, /13\.00,1,25/);
  assert.ok(f.calls.toasts.includes('弹幕已保存（12 条）'));
});

test('danmaku failed segment does not save a partial file; unknown duration has a declared bounded window', async () => {
  const failure = fixture({ segment: async (_cid, _aid, index) => index === 2 ? null : [dm(index)] });
  await failure.controller.exportDanmaku();
  assert.equal(failure.calls.menus.length, 0);
  assert.ok(failure.calls.toasts.some(text => text.includes('第 2 段加载失败')));
  assert.ok(failure.calls.toasts.every(text => !text.includes('已保存')));
  const bounded = fixture(); bounded.state.video.duration = 0;
  await bounded.controller.exportDanmaku();
  assert.equal(bounded.calls.segments.length, 12);
  assert.ok(bounded.calls.toasts.includes('弹幕已保存（前 72 分钟，12 条）'));
});

for (const method of ['exportDanmaku', 'exportSubtitle', 'exportCover']) {
  test(`${method}: cancellation never reports a saved file and releases the operation lock`, async () => {
    const f = fixture({ pick: async () => [] });
    await f.controller[method](); await f.controller[method]();
    assert.equal(f.calls.menus.length, 2);
    assert.ok(f.calls.toasts.every(text => !text.includes('已保存')));
  });
}

test('subtitle export uses the chosen track snapshot, not the first track or a later selection', async () => {
  const cues = deferred(), f = fixture({ subtitle: () => cues.promise });
  const work = f.controller.exportSubtitle();
  f.state.video.subtitle.lanDoc = 'Other'; f.state.video.subtitle.url = 'different-track'; f.state.video.title = 'New title';
  cues.resolve([{ from: 3.5, to: 4, content: 'chosen language' }]); await work;
  assert.deepEqual(f.calls.subtitles, ['selected-en']);
  assert.match(f.calls.menus[0].newFileNames[0], /Old title.*English/);
  assert.match(Buffer.concat(f.calls.writes).toString(), /00:00:03,500.*\nchosen language/);
});

test('cover export retains its original extension and identity after a delayed response', async () => {
  const bytes = deferred(), f = fixture({ cover: () => bytes.promise });
  const work = f.controller.exportCover();
  f.state.video.cover = 'https://img/new.webp'; f.state.video.bvid = 'BVnew';
  bytes.resolve(new ArrayBuffer(2)); await work;
  assert.deepEqual(f.calls.covers, ['https://img/old.png?x=1']);
  assert.match(f.calls.menus[0].newFileNames[0], /BVold.*\.png$/);
});

for (const method of ['exportDanmaku', 'exportSubtitle', 'exportCover']) {
  test(`${method}: source change or exit discards late network results`, async () => {
    const pending = deferred();
    const f = fixture({ segment: () => pending.promise, subtitle: () => pending.promise, cover: () => pending.promise });
    const work = f.controller[method]();
    f.state.destroyed = true; f.controller.invalidate();
    const messages = f.calls.toasts.length;
    pending.resolve(method === 'exportCover' ? new ArrayBuffer(1) : []); await work;
    assert.equal(f.calls.menus.length, 0); assert.equal(f.calls.toasts.length, messages);
  });
}

test('screenshot freezes playback time and releases both owned image resources after saving', async () => {
  const packed = deferred(), f = fixture({ pack: () => packed.promise });
  const work = f.controller.captureScreenshot(); await tick();
  f.state.video.playhead = 80; packed.resolve(new ArrayBuffer(2)); await work;
  assert.deepEqual(f.calls.captures, [17.8]);
  assert.equal(f.calls.photos[0][3], 'BiliHarmony_17s');
  assert.deepEqual(f.calls.released, ['packer', 'frame']);
});

test('screenshot releases packer/frame on encode failure and skips album UI after source change', async () => {
  const failure = fixture({ pack: async () => { throw Error('encode failed'); } });
  await failure.controller.captureScreenshot();
  assert.deepEqual(failure.calls.released, ['packer', 'frame']); assert.equal(failure.calls.photos.length, 0);
  const captured = deferred(), stale = fixture({ capture: () => captured.promise });
  const work = stale.controller.captureScreenshot(); stale.controller.invalidate();
  captured.resolve(stale.frame); await work;
  assert.deepEqual(stale.calls.released, ['frame']); assert.equal(stale.calls.photos.length, 0);
  assert.deepEqual(stale.calls.toasts, []);
});

test('screenshot album cancellation releases resources and never announces a saved image', async () => {
  const f = fixture({ photo: async () => false });
  await f.controller.captureScreenshot();
  assert.deepEqual(f.calls.released, ['packer', 'frame']);
  assert.deepEqual(f.calls.toasts, []);
});
