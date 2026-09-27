const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
function read(name) {
  const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, name + '.ets');
  return fs.readFileSync(override && fs.existsSync(override) ? override : path.join(root, name + '.ets'), 'utf8')
    .replace(/\r\n/g, '\n');
}
function environment(mocks = {}, timers = []) {
  const cache = new Map();
  function compile(source, name, globals = {}) {
    const module = { exports: {} };
    const output = ts.transpileModule(source, {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    }).outputText;
    const requireLocal = dependency => {
      const resolved = dependency.startsWith('.') ? path.posix.normalize(path.posix.join(path.posix.dirname(name), dependency)) : dependency;
      if (resolved in mocks) return mocks[resolved];
      if (resolved === 'common/CommentLog') return { CommentLog: { info() {}, warn() {}, errorText: String } };
      if (dependency.startsWith('.')) return load(resolved);
      throw new Error('Missing platform mock: ' + dependency);
    };
    new Function('require', 'module', 'exports', 'setTimeout', ...Object.keys(globals), output)(
      requireLocal, module, module.exports, (callback, delay) => { timers.push({ callback, delay }); return timers.length; },
      ...Object.values(globals));
    return module.exports;
  }
  function load(name) {
    if (!cache.has(name)) cache.set(name, compile(read(name), name));
    return cache.get(name);
  }
  return { load, compile };
}
function item(content, pictures = []) {
  return { rpid: 318666621664, content, pictures, upLiked: false, emotes: [], mentions: [], jumps: [] };
}
const measure = (text, size) => Array.from(text).reduce((sum, glyph) => sum + (glyph.charCodeAt(0) < 128 ? size * .55 : size), 0);
const allRuns = pages => pages.flatMap(page => page.lines.flatMap(line => line.runs));
const tick = () => new Promise(resolve => setImmediate(resolve));

test('share layout keeps a long comment complete across pages with bounded explicit height', () => {
  const layout = environment().load('components/reply/ReplyShareLayout');
  const content = '第一段：完整评论，不应变成省略号。\n' + '汉字MixedText😀'.repeat(280) + '【全文结束】';
  const pages = layout.planReplySharePages(item(content), measure, 1100);
  assert.ok(pages.length > 1);
  assert.equal(allRuns(pages).map(run => run.text).join(''), content);
  assert.ok(pages.every(page => page.height <= 1100 && page.height > 356));
  assert.ok(pages.every((page, index) => page.number === index + 1 && page.total === pages.length));
  assert.ok(pages.every(page => page.lines.every(line => line.width <= layout.REPLY_SHARE_CONTENT_WIDTH)));
});

test('share layout preserves inline emotes and all nine attachments without mutating the reply', () => {
  const layout = environment().load('components/reply/ReplyShareLayout');
  const pictures = Array.from({ length: 9 }, (_, index) => 'file://picture-' + index + '.png');
  const reply = item('表情[doge]后面仍然完整。'.repeat(20), pictures);
  reply.emotes = [{ text: '[doge]', url: 'file://doge.png', size: 2, displayUrl: () => 'file://doge.png' }];
  const original = JSON.stringify(reply);
  const pages = layout.planReplySharePages(reply, measure, 850);
  assert.deepEqual(pages.flatMap(page => page.pictures), pictures);
  assert.equal(allRuns(pages).filter(run => run.image).length, 20);
  assert.equal(allRuns(pages).map(run => run.image ? run.imageLabel : run.text).join(''), reply.content);
  assert.equal(JSON.stringify(reply), original);
});

test('share line breaks preserve joined emoji, modifiers, flags and combining accents', () => {
  const layout = environment().load('components/reply/ReplyShareLayout');
  const clusters = ['👨‍👩‍👧‍👦', '👍🏽', '🇨🇳', 'e\u0301', '❤️'];
  assert.deepEqual(layout.replyShareGraphemes(clusters.join('')), clusters);
  const pages = layout.planReplySharePages(item(clusters.join('').repeat(30)), text =>
    layout.replyShareGraphemes(text).length * 29);
  const lines = pages.flatMap(page => page.lines.map(line => line.runs.map(run => run.text).join('')));
  assert.equal(lines.join(''), clusters.join('').repeat(30));
  for (const line of lines) assert.ok(!line.endsWith('\u200D') && !line.startsWith('\u200D'));
});

test('share line breaks keep closing punctuation with its preceding character without dropping text', () => {
  const layout = environment().load('components/reply/ReplyShareLayout');
  const content = '甲'.repeat(21) + '乙，' + '丙'.repeat(5);
  const pages = layout.planReplySharePages(item(content), () => 10, 720, new Map(), 280);
  const lines = pages.flatMap(page => page.lines.map(line => line.runs.map(run => run.text).join('')));
  assert.ok(lines.length > 1);
  assert.equal(lines.join(''), content);
  assert.ok(lines.every(line => !/^[，。！？；：、）】》」』]/u.test(line)),
    'a closing punctuation mark must stay with the preceding character when wrapping');
  assert.ok(pages.every(page => page.lines.every(line => line.width <= 280 - 48)));
});

test('failed emote downloads become measured original labels instead of blank image spans', async () => {
  const layout = environment().load('components/reply/ReplyShareLayout');
  const reply = item('前文[doge]后文'.repeat(30));
  reply.emotes = [{ text: '[doge]', size: 2, displayUrl: () => 'https://example.com/doge.png' }];
  let attempts = 0;
  const sources = await layout.resolveReplyShareEmotes(reply, async () => { attempts++; throw new Error('offline'); });
  const pages = layout.planReplySharePages(reply, measure, 850, sources);
  assert.equal(attempts, 1);
  assert.ok(allRuns(pages).every(run => run.image.length === 0));
  assert.equal(allRuns(pages).map(run => run.text).join(''), reply.content);
  assert.ok(pages.every(page => page.lines.every(line => line.width <= layout.REPLY_SHARE_CONTENT_WIDTH)));
});

test('snapshot waits for rendering and scales long pages to the device pixel limit', async () => {
  const env = environment({ '@kit.ScanKit': {}, '@kit.ArkUI': {} });
  const source = read('components/reply/ReplyShareCard').split('@Component')[0];
  const { makeReplyShareSnapshot } = env.compile(source, 'components/reply/ReplyShareCard');
  const calls = [];
  let released = 0;
  const expected = { getImageInfo: async () => ({ size: { width: 865, height: 4096 } }),
    release: async () => { released++; } };
  const ui = { vp2px: value => value * 3,
    getComponentSnapshot: () => ({ getSizeLimitation: () => ({ maxWidth: 4096, maxHeight: 4096 }),
      createFromBuilder: async (...args) => { calls.push(args); return expected; } }) };
  assert.equal(await makeReplyShareSnapshot(ui, () => {}, 1800), expected);
  assert.equal(calls[0][2], true);
  assert.equal(calls[0][3].waitUntilRenderFinished, true);
  assert.equal(calls[0][3].scale, 4096 / 5400);
  assert.equal(released, 0, 'a complete native image remains available for export');
});

test('snapshot accepts one pixel of native rounding at the requested narrow page width', async () => {
  const env = environment({ '@kit.ScanKit': {}, '@kit.ArkUI': {} });
  const { makeReplyShareSnapshot } = env.compile(read('components/reply/ReplyShareCard').split('@Component')[0],
    'components/reply/ReplyShareCard');
  let released = 0;
  const pixel = { getImageInfo: async () => ({ size: { width: 679, height: 1441 } }),
    release: async () => { released++; } };
  const ui = { vp2px: value => value * 2,
    getComponentSnapshot: () => ({ getSizeLimitation: () => ({ maxWidth: 4096, maxHeight: 4096 }),
      createFromBuilder: async () => pixel }) };
  assert.equal(await makeReplyShareSnapshot(ui, () => {}, 720, 340), pixel);
  assert.equal(released, 0);
});

test('snapshot rejects a clipped native image and releases it', async () => {
  const env = environment({ '@kit.ScanKit': {}, '@kit.ArkUI': {} });
  const { makeReplyShareSnapshot } = env.compile(read('components/reply/ReplyShareCard').split('@Component')[0],
    'components/reply/ReplyShareCard');
  for (const size of [{ width: 678, height: 1440 }, { width: 680, height: 1438 }]) {
    let released = 0;
    const pixel = { getImageInfo: async () => ({ size }), release: async () => {
      released++;
      throw new Error('native release rejected');
    } };
    const ui = { vp2px: value => value * 2,
      getComponentSnapshot: () => ({ getSizeLimitation: () => ({ maxWidth: 4096, maxHeight: 4096 }),
        createFromBuilder: async () => pixel }) };
    await assert.rejects(makeReplyShareSnapshot(ui, () => {}, 720, 340), /评论图片尺寸不完整，请重试/);
    assert.equal(released, 1, 'each clipped map is released even when release itself rejects');
  }
});

test('snapshot refuses unavailable native dimensions and releases the unverified image', async () => {
  const env = environment({ '@kit.ScanKit': {}, '@kit.ArkUI': {} });
  const { makeReplyShareSnapshot } = env.compile(read('components/reply/ReplyShareCard').split('@Component')[0],
    'components/reply/ReplyShareCard');
  let released = 0;
  const pixel = { getImageInfo: async () => { throw new Error('native size query failed'); },
    release: async () => { released++; } };
  const ui = { vp2px: value => value,
    getComponentSnapshot: () => ({ getSizeLimitation: () => ({ maxWidth: 4096, maxHeight: 4096 }),
      createFromBuilder: async () => pixel }) };
  await assert.rejects(makeReplyShareSnapshot(ui, () => {}, 720, 340), /评论图片尺寸不完整，请重试/);
  assert.equal(released, 1);
});

test('share bounds use the current narrow window and fall back to the host window', async () => {
  const calls = [];
  const host = {};
  const window = {
    findWindow: name => { calls.push(['named', name]); return { getWindowProperties: () => ({ windowRect: { width: 480, height: 960 } }) }; },
    getLastWindow: async context => { calls.push(['host', context]); return { getWindowProperties: () => ({ windowRect: { width: 1200, height: 1600 } }) }; },
  };
  const env = environment({ '@kit.ScanKit': {}, '@kit.ArkUI': { window } });
  const { getReplyShareBounds } = env.compile(read('components/reply/ReplyShareCard').split('@Component')[0],
    'components/reply/ReplyShareCard');
  const ui = { getWindowName: () => 'split-screen', getHostContext: () => host, px2vp: value => value / 1.25 };
  const narrow = await getReplyShareBounds(ui);
  assert.equal(narrow.width, 360);
  assert.equal(narrow.height, 672);
  const fallback = await getReplyShareBounds({ ...ui, getWindowName: () => undefined });
  assert.equal(fallback.width, 380, 'large windows keep the maximum card width');
  assert.equal(fallback.height, 1184);
  assert.deepEqual(calls, [['named', 'split-screen'], ['host', host]]);
});

test('share bounds reject windows too narrow or too short to contain a full card', async () => {
  for (const rect of [{ width: 360, height: 960 }, { width: 480, height: 700 }]) {
    const env = environment({ '@kit.ScanKit': {}, '@kit.ArkUI': {
      window: { findWindow: () => ({ getWindowProperties: () => ({ windowRect: rect }) }) },
    } });
    const { getReplyShareBounds } = env.compile(read('components/reply/ReplyShareCard').split('@Component')[0],
      'components/reply/ReplyShareCard');
    const ui = { getWindowName: () => 'small-window', getHostContext: () => ({}), px2vp: value => value / 1.25 };
    await assert.rejects(getReplyShareBounds(ui), /当前窗口过小，请放大窗口后生成分享图片/);
  }
});

test('incomplete attachment decoding fails after checked retries and never exports an unchecked snapshot', async () => {
  const env = environment({ '@kit.ScanKit': {}, '@kit.ArkUI': {} });
  const source = read('components/reply/ReplyShareCard').split('@Component')[0];
  const { makeReplyShareSnapshot } = env.compile(source, 'components/reply/ReplyShareCard');
  const calls = [];
  const ui = { vp2px: value => value * 3,
    getComponentSnapshot: () => ({ getSizeLimitation: () => ({ maxWidth: 4096, maxHeight: 4096 }),
      createFromBuilder: async (...args) => { calls.push(args); throw new Error('image not decoded'); } }) };
  await assert.rejects(makeReplyShareSnapshot(ui, () => {}, 600), /未加载完整/);
  assert.equal(calls.length, 2);
  assert.ok(calls.every(args => args[2] === true));
});

function exportFixture(writeLimit = Infinity, releaseRejects = false) {
  const bytes = new Uint8Array([1, 2, 3, 4, 5]).buffer;
  const written = [], deleted = [], shown = [], timers = [];
  let released = 0, closed = 0;
  class SharedData { constructor(record) { this.records = [record]; } addRecord(record) { this.records.push(record); } }
  class ShareController {
    constructor(data) { this.data = data; this.events = {}; }
    on(name, callback) { this.events[name] = callback; }
    async show(context, options) { shown.push({ records: this.data.records, options, events: this.events }); }
  }
  const env = environment({
    '@kit.ImageKit': { image: { createImagePacker: () => ({ packToData: async () => bytes, release: async () => {} }) } },
    '@kit.CoreFileKit': { fileIo: { OpenMode: { READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
      openSync: () => ({ fd: 7 }), closeSync: () => { closed++; }, unlinkSync: path => deleted.push(path),
      writeSync: (_fd, buffer) => { const chunk = Array.from(new Uint8Array(buffer)).slice(0, writeLimit); written.push(...chunk); return chunk.length; },
    }, fileUri: { getUriFromPath: value => 'file://' + value } },
    '@kit.ShareKit': { systemShare: { SharedData, ShareController, SelectionMode: { SINGLE: 0, BATCH: 1 }, SharePreviewMode: { DETAIL: 1 } } },
    '@kit.ArkData': { uniformTypeDescriptor: { getUniformDataTypeByFilenameExtension: () => 'image/png', UniformDataType: { IMAGE: 'image' } } },
  }, timers);
  const api = env.load('components/reply/ReplyShareExport');
  const pixel = { release: async () => { released++; if (releaseRejects) throw new Error('already released'); } };
  return { api, pixel, written, deleted, shown, timers, released: () => released, closed: () => closed };
}

test('share export handles short file writes, releases the map, and previews every PNG together', async () => {
  const fixture = exportFixture(2, true);
  const first = await fixture.api.saveReplyShareImage({ cacheDir: '/cache' }, fixture.pixel, 'reply_session1_1');
  assert.deepEqual(fixture.written, [1, 2, 3, 4, 5]);
  assert.equal(fixture.released(), 1);
  assert.equal(fixture.closed(), 1);
  const second = { path: '/cache/reply_session1_2.png', uri: 'file:///cache/reply_session1_2.png' };
  await fixture.api.showReplyShareImages({}, [first, second]);
  assert.equal(fixture.timers.length, 0, 'an open preview must keep its image files');
  assert.equal(fixture.shown[0].options.selectionMode, 1);
  assert.deepEqual(fixture.shown[0].records.map(record => record.uri), [first.uri, second.uri]);
  fixture.shown[0].events.dismiss();
  fixture.timers.find(timer => timer.delay === 10000).callback();
  assert.deepEqual(fixture.deleted, [first.path, second.path]);
});

test('video, dynamic and bangumi QR payloads preserve the exact source and original reply anchor', () => {
  const cases = [
    ['pages/VideoDetail', { detail: { bvid: 'BV1ynhB6wEm6' } }, 'https://www.bilibili.com/video/BV1ynhB6wEm6#reply318666621664'],
    ['pages/DynamicDetail', { item: { dynId: '1099999999999999999' } }, 'https://t.bilibili.com/1099999999999999999#reply318666621664'],
    ['pages/BangumiDetail', { currentEpId: 123456 }, 'https://www.bilibili.com/bangumi/play/ep123456#reply318666621664'],
  ];
  for (const [name, context, expected] of cases) {
    const source = read(name);
    const from = source.indexOf('    buildShareLink:');
    const to = source.indexOf('    renderShareCard:', from);
    assert.ok(from >= 0 && to > from);
    const { make } = environment().compile('export function make() { return {\n' + source.slice(from, to) + '\n}; }', name);
    assert.equal(make.call(context).buildShareLink({ rpid: 318666621664 }), expected);
  }
});

test('a stalled image write fails explicitly and removes the incomplete PNG', async () => {
  const fixture = exportFixture(0);
  await assert.rejects(fixture.api.saveReplyShareImage({ cacheDir: '/cache' }, fixture.pixel, 'failed'), /写入失败/);
  assert.equal(fixture.released(), 1);
  assert.equal(fixture.closed(), 1);
  assert.deepEqual(fixture.deleted, ['/cache/failed.png']);
});

test('startup cleanup removes abandoned old sessions and preserves recent preview files', () => {
  const source = read('services/cache/RemoteAssetCache');
  const start = source.indexOf('  private static scheduleLegacyReplySharePurge(): void {');
  const end = source.indexOf('\n  /**', start);
  assert.ok(start >= 0 && end > start);
  const old = 'reply_share_123_' + (Date.now() - 48 * 60 * 60 * 1000) + '_1_1.png';
  const current = 'reply_share_123_' + Date.now() + '_2_1.png';
  const deleted = [], timers = [];
  const env = environment({}, timers);
  const { RemoteAssetCache } = env.compile(
    'let assetCacheDir = "/cache"; export class RemoteAssetCache { static legacyReplySharePurgeScheduled = false;\n' +
      source.slice(start, end) + '\n}', 'services/cache/RemoteAssetCache',
    { fs: { listFileSync: () => [old, current, 'reply_share_123.png', 'unrelated.png'], unlinkSync: value => deleted.push(value) } });
  RemoteAssetCache.scheduleLegacyReplySharePurge();
  for (const timer of timers) timer.callback();
  assert.deepEqual(deleted, ['/cache/' + old, '/cache/reply_share_123.png']);
});

test('production share flow renders every planned page and sends the exact comment link to QR generation', async () => {
  const env = environment();
  const layout = env.load('components/reply/ReplyShareLayout');
  const source = read('components/reply/RepliesController');
  const start = source.indexOf('  share(item: ReplyItem): void {');
  const end = source.indexOf('  /** 打开楼中楼', start);
  assert.ok(start >= 0 && end > start);
  const captured = [], names = [], codes = [], previews = [], snapshots = [], boundRequests = [];
  let view;
  const globals = {
    planReplySharePages: layout.planReplySharePages,
    resolveReplyShareEmotes: layout.resolveReplyShareEmotes,
    EmoteImageCache: { ensure: async url => url },
    makeReplyQr: async link => { codes.push(link); return null; },
    getReplyShareBounds: async ui => { boundRequests.push(ui); return { width: 340, height: 720 }; },
    makeReplyShareSnapshot: async (_ui, builder, height, width) => {
      snapshots.push({ height, width }); builder(); return { height, width };
    },
    saveReplyShareImage: async (_context, _pixel, name) => { names.push(name); return { path: '/cache/' + name, uri: name }; },
    showReplyShareImages: async (_context, files) => previews.push(files.slice()),
    removeReplyShareImages() {},
  };
  const { Harness } = env.compile('let replyShareSequence = 0; export class Harness {\n' + source.slice(start, end) + '\n}',
    'components/reply/RepliesController', globals);
  const link = 'https://www.bilibili.com/video/BV1ynhB6wEm6#reply318666621664';
  const ui = { getHostContext: () => ({ cacheDir: '/cache' }), px2vp: value => value,
    getMeasureUtils: () => ({ measureTextSize: ({ textContent, fontSize }) => ({ width: measure(textContent, parseFloat(fontSize)) }) }) };
  view = Object.assign(new Harness(), { shareCardBusy: false, shareCardQr: null, access: {
    toast() {}, buildShareLink: () => link, getUIContext: () => ui, ensureShareContext: () => true,
    isDestroyed: () => false, onShareFailed: (_item, _link, error) => { throw error; },
    renderShareCard: () => captured.push({ page: view.sharePage(), link: view.shareLink(), qr: view.shareQr() }),
  }});
  const reply = item('完整文本'.repeat(700) + '【末尾】',
    Array.from({ length: 9 }, (_, index) => 'file://picture-' + index + '.png'));
  view.share(reply);
  for (let i = 0; i < 30 && view.shareCardBusy; i++) await tick();
  assert.equal(view.shareCardBusy, false);
  assert.ok(captured.length > 1);
  assert.deepEqual(boundRequests, [ui]);
  assert.deepEqual(codes, [link]);
  assert.ok(captured.every(value => value.link === link && value.qr === null));
  const pages = captured.map(value => value.page);
  assert.equal(allRuns(pages).map(run => run.text).join(''), reply.content);
  assert.deepEqual(pages.flatMap(page => page.pictures), reply.pictures);
  assert.ok(pages.every(page => page.width === 340 && page.height <= 720));
  assert.ok(pages.every(page => page.lines.every(line => line.width <= 340 - 48)));
  assert.ok(pages.every(page => page.pictureSize * 3 + 20 <= 340 - 48));
  assert.deepEqual(snapshots, pages.map(page => ({ height: page.height, width: page.width })),
    'every native snapshot receives the page dimensions chosen for this window');
  assert.equal(previews[0].length, captured.length);
  const firstNames = names.slice();
  view.share(reply);
  for (let i = 0; i < 30 && view.shareCardBusy; i++) await tick();
  assert.equal(new Set(names).size, names.length, 'repeated sharing must not reuse files pending old cleanup');
  assert.equal(names.length, firstNames.length * 2);
});
