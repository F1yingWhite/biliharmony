const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function fixture() {
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'components/player/PlayerView.ets'), 'utf8');
  const start = source.indexOf('  private interactionBottomMargin():');
  const end = source.indexOf('  private bindInteractions():', start);
  assert.ok(start >= 0 && end > start);
  const code = ts.transpileModule('class View {\n' + source.slice(start, end) + '\n}; return View;',
    {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  return Object.assign(new (new Function(code)())(), {interactionViewportHeight: 0, danmakuFixedHeight: 0,
    dmEngine: {height: 216}, showControls: true, fullscreen: false});
}

test('interaction height uses the measured player viewport and reserves the actual control bar', () => {
  const view = fixture(); view.onInteractionViewportChanged(202.5);
  assert.equal(view.interactionAvailableHeight(), 146.5);
  view.showControls = false; assert.equal(view.interactionAvailableHeight(), 182.5);
  view.onInteractionViewportChanged(320); view.fullscreen = true; view.showControls = true;
  assert.equal(view.interactionBottomMargin(), 92); assert.equal(view.interactionAvailableHeight(), 220);
});

test('viewport fallback and invalid size callbacks cannot give a card negative or stale fullscreen space', () => {
  const view = fixture(); assert.equal(view.interactionAvailableHeight(), 160);
  view.danmakuFixedHeight = 180; assert.equal(view.interactionAvailableHeight(), 124);
  view.onInteractionViewportChanged(360); view.onInteractionViewportChanged('200');
  assert.equal(view.interactionAvailableHeight(), 144);
  for (const value of [0, -1, NaN, undefined, 'bad']) view.onInteractionViewportChanged(value);
  assert.equal(view.interactionAvailableHeight(), 144);
  view.onInteractionViewportChanged(20); assert.equal(view.interactionAvailableHeight(), 0);
});
