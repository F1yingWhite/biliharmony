const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const source = fs.readFileSync(path.join(sourceRoot, 'components/player/PlayerView.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('  private ' + name + '(');
  assert.ok(start >= 0, name);
  const brace = source.indexOf('{', start); let depth = 1, end = brace + 1;
  while (depth && end < source.length) {if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++;}
  return source.slice(start, end);
}
function fixture(props = {}) {
  const modes = {Begin: 0, Moving: 1, End: 2, Click: 3};
  const code = ts.transpileModule('class View {' + method('onProgressSliderChange') + method('finishProgressPreviewInteraction') + method('scheduleControlsHide') + '}; return View;', {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  // HarmonyOS timers return numeric handles. Adapt Node's Timeout handles only
  // at that platform boundary, leaving production scheduling/callbacks intact.
  let nextTimer = 0;
  const timerHandles = new Map();
  const schedule = (callback, delay) => {
    const id = ++nextTimer;
    timerHandles.set(id, setTimeout(() => {timerHandles.delete(id); callback();}, delay));
    return id;
  };
  const cancel = id => {clearTimeout(timerHandles.get(id)); timerHandles.delete(id);};
  const View = new Function('SliderChangeMode', 'Haptic', 'setTimeout', 'clearTimeout', code)
    (modes, {seek() {}}, schedule, cancel);
  const events = [], stateWrites = [];
  const stateFields = new Set([...source.matchAll(/@State\s+(?:private\s+)?(\w+):/g)].map(m => m[1]));
  const view = new Proxy(Object.assign(new View(), {
    sliderDragging: false, sliderDragValue: 0, playheadSec: 12.5,
    playing: false, showControls: true, showMoreMenu: false, showSideDrawer: false, hideTimer: -1,
    progressCtl: {publish: (value, smooth) => events.push(['progress', value, smooth])},
    scrubCtl: {show: value => events.push(['preview', value])},
    seekTargetCtl: {show: value => events.push(['target', value])},
    requestSeekPreview: value => events.push(['image', value]),
    closeSeekPreview: () => events.push(['close']),
    seekTo: (value, precise) => events.push(['seek', value, precise]),
    ...props,
  }), {set(obj, key, value) {if (stateFields.has(key) && obj[key] !== value) stateWrites.push(key); obj[key] = value; return true;}});
  return {view, modes, events, stateWrites};
}
test('100 slider motion samples update child previews without changing parent reactive state or seeking', () => {
  const f = fixture(); f.view.onProgressSliderChange(20, f.modes.Begin); f.events.length = 0; f.stateWrites.length = 0;
  for (let i = 1; i <= 100; i++) f.view.onProgressSliderChange(20 + i / 100, f.modes.Moving);
  assert.deepEqual(f.stateWrites, []);
  assert.equal(f.events.filter(e => e[0] === 'target').length, 100);
  assert.equal(f.events.filter(e => e[0] === 'preview').length, 100);
  assert.equal(f.events.filter(e => e[0] === 'seek').length, 0);
  assert.equal(f.view.sliderDragValue, 21);
});
test('release aligns to the committed target before clearing previews and submits one seek', () => {
  const f = fixture(); f.view.onProgressSliderChange(20, f.modes.Begin); f.events.length = 0;
  f.view.onProgressSliderChange(21.25, f.modes.End);
  assert.deepEqual(f.events[0], ['progress', 21.25, false]);
  assert.deepEqual(f.events.filter(e => e[0] === 'seek'), [['seek', 21.25, true]]);
  assert.equal(f.view.sliderDragging, false);
  f.view.finishProgressPreviewInteraction();
  assert.deepEqual(f.events.filter(e => e[0] === 'progress'), [['progress', 21.25, false]], 'late touch-up must not overwrite the committed target');
});
test('cancel immediately returns both preview layers and progress to the real playhead without seeking', () => {
  const f = fixture(); f.view.onProgressSliderChange(200, f.modes.Begin); f.events.length = 0;
  f.view.finishProgressPreviewInteraction();
  assert.deepEqual(f.events.slice(0, 3), [['progress', 12.5, false], ['preview', -1], ['target', -1]]);
  assert.equal(f.events.filter(e => e[0] === 'seek').length, 0);
});
test('an active slider survives the prior hide deadline and starts a fresh deadline only after End', t => {
  // Run production setTimeout/clearTimeout callbacks with a controlled clock,
  // rather than replacing the hide scheduler with a test implementation.
  t.mock.timers.enable({apis: ['setTimeout']});
  const f = fixture({playing: true});
  f.view.scheduleControlsHide();
  t.mock.timers.tick(2500);
  f.view.onProgressSliderChange(20, f.modes.Begin);
  assert.equal(f.view.hideTimer, -1, 'Begin must cancel the deadline from before the touch');
  t.mock.timers.tick(3100);
  assert.equal(f.view.showControls, true, 'controls remain visible while a finger holds the slider for over 3s');
  f.view.scheduleControlsHide(); // A playback event may request another hide while dragging.
  assert.equal(f.view.hideTimer, -1, 'playback callbacks cannot re-arm hiding during slider ownership');
  t.mock.timers.tick(3100);
  assert.equal(f.view.showControls, true);
  f.view.onProgressSliderChange(21.25, f.modes.End);
  const deadline = f.view.hideTimer;
  assert.notEqual(deadline, -1, 'End starts a fresh normal hide deadline');
  t.mock.timers.tick(1500);
  f.view.finishProgressPreviewInteraction(); // Native End runs before the user TouchUp callback.
  assert.equal(f.view.hideTimer, deadline, 'late TouchUp cannot restart the same completed interaction');
  assert.deepEqual(f.events.filter(e => e[0] === 'progress'), [['progress', 21.25, false]],
    'late TouchUp cannot return the committed target to the prior playhead');
  t.mock.timers.tick(1499);
  assert.equal(f.view.showControls, true);
  t.mock.timers.tick(1);
  assert.equal(f.view.showControls, false, 'controls hide 3s after End, not after Begin or late TouchUp');
});
test('a hide callback already scheduled cannot hide controls after slider ownership begins', t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  const f = fixture({playing: true});
  f.view.scheduleControlsHide();
  // Exercise the callback ownership guard independently of Begin's timer cancellation.
  f.view.sliderDragging = true;
  t.mock.timers.tick(3000);
  assert.equal(f.view.showControls, true);
  assert.equal(f.view.hideTimer, -1);
});
test('cancel restores the real sample and resumes hiding only while playback is active', t => {
  t.mock.timers.enable({apis: ['setTimeout']});
  for (const playing of [true, false]) {
    const f = fixture({playing});
    f.view.onProgressSliderChange(200, f.modes.Begin);
    f.events.length = 0;
    f.view.finishProgressPreviewInteraction();
    assert.deepEqual(f.events.slice(0, 3), [['progress', 12.5, false], ['preview', -1], ['target', -1]]);
    assert.equal(f.events.filter(e => e[0] === 'seek').length, 0);
    const deadline = f.view.hideTimer;
    assert.equal(deadline === -1, !playing, 'paused controls cannot acquire a new hide timer on cancel');
    f.view.finishProgressPreviewInteraction();
    assert.equal(f.view.hideTimer, deadline, 'a repeated cleanup cannot re-arm hiding');
    t.mock.timers.tick(3000);
    assert.equal(f.view.showControls, !playing);
  }
});
test('each native sample reaches the small progress control, with buffering/background/seek smoothing gates', () => {
  // Execute the actual adapter prefix; downstream business/subtitle IO is irrelevant to this channel.
  const body = method('onPlaybackProgress').split('    this.interactionCtl.update(seconds);')[0] + '\n  }';
  const code = ts.transpileModule('class View {' + body + '}; return View;', {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  const View = new Function(code)(), samples = [];
  const view = Object.assign(new View(), {playing: true, buffering: false, seekLocked: false, progressCtl: {publish: (v, s) => samples.push([v, s])}});
  for (const time of [10.1, 10.25, 10.4, 10.55]) view.onPlaybackProgress(time, false);
  assert.deepEqual(samples, [[10.1, true], [10.25, true], [10.4, true], [10.55, true]]);
  for (const flag of ['playing', 'buffering', 'seekLocked']) {
    view[flag] = flag !== 'playing'; view.onPlaybackProgress(11, false); assert.equal(samples.at(-1)[1], false);
    view[flag] = flag === 'playing';
  }
  const count = samples.length;
  view.onPlaybackProgress(12, true); assert.equal(samples.length, count, 'background samples do not animate hidden controls');
});
