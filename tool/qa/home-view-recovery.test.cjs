// Run the production HomeView recovery lifecycle; layout, Scroller and feed IO are boundaries.
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
function section(source, start, end) {
  const begin = source.indexOf(start), finish = source.indexOf(end, begin + start.length);
  assert.ok(begin >= 0 && finish > begin, 'production anchors: ' + start);
  return source.slice(begin, finish);
}
function compile(source, globals = {}) {
  const module = { exports: {} };
  const code = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
  } }).outputText;
  new Function('module', 'exports', ...Object.keys(globals), code)(
    module, module.exports, ...Object.values(globals));
  return module.exports;
}
function fixture(restored) {
  const { AppRecoveryState } = compile(read('common/AppRecoveryState'));
  if (restored) AppRecoveryState.restore(JSON.stringify({ version: 1, rootTab: 0, views: restored }));
  const source = read('views/HomeView');
  const methods = section(source, '  async aboutToAppear(): Promise<void> {',
    '  /** 首页推荐和热门卡片共用视频举报表单。 */') +
    section(source, '  private channelEmpty(', '  onReachEnd(');
  const { Home } = compile('export class Home {\n' + methods + '\n}', {
    AppRecoveryState, AppTheme: { resetHeaderFade() {} },
  });
  const scrollers = Array.from({ length: 3 }, () => ({
    calls: [], offset: { xOffset: 0, yOffset: 0 }, bound: true,
    currentOffset() { if (!this.bound) throw new Error('unbound'); return this.offset; },
    scrollTo(value) {
      if (!this.bound) throw new Error('unbound');
      this.calls.push(value);
      // Native Scroller clamps to the currently loaded range; no paging is synthesized.
      this.offset = { xOffset: value.xOffset, yOffset: Math.min(200, value.yOffset) };
    },
  }));
  const operations = [];
  const page = Object.assign(new Home(), {
    tab: 0, visualTab: 0, recoveryActive: false,
    recoveryOffsets: [undefined, undefined, undefined],
    recCount: 0, hotCount: 0, liveCount: 0,
    recScroller: scrollers[0], hotScroller: scrollers[1], liveScroller: scrollers[2],
    videoReportDialog: null,
    feed: {
      activate: async index => { operations.push(['activate', index]); },
      load: async (index, reset) => { operations.push(['load', index, reset]); },
      dispose: () => { operations.push(['dispose']); },
      accountChanged: async index => { operations.push(['account', index]); },
      recommendModeChanged: async () => { operations.push(['mode']); },
    },
  });
  return { page, recovery: AppRecoveryState, scrollers, operations,
    saved: () => new Map(JSON.parse(AppRecoveryState.serialize()).views.map(entry => [entry.key, entry.state])) };
}

test('home recovery waits for rows, restores its channel once, and saves the actual clamped position', async () => {
  const f = fixture([{ key: 'home', state: { tab: 2 } }, { key: 'home:2', state: { scrollY: 550 } }]);
  await f.page.aboutToAppear();
  assert.equal(f.page.tab, 2); assert.equal(f.page.visualTab, 2);
  f.page.restoreFeedScroll(2);
  assert.equal(f.scrollers[2].calls.length, 0);
  f.page.liveCount = 1;
  f.page.restoreFeedScroll(2); f.page.restoreFeedScroll(2);
  assert.deepEqual(f.scrollers[2].calls, [{ xOffset: 0, yOffset: 550, animation: false }]);
  f.page.saveFeedScroll(2);
  assert.equal(f.saved().get('home:2').scrollY, 200);
  assert.deepEqual(f.operations, [['activate', 2]], 'restore never requests extra pages');
});

test('home refresh and feed policy changes cancel a pending restored offset', async () => {
  const f = fixture([{ key: 'home:0', state: { scrollY: 90 } }, { key: 'home:1', state: { scrollY: 80 } }]);
  await f.page.aboutToAppear();
  f.page.onRefresh(0); f.page.recCount = 1; f.page.restoreFeedScroll(0);
  assert.equal(f.scrollers[0].calls.length, 0);
  assert.deepEqual(f.operations.at(-1), ['load', 0, true]);
  await f.page.onLoginChanged(); f.page.hotCount = 1; f.page.restoreFeedScroll(1);
  assert.equal(f.scrollers[1].calls.length, 0);
  f.page.recoveryOffsets[0] = { scrollY: 90 };
  await f.page.onRecommendModeChanged(); f.page.restoreFeedScroll(0);
  assert.equal(f.scrollers[0].calls.length, 0);
});

test('home departure saves attached lists, retains unavailable channels, and rejects late layout callbacks', async () => {
  const f = fixture([{ key: 'home:2', state: { scrollY: 75 } }]);
  await f.page.aboutToAppear();
  f.scrollers[0].offset.yOffset = 60;
  f.scrollers[1].bound = false;
  let closed = 0;
  f.page.videoReportDialog = { close() { closed++; } };
  f.page.aboutToDisappear(); f.page.liveCount = 1; f.page.restoreFeedScroll(2);
  assert.equal(f.saved().get('home:0').scrollY, 60);
  assert.equal(f.saved().get('home:2').scrollY, 75);
  assert.equal(f.saved().has('home:1'), false);
  assert.equal(f.scrollers[2].calls.length, 0);
  assert.equal(f.page.recoveryActive, false);
  assert.equal(closed, 1); assert.equal(f.page.videoReportDialog, null);
  assert.deepEqual(f.operations.at(-1), ['dispose']);
});

test('a new home visit cannot consume ordinary in-process saved offsets', async () => {
  const f = fixture();
  f.recovery.saveView('home', { tab: 1 });
  f.recovery.saveView('home:1', { scrollY: 150 });
  await f.page.aboutToAppear(); f.page.hotCount = 1; f.page.restoreFeedScroll(1);
  assert.equal(f.page.tab, 0);
  assert.equal(f.scrollers[1].calls.length, 0);
});
