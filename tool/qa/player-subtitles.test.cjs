const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
}
const tick = () => new Promise(resolve => setImmediate(resolve));
const cue = content => ({from: 3, to: 10, content});

function fixture(onStateChange = () => {}) {
  const requests = [], states = [];
  const source = fs.readFileSync(path.join(root, 'components/player/PlayerSubtitleController.ets'), 'utf8');
  const code = ts.transpileModule(source, {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
  }).outputText;
  const mod = {exports: {}};
  new Function('require', 'module', 'exports', code)(name => {
    assert.equal(name, '../../api/BiliApi');
    return {BiliApi: {getSubtitleCues(url) {
      const pending = deferred(); requests.push({url, ...pending}); return pending.promise;
    }}};
  }, mod, mod.exports);
  const ctl = new mod.exports.PlayerSubtitleController(() => {
    states.push({loading: ctl.loading, index: ctl.index, enabled: ctl.enabled, text: ctl.text});
    onStateChange();
  });
  const tracks = [{url: 'zh', lan: 'zh', lanDoc: '中文'}, {url: 'en', lan: 'en', lanDoc: 'English'}];
  return {ctl, tracks, requests, states};
}

function viewFixture() {
  let view;
  const f = fixture(() => view.syncSubtitleState());
  const source = fs.readFileSync(path.join(root, 'components/player/PlayerView.ets'), 'utf8')
    .replace(/\r\n/g, '\n');
  const start = source.indexOf('  onSubtitlesChanged(): void {');
  const end = source.indexOf('  private toast(message:', start);
  assert.ok(start >= 0 && end > start, 'production subtitle callback methods must be present');
  const mod = {exports: {}};
  const code = ts.transpileModule('export class Harness {\n' + source.slice(start, end) + '\n}', {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
  }).outputText;
  new Function('module', 'exports', code)(mod, mod.exports);
  view = new mod.exports.Harness();
  Object.assign(view, {subtitleCtl: f.ctl, subtitles: f.tracks, playheadSec: 5,
    closeSettingPanels() {}});
  return {...f, view};
}

for (const action of ['toggleSubtitle', 'changeSubtitle']) {
  test(`player ${action} can enable CC during the initial preload without a duplicate fetch`, async () => {
    const f = viewFixture();
    f.view.onSubtitlesChanged();
    assert.equal(f.view.subtitleOn, false);
    assert.equal(f.view.subtitleLoading, true);
    f.view[action](action === 'toggleSubtitle' ? true : 0);
    assert.equal(f.ctl.enabled, true, 'turning on the track must not be ignored while its cues load');
    assert.equal(f.view.subtitleOn, true);
    assert.equal(f.view.subtitleLoading, true);
    f.view[action](action === 'toggleSubtitle' ? true : 0);
    assert.equal(f.requests.length, 1, 'use the pending preload rather than issue another request');
    f.view.updateSubtitle(6);
    assert.equal(f.view.subtitleText, '');
    f.requests[0].resolve([cue('中文')]); await tick();
    assert.equal(f.view.subtitleText, '中文');
    assert.equal(f.view.subtitleLoading, false);
    assert.equal(f.view.subtitleOn, true);
  });
}

test('subtitle completion publishes the settled loading state to the player', async () => {
  const f = fixture(); f.ctl.setTracks(f.tracks, 5);
  assert.equal(f.states.at(-1).loading, true);
  f.requests[0].resolve([cue('中文')]); await tick();
  assert.equal(f.ctl.loading, false);
  assert.equal(f.states.at(-1).loading, false);
});

test('enabling captions while paused displays the cue at the retained playhead', async () => {
  const f = fixture(); f.ctl.setTracks(f.tracks, 5);
  f.requests[0].resolve([cue('中文')]); await tick();
  f.ctl.changeSubtitle(0);
  f.requests[1].resolve([cue('中文')]); await tick();
  assert.equal(f.ctl.text, '中文', 'a paused player cannot wait for another timeUpdate');
  assert.equal(f.states.at(-1).text, '中文');
});

test('switching languages clears previous cues and refreshes at the latest playhead', async () => {
  const f = fixture(); f.ctl.setTracks(f.tracks, 5);
  f.requests[0].resolve([cue('中文')]); await tick();
  f.ctl.changeSubtitle(0); f.requests[1].resolve([cue('中文')]); await tick();
  f.ctl.update(5); assert.equal(f.ctl.text, '中文');
  f.ctl.changeSubtitle(1); f.ctl.update(6);
  assert.equal(f.ctl.text, '', 'old-language cues cannot reappear during the new request');
  f.ctl.update(9);
  f.requests[2].resolve([{from: 3, to: 8, content: 'earlier'}, {from: 8, to: 10, content: 'latest'}]);
  await tick();
  assert.equal(f.ctl.text, 'latest');
  assert.equal(f.states.at(-1).loading, false);
});

for (const clear of ['disable', 'removeTracks']) {
  test(`subtitle ${clear} cancels an in-flight load and publishes an idle state`, async () => {
    const f = fixture(); f.ctl.setTracks(f.tracks, 5);
    if (clear === 'disable') f.ctl.changeSubtitle(-1);
    else f.ctl.setTracks([], 5);
    const settled = {loading: false, index: -1, enabled: false, text: ''};
    assert.deepEqual(f.states.at(-1), settled);
    f.requests[0].resolve([cue('stale')]); await tick();
    f.ctl.update(5);
    assert.deepEqual(f.states.at(-1), settled);
    assert.equal(f.ctl.text, '');
  });
}

test('an older subtitle request cannot clear or overwrite a newer pending language', async () => {
  const f = fixture(); f.ctl.setTracks(f.tracks, 5);
  f.ctl.changeSubtitle(1);
  f.requests[0].reject(new Error('old request')); await tick();
  assert.equal(f.ctl.loading, true); assert.equal(f.ctl.index, 1);
  f.requests[1].resolve([cue('English')]); await tick();
  assert.equal(f.ctl.text, 'English'); assert.equal(f.ctl.loading, false);
  assert.equal(f.states.at(-1).loading, false);
});
