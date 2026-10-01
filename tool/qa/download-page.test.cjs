const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const tick = () => new Promise(resolve => setImmediate(resolve));
const ANCHOR = {
  prepare: ['  private prepare(): void {', '  private bg(): string {'],
  confirm: ['  private confirm(', '  private exportItem('],
  export: ['  private exportItem(', '  private jumpItem('],
};
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
}
function compile(source, names = [], values = []) {
  const module = {exports: {}};
  const code = ts.transpileModule(source, {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText;
  new Function('module', 'exports', ...names, code)(module, module.exports, ...values);
  return module.exports;
}
function fixture({init = async () => {}, menu = () => Promise.resolve({index: 0}), io = {}, targets = ['target']} = {}) {
  const filename = process.env.ARKTS_TEST_SOURCE_ROOT
    ? path.join(process.env.ARKTS_TEST_SOURCE_ROOT, 'pages/DownloadCenterPage.ets')
    : 'entry/src/main/ets/pages/DownloadCenterPage.ets';
  const source = fs.readFileSync(filename, 'utf8').replace(/\r\n/g, '\n');
  const methods = Object.values(ANCHOR).map(([start, end]) => {
    const begin = source.indexOf(start), finish = source.indexOf(end, begin);
    assert.ok(begin >= 0 && finish > begin, `method anchors: ${start} -> ${end}`);
    return source.slice(begin, finish);
  }).join('\n');
  const picker = {DocumentViewPicker: class {save() {return Promise.resolve(targets);}}, DocumentSaveOptions: class {}};
  const fileIo = {OpenMode: {READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8}, ...io};
  const {Harness} = compile('export class Harness {\n' + methods + '\n}',
    ['DownloadCenter', 'picker', 'fs', 'AppTheme'], [{init}, picker, fileIo, {DANGER: '#FF0000'}]);
  const {RequestEpoch} = compile(fs.readFileSync('entry/src/main/ets/common/RequestEpoch.ets', 'utf8'));
  const page = new Harness(), messages = [], refreshes = [];
  Object.assign(page, {
    destroyed: false, prepareEpoch: new RequestEpoch(), preparing: false, prepareError: '',
    getUIContext: () => ({getHostContext: () => ({}), getPromptAction: () => ({showDialog: menu})}),
    toast: message => messages.push(message), refreshTasks: () => refreshes.push(true), isDark: false,
  });
  return {page, messages, refreshes};
}
const item = {filePath: 'source', title: 'media', kind: 1, extension: () => '.m4a'};

test('confirmation failure never executes a destructive action', async () => {
  let actions = 0;
  const {page} = fixture({menu: () => {throw new Error('window unavailable');}});
  page.confirm('delete?', () => actions++);
  await tick();
  assert.equal(actions, 0);
});

test('confirmation rejection is handled without executing action', async () => {
  let actions = 0;
  const {page} = fixture({menu: () => Promise.reject(new Error('cancelled'))});
  page.confirm('delete?', () => actions++);
  await tick();
  assert.equal(actions, 0);
});

test('confirmation requires acceptance from a still-active page', async () => {
  const pending = deferred(); let actions = 0;
  const {page} = fixture({menu: () => pending.promise});
  page.confirm('delete?', () => actions++);
  page.destroyed = true;
  pending.resolve({index: 1}); await tick();
  assert.equal(actions, 0);
  const live = fixture({menu: () => Promise.resolve({index: 1})}).page;
  live.confirm('delete?', () => actions++); await tick();
  assert.equal(actions, 1);
});

test('source-open failure never opens or truncates the export target', async () => {
  const opened = [], closed = [];
  const {page, messages} = fixture({io: {
    openSync(path) {opened.push(path); if (path === 'source') throw new Error('missing'); return {fd: 2};},
    closeSync(file) {closed.push(file.fd);}, copyFileSync() {},
  }});
  page.exportItem(item); await tick();
  assert.deepEqual(opened, ['source']);
  assert.deepEqual(closed, []);
  assert.deepEqual(messages, ['导出失败，请重试']);
});

for (const failure of ['target-open', 'copy', 'target-close', 'none']) {
  test(`export closes each acquired file even after ${failure}`, async () => {
    const closed = [], copied = [];
    const {page, messages} = fixture({io: {
      openSync(path) {
        if (path === 'target' && failure === 'target-open') throw new Error('target unavailable');
        return {fd: path === 'source' ? 1 : 2};
      },
      copyFileSync(source, target) {copied.push([source, target]); if (failure === 'copy') throw new Error('copy failure');},
      closeSync(file) {closed.push(file.fd); if (file.fd === 2 && failure === 'target-close') throw new Error('close failure');},
    }});
    page.exportItem(item); await tick();
    assert.deepEqual(closed, failure === 'target-open' ? [1] : [2, 1]);
    assert.deepEqual(copied, failure === 'target-open' ? [] : [[1, 2]]);
    assert.deepEqual(messages, [failure === 'none' ? '已导出到所选位置' : '导出失败，请重试']);
  });
}

test('restore failure becomes retryable error and success clears it', async () => {
  let calls = 0;
  const {page, refreshes} = fixture({init: () => ++calls === 1 ? Promise.reject(new Error('storage unavailable')) : Promise.resolve()});
  page.prepare(); await tick();
  assert.equal(page.preparing, false);
  assert.match(page.prepareError, /加载失败/);
  assert.equal(refreshes.length, 0);
  page.prepare(); assert.equal(page.prepareError, ''); await tick();
  assert.equal(page.preparing, false);
  assert.equal(page.prepareError, '');
  assert.equal(refreshes.length, 1);
});

test('stale restore failure does not end a newer restore or change its error', async () => {
  const old = deferred(), current = deferred(); let calls = 0;
  const {page} = fixture({init: () => ++calls === 1 ? old.promise : current.promise});
  page.prepare(); page.prepare();
  old.reject(new Error('old failure')); await tick();
  assert.equal(page.preparing, true);
  assert.equal(page.prepareError, '');
  current.resolve(); await tick();
  assert.equal(page.preparing, false);
});

test('restore settling after page exit never changes view state', async () => {
  const pending = deferred();
  const {page} = fixture({init: () => pending.promise});
  page.prepare(); page.destroyed = true; page.prepareEpoch.invalidate();
  pending.reject(new Error('late failure')); await tick();
  assert.equal(page.preparing, true);
  assert.equal(page.prepareError, '');
});
