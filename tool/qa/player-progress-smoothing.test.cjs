const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createArktsLoader} = require('./arkts-module.cjs');
const {createNativeComponent} = require('./arkui-ui-harness.cjs');

const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const source = fs.readFileSync(path.join(sourceRoot, 'components/player/PlayerProgressBar.ets'), 'utf8');
const valueWatch = source.match(/@Prop\s+@Watch\('([^']+)'\)\s+value\b/);
const previewWatch = source.match(/@Prop\s+@Watch\('([^']+)'\)\s+previewValue\b/);
const visibleWatch = source.match(/@Prop\s+@Watch\('([^']+)'\)\s+controlsVisible\b/);
const mode = {Begin: 'Begin', Moving: 'Moving', End: 'End', Click: 'Click'};
const touch = {Up: 'up', Cancel: 'cancel', Down: 'down'};

function controller() {
  return new (createArktsLoader()('components/player/PlayerProgressController').PlayerProgressController)();
}

function fixture(props = {}) {
  const ctl = props.progressCtl || controller(), animations = [], changes = [], endings = [];
  const ui = createNativeComponent('components/player/PlayerProgressBar', {
    props: {value: 12, duration: 100, progressCtl: ctl,
      getUIContext: () => ({animateTo(options, change) {animations.push(options); change();}}),
      onChange: (...args) => changes.push(args), onInteractionEnd: () => endings.push('end'), ...props},
    mocks: {'common/SponsorBlock': {sponsorBlockCategory: () => ({color: '#FA8D23'})}},
    globals: {SliderBlockType: {IMAGE: 'image'}, TouchType: touch, SliderChangeMode: mode},
  });
  ui.component.aboutToAppear();
  return {...ui, ctl, animations, changes, endings,
    value() {ui.build(); return ui.nodes.find(node => node.type === 'Slider').args[0].value;},
    slider() {ui.build(); return ui.nodes.find(node => node.type === 'Slider');},
    fallback(value) {
      assert.ok(valueWatch, 'fallback value updates need an observer');
      ui.component.value = value; ui.component[valueWatch[1]]();
    },
    preview(value) {
      assert.ok(previewWatch, 'preview changes need an observer');
      ui.component.previewValue = value; ui.component[previewWatch[1]]();
    },
    visible(value) {
      assert.ok(visibleWatch, 'visibility changes need an observer');
      ui.component.controlsVisible = value; ui.component[visibleWatch[1]]();
    },
  };
}

test('progress channel replays the latest sample immediately to each new target and detaches by identity', () => {
  const ctl = controller(), first = [], second = [], late = [];
  const a = {updateProgress: (...args) => first.push(args)};
  const b = {updateProgress: (...args) => second.push(args)};
  ctl.publish(20.15, true);
  ctl.attach(a); ctl.attach(a); ctl.attach(b);
  assert.deepEqual(first, [[20.15, false]], 'attaching twice must not restart the same bar');
  assert.deepEqual(second, [[20.15, false]]);
  ctl.publish(20.3, true);
  ctl.detach({updateProgress: a.updateProgress});
  ctl.publish(20.45, true);
  assert.equal(first.length, 3, 'detaching another object cannot detach a visible target');
  ctl.detach(a); ctl.publish(20.6, true);
  assert.equal(first.length, 3);
  assert.equal(second.length, 4);
  ctl.attach({updateProgress: (...args) => late.push(args)});
  assert.deepEqual(late, [[20.6, false]]);
});

test('progress channel rejects invalid times and republishes equal samples for pause alignment', () => {
  const ctl = controller(), samples = [];
  ctl.attach({updateProgress: (...args) => samples.push(args)});
  for (const value of [-1, NaN, Infinity, -Infinity]) ctl.publish(value, true);
  ctl.publish(0, true); ctl.publish(0, true); ctl.publish(0, false); ctl.publish(0, false);
  assert.deepEqual(samples, [[0, true], [0, false], [0, false]]);
});

test('native samples request only local 150ms linear transitions to actual media positions', () => {
  const f = fixture();
  assert.equal(f.value(), 12);
  for (const value of [12.15, 12.3, 12.6]) {
    f.ctl.publish(value, true);
    assert.equal(f.value(), value, 'the endpoint must be the actual sample, without extrapolation');
    assert.deepEqual(f.animations.at(-1), {duration: 150, curve: 'Linear'});
  }
  assert.equal(f.component.value, 12, 'samples cannot mutate the parent fallback prop');
  assert.deepEqual(f.changes, [], 'sample animations cannot request a business seek');
});

test('seconds-level fallback cannot rewind a sampled bar, while a bar without a channel still follows props', () => {
  const sampled = fixture(); sampled.ctl.publish(12.75, true);
  const before = sampled.animations.length;
  sampled.fallback(12);
  assert.equal(sampled.value(), 12.75);
  assert.equal(sampled.animations.length, before);
  const fallback = fixture({progressCtl: null});
  fallback.fallback(14.25);
  assert.equal(fallback.value(), 14.25);
  assert.deepEqual(fallback.animations.at(-1), {duration: 0, curve: 'Linear'});
});

test('pause, buffering and seek request immediate alignment even for the identical in-flight endpoint', () => {
  const f = fixture(); f.ctl.publish(12.15, true);
  const priorState = f.component.renderedProgress;
  f.ctl.publish(12.15, false);
  assert.equal(f.value(), 12.15);
  assert.notEqual(f.component.renderedProgress, priorState,
    'an identical immediate value must change local State, rather than an equality no-op');
  assert.deepEqual(f.animations.at(-1), {duration: 0, curve: 'Linear'});
  f.ctl.publish(50.125, false);
  assert.equal(f.value(), 50.125);
  assert.deepEqual(f.animations.at(-1), {duration: 0, curve: 'Linear'});
});

test('scrub preview takes precedence over native samples and clearing aligns to the latest real sample', () => {
  const f = fixture(); f.ctl.publish(12.15, true);
  f.preview(70.25); const before = f.animations.length;
  f.ctl.publish(12.3, true); f.ctl.publish(12.45, false); f.fallback(12);
  assert.equal(f.value(), 70.25);
  assert.equal(f.animations.length, before, 'real samples are cached without animating under the finger');
  f.preview(-1);
  assert.equal(f.value(), 12.45);
  assert.deepEqual(f.animations.at(-1), {duration: 0, curve: 'Linear'});
  f.preview(80); f.ctl.publish(80, false); f.preview(-1);
  assert.equal(f.value(), 80, 'committed seek target survives preview release');
});

test('drag ownership stops animations and touch cancel resumes actual samples without a seek', () => {
  const f = fixture();
  let slider = f.slider(); slider.props.onChange(30.25, mode.Begin);
  f.ctl.publish(12.3, true); f.fallback(12);
  assert.equal(f.value(), 30.25);
  slider.props.onChange(31.875, mode.Moving); f.ctl.publish(12.45, false);
  assert.equal(f.value(), 31.875);
  slider.props.onTouch({type: touch.Down});
  assert.deepEqual(f.endings, []);
  slider.props.onTouch({type: touch.Cancel});
  assert.equal(f.value(), 12.45);
  assert.deepEqual(f.changes, [[30.25, mode.Begin], [31.875, mode.Moving]]);
  assert.deepEqual(f.endings, ['end']);
  f.ctl.publish(12.6, true);
  assert.deepEqual(f.animations.at(-1), {duration: 150, curve: 'Linear'});
});

test('slider End and track Click forward the exact target once and settle without a delayed preview rewind', () => {
  const f = fixture({onChange(value, changeMode) {
    if (changeMode === mode.End || changeMode === mode.Click) f.ctl.publish(value, false);
  }});
  const slider = f.slider(); slider.props.onChange(45.678, mode.Moving);
  slider.props.onChange(45.678, mode.End); slider.props.onTouch({type: touch.Up});
  assert.equal(f.value(), 45.678);
  slider.props.onChange(67.891, mode.Click);
  assert.equal(f.value(), 67.891);
});

test('appearance replays cached progress without animation and disappearance detaches the originally attached channel', () => {
  const first = controller(), other = controller(); first.publish(42.25, true);
  const f = fixture({progressCtl: first});
  assert.equal(f.value(), 42.25);
  assert.deepEqual(f.animations, [], 'cached appearance replay cannot animate before the native Slider exists');
  f.component.progressCtl = other;
  f.component.aboutToDisappear();
  const before = f.animations.length;
  first.publish(42.5, true); other.publish(80, true); f.fallback(70); f.preview(75);
  assert.equal(f.animations.length, before, 'destroyed controls cannot accept late state writes');
  f.component.previewValue = -1;
  f.component.aboutToAppear();
  assert.equal(f.value(), 80, 'reappearing controls take the newly attached channel sample');
  f.component.aboutToDisappear();
  f.component.progressCtl = null;
  f.component.aboutToAppear(); f.fallback(90);
  assert.equal(f.value(), 90, 'an old sampled channel cannot suppress fallback after reappearance');
});

test('both bottom layouts and compact controls pass the real-progress channel separately from preview', () => {
  const ctl = controller();
  for (const [name, fullscreen] of [['PlayerBottomControls', false], ['PlayerBottomControls', true], ['PlayerCompactControls', false]]) {
    const ui = createNativeComponent('components/player/' + name, {
      props: {playing: true, fullscreen, progress: 12, scrubPreview: 70, progressCtl: ctl, controlsVisible: false,
        duration: 100, chapters: [], hotPoints: [], sponsorSegments: []},
      recordComponents: {'components/player/PlayerProgressBar': ['PlayerProgressBar']},
      mocks: {'common/Utils': {formatDuration: value => String(value)}},
      globals: {
        Circle: () => ({width() {return this;}, height() {return this;}, fill() {return this;}}),
        TextInput: () => {let native; native = new Proxy({}, {get: () => () => native}); return native;},
      },
    });
    ui.build();
    const props = ui.nodes.find(node => node.type === 'PlayerProgressBar').args[0];
    assert.equal(props.value, 12, name + ' uses real fallback, never a preview disguised as a sample');
    assert.equal(props.previewValue, 70);
    assert.equal(props.progressCtl, ctl);
    assert.equal(props.controlsVisible, false);
  }
});

test('initially hidden controls cache 100 native samples without animation or local State changes', () => {
  const ctl = controller(); ctl.publish(12.25, true);
  const f = fixture({controlsVisible: false, progressCtl: ctl});
  const hiddenState = f.component.renderedProgress;
  assert.equal(f.animations.length, 0, 'hidden mounting replay is private cache only');
  for (let i = 0; i < 100; i++) {
    f.ctl.publish(12.5 + i * 0.15, i % 2 === 0);
    f.fallback(12 + Math.floor(i * 0.15));
  }
  assert.equal(f.animations.length, 0);
  assert.equal(f.component.renderedProgress, hiddenState, 'hidden samples cannot allocate responsive state');
  f.visible(true);
  assert.equal(f.value(), 12.5 + 99 * 0.15);
  assert.deepEqual(f.animations, [{duration: 0, curve: 'Linear'}], 'showing applies the latest sample once');
  f.fallback(12);
  assert.equal(f.animations.length, 1);
  assert.equal(f.value(), 12.5 + 99 * 0.15, 'an old fallback cannot rewind newly visible progress');
});

test('hiding an active bar suppresses further sample and preview writes, then resumes native smoothing after alignment', () => {
  const f = fixture(); f.ctl.publish(12.15, true);
  const activeState = f.component.renderedProgress, activeAnimations = f.animations.length;
  f.visible(false);
  for (let i = 0; i < 100; i++) f.ctl.publish(20 + i * 0.15, true);
  f.preview(70); f.preview(-1); f.fallback(12);
  assert.equal(f.component.renderedProgress, activeState);
  assert.equal(f.animations.length, activeAnimations);
  f.visible(true);
  assert.equal(f.value(), 20 + 99 * 0.15);
  assert.equal(f.animations.length, activeAnimations + 1);
  assert.deepEqual(f.animations.at(-1), {duration: 0, curve: 'Linear'});
  f.ctl.publish(35, true);
  assert.deepEqual(f.animations.at(-1), {duration: 150, curve: 'Linear'});
});

test('visibility alignment retains seek preview priority and releases stale local drag ownership', () => {
  const f = fixture(); f.slider().props.onChange(30, mode.Begin);
  f.visible(false); f.preview(70.25); f.ctl.publish(12.75, true);
  const before = f.animations.length;
  f.visible(true);
  assert.equal(f.value(), 70.25);
  assert.equal(f.animations.length, before + 1);
  assert.deepEqual(f.animations.at(-1), {duration: 0, curve: 'Linear'});
  f.preview(-1);
  assert.equal(f.value(), 12.75, 'hidden drag ownership cannot block actual sample alignment');
  const fallback = fixture({controlsVisible: false, progressCtl: null});
  fallback.fallback(44.125); fallback.visible(true);
  assert.equal(fallback.value(), 44.125, 'without a channel visibility still uses the latest fallback');
});

test('hidden bottom and compact controls keep scrub updates private until showing, including cleared previews', () => {
  for (const name of ['PlayerBottomControls', 'PlayerCompactControls']) {
    let target;
    const ui = createNativeComponent('components/player/' + name, {
      props: {controlsVisible: false, scrubCtl: {
        attach(value) {target = value;}, detach(value) {assert.equal(value, target); target = undefined;},
      }},
      recordComponents: {'components/player/PlayerProgressBar': ['PlayerProgressBar']},
      mocks: {'common/Utils': {formatDuration: value => String(value)}},
    });
    const controlSource = fs.readFileSync(path.join(sourceRoot, 'components/player/' + name + '.ets'), 'utf8');
    const observer = controlSource.match(/@Prop\s+@Watch\('([^']+)'\)\s+controlsVisible\b/);
    assert.ok(observer, name + ' must observe visibility');
    ui.component.aboutToAppear();
    for (let i = 0; i < 100; i++) target.showScrub(i + 0.25);
    assert.equal(ui.component.scrubPreview, -1, name + ' hidden scrub events cannot write State');
    ui.component.controlsVisible = true; ui.component[observer[1]]();
    assert.equal(ui.component.scrubPreview, 99.25);
    ui.component.controlsVisible = false; ui.component[observer[1]]();
    target.showScrub(-1);
    assert.equal(ui.component.scrubPreview, 99.25);
    ui.component.controlsVisible = true; ui.component[observer[1]]();
    assert.equal(ui.component.scrubPreview, -1, name + ' cannot revive an ended preview');
    ui.component.aboutToDisappear();
    assert.equal(target, undefined);
  }
});

test('local progress animation does not introduce frame timers or display sync into control components', () => {
  for (const name of ['PlayerProgressController', 'PlayerProgressBar', 'PlayerBottomControls', 'PlayerCompactControls']) {
    const code = fs.readFileSync(path.join(sourceRoot, 'components/player/' + name + '.ets'), 'utf8');
    assert.doesNotMatch(code, /\b(?:setInterval|setTimeout|displaySync|requestAnimationFrame)\b/);
  }
});
