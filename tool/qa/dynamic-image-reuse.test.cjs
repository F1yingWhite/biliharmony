// Execute the production DynCard builders and navigation with the existing native-DSL harness.
// Getter arguments model ArkUI's by-reference Builder contract, while the AST checks below
// ensure production calls actually qualify for that contract. This is not a native partial-
// update, image-decoder or screenshot test; CompileArkTS and device fixtures cover those.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

// Extend only the harness's native boundary inventory for DynCard's Grid and rich Text.
// Production conditions, URL transforms, loops, keys and click closures remain unchanged.
const harnessPath = path.join(__dirname, 'arkui-ui-harness.cjs');
let harnessSource = fs.readFileSync(harnessPath, 'utf8');
const containerAnchor = "'Stack']);";
const nodeAnchor = "'Stack', 'Progress'])";
assert.ok(harnessSource.includes(containerAnchor) && harnessSource.includes(nodeAnchor));
harnessSource = harnessSource.replace(containerAnchor, "'Stack', 'Grid', 'GridItem', 'Text']);")
  .replace(nodeAnchor, "'Stack', 'Progress', 'Grid', 'GridItem', 'Span', 'ImageSpan'])")
  .replace('module.exports = {createNativeComponent};', 'module.exports = {createNativeComponent, nativeBlocks};');
const harness = new Module(harnessPath, module);
harness.filename = harnessPath;
harness.paths = Module._nodeModulePaths(__dirname);
harness._compile(harnessSource, harnessPath);
const {createNativeComponent, nativeBlocks} = harness.exports;

const sourceRoot = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const source = fs.readFileSync(path.join(sourceRoot, 'components/dynamic/DynCard.ets'), 'utf8');
const ast = ts.createSourceFile('DynCard.ts', nativeBlocks(source.replace(/\bstruct\s+(\w+)/g, 'class $1')),
  ts.ScriptTarget.ES2020, true, ts.ScriptKind.TS);
assert.deepEqual(ast.parseDiagnostics.map(diagnostic => diagnostic.messageText), [], 'native DSL adaptation must parse');
const cardClass = ast.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'DynCard');
const method = name => cardClass.members.find(node => ts.isMethodDeclaration(node) && node.name.getText(ast) === name);
function walk(node, visit) {visit(node); ts.forEachChild(node, child => walk(child, visit));}
function calls(name) {
  const result = [];
  walk(cardClass, node => {
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
      node.expression.expression.kind === ts.SyntaxKind.ThisKeyword && node.expression.name.text === name) result.push(node);
  });
  return result;
}
const compact = node => node.getText(ast).replace(/\s/g, '');

test('dynamic image Builders keep one required object parameter and object-literal calls at every nesting level', () => {
  for (const [name, type, fields] of [
    ['ImageGrid', 'DynamicImageGridParams', {item: 'DynamicItem', inset: 'number'}],
    ['ForwardedCard', 'DynamicForwardedCardParams', {item: 'DynamicItem'}],
  ]) {
    const builder = method(name);
    assert.equal(builder.parameters.length, 1, name + ': multiple arguments compile as by-value snapshots');
    assert.ok(ts.isIdentifier(builder.parameters[0].name));
    assert.equal(builder.parameters[0].type.getText(ast), type);
    assert.equal(builder.parameters[0].questionToken, undefined);
    const declaration = ast.statements.find(node => ts.isInterfaceDeclaration(node) && node.name.text === type);
    assert.ok(declaration, type);
    for (const [field, fieldType] of Object.entries(fields)) {
      const member = declaration.members.find(node => node.name.getText(ast) === field);
      assert.ok(member && !member.questionToken);
      assert.equal(member.type.getText(ast), fieldType);
    }
    for (const call of calls(name)) {
      assert.equal(call.arguments.length, 1);
      assert.ok(ts.isObjectLiteralExpression(call.arguments[0]), name + ': reference arguments must be object literals');
      assert.ok(call.arguments[0].properties.every(node => ts.isPropertyAssignment(node)));
    }
    walk(builder.body, node => {
      if (!ts.isVariableDeclaration(node) || !node.initializer) return;
      assert.ok(!/\bparams\.(?:item|inset)\b/.test(node.initializer.getText(ast)),
        name + ': do not freeze a reference field into a local Builder snapshot');
    });
  }
  assert.deepEqual(calls('ImageGrid').map(call => compact(call.arguments[0])).sort(),
    ['{item:params.item,inset:20}', '{item:this.item,inset:0}'].sort());
  assert.deepEqual(calls('ForwardedCard').map(call => compact(call.arguments[0])).sort(),
    ['{item:params.item.original}', '{item:this.item.original}'].sort());
});

function fixture() {
  const routes = [], geometryReads = [];
  class DynamicActionState {liked = false; likeCount = 0; forwardCount = 0;}
  class DynamicCardActions {invalidate() {} sync() {}}
  const ui = createNativeComponent('components/dynamic/DynCard', {
    mocks: {
      'common/MotionTokens': {MotionTokens: {KEY_REDUCE_MOTION: 'reduceMotion', isReduced: () => false}},
      'common/AppRouter': {AppNavStack: {pushPathByName: (...args) => routes.push(args)},
        NAV_IMAGE_VIEWER: 'images', NAV_DYNAMIC_DETAIL: 'dynamic', NAV_VIDEO_DETAIL: 'video',
        NAV_LIVE_ROOM: 'live', NAV_BANGUMI_DETAIL: 'bangumi', NAV_USER_SPACE: 'user', NAV_SEARCH: 'search'},
      'common/Haptic': {Haptic: {tap() {}}},
      'common/EmoteResolver': {EmoteResolver: {ensureLoaded() {}}},
      'common/EmoteImageCache': {EmoteImageCache: {localPathOf: url => url}},
      'components/dynamic/DynamicContent': {contentPartsOf: () => [], cachedDynamicRichDetail: () => undefined},
      'components/dynamic/DynamicCardActions': {DynamicCardActions, DynamicActionState},
      'services/auth/UserStore': {UserStore: {isLogin: false}},
      'api/DynamicApi': {DynamicApi: {}},
      '@kit.ArkUI': {}, '@kit.ImageKit': {},
    },
    recordComponents: {'components/UserDecorations': ['DecoratedAvatar', 'UserDecorationBanner']},
    globals: {ImageSpanAlignment: {BOTTOM: 'bottom'}, AppStorage: {setOrCreate() {}}},
    props: {idPrefix: 'feed-', gridWidth: 332, sharedImageTransition: true},
  });
  ui.component.getUIContext = () => ({px2vp: value => value,
    getComponentUtils: () => ({getRectangleById: id => {
      geometryReads.push(id);
      return {size: {width: 100, height: 100}, windowOffset: {x: 10, y: 20}};
    }}), animateTo: (_options, callback) => callback(),
  });
  const {DynamicItem} = ui.load('model/Models');
  const item = (id, count, extra = {}) => Object.assign(new DynamicItem(), {
    dynId: id, uname: id + '-author', images: Array.from({length: count}, (_unused, index) =>
      'https://i0.hdslb.com/bfs/album/' + id + '-' + index + '.jpg'), ...extra,
  });
  const rebind = next => ui.component.aboutToReuse({item: next, idPrefix: 'feed-'});
  // Retain the first callback and argument identity; changing the owning @Prop only
  // changes the getter's result. Calling build() again would hide a by-value regression.
  const retain = (name, getItem, inset) => {
    const ref = {get item() {return getItem();}, inset};
    const retained = ui.component[name].bind(ui.component, ref);
    return () => ui.render(retained);
  };
  const photos = () => ui.nodes.filter(node => node.type === 'Image' && /bfs\/album\//.test(node.args[0]));
  const clickPhoto = node => {
    let target = node;
    while (target && !target.props.onClick) target = target.parent;
    assert.ok(target, 'photo must have a clickable image or containing cell');
    target.props.onClick();
    assert.equal(routes.at(-1)[0], 'images');
    return routes.at(-1)[1];
  };
  return {...ui, routes, geometryReads, item, rebind, retain, photos, clickPhoto};
}

function assertPhotos(f, host, item, inset = 0) {
  const photos = f.photos(), visible = item.images.slice(0, 9);
  assert.equal(photos.length, visible.length);
  assert.deepEqual(photos.map(node => node.args[0]), visible.map(url =>
    url + '@' + (item.images.length === 1 ? 900 : 320) + 'w.webp'));
  assert.deepEqual(photos.map(node => node.props.id), visible.map((_url, index) =>
    'feed-dynamic-host-' + host.dynId + '-img-' + item.dynId + '-' + index));
  assert.ok(f.loops.every(loop => new Set(loop.keys).size === loop.keys.length));
  const cell = (332 - inset - 8) / 3;
  if (item.images.length === 1) assert.equal(photos[0].props.height, cell * 2 + 4);
  else assert.equal(f.nodes.find(node => node.type === 'Grid').props.height,
    Math.ceil(visible.length / 3) * cell + (Math.ceil(visible.length / 3) - 1) * 4);
  for (const [index, photo] of photos.entries()) {
    const viewer = f.clickPhoto(photo);
    assert.deepEqual(viewer.images, item.images, 'viewer receives current full originals, including overflow');
    assert.equal(viewer.initialIndex, index);
    assert.deepEqual(viewer.srcPreviews, item.images.map(url =>
      url + '@' + (item.images.length === 1 ? 900 : 320) + 'w.webp'));
    assert.equal(viewer.srcIds[index], photo.props.id);
    assert.equal(viewer.transitionId, 'feed-image-viewer-host-' + host.dynId + '-img-' + item.dynId + '-' + index);
  }
}

test('retained root image Builder follows single → multiple → single reuse with current URLs, IDs, geometry and clicks', () => {
  const f = fixture(), a = f.item('root-a', 1), b = f.item('root-b', 4), c = f.item('root-c', 1);
  f.rebind(a);
  const update = f.retain('ImageGrid', () => f.component.item, 0);
  update(); assertPhotos(f, a, a);
  const initialKeys = f.loops.flatMap(loop => loop.keys);
  f.rebind(b); update(); assertPhotos(f, b, b);
  assert.equal(f.nodes.some(node => node.type === 'Image' && node.args[0].includes('root-a')), false);
  assert.ok(f.loops.flatMap(loop => loop.keys).every(key => !initialKeys.includes(key)));
  f.rebind(c); update(); assertPhotos(f, c, c);
  assert.equal(f.nodes.some(node => node.type === 'Grid'), false);
  assert.ok(f.geometryReads.at(-1).includes('root-c-img-root-c'));
});

test('same image URL across different dynamic IDs gets a new single-image native key and target ID', () => {
  const f = fixture(), a = f.item('same-url-a', 1), b = f.item('same-url-b', 1);
  b.images = a.images.slice(); f.rebind(a);
  const update = f.retain('ImageGrid', () => f.component.item, 0); update();
  const initialKey = f.loops[0].keys[0];
  f.rebind(b); update(); assertPhotos(f, b, b);
  assert.notEqual(f.loops[0].keys[0], initialKey);
});

test('dynamic photo geometry binds only in an enabled embedded transition with reduced motion disabled', () => {
  const f = fixture(), update = f.retain('ImageGrid', () => f.component.item, 0);
  for (const count of [1, 4]) {
    const item = f.item('geometry-' + count, count); f.rebind(item);
    for (const shared of [false, true]) {
      for (const reduced of [false, true]) {
        f.component.sharedImageTransition = shared;
        f.component.reduceMotion = reduced;
        update();
        assert.deepEqual(f.photos().map(node => node.props.geometryTransition), item.images.map((_url, index) =>
          shared && !reduced ? 'feed-image-viewer-host-' + item.dynId + '-img-' + item.dynId + '-' + index : ''));
      }
    }
  }
});

test('retained image Builder updates same-ID image replacement, duplicate URL keys and ninth-cell overflow', () => {
  const f = fixture(), a = f.item('same-id', 1), b = f.item('same-id', 11);
  b.images[1] = b.images[0]; f.rebind(a);
  const update = f.retain('ImageGrid', () => f.component.item, 0); update();
  const oldKey = f.loops[0].keys[0];
  f.rebind(b); update(); assertPhotos(f, b, b);
  assert.ok(f.loops[0].keys.every(key => key !== oldKey));
  assert.ok(f.nodes.some(node => node.type === 'Text' && node.args[0] === '+2'));
  const viewer = f.clickPhoto(f.photos()[8]);
  assert.equal(viewer.srcIds[10], viewer.srcIds[8]);
  assert.equal(viewer.srcRects[10], viewer.srcRects[8]);
});

test('retained forwarded Builder follows multi-level replacement and routes each original image/detail/major', () => {
  const f = fixture();
  const chain = suffix => {
    const deepest = f.item('deep-' + suffix, 1, {title: 'Video ' + suffix,
      cover: 'https://i0.hdslb.com/bfs/archive/' + suffix + '.jpg', bvid: 'BV-' + suffix});
    const middle = f.item('middle-' + suffix, 2, {original: deepest});
    return f.item('host-' + suffix, 0, {original: middle});
  };
  f.rebind(chain('old'));
  const update = f.retain('ForwardedCard', () => f.component.item.original);
  update(); assert.equal(f.photos().length, 3);
  const current = chain('new'); f.rebind(current); update();
  const middle = current.original, deepest = middle.original;
  const photos = f.photos();
  assert.deepEqual(photos.map(node => node.args[0]),
    [...middle.images.map(url => url + '@320w.webp'), deepest.images[0] + '@900w.webp']);
  assert.equal(photos.some(node => node.args[0].includes('-old-')), false);
  for (const [index, photo] of photos.entries()) {
    const owner = index < middle.images.length ? middle : deepest;
    const ownerIndex = index < middle.images.length ? index : 0;
    const viewer = f.clickPhoto(photo);
    assert.deepEqual(viewer.images, owner.images);
    assert.equal(viewer.initialIndex, ownerIndex);
    assert.equal(viewer.srcIds[ownerIndex], 'feed-dynamic-host-host-new-img-' + owner.dynId + '-' + ownerIndex);
  }
  for (const owner of [middle, deepest]) {
    f.nodes.find(node => node.type === 'Text' && node.args[0] === '@' + owner.uname).props.onClick();
    assert.equal(f.routes.at(-1)[0], 'dynamic');
    assert.equal(f.routes.at(-1)[1].item, owner);
  }
  const major = f.nodes.find(node => node.type === 'Row' && node.props.id?.includes('-card-deep-new-BV-new'));
  assert.ok(major); major.props.onClick();
  assert.equal(f.routes.at(-1)[0], 'video');
  assert.equal(f.routes.at(-1)[1].bvid, deepest.bvid);
  assert.equal(f.routes.at(-1)[1].cover, deepest.cover + '@240w.webp');
});

test('full production build keeps root and forwarded photos separate after reuse and removes empty image branches', () => {
  const f = fixture(), root = f.item('full-a', 1, {original: f.item('forward-a', 2)});
  f.rebind(root); f.build(); assert.equal(f.photos().length, 3);
  const next = f.item('full-b', 2, {original: f.item('forward-b', 1)});
  f.rebind(next); f.build();
  assert.equal(f.photos().length, 3);
  assert.ok(f.photos().every(node => !node.args[0].includes('-a-')));
  for (const photo of f.photos()) {
    const owner = photo.props.id.includes('-img-forward-b-') ? next.original : next;
    assert.deepEqual(f.clickPhoto(photo).images, owner.images);
  }
  f.rebind(f.item('no-images', 0)); f.build();
  assert.deepEqual(f.photos(), []);
  assert.equal(f.nodes.some(node => node.type === 'Grid'), false);
});
