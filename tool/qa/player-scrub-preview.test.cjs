const test = require('node:test');
const assert = require('node:assert/strict');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');

function fixture(props = {}) {
  let target;
  const ui = createNativeComponent('components/player/PlayerGestureOverlay', {
    props: {duration: 7200, panStartTime: 3600, scrubCtl: {
      attach(value) {target = value;}, detach(value) {assert.equal(value, target); target = undefined;},
    }, ...props},
  });
  ui.component.aboutToAppear();
  return {ui, show(value) {target.showScrub(value); ui.build();},
    text() {return ui.nodes.filter(node => node.type === 'Text').map(node => node.args[0]);}};
}

test('horizontal scrub reports signed displacement from its fixed start while retaining target and duration', () => {
  const f = fixture();
  f.show(3605.2);
  assert.deepEqual(f.text(), ['01:00:05 / 02:00:00', '快进 5.2 秒']);
  f.show(3594.8);
  assert.deepEqual(f.text(), ['59:54 / 02:00:00', '后退 5.2 秒']);
  f.show(3600);
  assert.deepEqual(f.text(), ['01:00:00 / 02:00:00', '未移动']);
  assert.equal(f.ui.component.panStartTime, 3600, 'scrub updates cannot change the captured start');
  f.show(-1);
  assert.deepEqual(f.text(), [], 'ending the scrub immediately hides the preview');
  f.ui.component.aboutToDisappear();
});

test('clamped edge targets show the actual short displacement and long deltas have explicit units', () => {
  const f = fixture({panStartTime: 2.5, duration: 100});
  f.show(0);
  assert.deepEqual(f.text(), ['00:00 / 01:40', '后退 2.5 秒']);
  f.ui.component.panStartTime = 90;
  f.show(99.5);
  assert.deepEqual(f.text(), ['01:39 / 01:40', '快进 9.5 秒']);
  f.ui.component.panStartTime = 0;
  f.ui.component.duration = 7200;
  for (const [value, label] of [[60, '快进 60 秒'], [75.2, '快进 1 分 15.2 秒'],
    [3661.2, '快进 1 小时 1 分 1.2 秒']]) {
    f.show(value);
    assert.equal(f.text().at(-1), label);
  }
  f.ui.component.panStartTime = 75.2;
  f.show(0);
  assert.equal(f.text().at(-1), '后退 1 分 15.2 秒');
});

test('progress slider preview keeps whole-video timing and never borrows the previous pan start', () => {
  const f = fixture({panStartTime: 1000});
  f.show(1010);
  assert.equal(f.text().at(-1), '快进 10 秒');
  f.ui.component.sliderSeekPreview = 5400;
  f.show(5400);
  assert.deepEqual(f.text(), ['01:30:00 / 02:00:00']);
  f.show(5401.25);
  assert.deepEqual(f.text(), ['01:30:01 / 02:00:00'], 'moving uses the injected latest slider value');
  f.show(-1);
  assert.deepEqual(f.text(), ['01:30:00 / 02:00:00']);
  f.ui.component.sliderSeekPreview = -1;
  f.ui.build();
  assert.deepEqual(f.text(), []);
});
