// Execute production Hero controllers, component state/methods and MotionTokens.
// Only ArkUI scheduling, navigation, display and network are fake platform boundaries.
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
    .replace(/\r\n/g, '\n') + '\n';
}
function section(source, start, end) {
  const begin = source.indexOf(start), finish = source.indexOf(end, begin);
  assert.ok(begin >= 0 && finish > begin, 'production anchors: ' + start + ' -> ' + end);
  return source.slice(begin, finish);
}
function clean(source) { return source.replace(/@(?:State|Prop|StorageProp|Watch)\s*(?:\([^)]*\))?\s*/g, ''); }
function environment(reduced) {
  const storage = new Map([['reduceMotionEnabled', reduced]]), cache = new Map(), calls = [];
  const timers = new Map(), frames = [], animations = []; let clock = 0;
  const display = { getDefaultDisplaySync: () => ({ width: 400, height: 800 }) };
  const ui = {
    px2vp: x => x, vp2px: x => x,
    postFrameCallback: frame => frames.push(frame),
    animateTo: (options, update) => { animations.push(options); update(); },
    getComponentUtils: () => { throw Error('reduced navigation must not measure a source node'); },
    getComponentSnapshot: () => { throw Error('reduced navigation must not capture a snapshot'); },
  };
  const globals = {
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value),
      delete: key => storage.delete(key) },
    NavPathStack: class { pushPathByName(...args) { calls.push(['push', ...args]); } pop(...args) { calls.push(['pop', ...args]); } },
    SwiperController: class { changeIndex(...args) { calls.push(['index', ...args]); } }, Scroller: class {},
    Curve: { EaseOut: 'out', EaseInOut: 'inout', Sharp: 'sharp', Friction: 'friction' },
    setTimeout: fn => { timers.set(++clock, fn); return clock; }, clearTimeout: id => timers.delete(id),
    Haptic: { light() {} }, Immersive: { setBarIcons() {}, statusBarHeight: () => 20 },
    DynamicItem: class {}, ReplyItem: class {},
  };
  function compile(source, file) {
    const module = { exports: {} };
    const code = ts.transpileModule(source, { compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
    } }).outputText;
    const requireLocal = name => {
      if (name.startsWith('.')) return load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)));
      if (name === '@kit.ArkUI') return { FrameCallback: class {}, display };
      if (name === '@kit.NetworkKit') return { http: {
        RequestMethod: { HEAD: 'HEAD' }, createHttp: () => ({ destroy() {}, request: async () => ({ header: {} }) }),
      } };
      throw Error('unmocked platform import: ' + name);
    };
    new Function('require', 'module', 'exports', ...Object.keys(globals), code)(
      requireLocal, module, module.exports, ...Object.values(globals));
    return module.exports;
  }
  function load(file) {
    if (!cache.has(file)) cache.set(file, compile(read(file), file));
    return cache.get(file);
  }
  function harness(file, ranges, extra = '', fields = '') {
    const source = read(file);
    const imports = file.startsWith('components/') ? '../../common/' : '../common/';
    return compile(`import { MotionTokens } from '${imports}MotionTokens';
      import { AppNavStack, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
        HERO_NAV_TRANSITION_FINISH_REQUEST_KEY, NAV_VIDEO_DETAIL, NAV_IMAGE_VIEWER } from '${imports}AppRouter';
      import { biliImageOriginal, biliImageThumbnail, FEED_COVER_WIDTH } from '${imports}ImageUrl';
      import { BasicDataSource } from '${imports}BasicDataSource';
      import { FrameCallback, display } from '@kit.ArkUI'; import { http } from '@kit.NetworkKit';
      ${extra}\nexport class Harness {\n${clean(fields)}\n${clean(ranges.map(([a,b]) => section(source,a,b)).join('\n'))}\n}`,
    file).Harness;
  }
  return { storage, calls, timers, frames, animations, ui, load, harness };
}
function videoHarness(reduced) {
  const env = environment(reduced);
  const Hero = env.load('components/video/VideoHeroTransitionController').VideoHeroTransitionController;
  const state = { wholeCardSnapshot: null, fromWholeCard: false, fromRect: false, entranceArmed: false };
  const access = {};
  for (const name of ['ContentOpacity', 'HeroVisible', 'HeroSource', 'HeroX', 'HeroY', 'HeroWidth', 'HeroHeight',
    'HeroRadius', 'HeroOpacity', 'WholeCardAnimating', 'WholeCardSnapshot', 'WholeCardSnapshotOpacity',
    'WholeCardScale', 'WholeCardTranslateX', 'WholeCardTranslateY', 'WholeCardClipHeight', 'WholeCardRadius',
    'WholeCardSnapshotHeight', 'FromWholeCard', 'FromRect', 'EntranceArmed']) {
    const key = name[0].toLowerCase() + name.slice(1);
    access['set' + name] = value => { state[key] = value; };
  }
  access.getWholeCardSnapshot = () => state.wholeCardSnapshot;
  access.isFromWholeCard = () => state.fromWholeCard;
  access.isFromRect = () => state.fromRect;
  access.isEntranceArmed = () => state.entranceArmed;
  const motion = { gateFallbackMs: 600, wholeCardExpandMs: 340, wholeCardContentMs: 180,
    wholeCardSnapshotFadeMs: 140, wholeCardSnapshotFadeDelayMs: 90, cardFlightMs: 280,
    cardContentMs: 180, cardContentDelayMs: 100, cardCoverRadius: 6, popDurationMs: 360,
    wholeCardCollapseMs: 340, exitSnapshotInMs: 140, exitSnapshotInDelayMs: 70,
    exitContentOutMs: 180, exitContentOutDelayMs: 100, cardExitContentMs: 180, cardExitFlightMs: 280, cardCornerVp: 6 };
  const keys = { snapshotKey: 'snapshot', activeKey: 'active', durationKey: 'duration', finishRequestKey: 'finish' };
  const hero = new Hero(keys, motion, access, () => ({ x: 0, y: 0, w: 400, h: 220 }), () => 'cover',
    () => 400, () => 800, () => ({ x: 10, y: 30, w: 180, h: 120 }),
    () => ({ x: 10, y: 30, w: 180, h: 100 }), () => false, () => false, () => false,
    () => env.ui, fn => env.timers.set(env.timers.size + 1, fn));
  return { ...env, hero, state };
}
function imageHarness(reduced) {
  const env = environment(reduced), source = read('pages/ImageViewer');
  const fields = section(source, 'export struct ImageViewerPage {', '  aboutToAppear(): void {')
    .replace('export struct ImageViewerPage {', '');
  const frame = section(source, 'const IMAGE_HERO_ENTER_DURATION:', '@Component');
  const Harness = env.harness('pages/ImageViewer', [
    ['  aboutToAppear(): void {\n    this.closing', '  private currentUrl():'],
    ['  private currentUrl():', '  private imageExtension('],
    ['  aboutToDisappear(): void {', '  build() {\n    Stack({ alignContent: Alignment.Center }) {\n      Column()'],
  ], frame, fields);
  const page = new Harness(); page.getUIContext = () => env.ui;
  page.param = { images: ['https://i0.hdslb.com/test.jpg'], initialIndex: 0,
    srcRect: { x: 10, y: 20, w: 100, h: 60 }, transitionId: 'source-0' };
  return { ...env, page };
}

test('reduced video entry frees staged and owned snapshots, opens its gate and skips scheduling', async () => {
  const { hero, state, storage, timers, frames, animations } = videoHarness(true);
  let staged = 0, owned = 0;
  storage.set('snapshot', { release: () => staged++ });
  state.wholeCardSnapshot = { release: () => owned++ }; state.fromWholeCard = state.fromRect = true;
  assert.equal(hero.prepareWholeCardEntrance(), false);
  hero.prepareCardEntrance(); hero.armEntranceGate(); hero.triggerEntranceExpansion(); hero.triggerWholeCardExpansion();
  await hero.waitEntranceGate();
  assert.deepEqual([staged, owned], [1, 1]); assert.equal(storage.has('snapshot'), false);
  assert.equal(state.wholeCardSnapshot, null); assert.equal(state.contentOpacity, 1);
  assert.equal(state.heroVisible, false); assert.equal(state.wholeCardAnimating, false);
  assert.equal(state.fromRect, false); assert.equal(state.fromWholeCard, false);
  assert.deepEqual([timers.size, frames.length, animations.length], [0, 0, 0]);
  assert.equal(storage.get('active'), false); assert.equal(storage.get('duration'), 0);
});

test('reduced video close releases an aliased snapshot once and pops synchronously without a hero lock', () => {
  const { hero, state, storage, calls, frames, animations } = videoHarness(true);
  let released = 0; const snapshot = { release: () => released++ };
  state.wholeCardSnapshot = snapshot; storage.set('snapshot', snapshot); storage.set('active', true);
  hero.runCloseTransition();
  assert.equal(released, 1); assert.deepEqual(calls, [['pop', false]]);
  assert.equal(storage.get('active'), false); assert.ok(storage.get('finish') > 0);
  assert.deepEqual([frames.length, animations.length], [0, 0]);
});

test('enabling reduced motion before an already queued video frame releases the gate without flying', async () => {
  const { hero, state, storage, frames, animations } = videoHarness(false);
  let released = 0; storage.set('snapshot', { release: () => released++ });
  assert.equal(hero.prepareWholeCardEntrance(), true); hero.armEntranceGate(); hero.triggerWholeCardExpansion();
  let opened = false; hero.waitEntranceGate().then(() => { opened = true; });
  await Promise.resolve(); assert.equal(opened, false);
  storage.set('reduceMotionEnabled', true); frames.shift().onFrame(0); await Promise.resolve();
  assert.equal(opened, true); assert.equal(released, 1); assert.equal(animations.length, 0);
  assert.equal(state.contentOpacity, 1); assert.equal(state.wholeCardAnimating, false);
});

test('default video whole-card entrance still waits for VSync and the actual animation completion', async () => {
  const { hero, state, storage, frames, animations } = videoHarness(false);
  let released = 0; storage.set('snapshot', { release: () => released++ });
  assert.equal(hero.prepareWholeCardEntrance(), true); hero.armEntranceGate(); hero.triggerWholeCardExpansion();
  let opened = false; hero.waitEntranceGate().then(() => { opened = true; });
  await Promise.resolve(); assert.equal(opened, false); assert.equal(animations.length, 0);
  assert.equal(state.wholeCardScale, .45); assert.equal(state.contentOpacity, 0);
  frames.shift().onFrame(0); assert.deepEqual(animations.map(x => x.duration), [340, 180, 140]);
  assert.equal(opened, false); animations[0].onFinish(); await Promise.resolve();
  assert.equal(opened, true); assert.equal(state.wholeCardAnimating, false); assert.equal(released, 0);
});

test('reduced image entry immediately exposes image and controls without matching source geometry or input timers', () => {
  const { page, timers, frames, animations } = imageHarness(true);
  page.aboutToAppear();
  assert.equal(page.hasSystemGeometryTransition(), false);
  assert.notEqual(page.transitionIdFor(0), page.param.transitionId);
  assert.deepEqual([page.viewerOpacity, page.uiOpacity, page.bgOpacity], [1, 1, 1]);
  assert.equal(page.interactionReady, true); assert.equal(page.heroVisible, false);
  assert.equal(page.entryFromRect, false); assert.equal(timers.size, 0); assert.equal(animations.length, 0);
  assert.equal(frames.length, 1, 'only the existing nonanimated initial Swiper positioning remains');
});

test('reduced zoomed image close bypasses child handshake, clears all hero timers/frame and only pops once', () => {
  const { page, calls, timers, storage, animations } = imageHarness(true);
  let released = 0; page.heroFrame = { release: () => released++ };
  page.currentZoomed = true; page.entryFromRect = true; page.heroExitPending = true;
  for (const [i, field] of ['heroFallbackTimer', 'interactionReadyTimer', 'heroHandoffTimer', 'heroExitTimer'].entries()) {
    timers.set(i + 1, () => {}); page[field] = i + 1;
  }
  storage.set('heroNavTransitionActive', true);
  page.goBack(); page.goBack(); page.finishZoomedBack(3, 20, 40);
  assert.deepEqual(calls, [['pop', false]]); assert.equal(page.resetZoomForExit, false);
  assert.equal(released, 1); assert.equal(page.heroFrame, null); assert.equal(page.heroVisible, false);
  assert.equal(page.heroExitPending, false); assert.equal(timers.size, 0); assert.equal(animations.length, 0);
  assert.equal(storage.get('heroNavTransitionActive'), false);
  assert.ok(storage.get('heroNavTransitionFinishRequest') > 0);
});

test('reduced motion aborts image entrance queued before preference changed and releases gesture wait', () => {
  const { page, storage, timers, frames, animations } = imageHarness(false);
  page.param.transitionId = ''; page.aboutToAppear(); page.startHeroEntrance(1000, 500);
  assert.equal(page.interactionReady, false); assert.equal(page.heroVisible, true);
  storage.set('reduceMotionEnabled', true);
  while (frames.length) frames.shift().onFrame(0);
  assert.equal(page.interactionReady, true); assert.equal(page.heroVisible, false);
  assert.equal(page.viewerOpacity, 1); assert.equal(timers.size, 0); assert.equal(animations.length, 0);
});

test('reduced dynamic detail bypasses both directions, leaves content visible and releases navigation', () => {
  const env = environment(true), source = read('pages/DynamicDetail');
  const fields = section(source, 'export struct DynamicDetailPage {', '  /**\n   * 评论编排控制器')
    .replace('export struct DynamicDetailPage {', '');
  const frame = section(source, 'class DynamicHeroFrameCallback', '@Component');
  // This fixture exercises only Hero navigation; submission behavior has its own complete-module tests.
  const Harness = env.harness('pages/DynamicDetail', [['  private targetCardRect():', '  aboutToAppear():']],
    frame + '\nclass ReplySubmissionController { reset() {} dispose() {} }', fields);
  const page = new Harness(); page.getUIContext = () => env.ui;
  page.param = { srcRect: { x: 10, y: 20, w: 100, h: 60 } };
  page.prepareEntrance(); page.triggerEntrance(); page.goBack(); page.goBack();
  assert.equal(page.heroVisible, false); assert.equal(page.contentOpacity, 1); assert.equal(page.entranceArmed, false);
  assert.equal(env.frames.length, 0); assert.equal(env.animations.length, 0);
  assert.deepEqual(env.calls, [['pop', false]]); assert.equal(env.storage.get('heroNavTransitionActive'), false);
});

for (const entry of ['video card', 'private video', 'private image', 'reply pictures', 'user header']) {
  test(`reduced ${entry} navigation preserves its payload without measuring/capturing/animating`, () => {
    const env = environment(true); let Harness, page, expectedRoute, expectedPayload;
    if (entry === 'video card') {
      Harness = env.harness('components/video/VideoCard', [['  private openDetail():', '\n}\n']]);
      page = new Harness(); page.video = { bvid: 'BV1', aid: 10, title: 'title', cover: 'cover' };
      page.wholeCardTransition = true; expectedRoute = 'VideoDetail'; expectedPayload = page.video;
      page.getUIContext = () => env.ui; page.openDetail();
    } else if (entry.startsWith('private')) {
      Harness = env.harness('pages/Messages', [['  private richMediaId(', '  @Builder\n  RichMessageCard']]);
      page = new Harness(); page.getUIContext = () => env.ui;
      const item = { imageUrl: entry === 'private image' ? 'image' : '', richBvid: 'BV1', richAid: 10,
        richTitle: 'title', richCover: 'cover', text: '' };
      expectedRoute = item.imageUrl ? 'ImageViewer' : 'VideoDetail';
      expectedPayload = item.imageUrl ? { images: ['image'], initialIndex: 0 } : { bvid: 'BV1', aid: 10, title: 'title', cover: 'cover' };
      page.openRichMessage(item);
    } else if (entry === 'reply pictures') {
      Harness = env.harness('components/reply/ReplyCard', [['  private openPicture(', '  private visualDepth():']]);
      page = new Harness(); page.getUIContext = () => env.ui; page.item = { pictures: ['one', 'two'] };
      expectedRoute = 'ImageViewer'; expectedPayload = { images: ['one', 'two'], initialIndex: 1 }; page.openPicture(1);
    } else {
      Harness = env.harness('pages/UserSpace', [['  private openHeaderImage():', '  @Builder\n  HeaderImage('],
        ['  private headerTransitionId(', '  async init():']]);
      page = new Harness(); page.getUIContext = () => env.ui;
      page.info = { collectionHeaders: [], topPhoto: 'banner' }; page.headerIndex = 0; page.param = { mid: 42 };
      expectedRoute = 'ImageViewer'; expectedPayload = { images: ['banner'], initialIndex: 0 }; page.openHeaderImage();
    }
    assert.deepEqual(env.calls, [['push', expectedRoute, expectedPayload, false]]);
    assert.equal(env.animations.length, 0); assert.equal(env.storage.has('heroNavTransitionActive'), false);
  });
}
