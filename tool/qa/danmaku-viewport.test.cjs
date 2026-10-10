const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader } = require('./arkts-module.cjs');

// Load the complete production engine and its relative imports. Only the Canvas
// boundary is synthetic: the assertions inspect actual stroke/fill coordinates.
const load = createArktsLoader({ mocks: { 'api/BiliApi': {} } });
const { PlayerDanmakuEngine } = load('components/player/PlayerDanmakuEngine');
const modes = [1, 6, 5, 4];
const sizes = [18, 25, 36, 45];

function fixture({ height = 216, fullscreen = false, density = 22, spacing = 1,
  descentRatio = 0.2, metric = 'present' } = {}) {
  const pixels = [], measurements = new Map();
  const fontVp = ctx => {
    const match = /([\d.]+)vp/.exec(ctx.font);
    assert.ok(match, 'production draw must supply an actual vp font');
    return Number(match[1]);
  };
  const ctx = {
    font: '600 12vp sans-serif', lineWidth: 0,
    clearRect() { pixels.length = 0; },
    measureText(text) {
      const font = fontVp(this);
      measurements.set(text, (measurements.get(text) || 0) + 1);
      const result = { width: Math.max(20, text.length * font * 0.45), actualBoundingBoxAscent: font * 0.8 };
      if (metric === 'present') result.actualBoundingBoxDescent = font * descentRatio;
      if (metric === 'nan') result.actualBoundingBoxDescent = NaN;
      if (metric === 'negative') result.actualBoundingBoxDescent = -1;
      return result;
    },
    strokeText(text, x, y) {
      this.lastStroke = { text, x, y, font: fontVp(this), lineWidth: this.lineWidth };
    },
    fillText(text, x, y) {
      const font = fontVp(this), descent = font * descentRatio;
      assert.deepEqual(this.lastStroke, { text, x, y, font, lineWidth: this.lineWidth },
        'fill and outline must use the same actual Canvas coordinates');
      pixels.push({ text, x, y, font, descent, bottom: y + descent + this.lineWidth / 2 });
    },
  };
  const engine = new PlayerDanmakuEngine(ctx);
  engine.fullscreen = fullscreen;
  engine.setViewport(fullscreen ? 844 : 390, height);
  engine.setDensity(density);
  engine.setSpacing(spacing);
  engine.lastPlayerTime = 10;
  return { engine, pixels, measurements, ctx };
}

function item(mode, fontsize, id, text = `row-${id}`) {
  return { time: 10, mode, fontsize, id, idStr: String(id), text,
    color: 16777215, weight: 10, mergeCount: 1 };
}

function redraw(f) {
  // The instant of spawn starts scrolling text outside the viewport. Move it
  // horizontally inside without altering any production-assigned vertical lane.
  for (const dm of f.engine.active) if (!dm.isFixed) dm.x = 30;
  f.engine.drawFrame(false);
  assert.equal(f.pixels.length, f.engine.active.length, 'every retained comment must actually draw');
}

function fill(f, mode, fontsize, count = 128) {
  f.engine.setList(Array.from({ length: count }, (_, id) => item(mode, fontsize, id)));
  f.engine.spawn(10);
  redraw(f);
  assert.ok(f.pixels.length > 1, 'fixture must fill several real lanes');
}

function assertInside(f, label) {
  assert.ok(f.pixels.length > 0, label + ': expected visible comments');
  for (const pixel of f.pixels) {
    assert.ok(pixel.x < f.engine.width && pixel.x >= 0, label + ': text must be horizontally visible');
    assert.ok(pixel.bottom <= f.engine.height + 1e-7,
      `${label}: ${pixel.text} bottom ${pixel.bottom} exceeds viewport ${f.engine.height}`);
  }
}

function assertLastRowUsed(f, label) {
  assertInside(f, label);
  const lowest = f.pixels.reduce((a, b) => a.bottom > b.bottom ? a : b);
  const dm = f.engine.active.find(candidate => candidate.renderText === lowest.text);
  assert.ok(dm, label + ': lowest pixels must belong to a real assigned comment');
  // Render a hypothetical next lane through the same production draw method.
  // A whole additional row must not fit with the documented 1vp outline/round
  // margin. This oracle never computes laneCount or repeats its allocation math.
  const retained = f.engine.active.slice();
  try {
    f.engine.active = [{ ...dm, lane: dm.lane + 1 }];
    redraw(f);
    assert.ok(f.pixels[0].bottom + 1 > f.engine.height,
      `${label}: one additional complete row fits below the last drawn row (${lowest.bottom})`);
  } finally {
    f.engine.active = retained;
    redraw(f);
  }
}

for (const [height, fullscreen] of [[216, false], [391, true]]) {
  for (const mode of modes) {
    test(`mode ${mode} uses the last safe row at ${height}vp across density, spacing and protocol sizes`, () => {
      for (const density of [22, 27, 30]) for (const spacing of [0.5, 1, 2]) for (const fontsize of sizes) {
        const f = fixture({ height, fullscreen, density, spacing });
        fill(f, mode, fontsize);
        assertLastRowUsed(f, `height=${height} mode=${mode} density=${density} spacing=${spacing} size=${fontsize}`);
      }
    });
  }
}

test('row rounding stays safe just above and below a multiple of the real row pitch', () => {
  for (const mode of modes) for (const density of [22, 27, 30]) for (const spacing of [0.5, 1, 2]) {
    const pitch = fixture({ density, spacing }).engine.lineHeight();
    for (const offset of [-0.2, 0, 0.2]) for (const fontsize of [25, 45]) {
      const f = fixture({ height: pitch * 17 + offset, density, spacing });
      fill(f, mode, fontsize);
      assertLastRowUsed(f, `near pitch multiple mode=${mode} density=${density} spacing=${spacing} offset=${offset} size=${fontsize}`);
    }
  }
});

test('large real descenders and legitimate zero descenders determine the visible bottom row', () => {
  for (const mode of modes) for (const descentRatio of [0, 0.75]) {
    const f = fixture({ height: 216, descentRatio });
    fill(f, mode, 45);
    const lastBaseline = Math.max(...f.pixels.map(p => p.y));
    if (descentRatio > 0.2) {
      const normal = fixture({ height: 216 });
      fill(normal, mode, 45);
      assert.ok(Math.max(...normal.pixels.map(p => p.y)) > lastBaseline,
      'the large-descent path must choose an earlier baseline than ordinary metrics');
    }
    assertLastRowUsed(f, `mode=${mode} real descent=${descentRatio}`);
  }
});

test('missing, NaN and negative descent metrics safely fall back to 20 percent of the actual font', () => {
  for (const mode of modes) for (const metric of ['missing', 'nan', 'negative']) {
    const f = fixture({ height: 391, fullscreen: true, metric, descentRatio: 0.2 });
    fill(f, mode, 45);
    assertLastRowUsed(f, `mode=${mode} metrics=${metric}`);
  }
});

test('shrinking viewport and changing font, spacing or density retain old comments inside the Canvas', () => {
  for (const mode of modes) {
    const f = fixture({ height: 391, fullscreen: true, density: 27, descentRatio: 0.45 });
    // Start from genuinely allocated bottom lanes with mixed actual font sizes.
    fill(f, mode, 45);
    const retained = f.engine.active.slice().sort((a, b) => b.lane - a.lane).slice(0, 12);
    retained.forEach((dm, index) => { dm.item.fontsize = sizes[index % sizes.length]; });
    f.engine.active = retained;
    f.engine.pin(retained[0]);
    f.engine.setFontScale(1);
    const identities = new Set(retained), pinned = f.engine.pinned;
    const checks = [
      ['viewport shrink', () => f.engine.setViewport(390, 216)],
      ['font scale increase', () => f.engine.setFontScale(1.7)],
      ['spacing increase', () => f.engine.setSpacing(2)],
      ['density change', () => f.engine.setDensity(22)],
      ['compact spacing', () => f.engine.setSpacing(0.5)],
      ['overlap density', () => f.engine.setDensity(30)],
    ];
    for (const [label, change] of checks) {
      change(); redraw(f);
      assert.equal(f.engine.active.length, identities.size, `mode=${mode} ${label}: old comments must not disappear`);
      assert.ok(f.engine.active.every(dm => identities.has(dm)), `mode=${mode} ${label}: active identity must remain`);
      assert.equal(f.engine.pinned, pinned, `mode=${mode} ${label}: pinned identity must remain`);
      assertInside(f, `mode=${mode} ${label}`);
    }
    // Newly allocated comments must also remain inside after the old items move.
    f.engine.setList(Array.from({ length: 80 }, (_, id) => item(mode, 45, id + 1000)));
    f.engine.spawn(10); redraw(f);
    assert.ok(f.engine.active.some(dm => dm.item.id >= 1000), 'the new burst must actually draw new comments');
    assertInside(f, `mode=${mode} newly allocated comments after reflow`);
    assert.ok([...identities].every(dm => f.engine.active.includes(dm)), 'new allocations must retain the old comments');
  }
});

for (const clear of ['clearCaches', 'eviction']) {
  test(`${clear} remeasures old descenders before a smaller viewport reflows them`, () => {
    for (const mode of modes) {
      const f = fixture({ height: 391, fullscreen: true, descentRatio: 0.75 });
      fill(f, mode, 45);
      const old = f.engine.active.slice(), measurements = new Map(f.measurements);
      if (clear === 'clearCaches') f.engine.clearCaches();
      else {
        // Exercise the real cache limit with distinct measured texts, while the
        // existing active comments remain untouched in the production engine.
        for (let index = 0; index < 800; index++) f.engine.measure(`cache-burst-${index}`, 14);
      }
      f.engine.setViewport(390, 216); redraw(f);
      assert.equal(f.engine.active.length, old.length, `mode=${mode}: cache lifetime must not discard comments`);
      assert.ok(old.every(dm => f.engine.active.includes(dm)), `mode=${mode}: existing objects must remain`);
      assertInside(f, `mode=${mode} ${clear} then viewport shrink`);
      assert.ok(old.some(dm => f.measurements.get(dm.renderText) > measurements.get(dm.renderText)),
        `mode=${mode}: cleared bottom metrics must be measured again, not replaced with a smaller fallback`);
    }
  });
}
