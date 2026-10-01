// Production favorite picker with controlled folder loads and submissions.
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

function fixture() {
  const loads = [], saves = [], states = [], notices = [], favorites = [];
  const page = {destroyed: false, actionBusy: false, aid: 12, loggedIn: true};
  const modules = new Map();
  const mocks = {
    'api/FavoriteApi': {FavoriteApi: {
      getFavoriteFoldersForVideo(aid, mid) {
        const pending = deferred(); loads.push({aid, mid, ...pending}); return pending.promise;
      },
      modifyVideoFavorite(aid, keep, drop) {
        const pending = deferred(); saves.push({aid, keep, drop, ...pending}); return pending.promise;
      }
    }},
    'services/auth/UserStore': {UserStore: {current: {mid: 7}}}
  };
  function load(name) {
    if (mocks[name]) return mocks[name];
    if (modules.has(name)) return modules.get(name);
    const source = fs.readFileSync(path.join(root, name + '.ets'), 'utf8');
    const code = ts.transpileModule(source, {
      compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
    }).outputText;
    const mod = {exports: {}};
    new Function('require', 'module', 'exports', code)(dependency => {
      assert.ok(dependency.startsWith('.'), 'unexpected platform boundary: ' + dependency);
      return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), dependency)));
    }, mod, mod.exports);
    modules.set(name, mod.exports);
    return mod.exports;
  }
  const {VideoFavoritePicker} = load('components/video/VideoFavoritePicker');
  const picker = new VideoFavoritePicker({
    isDestroyed: () => page.destroyed,
    ensureLogin: () => page.loggedIn,
    getAid: () => page.aid,
    isActionBusy: () => page.actionBusy,
    setActionBusy: value => {page.actionBusy = value;},
    setFavorited: value => favorites.push(value),
    toast: value => notices.push(value),
    publish: value => states.push(value)
  });
  return {picker, page, loads, saves, states, notices, favorites, state: () => states.at(-1)};
}

async function opened(f, folders = [{id: 1, favorited: false}, {id: 2, favorited: true}]) {
  const opening = f.picker.open();
  f.loads.at(-1).resolve(folders);
  await opening;
}

test('favorite picker cannot save or edit an unfinished folder load', async () => {
  const f = fixture(), opening = f.picker.open();
  f.picker.toggle(1);
  await f.picker.save();
  assert.deepEqual(f.saves, []);
  assert.equal(f.page.actionBusy, false);
  assert.deepEqual(f.state().checked, []);
  f.loads[0].resolve([{id: 1, favorited: true}]); await opening;
  assert.deepEqual(f.state().checked, [1]);
});

test('favorite picker freezes submitted selection and blocks duplicate saves until success', async () => {
  const f = fixture(); await opened(f);
  f.picker.toggle(2); // Submit removal of the final favorite folder.
  const saving = f.picker.save();
  assert.equal(f.state().saving, true);
  assert.equal(f.page.actionBusy, true);
  assert.deepEqual(f.saves.map(({aid, keep, drop}) => ({aid, keep, drop})), [{aid: 12, keep: [], drop: [2]}]);
  f.picker.toggle(1); f.picker.setOpen(false);
  await f.picker.save(); await f.picker.open();
  assert.deepEqual(f.state().checked, []);
  assert.equal(f.state().open, true);
  assert.equal(f.saves.length, 1); assert.equal(f.loads.length, 1);
  f.saves[0].resolve({ok: true}); await saving;
  assert.deepEqual(f.favorites, [false], 'publish the submitted target rather than any later UI selection');
  assert.equal(f.state().open, false); assert.equal(f.state().saving, false);
  assert.equal(f.page.actionBusy, false);
});

test('successful favorite save reflects the submitted set when a user taps during the request', async () => {
  const f = fixture(); await opened(f, [{id: 1, favorited: true}]);
  f.picker.toggle(1);
  const saving = f.picker.save();
  assert.deepEqual(f.saves[0].drop, [1]);
  f.picker.toggle(1);
  f.saves[0].resolve({ok: true}); await saving;
  assert.deepEqual(f.favorites, [false], 'the server removed the last folder, so the page must show unfavorited');
});

for (const rejects of [false, true]) {
  test(`favorite picker failed save preserves selection and releases controls for retry (reject=${rejects})`, async () => {
    const f = fixture(); await opened(f);
    f.picker.toggle(1); f.picker.toggle(2);
    const saving = f.picker.save();
    if (rejects) f.saves[0].reject(new Error('offline'));
    else f.saves[0].resolve({ok: false, message: 'denied'});
    await saving;
    assert.equal(f.state().open, true); assert.equal(f.state().saving, false);
    assert.equal(f.page.actionBusy, false); assert.deepEqual(f.state().checked, [1]);
    assert.deepEqual(f.favorites, []); assert.equal(f.notices.length, 1);
    const retry = f.picker.save();
    assert.deepEqual(f.saves[1].keep, [1]); assert.deepEqual(f.saves[1].drop, [2]);
    f.saves[1].resolve({ok: true}); await retry;
    assert.deepEqual(f.favorites, [true]);
  });
}

test('closing a loading picker invalidates its response before a new opening', async () => {
  const f = fixture(), old = f.picker.open();
  f.picker.setOpen(false);
  const current = f.picker.open();
  f.loads[0].reject(new Error('old load')); await old;
  assert.equal(f.state().open, true); assert.equal(f.state().loading, true);
  assert.deepEqual(f.notices, []);
  f.loads[1].resolve([{id: 3, favorited: true}]); await current;
  assert.deepEqual(f.state().checked, [3]); assert.equal(f.state().loading, false);
});

for (const pending of ['load', 'save']) {
  test(`leaving and reusing the page clears the picker and ignores an old ${pending} completion`, async () => {
    const f = fixture();
    let old;
    if (pending === 'load') old = f.picker.open();
    else {await opened(f); f.picker.toggle(1); old = f.picker.save();}
    f.page.destroyed = true; f.picker.dispose();
    f.page.destroyed = false; f.page.actionBusy = false; f.picker.reset();
    const current = f.picker.open();
    if (pending === 'load') f.loads[0].resolve([{id: 9, favorited: true}]);
    else f.saves[0].resolve({ok: true});
    await old;
    assert.equal(f.state().open, true); assert.equal(f.state().loading, true);
    assert.deepEqual(f.state().checked, []);
    assert.deepEqual(f.favorites, []); assert.deepEqual(f.notices, []);
    f.loads.at(-1).resolve([{id: 3, favorited: false}]); await current;
    assert.equal(f.state().loading, false);
  });
}

test('closed, empty and logged-out pickers cannot submit favorites', async () => {
  const f = fixture(); await f.picker.save();
  await opened(f, []); await f.picker.save();
  assert.deepEqual(f.saves, []);
  await opened(f); f.page.loggedIn = false; await f.picker.save();
  assert.deepEqual(f.saves, []); assert.equal(f.page.actionBusy, false);
});
