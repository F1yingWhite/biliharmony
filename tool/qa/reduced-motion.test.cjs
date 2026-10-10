// Execute production preferences, navigation lifecycle and action handlers.
// ArkUI rendering DSL is excluded; storage, native navigation and animation scheduling are boundaries.
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
function section(source, from, to) {
  const start = source.indexOf(from), end = source.indexOf(to, start + from.length);
  assert.ok(start >= 0 && end > start, 'production anchors: ' + from);
  return source.slice(start, end);
}
function diskFixture(value) {
  let disk = new Map([['reduceMotionEnabled', String(value)]]);
  const opened = [], puts = [], pending = [];
  const preferences = { getPreferencesSync(context, { name }) {
    assert.equal(name, 'bili_theme_state');
    opened.push(context);
    const cache = new Map(disk);
    return {
      getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
      putSync: (key, next) => { puts.push([key, next]); cache.set(key, next); },
      flush: () => new Promise(resolve => {
        const snapshot = new Map(cache);
        pending.push(() => { disk = snapshot; resolve(); });
      }),
    };
  } };
  return { preferences, opened, puts, pending, read: key => disk.get(key),
    async finishFlushes() { for (const commit of pending.splice(0)) commit(); await Promise.resolve(); } };
}
function environment(boundary = diskFixture(false), initial = {}) {
  const storage = new Map(Object.entries(initial)), cache = new Map(), timers = new Map();
  const navCalls = [], animations = [], haptics = [], transitions = [];
  let timerId = 0;
  const globals = {
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value), delete: key => storage.delete(key) },
    PersistentStorage: { persistProp: (key, value) => { if (!storage.has(key)) storage.set(key, value); } },
    NavPathStack: class { disableAnimation(value) { navCalls.push(value); } },
    Curve: { EaseOut: 'ease-out', EaseInOut: 'ease-in-out', Linear: 'linear' },
    Handedness: { LEFT: 'left' },
    TransitionEffect: { OPACITY: { animation: options => { transitions.push(options); return options; } } },
    $r: value => value,
    setTimeout: (callback, delay) => { timers.set(++timerId, { callback, delay }); return timerId; },
    clearTimeout: id => timers.delete(id),
    NavigationOperation: { POP: 1, PUSH: 0 },
  };
  const mocks = {
    '@kit.ArkUI': { uiMaterial: {}, curves: { springMotion: () => 'spring' } },
    '@kit.ArkData': { preferences: boundary.preferences },
    '@kit.AbilityKit': {}, '@kit.BasicServicesKit': { deviceInfo: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    '@kit.SensorServiceKit': { vibrator: { startVibration: async (...args) => { haptics.push(args); } } },
    BuildProfile: { DEBUG: false },
  };
  function compile(source, name) {
    const module = { exports: {} };
    const code = ts.transpileModule(source, { compilerOptions: {
      target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS,
    } }).outputText;
    const requireLocal = dependency => {
      if (dependency in mocks) return mocks[dependency];
      if (dependency.startsWith('.')) return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), dependency)));
      throw new Error('Unexpected platform dependency ' + dependency);
    };
    new Function('require', 'module', 'exports', ...Object.keys(globals), code)(
      requireLocal, module, module.exports, ...Object.values(globals));
    return module.exports;
  }
  function load(name) {
    if (!cache.has(name)) cache.set(name, compile(read(name), name));
    return cache.get(name);
  }
  const ui = { animateTo: (options, update) => { animations.push(options); update(); } };
  function index() {
    const source = read('pages/Index');
    const { Harness } = compile(`import { MotionTokens } from '../common/MotionTokens';
      import { AppNavStack, HERO_NAV_TRANSITION_ACTIVE_KEY,
      HERO_NAV_TRANSITION_DURATION_KEY } from '../common/AppRouter';
      export class Harness {\n` +
      section(source, '  private onMotionPreferenceChanged():', '\n  }\n') + '\n  }\n' +
      section(source, '  private finishHeroNavTransition(', '  /** 路由参数守卫') + '\n}', 'pages/Index');
    return Object.assign(new Harness(), { reduceMotion: false, tabScale: [1, 1, 1, 1], heroTransitionProxy: null,
      heroTransitionToken: 0, heroTransitionInputLocked: false, heroTransitionClock: 0, getUIContext: () => ui });
  }
  function action() {
    const source = read('components/video/VideoActionItem');
    const prefix = section(source, 'import ', '  build() {')
      .replace('@Component\nexport struct VideoActionItem {', 'export class VideoActionItem {')
      .replace(/@(?:State|Prop|StorageProp)\s*(?:\([^)]*\))?\s*/g, '');
    const callback = section(source, '    .onClick(() => {', '    })\n    .gesture')
      .slice('    .onClick(() => {'.length);
    const { VideoActionItem } = compile(prefix + '\n  tap(): void {\n' + callback + '\n}\n}',
      'components/video/VideoActionItem');
    return Object.assign(new VideoActionItem(), { getUIContext: () => ui });
  }
  function tab() {
    const method = section(read('pages/Index'), '  private tapTabItem(', '  @Builder\n  TabBarItem');
    const { Harness } = compile("import { Haptic } from '../common/Haptic';\nexport class Harness {\n" + method + '\n}', 'pages/Index');
    return Object.assign(new Harness(), { currentTab: 0, tabScale: [1, 1, 1, 1], reduceMotion: true });
  }
  function floatingTabs() {
    const method = section(read('views/HomeView'), '  onHandSideChanged():', "  @StorageProp('windowStatusBarHeight')");
    const { Harness } = compile("import { MotionTokens } from '../common/MotionTokens';\nexport class Harness {\n" + method + '\n}', 'views/HomeView');
    return Object.assign(new Harness(), { handLayoutMounted: true, handSide: 'left', handPosition: 0,
      reduceMotion: true, getUIContext: () => ui });
  }
  function preferenceRow() {
    const method = section(read('pages/PreferencesPage'), '  private changeChecked(', '  @Builder\n  Content()');
    const { Harness } = compile('export class Harness {\n' + method + '\n}', 'pages/PreferencesPage');
    return Object.assign(new Harness(), { checked: false, rowEnabled: true, onChange() {} });
  }
  return { load, storage, timers, navCalls, animations, haptics, transitions, index, action, tab, floatingTabs, preferenceRow };
}

test('reduce-motion changes flush to Preferences and recover in new contexts and module graphs', async () => {
  const disk = diskFixture(false), first = environment(disk), context1 = {};
  const theme = first.load('common/AppTheme').AppTheme;
  const motion = first.load('common/MotionTokens').MotionTokens;
  theme.init(context1); await theme.initThemeStore(context1);
  assert.equal(motion.isReduced(), false);
  theme.setReduceMotion(true);
  assert.equal(motion.duration(260), 0, 'the runtime preference changes immediately');
  assert.equal(disk.read('reduceMotionEnabled'), 'false', 'putSync alone must not pretend to be durable');
  assert.ok(disk.pending.length > 0, 'production must request a real flush');
  await disk.finishFlushes();
  assert.equal(disk.read('reduceMotionEnabled'), 'true');
  const fresh = environment(disk), context2 = {};
  const freshTheme = fresh.load('common/AppTheme').AppTheme;
  freshTheme.init(context2);
  assert.equal(fresh.storage.get('reduceMotionEnabled'), false, 'no AppStorage is copied between processes');
  await freshTheme.initThemeStore(context2);
  const freshMotion = fresh.load('common/MotionTokens').MotionTokens;
  assert.equal(freshMotion.isReduced(), true);
  freshTheme.setReduceMotion(false);
  assert.equal(freshMotion.duration(260), 260);
  await disk.finishFlushes();
  const third = environment(disk, { reduceMotionEnabled: true }), context3 = {};
  const thirdTheme = third.load('common/AppTheme').AppTheme;
  thirdTheme.init(context3); await thirdTheme.initThemeStore(context3);
  assert.equal(third.load('common/MotionTokens').MotionTokens.isReduced(), false,
    'Preferences false must replace a stale legacy true value');
  assert.deepEqual(disk.opened, [context1, context2, context3]);
  assert.ok(disk.puts.some(([key, value]) => key === 'reduceMotionEnabled' && value === 'true'));
  assert.ok(disk.puts.some(([key, value]) => key === 'reduceMotionEnabled' && value === 'false'));
});

test('enabling reduced motion finishes an active native hero and re-enabling motion restores navigation animation', () => {
  const env = environment(), page = env.index();
  env.storage.set('heroNavTransitionActive', true);
  let finished = 0;
  const transition = page.heroNavTransition({}, {}, 1);
  transition.transition({ finishTransition() { finished++; throw new Error('native transition already completed'); } });
  assert.equal(page.heroTransitionInputLocked, true);
  env.storage.set('reduceMotionEnabled', true);
  page.reduceMotion = true; page.onMotionPreferenceChanged();
  assert.equal(finished, 1);
  assert.equal(page.heroTransitionProxy, null);
  assert.equal(page.heroTransitionInputLocked, false);
  assert.equal(page.heroTransitionClock, 0);
  assert.equal(env.storage.get('heroNavTransitionActive'), false);
  // A native completion and timeout can arrive after the explicit finish; neither may finish it twice.
  for (const options of env.animations) options.onFinish?.();
  for (const timer of env.timers.values()) timer.callback();
  assert.equal(finished, 1);
  env.storage.set('reduceMotionEnabled', false);
  page.reduceMotion = false; page.onMotionPreferenceChanged();
  assert.deepEqual(env.navCalls, [true, false]);
});

test('reduced motion clears a pending hero before the native transition proxy arrives', () => {
  const env = environment(), page = env.index();
  env.storage.set('heroNavTransitionActive', true);
  const transition = page.heroNavTransition({}, {}, 1);
  assert.equal(page.heroTransitionInputLocked, true);
  assert.equal(page.heroTransitionProxy, null);
  env.storage.set('reduceMotionEnabled', true);
  page.reduceMotion = true; page.onMotionPreferenceChanged();
  assert.equal(page.heroTransitionInputLocked, false);
  assert.equal(env.storage.get('heroNavTransitionActive'), false);
  let finished = 0;
  transition.transition({ finishTransition() { finished++; } });
  assert.equal(finished, 1, 'the late native proxy should commit immediately');
  assert.equal(env.animations.length, 0);
  assert.equal(env.timers.size, 0);
});

test('reduced action taps execute once without bounce timers and still respect the busy guard', () => {
  const env = environment(undefined, { reduceMotionEnabled: true }), item = env.action();
  let taps = 0;
  item.onTap = () => { taps++; };
  item.iconScale = 1.12;
  item.tap();
  assert.equal(taps, 1);
  assert.equal(env.haptics.length, 1);
  assert.equal(item.iconScale, 1);
  assert.equal(env.animations.length, 0);
  assert.equal(env.timers.size, 0);
  item.busy = true; item.tap();
  assert.equal(taps, 1);
  assert.equal(env.haptics.length, 1);
  item.busy = false;
  env.storage.set('reduceMotionEnabled', false);
  item.tap();
  assert.equal(taps, 2);
  assert.equal(env.animations.length, 1, 'normal feedback becomes available again');
  assert.equal(env.timers.size, 1);
  item.aboutToDisappear();
  assert.equal(env.timers.size, 0, 'unmount cancels the outstanding normal feedback timer');
});

test('accent ink meets text contrast for every selectable theme and platform accent', () => {
  const Theme = environment().load('common/AppTheme').AppTheme;
  const luminance = hex => {
    const rgb = hex.slice(1).match(/../g).map(value => parseInt(value, 16) / 255)
      .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
  };
  for (const color of [...Theme.PRESET_COLORS, '#FF0000', '#000000', '#FFFFFF']) {
    const bg = luminance(color), fg = luminance(Theme.onAccent(color));
    assert.ok((Math.max(bg, fg) + 0.05) / (Math.min(bg, fg) + 0.05) >= 4.5, color);
  }
  assert.equal(Theme.onAccent('#FFCC00'), '#000000');
  assert.equal(Theme.onAccent('#8E24AA'), '#FFFFFF');
});

test('feed columns retain a readable card width in narrow, phone and wide windows', () => {
  const Layout = environment().load('common/LayoutTokens').LayoutTokens;
  for (const width of [240, 320, 359, 360, 560, 820, 1040, 1800]) {
    const columns = Layout.feedColumns(width);
    const contentWidth = Math.min(width, Layout.feedMaxWidth) - 2 * Layout.horizontalPadding(width);
    const cardWidth = (contentWidth - (columns - 1) * Layout.feedGap) / columns;
    assert.ok(cardWidth >= 150, `${width}vp: ${columns} columns squeeze the card to ${cardWidth}vp`);
  }
  assert.equal(Layout.feedColumns(320), 1);
  assert.equal(Layout.feedColumns(360), 2, 'ordinary phone density remains unchanged');
});

test('native preference changes persist once and reject unchanged or disabled events', () => {
  const row = environment().preferenceRow(), values = [];
  row.onChange = value => { values.push(value); row.checked = value; };
  row.changeChecked(true); row.changeChecked(true);
  row.changeChecked(false); row.changeChecked(false);
  row.rowEnabled = false; row.changeChecked(true);
  assert.deepEqual(values, [true, false]);
});

test('reduced tab taps keep selection and haptics without any scale jump or timer', () => {
  const env = environment(), tab = env.tab();
  tab.tapTabItem(1);
  assert.equal(tab.currentTab, 1);
  assert.deepEqual(tab.tabScale, [1, 1, 1, 1]);
  assert.equal(env.timers.size, 0);
  assert.equal(env.haptics.length, 1);
  tab.reduceMotion = false; tab.tapTabItem(2);
  assert.equal(tab.currentTab, 2);
  assert.equal(tab.tabScale[2], 0.78);
  for (const timer of env.timers.values()) timer.callback();
  assert.deepEqual(tab.tabScale, [1, 1, 1, 1]);
});

test('floating home tabs apply handedness immediately when motion is reduced', () => {
  const env = environment(), tabs = env.floatingTabs();
  tabs.onHandSideChanged();
  assert.equal(tabs.handPosition, 1);
  assert.equal(env.animations.at(-1).duration, 0);
  tabs.reduceMotion = false; tabs.handSide = 'right'; tabs.onHandSideChanged();
  assert.equal(tabs.handPosition, 0);
  assert.equal(env.animations.at(-1).duration, 320);
  tabs.handLayoutMounted = false; tabs.onHandSideChanged();
  assert.equal(env.animations.length, 2, 'unmounted pages cannot start decorative animations');
});
