const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const ROOT = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() {let resolve, reject; const promise = new Promise((yes, no) => {resolve = yes; reject = no;}); return {promise, resolve, reject};}
function fixture() {
  const source = fs.readFileSync(path.join(ROOT, 'pages/YouTubeSaved.ets'), 'utf8').replace(/\r\n/g, '\n');
  const a = source.indexOf('  private isHistory():'), b = source.indexOf('  private toast(', a);
  assert.ok(a >= 0 && b > a, 'production list/thumbnail method anchors');
  const code = ts.transpileModule('class Harness {\n' + source.slice(a, b) + '\n}; return Harness;', {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  const later = deferred(), history = deferred(), thumbs = new Map(), calls = [], hits = new Map();
  let loads = [];
  const Harness = new Function('YouTubeHistoryStore', 'YouTubeWatchLaterStore', 'RemoteAssetCache', code)(
    {ensureLoaded: () => {loads.push('history'); return history.promise;}},
    {ensureLoaded: () => {loads.push('later'); return later.promise;}},
    {cachedThumbnail: url => hits.get(url) || url, ensureThumbnail: url => {calls.push(url); if (!thumbs.has(url)) thumbs.set(url, deferred()); return thumbs.get(url).promise;}});
  function page(mode = 'later') {
    const value = new Harness(); Object.assign(value, {mode, destroyed: false, loadGeneration: 0, items: [], loading: true, thumbLocal: new Map()}); return value;
  }
  // ArkUI dispatches an exit lifecycle callback only if the component defines one.
  function leave(page) {page.aboutToDisappear?.();}
  return {page, leave, later, history, thumbs, calls, hits, loads};
}
const rows = [{id: 'one', thumbnail: 'https://img/one'}];
for (const mode of ['later', 'history']) test(`saved ${mode}: normal restore loads list and thumbnail`, async () => {
  const f = fixture(), page = f.page(mode); page.aboutToAppear(); f[mode].resolve(rows); await tick();
  assert.deepEqual(page.items, rows); assert.equal(page.loading, false); assert.deepEqual(f.loads, [mode]); assert.deepEqual(f.calls, [rows[0].thumbnail]);
  f.thumbs.get(rows[0].thumbnail).resolve('file://one'); await tick(); assert.equal(page.localImage(rows[0].thumbnail), 'file://one');
});
test('saved: leaving during restore does not launch thumbnails or write exited state', async () => {
  const f = fixture(), page = f.page(); page.aboutToAppear(); f.leave(page); f.later.resolve(rows); await tick();
  assert.deepEqual(f.calls, []); assert.deepEqual(page.items, []); assert.equal(page.loading, true);
});
test('saved: restore rejection after exit does not finish the exited loading state', async () => {
  const f = fixture(), page = f.page(); page.aboutToAppear(); f.leave(page); f.later.reject(new Error('disk')); await tick(); assert.equal(page.loading, true);
});
test('saved: thumbnail completion after exit leaves the page map unchanged', async () => {
  const f = fixture(), page = f.page(); page.aboutToAppear(); f.later.resolve(rows); await tick(); f.leave(page);
  f.thumbs.get(rows[0].thumbnail).resolve('file://late'); await tick(); assert.equal(page.thumbLocal.size, 0);
});
test('saved: separate page re-entry still consumes the shared restore legitimately', async () => {
  const f = fixture(), old = f.page(); old.aboutToAppear(); f.leave(old); const current = f.page(); current.aboutToAppear();
  f.later.resolve(rows); await tick(); assert.deepEqual(old.items, []); assert.deepEqual(current.items, rows); assert.deepEqual(f.calls, [rows[0].thumbnail]);
  f.thumbs.get(rows[0].thumbnail).resolve('file://shared'); await tick(); assert.equal(old.thumbLocal.size, 0); assert.equal(current.thumbLocal.get(rows[0].thumbnail), 'file://shared');
});
test('saved: switching between independent history and later pages keeps their results separate', async () => {
  const f = fixture(), old = f.page('later'), current = f.page('history'); old.aboutToAppear(); f.leave(old); current.aboutToAppear();
  const historyRows = [{id: 'two', thumbnail: ''}]; f.history.resolve(historyRows); await tick(); f.later.resolve(rows); await tick();
  assert.deepEqual(current.items, historyRows); assert.deepEqual(old.items, []); assert.deepEqual(f.calls, []);
});
test('saved: failed restore ends current loading and a fresh page can retry', async () => {
  const f = fixture(), page = f.page(); page.aboutToAppear(); f.later.reject(new Error('disk')); await tick(); assert.equal(page.loading, false); assert.deepEqual(page.items, []);
  const retry = fixture(), current = retry.page(); current.aboutToAppear(); retry.later.resolve(rows); await tick(); assert.deepEqual(current.items, rows); assert.equal(current.loading, false);
});
test('saved: cached thumbnails avoid requests and failed thumbnails preserve remote fallback', async () => {
  const f = fixture(), page = f.page(); f.hits.set(rows[0].thumbnail, 'file://cached'); page.aboutToAppear(); f.later.resolve(rows); await tick(); assert.deepEqual(f.calls, []); assert.equal(page.localImage(rows[0].thumbnail), 'file://cached');
  const second = fixture(), other = second.page(); other.aboutToAppear(); second.later.resolve(rows); await tick(); second.thumbs.get(rows[0].thumbnail).reject(new Error('network')); await tick(); assert.equal(other.localImage(rows[0].thumbnail), rows[0].thumbnail); assert.equal(other.loading, false);
});
