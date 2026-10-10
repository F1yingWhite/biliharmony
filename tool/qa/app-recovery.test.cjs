const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const fixture = () => createArktsLoader()('common/AppRecoveryState').AppRecoveryState;
const snapshot = (views = [], rootTab = 1) => JSON.stringify({version: 1, rootTab, views});
const entry = (key, state) => ({key, state});

function methods(file, start, end, bindings = {}) {
  const source = fs.readFileSync(path.join(root, file + '.ets'), 'utf8').replace(/\r\n/g, '\n');
  const first = source.indexOf(start), last = source.indexOf(end, first);
  assert.ok(first >= 0 && last > first, 'real lifecycle method boundaries: ' + file);
  const code = ts.transpileModule('class Harness {\n' + source.slice(first, last) + '\n}; return Harness;', {
    compilerOptions: {target: ts.ScriptTarget.ES2020},
  }).outputText;
  return new Function(...Object.keys(bindings), code)(...Object.values(bindings));
}

test('recovery: fresh view saves do not become pending restores and consumed state cannot be replayed', () => {
  const state = fixture(); state.saveRootTab(2); state.saveView('search', {keyword: 'test', scrollY: 40});
  assert.equal(state.takeRootTab(), undefined); assert.equal(state.takeView('search'), undefined);
  state.restore(state.serialize()); assert.equal(state.takeRootTab(), 2); assert.equal(state.takeRootTab(), undefined);
  assert.deepEqual(state.takeView('search'), {keyword: 'test', scrollY: 40}); assert.equal(state.takeView('search'), undefined);
  state.saveView('search', {keyword: 'new'}); assert.equal(state.takeView('search'), undefined);
});

test('recovery: snapshots and consumed views are defensive copies of caller data', () => {
  const state = fixture(), input = {keyword: 'old', scrollY: 90}; state.saveView('search', input); input.keyword = 'changed';
  assert.equal(JSON.parse(state.serialize()).views[0].state.keyword, 'old');
  state.restore(state.serialize()); const restored = state.takeView('search'); restored.keyword = 'mutated';
  assert.equal(JSON.parse(state.serialize()).views[0].state.keyword, 'old');
});

for (const value of [undefined, null, false, 123, {}, '', '{', 'null', '[]', '"text"',
  '{"version":2,"views":[]}', '{"version":1,"views":{}}', 'x'.repeat(16385)]) {
  test('recovery: malformed or unsupported payload clears old pending state: ' + String(value).slice(0, 28), () => {
    const state = fixture(); state.restore(snapshot([entry('old', {scrollY: 10})], 2)); state.restore(value);
    assert.equal(state.takeRootTab(), undefined); assert.equal(state.takeView('old'), undefined);
    assert.deepEqual(JSON.parse(state.serialize()), {version: 1, rootTab: 0, views: []});
  });
}

test('recovery: malformed individual entries cannot discard valid siblings or admit oversized keys', () => {
  const state = fixture(); state.restore(snapshot([null, 5, 'bad', {}, entry('', {}), entry('x'.repeat(257), {}),
    entry('null', null), entry('number', 3), entry('valid', {keyword: 'ok'}), entry('other', {tab: 2})]));
  assert.deepEqual(state.takeView('valid'), {keyword: 'ok'}); assert.deepEqual(state.takeView('other'), {tab: 2});
  assert.deepEqual(JSON.parse(state.serialize()).views.map(value => value.key), ['valid', 'other']);
});

test('recovery: all numeric fields reject NaN, infinities, negatives, fractions and unsafe video IDs', () => {
  const state = fixture();
  for (const [index, value] of [NaN, Infinity, -Infinity, -1, '3', null, true].entries()) {
    state.saveView('bad' + index, {tab: value, searchTab: value, scrollX: value, scrollY: value, cid: value, position: value});
    assert.deepEqual(JSON.parse(state.serialize()).views.at(-1).state, {});
  }
  state.saveView('fraction', {tab: 1.5, searchTab: 1.5, cid: 1.5, scrollX: .5, scrollY: .5, position: .5});
  assert.deepEqual(JSON.parse(state.serialize()).views.at(-1).state, {scrollX: .5, scrollY: .5, position: .5});
  state.saveView('large', {tab: 21, searchTab: 21, cid: Number.MAX_SAFE_INTEGER + 1});
  assert.deepEqual(JSON.parse(state.serialize()).views.at(-1).state, {});
  state.restore('{"version":1,"rootTab":1,"views":[{"key":"overflow","state":{"position":1e309,"scrollY":1e309}}]}');
  assert.deepEqual(state.takeView('overflow'), {});
});

test('recovery: valid video state and bounded scroll survive a serialize/restore round trip', () => {
  const state = fixture(); state.saveView('video:123', {cid: 9007199254740991, position: 60.5, playing: false,
    tab: 20, searchTab: 20, scrollX: Number.MAX_VALUE, scrollY: Number.MAX_VALUE,
    keyword: 'k'.repeat(600), submitted: true, token: 'must never be persisted', account: {mid: 7}});
  state.restore(state.serialize()); const restored = state.takeView('video:123');
  assert.deepEqual(restored, {cid: 9007199254740991, position: 60.5, playing: false,
    tab: 20, searchTab: 20, scrollX: 10000000, scrollY: 10000000, keyword: 'k'.repeat(512), submitted: true});
  assert.equal(JSON.parse(state.serialize()).views[0].state.token, undefined);
});

test('recovery: root tab validation is independent of child state and only tabs 0 through 2 are accepted', () => {
  const state = fixture(); state.saveRootTab(2);
  for (const invalid of [-1, 3, .5, NaN, Infinity, '1']) state.saveRootTab(invalid);
  assert.equal(JSON.parse(state.serialize()).rootTab, 2);
  state.restore(snapshot([entry('child', {tab: 2})], 3));
  assert.equal(state.takeRootTab(), undefined); assert.deepEqual(state.takeView('child'), {tab: 2});
  state.restore(snapshot([], 0)); assert.equal(state.takeRootTab(), 0);
});

test('recovery: view count and serialized payload are bounded while retaining newest views', () => {
  const state = fixture();
  for (let index = 0; index < 41; index++) state.saveView('page:' + index, {tab: index % 3});
  let encoded = state.serialize(), saved = JSON.parse(encoded);
  assert.equal(saved.views.length, 40); assert.equal(saved.views[0].key, 'page:1'); assert.equal(saved.views.at(-1).key, 'page:40');
  for (let index = 0; index < 40; index++) state.saveView('large:' + index + 'x'.repeat(230), {keyword: 'k'.repeat(512)});
  encoded = state.serialize(); saved = JSON.parse(encoded);
  assert.ok(encoded.length <= 16384); assert.ok(saved.views.length < 40); assert.ok(saved.views.at(-1).key.startsWith('large:39'));
  state.restore(encoded); assert.ok(state.takeView(saved.views.at(-1).key));
});

test('recovery: incoming oversized view arrays process at most forty records', () => {
  const state = fixture(); state.restore(snapshot(Array.from({length: 100}, (_, index) => entry('page:' + index, {tab: 1}))));
  assert.equal(JSON.parse(state.serialize()).views.length, 40); assert.equal(state.takeView('page:40'), undefined);
  assert.deepEqual(state.takeView('page:39'), {tab: 1});
});

test('recovery: two route keys consume independently, and a late save cannot recreate consumed pending state', async () => {
  const state = fixture(); state.restore(snapshot([entry('search:first', {keyword: 'first'}), entry('search:second', {keyword: 'second'})]));
  assert.deepEqual(state.takeView('search:first'), {keyword: 'first'}); await tick();
  state.saveView('search:first', {keyword: 'late'}); assert.equal(state.takeView('search:first'), undefined);
  assert.deepEqual(state.takeView('search:second'), {keyword: 'second'});
  state.restore(undefined); assert.equal(state.takeView('search:second'), undefined);
});

test('recovery: real EntryAbility onSaveState preserves system parameters and saves the bounded snapshot only for recovery', () => {
  const state = fixture(); state.saveRootTab(2); state.saveView('home', {tab: 1});
  const AbilityConstant = {StateType: {APP_RECOVERY: 1}, OnSaveResult: {ALL_AGREE: 0}};
  const Harness = methods('entryability/EntryAbility', '  onSaveState(', '  /** 服务卡片', {AppRecoveryState: state, AbilityConstant});
  const ability = new Harness(), normal = {system: 'keep'};
  assert.equal(ability.onSaveState(0, normal), 0); assert.deepEqual(normal, {system: 'keep'});
  const recovery = {system: 'keep'}; assert.equal(ability.onSaveState(1, recovery), 0); assert.equal(recovery.system, 'keep');
  assert.equal(JSON.parse(recovery[state.WANT_KEY]).rootTab, 2);
});

test('recovery: real Index appearance consumes the root tab once and preserves later navigation', () => {
  const state = fixture(); state.restore(snapshot([], 2));
  const Harness = methods('pages/Index', '  aboutToAppear(): void', '  onAppBackgroundChanged()', {
    AppRecoveryState: state, UserStore: {ensureLoaded() {}}, PlatformStore: {init() {}},
    Handedness: {init() {}, setActive() {}}, Index: {displayWidthVp: () => 440},
  });
  const page = new Harness(); Object.assign(page, {currentTab: 0, appInBackground: false,
    onMotionPreferenceChanged() {}, reapplyBarColors() {}});
  page.aboutToAppear(); assert.equal(page.currentTab, 2); page.currentTab = 1; page.aboutToAppear();
  assert.equal(page.currentTab, 1); assert.equal(JSON.parse(state.serialize()).rootTab, 1);
});

test('recovery: real Home account change discards consumed account-dependent feed offsets before asynchronous reload', async () => {
  const state = fixture(); state.restore(snapshot([entry('home:0', {scrollY: 1234})]));
  const waiting = deferred(), calls = [];
  const Harness = methods('views/HomeView', '  async onLoginChanged(): Promise<void>', '  private async onRecommendModeChanged():');
  const home = new Harness(); Object.assign(home, {tab: 0, recoveryOffsets: [state.takeView('home:0'), undefined, undefined],
    feed: {accountChanged: tab => {calls.push(tab); return waiting.promise;}}});
  const changing = home.onLoginChanged(); assert.deepEqual(home.recoveryOffsets, [undefined, undefined, undefined]);
  assert.deepEqual(calls, [0]); waiting.resolve(); await changing;
  assert.deepEqual(home.recoveryOffsets, [undefined, undefined, undefined]); assert.equal(state.takeView('home:0'), undefined);
});
