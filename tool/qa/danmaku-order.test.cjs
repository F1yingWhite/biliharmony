const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createArktsLoader } = require('./arkts-module.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const realSegment = require('./fixtures/danmaku-seg1-unordered.json');

function item(id, time, text = 'comment-' + id, mode = 1, weight = 9) {
  return { id, idStr: String(id), time, text, mode, weight, fontsize: 25, color: 16777215, mergeCount: 1 };
}
function fixture() {
  const load = createArktsLoader({ mocks: { 'api/BiliApi': {} } });
  const { PlayerDanmakuEngine } = load('components/player/PlayerDanmakuEngine');
  const drawn = new Set();
  const ctx = { measureText: text => ({ width: text.length * 7 }), clearRect() {}, strokeText() {},
    fillText(text) { drawn.add(text); } };
  const engine = new PlayerDanmakuEngine(ctx);
  engine.fullscreen = true; engine.width = 844; engine.height = 391;
  const playUntil = end => {
    for (let step = 0; step <= Math.ceil(end * 20); step++) {
      const seconds = step / 20; engine.lastPlayerTime = seconds;
      engine.spawn(seconds); engine.drawFrame(true, 1000 + step * 50);
    }
  };
  return { engine, drawn, playUntil };
}

function viewHarness(engine) {
  const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
  const source = fs.readFileSync(path.join(root, 'components/player/PlayerView.ets'), 'utf8').replace(/\r\n/g, '\n');
  const begin = source.indexOf('  setDmMerge(on: boolean): void {');
  const end = source.indexOf('  private toggleDmBlock(', begin);
  assert.ok(begin >= 0 && end > begin);
  const theme = fs.readFileSync(path.join(root, 'common/AppTheme.ets'), 'utf8').replace(/\r\n/g, '\n');
  const settings = theme.slice(theme.indexOf('export class DanmakuSettings'), theme.indexOf('\nexport class AppTheme'));
  const sourceBegin = source.indexOf('  async onSourceVersionChanged(): Promise<void> {');
  const sourceEnd = source.indexOf('  onExternalDanmakuChanged(): void {', sourceBegin);
  assert.ok(sourceBegin >= 0 && sourceEnd > sourceBegin);
  const compiled = ts.transpileModule(settings + '\nexport class View {\n' + source.slice(begin, end) +
    source.slice(sourceBegin, sourceEnd) + '\n}', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const mod = { exports: {} }; new Function('exports', compiled)(mod.exports);
  const view = new mod.exports.View();
  Object.assign(view, { dmEngine: engine, dmClock: { stop() {}, frameRateChanged() {} },
    persistDanmaku() {}, loadDanmaku() { this.reloads++; }, reloads: 0 });
  return view;
}

test('an unordered initial segment displays early comments instead of waiting behind its first future item', () => {
  const f = fixture(); const raw = [item(4, 50), item(2, 2), item(1, 1), item(3, 3)];
  f.engine.setList(raw); f.playUntil(4);
  assert.deepEqual([...f.drawn].sort(), ['comment-1', 'comment-2', 'comment-3']);
  assert.deepEqual(raw.map(value => value.id), [4, 2, 1, 3], 'server-owned input must remain untouched');
});

test('real anonymous segment timing preserves its comments at the actual default density', () => {
  const f = fixture();
  const rows = realSegment.rows || realSegment.items || realSegment.samples;
  assert.ok(Array.isArray(rows) && rows.length > 100, 'fixture must contain actual unordered timing');
  const duration = realSegment.metadata.pageDurationSeconds;
  const comments = rows.map((row, index) => item(index + 1, row[0], 'sample-' + index, row[1], row[2]));
  f.engine.setList(comments); assert.equal(f.engine.density, 22); f.playUntil(duration);
  const inVideo = comments.filter(comment => comment.time <= duration).length;
  assert.ok(f.drawn.size >= Math.floor(inVideo * 0.85),
    `default engine only displayed ${f.drawn.size} of ${inVideo} eligible fixture comments`);
});

test('turning duplicate hiding off restores comments from already-loaded segments without another fetch', () => {
  const f = fixture(); const view = viewHarness(f.engine);
  f.engine.mergeDuplicates = true;
  f.engine.setList([item(1, 2, 'same'), item(2, 3, 'same'), item(3, 4, 'same')]);
  assert.equal(f.engine.list.length, 1); view.setDmMerge(false);
  assert.equal(f.engine.list.length, 3); assert.equal(f.engine.list[0].mergeCount, 1);
  assert.equal(view.reloads, 0);
});

test('resetting danmaku settings restores duplicates and synchronizes the engine merge switch', () => {
  const f = fixture(); const view = viewHarness(f.engine);
  f.engine.mergeDuplicates = true; view.dmMerge = true;
  f.engine.setList([item(1, 2, 'same'), item(2, 3, 'same'), item(3, 4, 'same')]);
  view.resetDanmakuSettings();
  assert.equal(view.dmMerge, false); assert.equal(f.engine.mergeDuplicates, false);
  assert.equal(f.engine.list.length, 3);
});

test('duplicate hiding also clusters comments appended by later segments', () => {
  const f = fixture(); f.engine.mergeDuplicates = true;
  f.engine.setList([item(1, 359, 'same')]);
  f.engine.appendSorted([item(3, 362, 'other'), item(2, 361, 'same')]);
  assert.deepEqual(f.engine.list.map(value => value.text), ['same', 'other']);
  assert.equal(f.engine.list[0].mergeCount, 2);
});

test('changing duplicate hiding does not replay an already-consumed comment while restoring an unseen near-time duplicate', () => {
  const f = fixture(); f.engine.density = 30; f.engine.mergeDuplicates = true;
  f.engine.setList([item(1, 2, 'same'), item(2, 2.04, 'same'), item(3, 2.07, 'different')]);
  f.engine.lastPlayerTime = 2.08; f.engine.spawn(2.08);
  assert.deepEqual(f.engine.active.map(value => value.item.id), [1, 3]);
  viewHarness(f.engine).setDmMerge(false);
  f.engine.lastPlayerTime = 2.2; f.engine.spawn(2.2);
  assert.deepEqual(f.engine.active.map(value => value.item.id), [1, 3, 2]);
  f.engine.resetAt(2); f.engine.spawn(2);
  assert.deepEqual(f.engine.active.map(value => value.item.id), [1, 2, 3], 'explicit replay/seek still permits comments to replay');
});

test('preloading a future segment cannot consume an existing due comment waiting for a render update', () => {
  const f = fixture(); f.engine.setList([item(1, 10), item(2, 10.08)]);
  f.engine.lastPlayerTime = 10;
  f.engine.appendSorted([item(3, 360)]); f.engine.spawn(10);
  assert.deepEqual(f.engine.active.map(value => value.item.id), [1, 2]);
});

test('switching the video clears the unmerged cache before a duplicate-setting change can revive old comments', async () => {
  const f = fixture(); const view = viewHarness(f.engine);
  f.engine.mergeDuplicates = true; f.engine.setList([item(1, 2, 'old'), item(2, 3, 'old')]);
  Object.assign(view, {
    destroyed: false, playbackSourceGeneration: 0, exportMenuGeneration: 0,
    aid: 2, bvid: 'BV-new', cid: 20,
    mediaExport: { invalidate() {}, syncDownload() {} }, auxiliary: { invalidate() {}, bind() {} },
    interactionCtl: { invalidate() {} }, bindInteractions() {},
    onOnlineCount() {}, releaseSeekPreview() {}, subtitleCtl: null,
    sponsorCtl: { invalidateForSourceChange() {} }, seekTargetCtl: { show() {} },
    playback: { async replaceSource() {} }, playbackSource: () => ({}), armDeferredLoads() {}
  });
  await view.onSourceVersionChanged(); view.setDmMerge(false);
  assert.deepEqual(f.engine.list, []);
});
