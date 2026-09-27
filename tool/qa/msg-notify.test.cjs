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
  new Function('MsgUnreadStore', 'MessageApi', 'module', 'exports', code)(
    {clearCategory: value => clears.push(value)}, api, module, module.exports);
  const list = new module.exports.Harness();
  Object.assign(list, {tab, active: true, loading: false, hasMore: true,
    reloadPending: false, lastReportedSysCursor: '',
    source: {reset() {}, append() {}, totalCount: () => 1}});
  return {list, clears};
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
