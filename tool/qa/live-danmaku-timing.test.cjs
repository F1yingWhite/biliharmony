// Execute the production renderer with a controllable frame clock and wall clock.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

const root = path.resolve(__dirname, '../../entry/src/main/ets');
const relative = 'components/live/LiveDanmakuRenderer.ets';
const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, relative);
const source = fs.readFileSync(override && fs.existsSync(override) ? override : path.join(root, relative), 'utf8');
const code = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;

function fixture() {
  let wallMs = 1_000_000;
  const counts = { starts: 0, stops: 0, clears: 0 };
  const mocks = {
    '../../model/LiveModels': { LiveChatMessage: { textWithoutEmotes: message => message.text } },
    '../player/PlayerDanmakuSupport': { colorHex: () => '#FFFFFF' },
    '@kit.ImageKit': { image: {} },
    '../../services/network/HttpClient': { HttpClient: {} },
    '../../common/Constants': { Constants: {} }
  };
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'Date', code)(name => {
    assert.ok(name in mocks, 'Unexpected dependency: ' + name);
    return mocks[name];
  }, module, module.exports, { now: () => wallMs });
  const renderer = new module.exports.LiveDanmakuRenderer({
    measureText: text => ({ width: text.length * 7 }),
    clearRect() { counts.clears++; }, strokeText() {}, fillText() {}
  });
  renderer.width = 844;
  renderer.height = 391;
  renderer.density = 30;
  renderer.attachClock({
    start() { counts.starts++; }, stop() { counts.stops++; },
    release() {}, frameRateChanged() {}
  });
  renderer.setBaseline([]);
  renderer.setPlayback(true, true);
  const messages = [];
  function append(id) {
    messages.push({ id, timestamp: Math.floor(wallMs / 1000), text: '实时弹幕',
      color: 16777215, emotes: [], type: 'danmaku' });
    renderer.onMessagesChanged(messages);
  }
  function frame(frameMs) {
    wallMs = 999_000 + frameMs;
    renderer.renderTick(frameMs);
  }
  append('first');
  frame(1000);
  return { renderer, counts, append, frame, comment: renderer.active[0],
    setWallMs(value) { wallMs = value; } };
}

function near(actual, expected, message) {
  assert.ok(Math.abs(actual - expected) < 0.00001,
    `${message}: expected ${expected}, got ${actual}`);
}

for (const fps of [30, 60, 90, 120]) {
  test(`live danmaku travel follows elapsed time at ${fps} fps`, () => {
    const f = fixture();
    const initialX = f.comment.x;
    const speed = f.comment.speed;
    for (let i = 1; i <= fps; i++) f.frame(1000 + i * 1000 / fps);
    near(initialX - f.comment.x, speed, 'One second of movement');
  });
}

test('fresh batches and queue spawning preserve a running clock and scrolling speed', () => {
  const f = fixture();
  const initialX = f.comment.x;
  for (let i = 1; i <= 60; i++) {
    const frameMs = 1000 + i * 1000 / 60;
    f.setWallMs(999_000 + frameMs);
    f.append('batch-' + i);
    f.frame(frameMs);
  }
  assert.ok(f.renderer.active.length > 1, 'The queue must actually spawn incoming batches');
  near(initialX - f.comment.x, f.comment.speed, 'Batch-independent one-second movement');
  assert.equal(f.counts.starts, 1, 'Running clock starts once across repeated batches');
});

test('pause stops the clock, retains the drawn frame, and excludes paused wall time on resume', () => {
  const f = fixture();
  f.frame(1020);
  const pausedX = f.comment.x;
  const clears = f.counts.clears;
  f.renderer.setPlayback(false, true);
  assert.equal(f.counts.stops, 1);
  assert.equal(f.counts.clears, clears, 'Pausing must preserve the visible Canvas contents');
  assert.equal(f.comment.x, pausedX);
  f.renderer.setPlayback(true, true);
  assert.equal(f.counts.starts, 2);
  f.frame(61020);
  assert.equal(f.comment.x, pausedX, 'The first resumed frame establishes its time baseline');
  f.frame(61020 + 1000 / 120);
  near(pausedX - f.comment.x, f.comment.speed / 120, 'Resumed high-refresh movement');
});

test('initial and duplicate frame timestamps do not manufacture scrolling movement', () => {
  const f = fixture();
  near(f.comment.x, f.renderer.width + 10, 'First frame position');
  f.frame(1000);
  near(f.comment.x, f.renderer.width + 10, 'Duplicate timestamp position');
});

test('re-enabling danmaku after clearing starts a new clock baseline', () => {
  const f = fixture();
  f.renderer.toggle(false);
  assert.equal(f.counts.stops, 1);
  assert.equal(f.renderer.hasWork(), false);
  f.renderer.toggle(true);
  f.setWallMs(1_001_000);
  f.append('after-toggle');
  f.frame(2000);
  assert.equal(f.counts.starts, 2);
  const next = f.renderer.active[0];
  near(next.x, f.renderer.width + 10, 'New frame baseline');
});
