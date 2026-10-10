const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');
const {createArktsLoader} = require('./arkts-module.cjs');

const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const source = fs.readFileSync(path.join(sourceRoot, 'components/player/PlayerProgressBar.ets'), 'utf8');
const watch = source.match(/@Prop\s+@Watch\('([^']+)'\)\s+hotPoints\b/);
const {HotPoint} = createArktsLoader()('model/video/VideoAuxiliaryModels');

function fixture(details, props = {}) {
  let reads = 0;
  const points = values => values.map((detail, index) => {
    const point = Object.assign(new HotPoint(), {from: index * 10, to: (index + 1) * 10});
    Object.defineProperty(point, 'detail', {get() {reads++; return detail;}, configurable: true});
    return point;
  });
  const ui = createNativeComponent('components/player/PlayerProgressBar', {
    props: {duration: Math.max(1, details.length) * 10, hotPoints: points(details),
      getUIContext: () => ({animateTo: (_options, change) => change()}), ...props},
    mocks: {'common/SponsorBlock': {sponsorBlockCategory: () => ({color: '#FA8D23'})}},
    globals: {SliderBlockType: {IMAGE: 'image'}, TouchType: {Up: 'up', Cancel: 'cancel', Down: 'down'},
      SliderChangeMode: {Begin: 'Begin', Moving: 'Moving', End: 'End', Click: 'Click'}},
  });
  // ArkUI invokes appearance once and the declared Watch callback when this Prop
  // changes; the native UI harness executes their actual production methods.
  ui.component.aboutToAppear?.();
  return {...ui, reads: () => reads, points,
    replace(values) {
      assert.ok(watch, 'hotPoints must declare an update observer');
      ui.component.hotPoints = points(values);
      ui.component[watch[1]]();
    },
    opacities() {
      ui.build();
      return ui.nodes.filter(node => node.type === 'Row' && node.props.backgroundColor === '#FB7299')
        .map(node => node.props.opacity);
    },
  };
}
function expected(values) {
  const points = values.map(detail => Object.assign(new HotPoint(), {detail}));
  return points.map(point => point.alphaOf(points));
}

test('progress heat opacity retains the existing normalization for initial and degenerate data', () => {
  for (const values of [[0, 25, 50, 100], [0, 0], [-5, -1], [-5, 5, 10], [NaN, 10], [5, Infinity], []]) {
    const f = fixture(values);
    assert.deepEqual(f.opacities(), expected(values));
  }
});

test('progress heat data replacement recomputes the maximum and clearing cannot retain stale normalization', () => {
  const f = fixture([10, 100]);
  assert.deepEqual(f.opacities(), expected([10, 100]));
  for (const values of [[5, 20], [0, 0], [], [2, 4]]) {
    f.replace(values);
    assert.deepEqual(f.opacities(), expected(values));
  }
});

test('progress heat preparation and every progress redraw have linear detail reads', () => {
  const count = 256, values = Array.from({length: count}, (_, index) => index + 1);
  const f = fixture(values);
  assert.ok(f.reads() <= count, 'initial preparation scans the array at most once');
  for (let frame = 0; frame < 24; frame++) {
    const before = f.reads();
    f.component.value = frame * 0.01;
    f.build();
    assert.equal(f.nodes.filter(node => node.type === 'Row' && node.props.backgroundColor === '#FB7299').length, count);
    assert.ok(f.reads() - before <= count,
      `frame ${frame} scanned ${f.reads() - before} heat values; drawing may read each point only once`);
  }
  const before = f.reads();
  f.replace(values.slice().reverse());
  assert.ok(f.reads() - before <= count, 'an array update scans the new maximum at most once');
  const normalized = f.opacities();
  assert.equal(normalized[0], 0.9);
  assert.equal(normalized.at(-1), 0.25 + 0.65 / count);
});

test('progress heat duration and compact changes preserve normalized opacity without another maximum scan', () => {
  const f = fixture([2, 4, 8]), alpha = f.opacities();
  f.component.duration = 120; f.component.compact = true;
  const before = f.reads();
  assert.deepEqual(f.opacities(), alpha);
  assert.equal(f.reads() - before, 3);
  const heat = f.nodes.filter(node => node.type === 'Row' && node.props.backgroundColor === '#FB7299');
  assert.ok(heat.every(node => node.props.height === 3));
  assert.equal(heat[0].props.width, (10 / 120 * 100) + '%');
  f.component.duration = 0;
  assert.deepEqual(f.opacities(), []);
});

test('progress slider retains subsecond values and forwards drag/end/cancel without quantizing seek', () => {
  const changes = [], endings = [];
  const f = fixture([], {value: 12.345, duration: 120,
    onChange: (...args) => changes.push(args), onInteractionEnd: () => endings.push('end')});
  f.build();
  const slider = f.nodes.find(node => node.type === 'Slider');
  assert.equal(slider.args[0].value, 12.345);
  assert.equal(slider.args[0].step, 0.01);
  slider.props.onChange(23.456, 'Moving');
  slider.props.onChange(23.456, 'End');
  slider.props.onTouch({type: 'down'});
  slider.props.onTouch({type: 'up'});
  slider.props.onTouch({type: 'cancel'});
  assert.deepEqual(changes, [[23.456, 'Moving'], [23.456, 'End']]);
  assert.deepEqual(endings, ['end', 'end']);
  f.component.duration = 0; f.build();
  assert.equal(f.nodes.find(node => node.type === 'Slider').args[0].max, 1);
});
