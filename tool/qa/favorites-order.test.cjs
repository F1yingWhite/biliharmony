// Complete favorite domain controllers; only network, account storage and platform boundaries are mocked.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');
function folder(id = 42, extra = {}) {
  return { id, title: 'Folder ' + id, cover: '', count: 3, type: 2, upperName: '', upperMid: 7,
    intro: 'description', viewCount: 0, isPublic: false, favorited: false, ...extra };
}
function video(aid) { return { aid, bvid: 'BV' + aid, title: 'Video ' + aid }; }
function fixture(api = {}) {
  const calls = [], notices = [], user = { current: { mid: 7 }, ensureLoaded: async () => {} };
  const defaults = {
    getFavoriteFolders: async () => ({ folders: [folder(42), folder(84)], hasMore: false }),
    getCollectedFolders: async () => ({ folders: [], hasMore: false }),
    getFavoriteVideos: async () => ({ videos: [video(1), video(2), video(3)], hasMore: false }),
    getCollectionVideos: async () => ({ videos: [video(4)], hasMore: false }),
    getAllFavoriteFolders: async () => [folder(42), folder(84)],
    sortFavoriteVideos: async () => ({ ok: true }), delFavoriteResources: async () => ({ ok: true }),
    moveFavoriteResources: async () => ({ ok: true }), addFavoriteFolder: async () => ({ ok: true }),
    editFavoriteFolder: async () => ({ ok: true }), delFavoriteFolder: async () => ({ ok: true })
  };
  const boundary = {};
  for (const [name, fallback] of Object.entries(defaults)) boundary[name] = async (...args) => {
    calls.push({ name, args }); return (api[name] || fallback)(...args);
  };
  const load = createArktsLoader({ mocks: {
    'api/FavoriteApi': { FavoriteApi: boundary }, 'services/auth/UserStore': { UserStore: user },
    '@kit.ArkTS': { collections: { Array }, util: {}, taskpool: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { debug() {}, info() {}, warn() {}, error() {} } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} }
  } });
  const library = new (load('components/favorites/FavoriteLibraryController').FavoriteLibraryController)();
  library.onToast = message => notices.push(message);
  return { library, editor: library.editor, calls, notices, user, api,
    auth: load('services/auth/AuthSession').AuthSession,
    callsOf: name => calls.filter(call => call.name === name).map(call => call.args),
    async open() { await library.activate(); await library.openFolder(folder()); } };
}
const edit = f => f.editor.toggleEdit();
const aids = f => f.library.videos.source.getAll().map(item => item.aid);

for (const exit of ['back', 'toggleEdit']) {
  test(`favorites ${exit} saves visible order once before leaving edit mode`, async () => {
    const pending = deferred(), f = fixture({ sortFavoriteVideos: () => pending.promise }); await f.open();
    await edit(f); f.editor.moveVideo(2, -1); f.editor.toggleChecked(3, 1);
    if (exit === 'back') f.library.back(); else edit(f);
    assert.deepEqual(f.callsOf('sortFavoriteVideos'), [[42, [1, 3, 2]]]); assert.equal(f.editor.view.editing, true);
    f.library.back(); edit(f); f.editor.moveVideo(0, 1);
    assert.equal(f.callsOf('sortFavoriteVideos').length, 1); assert.deepEqual(aids(f), [1, 3, 2]);
    pending.resolve({ ok: true }); await tick();
    assert.equal(f.editor.view.editing, false); assert.equal(f.editor.view.orderDirty, false); assert.equal(f.editor.view.busy, false);
    assert.deepEqual(f.editor.view.checkedAids, []); assert.equal(f.library.view.selected.id, 42);
  });
}
for (const rejected of [false, true]) {
  test(`favorites failed order save preserves edits and supports retry (reject=${rejected})`, async () => {
    let failed = true;
    const f = fixture({ sortFavoriteVideos: async () => {
      if (failed && rejected) throw Error('offline'); return { ok: !failed, message: 'save failed' };
    } }); await f.open(); await edit(f); f.editor.moveVideo(1, -1); f.editor.toggleChecked(2, 0); f.library.back(); await tick();
    assert.equal(f.editor.view.editing, true); assert.equal(f.editor.view.orderDirty, true); assert.equal(f.editor.view.busy, false);
    assert.deepEqual(f.editor.view.checkedAids, [2]); assert.ok(f.notices.length > 0);
    failed = false; f.library.back(); await tick();
    assert.equal(f.editor.view.editing, false); assert.equal(f.editor.view.orderDirty, false);
    assert.deepEqual(f.callsOf('sortFavoriteVideos'), [[42, [2, 1, 3]], [42, [2, 1, 3]]]);
  });
}
test('favorites unmodified edits exit locally without a server write', async () => {
  const f = fixture(); await f.open(); await edit(f); f.library.back();
  assert.equal(f.editor.view.editing, false); assert.equal(f.library.view.selected.id, 42); assert.deepEqual(f.callsOf('sortFavoriteVideos'), []);
});
test('returning from a folder preserves an exhausted root folder list', async () => {
  const f = fixture({ getFavoriteVideos: async () => ({ videos: [video(1)], hasMore: true }) }); await f.open();
  assert.equal(f.library.view.current.hasMore, true); f.library.back(); assert.equal(f.library.view.current.hasMore, false);
  await f.library.loadMore(); assert.deepEqual(f.callsOf('getFavoriteFolders').map(args => args[1]), [1]);
  assert.equal(f.library.folders.source.totalCount(), 2);
});
test('late root folder response cannot change the open video pagination', async () => {
  for (const [folderMore, videoMore] of [[false, true], [true, false]]) {
    const pending = deferred(), f = fixture({ getFavoriteVideos: async (_id, page) => ({ videos: [video(page)], hasMore: videoMore }) });
    await f.library.activate(); f.api.getFavoriteFolders = () => pending.promise;
    const rootLoad = f.library.folders.load(true); await f.library.openFolder(folder());
    pending.resolve({ folders: [folder()], hasMore: folderMore }); await rootLoad;
    assert.equal(f.library.view.current.hasMore, videoMore); await f.library.loadMore();
    assert.deepEqual(f.callsOf('getFavoriteVideos').map(args => args[1]), videoMore ? [1, 2] : [1]);
    f.library.back(); assert.equal(f.library.view.current.hasMore, folderMore);
  }
});
test('finishing edit mode discards a delayed move picker', async () => {
  const pending = deferred(), f = fixture({ getAllFavoriteFolders: () => pending.promise }); await f.open(); await edit(f); f.editor.toggleChecked(1, 0);
  const opening = f.editor.openMoveSheet(); await edit(f); pending.resolve([folder(42), folder(84)]); await opening;
  assert.equal(f.editor.view.moveVisible, false); assert.deepEqual(f.editor.view.moveTargets, []);
  assert.deepEqual(f.editor.view.checkedAids, []); assert.deepEqual(f.notices, []);
});
test('an earlier edit-session picker cannot reopen over a new selection', async () => {
  for (const revisit of [false, true]) {
    const pending = deferred(), f = fixture({ getAllFavoriteFolders: () => pending.promise }); await f.open(); await edit(f); f.editor.toggleChecked(1, 0);
    const opening = f.editor.openMoveSheet(); await edit(f);
    if (revisit) { f.library.back(); await f.library.openFolder(folder()); }
    await edit(f); f.editor.toggleChecked(3, 2); pending.resolve([folder(42), folder(84)]); await opening;
    assert.equal(f.editor.view.moveVisible, false); assert.deepEqual(f.editor.view.checkedAids, [3]); assert.deepEqual(f.editor.view.moveTargets, []);
  }
});
test('obsolete move picker failure stays quiet and a current request can open', async () => {
  const pending = deferred(); let requests = 0;
  const f = fixture({ getAllFavoriteFolders: () => ++requests === 1 ? pending.promise : Promise.resolve([folder(42), folder(84)]) });
  await f.open(); await edit(f); f.editor.toggleChecked(1, 0); const opening = f.editor.openMoveSheet(); await edit(f);
  pending.reject(Error('old failure')); await opening; assert.deepEqual(f.notices, []);
  await edit(f); f.editor.toggleChecked(2, 1); await f.editor.openMoveSheet();
  assert.equal(f.editor.view.moveVisible, true); assert.deepEqual(f.editor.view.moveTargets.map(item => item.id), [84]);
});

for (const domain of ['folders', 'collections', 'videos']) {
  const apiName = domain === 'folders' ? 'getFavoriteFolders' : domain === 'collections' ? 'getCollectedFolders' : 'getFavoriteVideos';
  const dataKey = domain === 'videos' ? 'videos' : 'folders';
  const item = id => domain === 'videos' ? video(id) : folder(id);
  test(`${domain}: retry failed page, deduplicate rows and preserve source identity`, async () => {
    const f = fixture(); await f.open(); let failed = true;
    f.api[apiName] = async (_id, page) => {
      if (page === 2 && failed) { failed = false; throw Error('offline'); }
      return { [dataKey]: page === 1 ? [item(1), item(1)] : [item(1), item(2)], hasMore: page === 1 };
    };
    const list = f.library[domain], source = list.source;
    await list.load(true); await list.load(false);
    assert.equal(list.view.page, 1); assert.ok(list.view.error.length > 0); assert.equal(source.totalCount(), 1);
    await list.load(false); assert.equal(list.view.page, 2); assert.equal(list.view.hasMore, false); assert.equal(list.view.error, '');
    assert.equal(list.source, source); assert.equal(source.totalCount(), 2);
    assert.deepEqual(f.callsOf(apiName).slice(-3).map(args => args[1]), [1, 2, 2]);
  });
  test(`${domain}: latest refresh wins without old finally clearing new loading`, async () => {
    const old = deferred(), latest = deferred(), f = fixture(); await f.open(); let calls = 0;
    f.api[apiName] = () => ++calls === 1 ? old.promise : latest.promise;
    const first = f.library[domain].load(true), second = f.library[domain].load(true);
    old.resolve({ [dataKey]: [item(99)], hasMore: false }); await first; assert.equal(f.library[domain].view.loading, true);
    latest.resolve({ [dataKey]: [item(100)], hasMore: true }); await second;
    assert.equal(f.library[domain].source.getData(0)[domain === 'videos' ? 'aid' : 'id'], 100);
    assert.equal(f.library[domain].view.loading, false);
  });
}

test('account switch clears all three sources and ignores old reads and edits', async () => {
  const pending = deferred(), action = deferred(), f = fixture(); await f.open();
  f.api.getCollectedFolders = () => pending.promise; const oldRead = f.library.collections.load(true);
  await edit(f); f.editor.toggleChecked(1, 0); f.api.delFavoriteResources = () => action.promise; const oldAction = f.editor.deleteChecked();
  f.user.current = { mid: 8 }; f.auth.advance(); f.api.getFavoriteFolders = async () => ({ folders: [folder(800)], hasMore: false });
  f.api.getCollectedFolders = async () => ({ folders: [], hasMore: false }); await f.library.accountChanged();
  pending.resolve({ folders: [folder(99)], hasMore: false }); action.resolve({ ok: true }); await Promise.all([oldRead, oldAction]);
  assert.deepEqual(f.library.folders.source.getAll().map(item => item.id), [800]);
  assert.equal(f.library.collections.source.totalCount(), 0); assert.equal(f.library.videos.source.totalCount(), 0);
  assert.equal(f.editor.view.busy, false); assert.equal(f.editor.view.editing, false); assert.deepEqual(f.notices, []);
});
test('leaving during initialization starts no late requests or view updates', async () => {
  const pending = deferred(), f = fixture(); f.user.ensureLoaded = () => pending.promise;
  const activation = f.library.activate(); f.library.dispose(); const snapshot = f.library.view; pending.resolve(); await activation;
  assert.deepEqual(f.calls, []); assert.equal(f.library.view, snapshot);
});
test('same-account reactivation clears obsolete action locks and ignores their late completion', async () => {
  const pending = deferred(), f = fixture({ delFavoriteResources: () => pending.promise }); await f.open(); await edit(f);
  f.editor.toggleChecked(1, 0); const removal = f.editor.deleteChecked();
  await f.library.activate(); assert.equal(f.editor.view.busy, false); await edit(f); f.editor.toggleChecked(2, 1);
  pending.resolve({ ok: true }); await removal;
  assert.deepEqual(aids(f), [1, 2, 3]); assert.deepEqual(f.editor.view.checkedAids, [2]); assert.deepEqual(f.notices, []);
});
test('logout while loading clears private source data and does not accept a late read', async () => {
  const pending = deferred(), f = fixture(); await f.open(); f.api.getFavoriteVideos = () => pending.promise;
  const read = f.library.videos.load(true); f.user.current = null; f.auth.advance(); await f.library.accountChanged();
  pending.resolve({ videos: [video(99)], hasMore: true }); await read;
  assert.equal(f.library.folders.source.totalCount(), 0); assert.equal(f.library.collections.source.totalCount(), 0);
  assert.equal(f.library.videos.source.totalCount(), 0); assert.equal(f.library.view.selected.id, 0);
});
test('pagination emits immutable snapshots, append notifications and targeted removals', async () => {
  const f = fixture(); await f.open(); const source = f.library.videos.source, changes = [];
  source.registerDataChangeListener({ onDataReloaded: () => changes.push('reset'), onDataAdd: index => changes.push(['add', index]),
    onDataDelete: index => changes.push(['delete', index]), onDataChange() {} });
  f.api.getFavoriteVideos = async (_id, page) => ({ videos: page === 1 ? [video(1)] : [video(2)], hasMore: page === 1 });
  await f.library.videos.load(true); const snapshot = f.library.view; changes.length = 0;
  await f.library.videos.load(false); assert.deepEqual(changes, [['add', 1]]);
  assert.equal(snapshot.current.count, 1); assert.equal(f.library.view.current.count, 2); assert.notEqual(snapshot, f.library.view);
  changes.length = 0; f.library.videos.remove([1]); assert.deepEqual(changes, [['delete', 0]]); assert.equal(f.library.videos.source, source);
});
test('collection normalization and late video results do not mutate another folder', async () => {
  const pending = deferred(), f = fixture(); await f.library.activate(); f.library.setCategory(1);
  const collection = folder(11, { type: 0 }); await f.library.openFolder(collection);
  assert.equal(collection.type, 0); assert.equal(f.library.view.selected.type, 21); assert.deepEqual(f.callsOf('getCollectionVideos'), [[11, 1]]);
  f.library.back(); f.library.setCategory(0); f.api.getFavoriteVideos = () => pending.promise; const old = f.library.openFolder(folder(42));
  f.library.back(); f.api.getFavoriteVideos = async () => ({ videos: [video(8)], hasMore: false }); await f.library.openFolder(folder(84));
  pending.resolve({ videos: [video(9)], hasMore: true }); await old;
  assert.equal(f.library.view.selected.id, 84); assert.deepEqual(aids(f), [8]); assert.equal(f.library.view.current.hasMore, false);
});
test('deletion uses confirmed IDs and preserves a later unsubmitted selection', async () => {
  const pending = deferred(), f = fixture({ delFavoriteResources: () => pending.promise }); await f.open(); await edit(f);
  f.editor.toggleChecked(1, 0); const confirmation = f.editor.selection(); f.editor.toggleChecked(1, 0); f.editor.toggleChecked(2, 1);
  const removing = f.editor.deleteChecked(confirmation); assert.deepEqual(f.callsOf('delFavoriteResources'), [[42, [1]]]);
  f.editor.toggleChecked(3, 2); assert.deepEqual(f.editor.view.checkedAids, [2]);
  pending.resolve({ ok: true }); await removing; assert.deepEqual(aids(f), [2, 3]); assert.deepEqual(f.editor.view.checkedAids, [2]);
});
test('a cancelled editing session cannot execute an old delete confirmation', async () => {
  const f = fixture(); await f.open(); await edit(f); f.editor.toggleChecked(1, 0); const confirmation = f.editor.selection();
  await edit(f); await edit(f); f.editor.toggleChecked(2, 1); await f.editor.deleteChecked(confirmation);
  assert.deepEqual(f.callsOf('delFavoriteResources'), []); assert.deepEqual(f.editor.view.checkedAids, [2]);
});
test('late move success cannot remove videos or end a newer editing session', async () => {
  const pending = deferred(), f = fixture({ moveFavoriteResources: () => pending.promise }); await f.open(); await edit(f); f.editor.toggleChecked(1, 0);
  const moving = f.editor.moveCheckedTo(folder(84)); f.library.dispose(); await f.library.activate(); await edit(f); f.editor.toggleChecked(2, 1);
  pending.resolve({ ok: true }); await moving; assert.deepEqual(aids(f), [1, 2, 3]); assert.equal(f.editor.view.editing, true);
  assert.deepEqual(f.editor.view.checkedAids, [2]); assert.deepEqual(f.notices, []);
});
test('moving selected videos retains unsaved ordering of remaining videos', async () => {
  const f = fixture(); await f.open(); await edit(f); f.editor.moveVideo(2, -1); f.editor.toggleChecked(1, 0);
  await f.editor.moveCheckedTo(folder(84)); assert.deepEqual(aids(f), [3, 2]);
  assert.equal(f.editor.view.editing, true); assert.equal(f.editor.view.orderDirty, true);
  await edit(f); assert.deepEqual(f.callsOf('sortFavoriteVideos'), [[42, [3, 2]]]);
});
test('delete failure retains selection; success realigns the next server page', async () => {
  let failed = true;
  const f = fixture({ getFavoriteVideos: async (_id, page) => ({ videos: page === 1 ? [video(1), video(2)] : [video(3)], hasMore: true }),
    delFavoriteResources: async () => ({ ok: !failed, message: 'refused' }) }); await f.open(); await edit(f); f.editor.toggleChecked(1, 0);
  await f.editor.deleteChecked(); assert.deepEqual(aids(f), [1, 2]); assert.deepEqual(f.editor.view.checkedAids, [1]);
  failed = false; await f.editor.deleteChecked(); await edit(f);
  f.api.getFavoriteVideos = async () => ({ videos: [video(2), video(3)], hasMore: false }); await f.library.loadMore();
  assert.equal(f.callsOf('getFavoriteVideos').at(-1)[1], 1); assert.deepEqual(aids(f), [2, 3]);
});
test('rename snapshots privacy/description/title and old completion cannot close a newer dialog', async () => {
  const pending = deferred(), f = fixture({ editFavoriteFolder: () => pending.promise }); await f.library.activate();
  const target = folder(); f.library.folderEditor.open(true, target); f.library.folderEditor.setInput('Renamed');
  const saving = f.library.folderEditor.submit(); target.isPublic = true; target.intro = 'changed';
  assert.deepEqual(f.callsOf('editFavoriteFolder'), [[42, 'Renamed', false, 'description']]);
  f.library.folderEditor.close(); f.library.folderEditor.open(false); f.library.folderEditor.setInput('New draft');
  pending.resolve({ ok: true }); await saving;
  assert.equal(f.library.folderEditor.view.visible, true); assert.equal(f.library.folderEditor.view.input, 'New draft');
  assert.equal(f.library.folderEditor.view.busy, false); assert.deepEqual(f.notices, []);
});
test('create failure preserves draft; success refresh supersedes old folder reads', async () => {
  let failed = true; const pending = deferred(), f = fixture({ addFavoriteFolder: async () => ({ ok: !failed, message: 'refused' }) });
  await f.library.activate(); f.library.folderEditor.open(false); f.library.folderEditor.setInput('New folder');
  await f.library.folderEditor.submit(); assert.equal(f.library.folderEditor.view.visible, true);
  assert.equal(f.library.folderEditor.view.input, 'New folder'); assert.equal(f.library.folderEditor.view.busy, false);
  f.api.getFavoriteFolders = () => pending.promise; const obsolete = f.library.folders.load(true);
  f.api.getFavoriteFolders = async () => ({ folders: [folder(123)], hasMore: false }); failed = false;
  await f.library.folderEditor.submit(); await tick(); pending.resolve({ folders: [folder(1)], hasMore: true }); await obsolete;
  assert.deepEqual(f.library.folders.source.getAll().map(item => item.id), [123]); assert.equal(f.library.folderEditor.view.visible, false);
});
