const test = require('node:test');
const assert = require('node:assert/strict');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const { environment, read } = require('./dynamic-test-env.cjs');

function chrome() {
  return environment().load('common/UserSpaceChrome').UserSpaceChrome;
}

test('space chrome retains independent scroll backgrounds for nested pages with the same user', () => {
  const Chrome = chrome();
  const outer = { mid: 123 }, inner = { mid: 123 };
  Chrome.setCovered(outer, true);
  assert.equal(Chrome.statusIconLight(outer, false), false);
  assert.equal(Chrome.statusIconLight(inner, false), true);
  Chrome.setCovered(inner, true);
  Chrome.setCovered(outer, false);
  assert.equal(Chrome.statusIconLight(outer, false), true);
  assert.equal(Chrome.statusIconLight(inner, false), false);
});

test('space chrome preserves banner contrast and follows the theme of an opaque status background', () => {
  const Chrome = chrome(), param = { mid: 123 };
  assert.equal(Chrome.statusIconLight(param, false), true);
  assert.equal(Chrome.statusIconLight(param, true), true);
  Chrome.setCovered(param, true);
  assert.equal(Chrome.statusIconLight(param, false), false);
  assert.equal(Chrome.statusIconLight(param, true), true);
  Chrome.setCovered(param, false);
  assert.equal(Chrome.statusIconLight(param, false), true);
});

function section(source, begin, end, from = 0) {
  const start = source.indexOf(begin, from), finish = source.indexOf(end, start + begin.length);
  assert.ok(start >= 0 && finish > start, 'production anchors: ' + begin + ' -> ' + end);
  return source.slice(start, finish);
}

// Execute the production Index methods and its space destination's onShown body;
// only the navigation stack and system-window calls are replaced.
function indexFixture() {
  const Chrome = chrome(), paths = [], calls = [];
  const routes = Object.fromEntries(['NAV_VIDEO_DETAIL', 'NAV_LIVE_ROOM', 'NAV_IMAGE_VIEWER',
    'NAV_USER_SPACE', 'NAV_BANGUMI_DETAIL'].map(name => [name, name]));
  const source = read('pages/Index');
  const spaceStart = source.indexOf('} else if (name === NAV_USER_SPACE)');
  assert.ok(spaceStart >= 0);
  const shown = section(source, '.stdDestination(() => {', '}, () => {', spaceStart)
    .slice('.stdDestination(() => {'.length);
  const methods = section(source, '  syncBarColors(): void {', '  private returnToHome(): void {');
  const validation = section(source, '  private static asUserSpaceParam(', '  private static asLiveRoomParam(');
  const code = ts.transpileModule(`export class Index {
    isDark: boolean = false;
    ${methods}
    ${validation}
    onShownUserSpace(param: Object): void { ${shown} }
  }`, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  new Function('module', 'exports', 'Immersive', 'AppNavStack', 'UserSpaceChrome', ...Object.keys(routes), code)(
    module, module.exports, { setBarIcons: (...args) => calls.push(args) }, {
      getAllPathName: () => paths.map(entry => entry.name),
      getParamByIndex: index => paths[index]?.param,
    }, Chrome, ...Object.values(routes));
  return { Chrome, paths, calls, routes, index: new module.exports.Index() };
}

test('Index restores the visible space instance after nested navigation, foregrounding and theme changes', () => {
  const f = indexFixture(), outer = { mid: 123 }, inner = { mid: 123 };
  f.Chrome.setCovered(outer, true);
  f.paths.push({ name: f.routes.NAV_USER_SPACE, param: outer });
  f.index.onShownUserSpace(outer);
  assert.deepEqual(f.calls.at(-1), [false, false]);
  f.paths.push({ name: f.routes.NAV_USER_SPACE, param: inner });
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [true, false]);
  f.paths.pop();
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [false, false]);
  f.index.isDark = true;
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [true, true]);
  f.index.isDark = false;
  f.index.onShownUserSpace(outer);
  assert.deepEqual(f.calls.at(-1), [false, false]);
  f.Chrome.setCovered(outer, false);
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [true, false]);
});

test('Index uses ordinary theme icons for invalid space params and retains other page policies', () => {
  const f = indexFixture();
  f.paths.push({ name: f.routes.NAV_USER_SPACE, param: null });
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [false, false]);
  f.index.onShownUserSpace({ mid: 0 });
  assert.deepEqual(f.calls.at(-1), [false, false]);
  f.paths[0] = { name: f.routes.NAV_VIDEO_DETAIL };
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [true, true]);
  f.paths[0] = { name: f.routes.NAV_BANGUMI_DETAIL };
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [true, false]);
  f.paths.length = 0;
  f.index.reapplyBarColors();
  assert.deepEqual(f.calls.at(-1), [false, false]);
});
