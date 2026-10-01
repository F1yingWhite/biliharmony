const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function fixture(tab, api) {
  const source = fs.readFileSync('entry/src/main/ets/components/MsgNotifyList.ets', 'utf8');
  const start = source.indexOf('  aboutToAppear(): void {');
  const end = source.indexOf('  private dedup(', start);
  assert.ok(start >= 0 && end > start);
  const module = {exports: {}};
  const clears = [];
  const code = ts.transpileModule('export class Harness {\n' + source.slice(start, end) + '\n}', {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText;
  const auth = {version: 0};
  new Function('MsgUnreadStore', 'MessageApi', 'AuthSession', 'module', 'exports', code)(
    {clearCategory: value => clears.push(value)}, api, auth, module, module.exports);
  const list = new module.exports.Harness();
  Object.assign(list, {tab, active: true, loading: false, hasMore: true,
    reloadPending: false, lastReportedSysCursor: '', lastReportedSysSession: auth.version,
    dedup: incoming => incoming,
    source: {reset() {}, append() {}, totalCount: () => 1}});
  return {list, clears, auth};
}

test('failed system read report preserves unread and retries on reopening the tab', async () => {
  let reports = 0;
  const api = {
    getSysNotifications: async () => ({error: '', items: [{sysCursor: '123'}], hasMore: false,
      cursorId: '', cursorTime: '', sysCursor: '123'}),
    updateSysMsgCursor: async () => ({ok: ++reports === 2}),
  };
  const {list, clears} = fixture('sys', api);
  await list.load(true);
  assert.deepEqual(clears, []);
  assert.equal(list.lastReportedSysCursor, '');
  list.active = true;
  list.onActiveChanged();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(reports, 2);
  assert.deepEqual(clears, ['sys']);
  assert.equal(list.lastReportedSysCursor, '123');
});

test('ordinary notification badge clears after a successful fetch, not after an error', async () => {
  let calls = 0;
  const {list, clears} = fixture('reply', {
    getMsgFeedNotify: async () => ++calls === 1 ? {error: 'network'} :
      {error: '', items: [], hasMore: false, cursorId: '', cursorTime: ''},
  });
  await list.load(true);
  assert.deepEqual(clears, []);
  await list.load(true);
  assert.deepEqual(clears, ['reply']);
});

test('reopening a tab during an old fetch schedules a fresh fetch', async () => {
  let resolveFirst, calls = 0;
  const first = new Promise(resolve => {resolveFirst = resolve;});
  const {list} = fixture('like', {
    getMsgFeedNotify: () => ++calls === 1 ? first : Promise.resolve({error: '', items: [], hasMore: false}),
  });
  const loading = list.load(true);
  list.onActiveChanged();
  resolveFirst({error: '', items: [], hasMore: false});
  await loading;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls, 2);
});

test('older system pages cannot move the confirmed cursor backwards', async () => {
  const reports = [];
  const {list, clears} = fixture('sys', {
    getSysNotifications: async cursor => ({error: '', items: [{sysCursor: cursor ? '100' : '200'}],
      hasMore: true, sysCursor: cursor ? '100' : '200'}),
    updateSysMsgCursor: async cursor => {reports.push(cursor); return {ok: true};},
  });
  await list.load(true);
  await list.load(false);
  assert.deepEqual(reports, ['200']);
  assert.deepEqual(clears, ['sys']);
});

test('an old account notification fetch cannot clear the new account badge', async () => {
  let resolve;
  const request = new Promise(yes => {resolve = yes;});
  const {list, clears, auth} = fixture('reply', {getMsgFeedNotify: () => request});
  const loading = list.load(true);
  auth.version++;
  resolve({error: '', items: [], hasMore: false});
  await loading;
  assert.deepEqual(clears, []);
});

test('an old account system read receipt cannot clear the new account badge', async () => {
  let resolve;
  const request = new Promise(yes => {resolve = yes;});
  const {list, clears, auth} = fixture('sys', {
    getSysNotifications: async () => ({error: '', items: [{sysCursor: '200'}], hasMore: false}),
    updateSysMsgCursor: () => request,
  });
  const loading = list.load(true);
  await new Promise(yes => setImmediate(yes));
  auth.version++;
  resolve({ok: true});
  await loading;
  assert.deepEqual(clears, []);
  assert.equal(list.lastReportedSysCursor, '');
});

test('the same public system cursor is confirmed again after switching accounts', async () => {
  let reports = 0;
  const {list, clears, auth} = fixture('sys', {
    getSysNotifications: async () => ({error: '', items: [{sysCursor: '200'}], hasMore: false,
      sysCursor: '200'}),
    updateSysMsgCursor: async () => ({ok: ++reports === 1}),
  });
  await list.load(true);
  await list.load(true);
  assert.equal(reports, 1, 'An unchanged cursor is cached for its current account');
  auth.version++;
  clears.length = 0;
  await list.load(true);
  assert.equal(reports, 2, 'The previous account confirmation cannot clear this account badge');
  assert.deepEqual(clears, [], 'A failed confirmation for the new account preserves its badge');
  assert.equal(list.lastReportedSysCursor, '');
});
