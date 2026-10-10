const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const {createArktsLoader} = require('./arkts-module.cjs');
const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const pageSource = fs.readFileSync(path.join(sourceRoot, 'pages/VideoDetail.ets'), 'utf8');
const viewSource = fs.readFileSync(path.join(sourceRoot, 'components/player/PlayerView.ets'), 'utf8');

// Execute the actual page methods and picture builder. Only display, Scroller,
// animation scheduling and native ArkUI nodes are replaced at their boundaries.
function method(source, name) {
  const start = source.search(new RegExp('^  (?:private )?' + name + '\\(', 'm'));
  assert.ok(start >= 0, 'production method exists: ' + name);
  const scanner = ts.createScanner(ts.ScriptTarget.ES2020, true, ts.LanguageVariant.Standard, source.slice(start));
  let depth = 0, begun = false;
  for (let kind = scanner.scan(); kind !== ts.SyntaxKind.EndOfFileToken; kind = scanner.scan()) {
    if (kind === ts.SyntaxKind.OpenBraceToken) {depth++; begun = true;}
    else if (kind === ts.SyntaxKind.CloseBraceToken && --depth === 0 && begun) {
      return source.slice(start, start + scanner.getTextPos());
    }
  }
  throw Error('unbalanced production method: ' + name);
}
function compileClass(name, methods, globals) {
  const code = ts.transpileModule('class ' + name + ' {\n' + methods.join('\n') + '\n}\nreturn ' + name + ';', {
    compilerOptions: {target: ts.ScriptTarget.ES2020},
  }).outputText;
  return new Function(...Object.keys(globals), code)(...Object.values(globals));
}
function pageFixture({playing = true, width = 1080, height = 1920} = {}) {
  const load = createArktsLoader();
  const {VideoDetailGeometry} = load('common/VideoDetailGeometry');
  const ScrollState = {Idle: 0, Scroll: 1, Fling: 2}, animations = [];
  const Page = compileClass('Page', ['playerHeight', 'computePlayerHeight', 'minPlayerHeight',
    'shouldCollapsePlayer', 'visiblePlayerHeight', 'setPlayerCollapse', 'onContentScrollFrame',
    'isScrollerAtTop', 'expandPlayerForResume'].map(name => method(pageSource, name)), {
    VideoDetailGeometry, ScrollState, Curve: {EaseOut: 1},
    Immersive: {statusBarHeight: () => 32, bottomInset: () => 20},
  });
  const page = Object.assign(new Page(), {
    screenWidthVp: 360, screenHeightVp: 780, realVideoWidth: width, realVideoHeight: height,
    currentCid: 8, detail: {aid: 7, width, height, rotate: 0, pages: []},
    playerHeightKey: '', playerHeightValue: 0, playerCollapseRaw: 0, playerCollapse: 0,
    playerPlaying: playing, playerEnded: false, startupCoverVisible: false,
    playUrl: 'https://example.invalid/video', playbackAddressFailed: false,
    refreshScreenSize() {},
    getUIContext: () => ({animateTo(options, change) {animations.push(options); change();}}),
  });
  const scroller = {y: 0, currentOffset() {return {yOffset: this.y};}};
  return {page, scroller, ScrollState, animations,
    scroll(offset, state = ScrollState.Scroll) {return page.onContentScrollFrame(offset, scroller, state);}};
}
function near(actual, expected, message) {assert.ok(Math.abs(actual - expected) < 1e-8, message + ': ' + actual + ' vs ' + expected);}

test('player collapse: small drag increments move the viewport 1:1 without quantized steps', () => {
  const f = pageFixture(), base = f.page.visiblePlayerHeight();
  let travel = 0;
  for (let step = 0; step < 30; step++) {
    const increment = [0.04, 0.05, 0.08, 0.2][step % 4]; travel += increment;
    near(f.scroll(increment), 0, 'the player consumes this drag');
    near(base - f.page.visiblePlayerHeight(), travel, 'every subpixel frame remains visible');
  }
  assert.equal(f.animations.length, 0, 'finger-driven size changes are never retargeted through animateTo');
});

test('player collapse: direction reversal restores all visual and raw displacement', () => {
  const f = pageFixture(), base = f.page.visiblePlayerHeight();
  const drags = [0.2, 0.35, 1.25, 12.4, 3.9, 0.15];
  for (const offset of drags) near(f.scroll(offset), 0, 'collapse consumes its available travel');
  near(base - f.page.visiblePlayerHeight(), drags.reduce((sum, value) => sum + value, 0), 'travel is linear');
  for (const offset of drags.slice().reverse()) near(f.scroll(-offset), 0, 'reverse consumes its available travel');
  near(f.page.playerCollapseRaw, 0, 'the gesture accumulation returns to its starting point');
  near(f.page.visiblePlayerHeight(), base, 'the picture fully returns without a residual gap');
});

test('player collapse: both endpoints conserve drag overflow for the comments list', () => {
  const f = pageFixture(), base = f.page.playerHeight(), max = base - f.page.minPlayerHeight();
  const remaining = f.scroll(max + 37.5);
  near(remaining, 37.5, 'only excess upward travel reaches comments');
  near(f.page.visiblePlayerHeight(), f.page.minPlayerHeight(), 'collapse stops at its real endpoint');
  near(f.page.playerCollapseRaw + remaining, max + 37.5, 'upward displacement is conserved');
  const returned = f.scroll(-(max + 19.5));
  near(returned, -19.5, 'only excess downward travel reaches the list');
  near(f.page.visiblePlayerHeight(), base, 'expansion stops at the full picture');
  near(max - returned, max + 19.5, 'downward displacement is conserved');
});

test('player collapse: comments must reach their top before a downward drag expands the picture', () => {
  const f = pageFixture(); f.scroll(80); const collapsed = f.page.visiblePlayerHeight();
  f.scroller.y = 55;
  assert.equal(f.scroll(-25), -25); near(f.page.visiblePlayerHeight(), collapsed, 'scrolling content retains picture size');
  f.scroller.y = 0;
  near(f.scroll(-25), 0, 'the picture now consumes the downward drag');
  near(f.page.visiblePlayerHeight(), collapsed + 25, 'expansion uses exactly the consumed travel');
});

test('player collapse: startup, playing landscape and programmatic scroll retain their picture viewport', () => {
  const f = pageFixture(); f.page.startupCoverVisible = true;
  assert.equal(f.scroll(25), 25); assert.equal(f.page.playerCollapseRaw, 0);
  f.page.startupCoverVisible = false;
  assert.equal(f.scroll(25, f.ScrollState.Idle), 25); assert.equal(f.page.playerCollapseRaw, 0);
  const landscape = pageFixture({width: 1920, height: 1080});
  assert.equal(landscape.scroll(25), 25); assert.equal(landscape.page.playerCollapseRaw, 0);
  landscape.page.playerPlaying = false;
  near(landscape.scroll(25), 0, 'paused landscape remains eligible for compact comments mode');
});

// Convert native container blocks into callbacks without rewriting their actual
// arguments, modifier chains, conditionals or callback bodies.
function nativeBlocks(source) {
  const scanner = ts.createScanner(ts.ScriptTarget.ES2020, true, ts.LanguageVariant.Standard, source), tokens = [];
  for (let kind = scanner.scan(); kind !== ts.SyntaxKind.EndOfFileToken; kind = scanner.scan()) {
    tokens.push({kind, start: scanner.getTokenPos(), end: scanner.getTextPos(), text: scanner.getTokenText()});
  }
  const balance = (start, open, close) => {
    let depth = 0;
    for (let i = start; i < tokens.length; i++) {
      if (tokens[i].kind === open) depth++;
      else if (tokens[i].kind === close && --depth === 0) return i;
    }
    throw Error('unbalanced native container');
  };
  const edits = [];
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].text !== 'Stack' || tokens[i + 1]?.kind !== ts.SyntaxKind.OpenParenToken) continue;
    const endArgs = balance(i + 1, ts.SyntaxKind.OpenParenToken, ts.SyntaxKind.CloseParenToken);
    if (tokens[endArgs + 1]?.kind !== ts.SyntaxKind.OpenBraceToken) continue;
    const endBody = balance(endArgs + 1, ts.SyntaxKind.OpenBraceToken, ts.SyntaxKind.CloseBraceToken);
    edits.push({start: tokens[endArgs].start, end: tokens[endArgs].end,
      text: (endArgs === i + 2 ? '' : ', ') + '() =>'});
    edits.push({start: tokens[endBody].end, end: tokens[endBody].end, text: ')'});
  }
  for (const edit of edits.sort((a, b) => b.start - a.start)) source = source.slice(0, edit.start) + edit.text + source.slice(edit.end);
  return source;
}
function pictureFixture(props = {}) {
  const nodes = [], parents = [], resizes = [];
  function native(type, ...args) {
    const parent = parents.at(-1), node = {type, args, parent, props: {}}; nodes.push(node);
    if (typeof args.at(-1) === 'function') {parents.push(node); args.at(-1)(); parents.pop();}
    let proxy;
    proxy = new Proxy({}, {get: (_target, key) => (...values) => {
      node.props[key] = values.length === 1 ? values[0] : values; return proxy;
    }});
    return proxy;
  }
  const Picture = compileClass('Picture', [method(viewSource, 'videoRenderScale'),
    nativeBlocks(method(viewSource, 'VideoPicture'))], {
    Stack: (...args) => native('Stack', ...args), XComponent: (...args) => native('XComponent', ...args),
    Image: (...args) => native('Image', ...args), XComponentType: {SURFACE: 0},
    Alignment: {Center: 0}, ImageFit: {Cover: 0}, HitTestMode: {None: 0}, Curve: {EaseOut: 0},
    MotionTokens: {content: 0, duration: () => 160},
  });
  const picture = Object.assign(new Picture(), {
    videoFixedHeight: 432, videoVisibleHeight: 432, mirrorOn: false,
    videoCover: 'cover', firstFrameShown: false, seekRecoveryCoverVisible: true,
    seekPreviewFrame: {kind: 'pixelmap'}, reduceMotion: false, xcController: {},
    playback: {resize: (...args) => resizes.push(args)}, onSurfaceReady() {},
    getUIContext: () => ({vp2px: value => value * 3}), ...props,
  });
  return {picture, nodes, resizes, render() {nodes.length = 0; picture.VideoPicture();},
    node(type) {return nodes.find(node => node.type === type);}};
}
function dimensions(node, parentWidth, parentHeight) {
  const constraint = node.props.constraintSize || {};
  let height = node.props.height === '100%' ? parentHeight : node.props.height;
  // Start with the shortened visible parent's height constraint. A stable
  // min=max picture constraint must then keep its native backing buffer whole.
  height = Math.min(height, parentHeight);
  if (Number.isFinite(constraint.minHeight)) height = Math.max(height, constraint.minHeight);
  if (Number.isFinite(constraint.maxHeight)) height = Math.min(height, constraint.maxHeight);
  return [node.props.width === '100%' ? parentWidth : node.props.width,
    height];
}

test('player picture: collapsing and expanding preserves the native buffer aspect at every visible size', () => {
  const page = pageFixture(), f = pictureFixture({videoFixedHeight: page.page.playerHeight()});
  const states = [0, 0.2, 1.9, 35, 110, 200, 230, 200, 35, 1.9, 0.2, 0];
  let lastSize;
  for (const collapse of states) {
    page.page.setPlayerCollapse(collapse);
    f.picture.videoVisibleHeight = page.page.visiblePlayerHeight(); f.render();
    const surface = f.node('XComponent'), picture = surface.parent;
    const [width, height] = dimensions(picture, 360, f.picture.videoVisibleHeight);
    const surfaceSize = dimensions(surface, width, height), scale = picture.props.scale;
    assert.deepEqual(surfaceSize, [360, f.picture.videoFixedHeight], 'layout never squeezes the previous native framebuffer');
    assert.deepEqual(picture.props.constraintSize,
      {minHeight: f.picture.videoFixedHeight, maxHeight: f.picture.videoFixedHeight},
      'a short visible parent cannot clamp the native picture buffer');
    assert.ok(scale, 'the picture has an explicit uniform render transform');
    assert.equal(picture.args[0].alignContent, 0, 'the picture and its overlays remain centered');
    assert.equal(scale.centerX, '50%'); assert.equal(scale.centerY, '50%');
    near(scale.x, scale.y, 'horizontal and vertical scales must match');
    near(scale.x, f.picture.videoVisibleHeight / f.picture.videoFixedHeight, 'the picture follows the visible viewport');
    near((surfaceSize[0] * scale.x) / (surfaceSize[1] * scale.y), 360 / f.picture.videoFixedHeight,
      'the displayed picture aspect never oscillates with native resize acknowledgement');
    if (!lastSize || surfaceSize.some((value, i) => value !== lastSize[i])) {
      surface.props.onSizeChange({}, {width: surfaceSize[0], height: surfaceSize[1]}); lastSize = surfaceSize;
    }
  }
  assert.deepEqual(f.resizes, [[1080, f.picture.videoFixedHeight * 3]],
    'comment scrolling does not queue a native resize for every layout frame');
});

test('player picture: startup cover, seek preview and mirrored video share the same scaling parent', () => {
  const f = pictureFixture({videoVisibleHeight: 195, mirrorOn: true}); f.render();
  const surface = f.node('XComponent'), overlays = f.nodes.filter(node => node.type === 'Image');
  assert.equal(overlays.length, 2);
  for (const overlay of overlays) {
    assert.equal(overlay.parent, surface.parent, 'cover and preview use the same coordinate system as real video');
    assert.deepEqual(dimensions(overlay, 360, f.picture.videoFixedHeight), [360, f.picture.videoFixedHeight]);
  }
  assert.equal(surface.parent.props.rotate.angleY, 180);
  near(surface.parent.props.scale.x, surface.parent.props.scale.y, 'mirror cannot introduce an independent size transform');
});

test('player picture: fullscreen keeps the actual surface viewport and clears the comment-collapse transform', () => {
  const f = pictureFixture({videoFixedHeight: 0, videoVisibleHeight: 0}); f.render();
  const surface = f.node('XComponent'), picture = surface.parent;
  assert.deepEqual(dimensions(picture, 780, 360), [780, 360]);
  const scale = picture.props.scale;
  near(scale.x, 1, 'fullscreen horizontal scale'); near(scale.y, 1, 'fullscreen vertical scale');
  assert.equal(f.picture.videoRenderScale(), 1);
});

test('player picture: fully collapsed paused landscape resumes through expansion without resizing its native buffer', () => {
  const page = pageFixture({playing: false, width: 1920, height: 1080});
  const base = page.page.playerHeight(), f = pictureFixture({videoFixedHeight: base});
  page.scroll(base * 2); near(page.page.visiblePlayerHeight(), 96, 'paused comments can fully collapse');
  let previousSize;
  function render() {
    f.picture.videoVisibleHeight = page.page.visiblePlayerHeight(); f.render();
    const surface = f.node('XComponent'), picture = surface.parent;
    const [width, height] = dimensions(picture, 360, f.picture.videoVisibleHeight);
    const currentSize = dimensions(surface, width, height);
    if (!previousSize || currentSize.some((value, index) => value !== previousSize[index])) {
      surface.props.onSizeChange({}, {width: currentSize[0], height: currentSize[1]}); previousSize = currentSize;
    }
    return picture.props.scale;
  }
  const compact = render(); near(compact.x, 96 / base, 'paused video keeps its original aspect at compact size');
  page.page.expandPlayerForResume();
  near(page.page.visiblePlayerHeight(), base, 'resume expansion reaches the full-size viewport');
  near(page.page.playerCollapseRaw, 0, 'resume leaves no stale raw collapse');
  const expanded = render(); near(expanded.x, 1, 'expanded picture horizontal scale'); near(expanded.y, 1, 'expanded picture vertical scale');
  assert.equal(page.animations.length, 1, 'user resume requests one expansion animation');
  assert.ok(page.animations[0].duration > 0);
  assert.deepEqual(f.resizes, [[1080, base * 3]], 'resume expansion reuses the existing buffer');
});
