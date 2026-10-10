const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createArktsLoader} = require('./arkts-module.cjs');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');
const {fixture: sessionFixture, tick} = require('./player-session-fixture.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

const immersive = {windowBrightness: () => 0.4, setWindowBrightness() {}};
const theme = {loadLastBrightness: () => 0.5, saveLastBrightness() {}};
function controllerFixture() {
  const load = createArktsLoader({mocks: {
    'common/Immersive': {Immersive: immersive}, 'common/AppTheme': {AppTheme: theme},
  }});
  const {PlayerGestureController} = load('components/player/PlayerGestureController');
  const previews = [], seeks = [], brightness = [], volumes = [];
  const ctl = new PlayerGestureController(value => previews.push(value), value => seeks.push(value),
    () => {}, () => {}, value => volumes.push(value), () => {}, value => brightness.push(value));
  return {ctl, previews, seeks, brightness, volumes, PlayerGestureController};
}

test('short horizontal movement has the same seconds on a 20-minute or two-hour video', () => {
  for (const duration of [1200, 7200]) {
    for (const width of [400, 800]) {
      const f = controllerFixture();
      f.ctl.beginPan(100, width, 600.25, duration);
      f.ctl.updatePan(width / 10, 0, width, duration);
      assert.equal(f.previews.at(-1), 606.25);
      f.ctl.updatePan(-width / 10, 0, width, duration);
      assert.equal(f.previews.at(-1), 594.25, 'reversing the swipe stays relative to the starting playhead');
      assert.deepEqual(f.seeks, [], 'motion updates only preview');
      f.ctl.endPan(); f.ctl.endPan();
      assert.deepEqual(f.seeks, [-1], 'release submits only once');
    }
  }
});

test('short clips reduce the window and every pan protects both edges and limits its range', () => {
  const f = controllerFixture();
  f.ctl.beginPan(100, 400, 10, 30);
  f.ctl.updatePan(40, 0, 400, 30); assert.equal(f.previews.at(-1), 13);
  f.ctl.updatePan(4000, 0, 400, 30); assert.equal(f.previews.at(-1), 29.5);
  f.ctl.updatePan(-4000, 0, 400, 30); assert.equal(f.previews.at(-1), 0);
  f.ctl.cancelPan();
  f.ctl.beginPan(100, 400, 1000, 7200);
  f.ctl.updatePan(4000, 0, 400, 7200); assert.equal(f.previews.at(-1), 1060);
  f.ctl.updatePan(-4000, 0, 400, 7200); assert.equal(f.previews.at(-1), 940);
  f.ctl.cancelPan();
  f.ctl.beginPan(100, 400, 7198, 7200);
  f.ctl.updatePan(40, 0, 400, 7200); assert.equal(f.previews.at(-1), 7199.5);
});

test('layout and metadata changes cannot alter the sensitivity of an ongoing pan', () => {
  const f = controllerFixture(); f.ctl.beginPan(100, 400, 600, 1200);
  f.ctl.updatePan(40, 0, 800, 7200); assert.equal(f.previews.at(-1), 606);
  f.ctl.updatePan(80, 0, 1, 0); assert.equal(f.previews.at(-1), 612);
});

test('unknown viewport, duration or playhead cannot become a horizontal seek', () => {
  const inputs = [
    ...[0, 1, -1, NaN, Infinity].map(width => [width, 100, 1200]),
    ...[0, -1, NaN, Infinity].map(duration => [400, 100, duration]),
    ...[-1, NaN, Infinity].map(start => [400, start, 1200]),
  ];
  for (const [width, start, duration] of inputs) {
    const f = controllerFixture(); f.ctl.beginPan(100, width, start, duration);
    f.ctl.updatePan(40, 0, width, duration); f.ctl.endPan();
    assert.deepEqual(f.seeks, []); assert.deepEqual(f.previews, [-1]);
  }
});

test('cancel and malformed motion discard a preview and reject late updates or repeated releases', () => {
  for (const badOffset of [undefined, NaN, Infinity]) {
    const f = controllerFixture();
    f.ctl.updatePan(40, 0, 400, 1200); assert.deepEqual(f.previews, []);
    f.ctl.beginPan(100, 400, 100, 1200); f.ctl.updatePan(40, 0, 400, 1200);
    if (badOffset === undefined) f.ctl.cancelPan();
    else f.ctl.updatePan(badOffset, 0, 400, 1200);
    assert.equal(f.previews.at(-1), -1);
    f.ctl.updatePan(80, 0, 400, 1200); f.ctl.endPan();
    assert.deepEqual(f.seeks, []); assert.equal(f.ctl.panMode, '');
    assert.equal(f.ctl.panGestureActive, false);
    f.ctl.beginPan(100, 400, 200, 1200); f.ctl.updatePan(40, 0, 400, 1200);
    assert.equal(f.previews.at(-1), 206, 'a fresh pan works after cancellation');
  }
});

test('live and unknown-size vertical gestures retain bounded volume and brightness adjustments', () => {
  for (const width of [0, 1, 400]) {
    const f = controllerFixture(); f.ctl.gestureVolume = 27;
    f.ctl.beginPan(500, width, 0, 0); f.ctl.updatePan(0, -10, width, 0); f.ctl.endPan();
    assert.ok(f.volumes.at(-1) > 27 && f.volumes.at(-1) < 34);
    f.ctl.beginPan(-1, width, 0, 0); f.ctl.updatePan(0, -10, width, 0); f.ctl.endPan();
    assert.ok(f.brightness.at(-1) > 0.4 && f.brightness.at(-1) < 0.47);
    f.ctl.beginPan(100, width, 0, 0); f.ctl.updatePan(40, 0, width, 0); f.ctl.endPan();
    assert.deepEqual(f.seeks, []);
  }
});

// Execute the production ArkUI adapters and constructor callbacks, with the real
// playback session/seek graph. Native hit testing and platform effects are mocked.
function viewFixture() {
  const f = sessionFixture(), effects = [], controller = controllerFixture();
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'components/player/PlayerView.ets'), 'utf8').replace(/\r\n/g, '\n');
  function between(start, end) {
    const a = source.indexOf(start), b = source.indexOf(end, a);
    assert.ok(a >= 0 && b > a, 'UI adapter anchors: ' + start); return source.slice(a, b);
  }
  const initialization = between('      this.gestureCtl = new PlayerGestureController(', '\n    }\n    this.playback.activate');
  const body = between('  private beginPlayerPan(', '  private progressDisplayTime(') +
    between('  private clearSeekPreviewInteraction(', '  private handleDoubleTap(') +
    between('  seekTo(positionSec:', '  toggleFullscreen():');
  const code = ts.transpileModule('class View {initialize() {' + initialization + '}\n' + body + '\n}; return View;',
    {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  const View = new Function('PlayerGestureController', 'Haptic', 'Immersive', 'AppTheme', 'clearTimeout', code)(
    controller.PlayerGestureController, {seek: () => effects.push(['haptic'])}, immersive, theme, f.globals.clearTimeout);
  const page = Object.assign(new View(), {playback: f.session, playing: true, panEnabled: true, endScreenOpen: false,
    showControls: false, hideTimer: -1, playheadSec: 1000.25, duration: 7200, gestureScrubValue: -1,
    dmEngine: {width: 400}, systemVolume: {percent: () => 27}, dmInteraction: {cancelPending() {}},
    scrubCtl: {show: value => effects.push(['preview', value])},
    seekTargetCtl: {show: value => effects.push(['target', value])},
    seekPreviewCtl: {release: () => effects.push(['release'])},
    requestSeekPreview: value => effects.push(['request', value]), closeSeekPreview: () => effects.push(['close']),
    scheduleControlsHide: () => effects.push(['hide']), applyGestureVolume: value => effects.push(['volume', value]),
  });
  let origin = 0, originWrites = 0;
  Object.defineProperty(page, 'gesturePanStartTime', {get: () => origin, set(value) {origin = value; originWrites++;}});
  page.initialize();
  const start = () => page.beginPlayerPan({fingerList: [{localX: 100}]});
  const move = offsetX => page.updatePlayerPan({offsetX, offsetY: 0});
  return {...f, page, effects, start, move, originWrites: () => originWrites};
}

test('view pan keeps the active hit surface, freezes its origin and releases one precise seek in playing or paused state', async () => {
  for (const playing of [true, false]) {
    const f = viewFixture(), {engine} = await f.boot(); f.playing();
    if (!playing) f.session.pause();
    f.page.playing = playing; f.page.showControls = !playing;
    f.page.hideTimer = f.globals.setTimeout(() => {f.page.showControls = false;}, 500);
    const playCalls = f.calls(engine, 'play').length, pauseCalls = f.calls(engine, 'pause').length;
    f.start(); assert.equal(f.page.hideTimer, -1);
    f.move(40); f.page.playheadSec = 1008; f.advance(600); f.move(80);
    assert.equal(f.page.showControls, !playing, 'the active surface must not unmount mid-swipe');
    assert.equal(f.page.gesturePanStartTime, 1000.25); assert.equal(f.originWrites(), 1);
    assert.equal(f.page.gestureScrubValue, 1012.25); assert.deepEqual(f.calls(engine, 'seek'), []);
    f.page.endPlayerPan(); f.page.endPlayerPan(); f.page.cancelPlayerPan();
    assert.deepEqual(f.effects.filter(effect => effect[0] === 'target').at(-1), ['target', 1012.25],
      'a late cancellation after release must retain the pending progress target');
    f.advance(60); await tick();
    assert.deepEqual(f.calls(engine, 'seek'), [['seek', 1012250, 0]]);
    assert.equal(f.calls(engine, 'play').length, playCalls); assert.equal(f.calls(engine, 'pause').length, pauseCalls);
    assert.equal(f.page.showControls, true); assert.equal(f.page.gestureScrubValue, -1);
    assert.equal(f.effects.filter(effect => effect[0] === 'haptic').length, 1);
    assert.equal(f.originWrites(), 1); f.session.deactivate();
  }
});

test('cancel, replay/source cleanup, release or disabled pan cannot commit late gesture events', async () => {
  for (const reset of ['cancelPlayerPan', 'clearSeekPreviewInteraction', 'releaseSeekPreview', 'disabled', 'disabled-end', 'invalid']) {
    const f = viewFixture(), {engine} = await f.boot(); f.playing(); f.start(); f.move(40);
    if (reset === 'disabled') {f.page.panEnabled = false; f.move(60);}
    else if (reset === 'disabled-end') {f.page.panEnabled = false; f.page.endPlayerPan();}
    else if (reset === 'invalid') f.move(NaN);
    else f.page[reset]();
    f.move(80); f.page.endPlayerPan(); f.advance(60); await tick();
    assert.deepEqual(f.calls(engine, 'seek'), [], reset);
    assert.equal(f.page.gestureScrubValue, -1); assert.equal(f.page.gestureCtl.panMode, '');
    assert.equal(f.effects.filter(effect => effect[0] === 'haptic').length, 0); f.session.deactivate();
  }
});

test('native gesture surface sends system cancellation through the cancel callback only', () => {
  const calls = [], recognizers = [];
  const gesture = kind => (...args) => {
    const handlers = {kind, args}; recognizers.push(handlers); let chain;
    chain = new Proxy({}, {get: (_target, name) => callback => {handlers[name] = callback; return chain;}});
    return chain;
  };
  const ui = createNativeComponent('components/player/PlayerGestureSurface', {
    props: {onPanEnd: () => calls.push('end'), onPanCancel: () => calls.push('cancel')},
    globals: {TapGesture: gesture('tap'), PanGesture: gesture('pan'), LongPressGesture: gesture('hold'),
      GestureGroup() {}, GestureMode: {Exclusive: 1}, PanDirection: {All: 1}},
  });
  ui.build(); const pan = recognizers.find(value => value.kind === 'pan');
  pan.onActionCancel(); assert.deepEqual(calls, ['cancel']);
  pan.onActionEnd(); assert.deepEqual(calls, ['cancel', 'end']);
});
