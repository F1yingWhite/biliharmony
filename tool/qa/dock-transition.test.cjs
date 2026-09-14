const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/pages/Index.ets'), 'utf8');
const start = source.indexOf('  onSearchSideChanged(): void {');
const end = source.indexOf('  aboutToAppear(): void {', start);
assert.ok(start >= 0 && end > start, 'dock animation production method must be present');
const code = ts.transpileModule('export class Harness {\n' + source.slice(start, end) + '\n}', {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
function setup() {
  const module = { exports: {} };
  new Function('module', 'exports', 'Curve', code)(module, module.exports, { EaseInOut: 0 });
  const animations = [];
  const p = new module.exports.Harness();
  Object.assign(p, { dockMounted: true, dockSide: 'right', searchSide: 'right',
    getUIContext: () => ({ animateTo(options, change) { animations.push(options); change(); } }) });
  return { p, animations };
}
test('both dock positions change inside one horizontal animation', () => {
  const { p, animations } = setup(); p.searchSide = 'left'; p.onSearchSideChanged();
  assert.equal(p.dockSide, 'left'); assert.equal(animations.length, 1);
  assert.ok(animations[0].duration > 0);
});
test('rapid reversal immediately retargets without waiting for an earlier transition', () => {
  const { p, animations } = setup();
  for (const side of ['left', 'right', 'left']) {
    p.searchSide = side; p.onSearchSideChanged(); assert.equal(p.dockSide, side);
  }
  assert.equal(animations.length, 3);
});
test('unchanged state or an unmounted dock never starts an animation', () => {
  const { p, animations } = setup(); p.onSearchSideChanged();
  p.dockMounted = false; p.searchSide = 'left'; p.onSearchSideChanged();
  assert.equal(p.dockSide, 'right'); assert.equal(animations.length, 0);
});
