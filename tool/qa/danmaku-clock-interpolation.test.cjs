const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader} = require('./arkts-module.cjs');

function fixture({playing = true, buffering = false, fallback = false, duration = 1000, delay = 0, easeOut = false} = {}) {
  let wall = 10000, intervalId = 0, translateX = 0, translateY = 0;
  const syncs = [], intervals = new Map(), pixels = [], saved = [];
  const view = {playing, buffering, seekLocked: false, enabled: true};
  const load = createArktsLoader({globals: {
    Date: class extends Date {static now() {return wall;}},
    setInterval(callback) {const id = ++intervalId; intervals.set(id, callback); return id;},
    clearInterval(id) {intervals.delete(id);},
  }, mocks: {
    'api/BiliApi': {},
    '@kit.ArkGraphics2D': {displaySync: {create() {
      if (fallback) throw Error('display unavailable');
      const sync = {starts: 0, stops: 0, setExpectedFrameRateRange() {},
        on(_event, callback) {this.callback = callback;}, off() {this.callback = null;},
        start() {this.starts++;}, stop() {this.stops++;}};
      syncs.push(sync); return sync;
    }}},
  }});
  const {PlayerDanmakuEngine} = load('components/player/PlayerDanmakuEngine');
  const {PlayerDanmakuClock} = load('components/player/PlayerDanmakuClock');
  const ctx = {measureText: text => ({width: text.length * 12}),
    clearRect() {pixels.length = 0;}, strokeText() {},
    fillText(text, x, y) {pixels.push({text, x: x + translateX, y: y + translateY});},
    save() {saved.push([translateX, translateY]);},
    restore() {[translateX, translateY] = saved.pop();},
    translate(x, y) {translateX += x; translateY += y;}, rotate() {}};
  const engine = new PlayerDanmakuEngine(ctx);
  Object.assign(engine, {width: 1000, height: 300, lastPlayerTime: 10});
  function special(at = 10) {
    return {id: 1, idStr: '1', time: at, mode: 7, color: 16777215, fontsize: 25, weight: 10,
      text: JSON.stringify([0, 0.5, '1-1', 4, 'advanced', 0, 0, 1, 0.5, duration, delay, easeOut])};
  }
  engine.list = [special()]; engine.spawn(10);
  const clock = new PlayerDanmakuClock({isPlaying: () => view.playing && !view.buffering && !view.seekLocked,
    isDanmakuOn: () => view.enabled, getFrameRate: () => 60, getEngine: () => engine, clearPinned() {}});
  const at = milliseconds => {wall = 10000 + milliseconds;};
  function frame(milliseconds) {
    at(milliseconds);
    // DisplaySync uses boot-relative nanoseconds, deliberately unrelated to Date.now().
    if (fallback) for (const callback of [...intervals.values()]) callback();
    else syncs.at(-1).callback({timestamp: (1000 + milliseconds) * 1000000});
  }
  return {engine, clock, view, syncs, intervals, pixels, at, frame, special, x: () => pixels[0]?.x};
}

for (const blocked of ['paused', 'buffering', 'seeking']) {
  test(`danmaku frame source never starts while ${blocked}`, () => {
    const f = fixture();
    if (blocked === 'paused') f.view.playing = false;
    if (blocked === 'buffering') f.view.buffering = true;
    if (blocked === 'seeking') f.view.seekLocked = true;
    f.clock.start();
    assert.equal(f.clock.isRunning(), false);
    assert.equal(f.syncs.length, 0);
    assert.equal(f.engine.active.length, 1);
    f.clock.redraw(); assert.equal(f.pixels.length, 1, 'paused Canvas can still restore its frame');
    f.clock.release();
  });
}

for (const fallback of [false, true]) {
  test(`danmaku ${fallback ? 'fallback' : 'DisplaySync'} stops itself when playback becomes blocked`, () => {
    const f = fixture({fallback}); f.clock.start(); f.frame(0); f.frame(50);
    const shown = f.x(); f.view.buffering = true; f.frame(100);
    assert.equal(f.clock.isRunning(), false);
    assert.equal(f.intervals.size, 0);
    f.at(10000); f.clock.redraw(); assert.equal(f.x(), shown);
    f.clock.release();
  });
}

for (const rate of [1, 2]) {
  test(`advanced danmaku interpolates ${rate}x between native samples using wall time`, () => {
    const f = fixture(); f.engine.setPlaybackRate(rate); f.clock.start(); f.frame(0);
    assert.equal(f.x(), 0);
    f.frame(50); assert.equal(f.x(), 50 * rate);
    f.frame(100); assert.equal(f.x(), 100 * rate);
    f.at(150); f.engine.lastPlayerTime = 10 + 0.15 * rate; f.frame(150);
    assert.equal(f.x(), 150 * rate);
    f.frame(200); assert.equal(f.x(), 200 * rate);
    assert.equal(f.engine.lastPlayerTime, 10 + 0.15 * rate, 'drawing never writes the native clock');
    f.clock.release();
  });
}

test('advanced extrapolation is bounded and duplicate native samples cannot refresh its budget', () => {
  const f = fixture(); f.clock.start(); f.frame(0); f.frame(300); assert.equal(f.x(), 300);
  for (const time of [500, 700, 900]) {
    f.at(time); f.engine.lastPlayerTime = 10; f.frame(time); assert.equal(f.x(), 300);
  }
  f.at(950); f.engine.setPlaybackRate(2); f.frame(1000); assert.equal(f.x(), 300, 'rate change cannot restart a stale sample');
  f.clock.release();
});

test('advanced interpolation stays continuous across hold-rate changes and a late native sample', () => {
  const f = fixture(); f.clock.start(); f.frame(0); f.frame(50); assert.equal(f.x(), 50);
  f.engine.setPlaybackRate(2); f.frame(100); assert.equal(f.x(), 150);
  f.engine.setPlaybackRate(1); f.frame(150); assert.equal(f.x(), 200);
  f.engine.lastPlayerTime = 10.15; f.clock.redraw(); assert.equal(f.x(), 200, 'late sample cannot rewind the shown frame');
  f.frame(200); assert.equal(f.x(), 250);
  f.at(0); f.clock.redraw(); assert.equal(f.x(), 250, 'wall clock rollback cannot move a redraw');
  f.clock.release();
});

test('pause and Canvas redraw freeze the shown advanced position and resume excludes paused wall time', () => {
  const f = fixture(); f.clock.start(); f.frame(0); f.frame(50);
  f.view.playing = false; f.at(60); f.clock.pause(); assert.equal(f.x(), 50);
  f.at(30000); f.clock.redraw(); assert.equal(f.x(), 50);
  f.engine.setPlaybackRate(2); f.clock.redraw(); assert.equal(f.x(), 50);
  f.view.playing = true; f.clock.start(); f.frame(30000); assert.equal(f.x(), 50);
  f.frame(30050); assert.equal(f.x(), 150);
  f.clock.release();
});

test('real seek resets the advanced interpolation and permits an earlier native timeline', () => {
  const f = fixture(); f.clock.start(); f.frame(0); f.frame(200); assert.equal(f.x(), 200);
  f.clock.stop(true); f.engine.resetAt(5); f.engine.list = [f.special(5)]; f.engine.spawn(5);
  f.clock.start(); f.frame(200); assert.equal(f.x(), 0);
  f.frame(250); assert.equal(f.x(), 50); assert.equal(f.engine.lastPlayerTime, 5);
  f.clock.release();
});

test('predicted advanced endpoint remains visible until native time confirms expiry', () => {
  const f = fixture({duration: 500}); f.engine.setPlaybackRate(2); f.clock.start(); f.frame(0); f.frame(300);
  assert.equal(f.x(), 1000); assert.equal(f.engine.active.length, 1);
  f.view.buffering = true; f.clock.pause(); f.at(3000); f.clock.redraw(); assert.equal(f.x(), 1000);
  f.engine.lastPlayerTime = 10.51; f.view.buffering = false; f.clock.start(); f.frame(3000);
  assert.equal(f.engine.active.length, 0); assert.equal(f.clock.isRunning(), false);
  f.clock.release();
});

test('eased advanced path holds its endpoint instead of evaluating the curve beyond duration', () => {
  const f = fixture({duration: 500, easeOut: true});
  f.engine.setPlaybackRate(2); f.clock.start(); f.frame(0); f.frame(300);
  assert.equal(f.x(), 1000);
  f.frame(1000); assert.equal(f.x(), 1000);
  assert.equal(f.engine.active.length, 1);
  f.clock.release();
});

test('advanced delay boundary uses interpolation while a real sample controls final expiry', () => {
  const f = fixture({delay: 500}); f.clock.start(); f.frame(0); f.frame(300); assert.equal(f.pixels.length, 0);
  f.at(400); f.engine.lastPlayerTime = 10.4; f.frame(400); assert.equal(f.pixels.length, 0);
  f.frame(500); assert.equal(f.x(), 0);
  f.frame(550); assert.equal(f.x(), 50);
  f.clock.release();
});

for (const mode of [1, 6]) {
  test(`mode ${mode} offscreen text skips Canvas calls while retaining movement and visible hit tests`, () => {
    const f = fixture();
    f.engine.clearActive();
    f.engine.list = [{id: 2, idStr: '2', time: 10, mode, text: 'ordinary', color: 16777215, fontsize: 25, weight: 10}];
    f.engine.cursor = 0; f.engine.spawn(10);
    const item = f.engine.active[0];
    item.x = mode === 1 ? f.engine.width + 30 : -item.textWidth - 30;
    f.engine.drawFrame(true, 1000);
    assert.equal(f.pixels.length, 0);
    assert.equal(f.engine.active.length, 1, 'unseen text is not discarded');
    f.engine.drawFrame(true, 2000);
    assert.equal(f.pixels.length, 1, 'normal frame movement still brings text into view');
    const glyph = f.pixels[0];
    const x = Math.max(0, Math.min(f.engine.width - 1, glyph.x + item.textWidth / 2));
    assert.equal(f.engine.hitTestActive(x, glyph.y - item.fontSizeVp / 2), item);
    item.x = mode === 1 ? -item.textWidth - 5 : f.engine.width + item.textWidth + 5;
    f.engine.drawFrame(false);
    assert.equal(f.pixels.length, 0);
    assert.equal(f.engine.active.length, 1, 'culling preserves the existing expiry boundary');
    f.engine.drawFrame(true, 3000);
    assert.equal(f.engine.active.length, 0, 'offscreen items continue to expire');
    f.clock.release();
  });
}
