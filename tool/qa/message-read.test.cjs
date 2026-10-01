// Actual private-message models and page methods with fake network/account boundaries.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
function read(relative) {
  const override = process.env.ARKTS_TEST_SOURCE_ROOT && path.join(process.env.ARKTS_TEST_SOURCE_ROOT, relative);
  return fs.readFileSync(override && fs.existsSync(override) ? override : path.join(root, relative), 'utf8')
    .replace(/\r\n/g, '\n');
}
function compile(source, imports = {}) {
  const module = {exports: {}};
  const code = ts.transpileModule(source, {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020}
  }).outputText;
  new Function('require', 'module', 'exports', code)(name => {
    assert.ok(name in imports, 'unmocked import: ' + name);
    return imports[name];
  }, module, module.exports);
  return module.exports;
}
const utils = compile(read('common/Utils.ets'));
const models = compile(read('model/message/MessageModels.ets'), {'../../common/Utils': utils});
const cursor = compile(read('common/MessageCursor.ets'), {'./Utils': utils});
const {BasicDataSource} = compile(read('common/BasicDataSource.ets'));
const pageSource = read('pages/Messages.ets');
function section(start, end) {
  const begin = pageSource.indexOf(start), finish = pageSource.indexOf(end, begin);
  assert.ok(begin >= 0 && finish > begin, 'page harness anchors: ' + start);
  return pageSource.slice(begin, finish);
}
const readStart = pageSource.includes('  private ensureReadSession(') ?
  '  private ensureReadSession(' : '  private clearSessionUnread(';
const methods = section('  async loadSessions(', '  async send():') +
  section(readStart, '  private richMediaId(') +
  section('  private richMediaId(', '  private imageMessageHeight(');
const sessionList = pageSource.slice(pageSource.indexOf('LazyForEach(this.sessionsSource'));
const keyExpression = sessionList.match(/\}, \(item: MessageSessionItem\) => (.+)\)/)[1];
// Match ArkUI's documented same-key cache behavior on both onDataChange and onDataReloaded.
const rowKey = new Function('item', 'return ' + keyExpression);
const messageList = pageSource.slice(pageSource.indexOf('LazyForEach(this.messagesSource'));
const messageKey = new Function('item', 'return ' +
  messageList.match(/\}, \(item: PrivateMessageItem\) => (.+)\)/)[1]);
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {resolve = yes; reject = no;});
  return {promise, resolve, reject};
}
const tick = () => new Promise(resolve => setImmediate(resolve));
function session(id, seqno, unread = 3) {
  return Object.assign(new models.MessageSessionItem(), {talkerId: id, maxSeqno: seqno, unread,
    name: 'User ' + id, sessionTs: 20});
}
function message(seqno) {
  return Object.assign(models.PrivateMessageItem.from({msg_seqno: seqno, msg_type: 1,
    content: '{"content":"hello"}'}), {seqnoText: seqno});
}
function messages(items = []) {return {error: '', messages: items, hasMore: false, minSeqno: 0, minSeqnoText: ''};}
function sessions(items = []) {return {error: '', sessions: items, hasMore: false};}
function fixture(api = {}, rows = [session(5, '100')]) {
  const auth = {version: 1}, calls = [], toasts = [], clears = [];
  const boundary = {
    getPrivateMessages: async () => messages([message('100')]),
    getMessageSessions: async () => sessions(rows),
    markPrivateMessagesRead: async (talkerId, ackSeqno) => {calls.push({talkerId, ackSeqno}); return {ok: true};},
    markAllNotificationsRead: async () => ({ok: true}),
    ...api,
  };
  const {Harness} = compile(
    "import {MessageApi} from 'api'; import {AuthSession} from 'auth';\n" +
    "import {MsgUnreadStore} from 'unread'; import {AppStorage} from 'storage';\n" +
    "import {compareMessageCursor} from 'cursor';\nexport class Harness {\n" + methods + '\n}', {
      api: {MessageApi: boundary}, auth: {AuthSession: auth}, unread: {MsgUnreadStore: {clearAll: () => clears.push('all')}},
      storage: {AppStorage: {setOrCreate() {}}}, cursor,
    });
  const page = Object.assign(new Harness(), {sessionLoading: false, sessionHasMore: true, sessionError: '',
    sessionCount: rows.length, messagesSource: new BasicDataSource(), sessionsSource: new BasicDataSource(),
    current: rows[0] || session(0, ''), messageGeneration: 1, messageLoading: false, hasMore: true, minSeqno: 0, minSeqnoText: '',
    firstVisibleMessage: 0, readAllLoading: false, confirmedReadSeqnos: new Map(), readAuthSession: auth.version,
    scheduleMessageScroll() {}, getUIContext: () => ({getPromptAction: () => ({showToast: t => toasts.push(t.message)})})});
  page.sessionsSource.reset(rows);
  return {page, api: boundary, auth, calls, toasts, clears};
}
function cachedRows(page) {
  const cache = new Map(), rendered = new Map();
  const render = () => {
    rendered.clear();
    for (const row of page.sessionsSource.getAll()) {
      const key = rowKey.call(page, row);
      if (!cache.has(key)) cache.set(key, {unread: row.unread, name: row.name, preview: row.preview});
      rendered.set(row.talkerId, cache.get(key));
    }
  };
  page.sessionsSource.registerDataChangeListener({onDataChange: render, onDataReloaded: render, onDataAdd: render});
  render(); return rendered;
}

test('session model and clone retain the exact int64 read cursor and pinned state', () => {
  const row = models.MessageSessionItem.from({talker_id: 5, max_seqno: '9223372036854775807',
    last_msg: {msg_seqno: '9223372036854775806'}, unread_count: 2, biz_msg_unread_count: 1});
  row.pinned = true;
  assert.equal(row.maxSeqno, '9223372036854775807');
  assert.equal(row.clone().maxSeqno, row.maxSeqno);
  assert.equal(row.clone().pinned, true);
  assert.equal(models.MessageSessionItem.from({last_msg: {msg_seqno: '9007199254740993'}}).maxSeqno, '9007199254740993');
  assert.equal(models.MessageSessionItem.from({max_seqno: '0', last_msg: {msg_seqno: '10'}}).maxSeqno, '0');
});

test('private message preserves exact server sequence while retaining the numeric compatibility field', () => {
  const item = models.PrivateMessageItem.from({msg_seqno: '9007199254740993'});
  assert.equal(item.seqnoText, '9007199254740993');
  assert.equal(item.seqno, Number('9007199254740993'));
  assert.equal(new models.PrivateMessagePageData().minSeqnoText, '');
});

test('reading displayed messages confirms the greatest exact cursor and rebuilds the cached unread row', async () => {
  const f = fixture({getPrivateMessages: async () => messages([
    message('9007199254740993'), message('9007199254740992')])}, [session(5, '9007199254740993', 7)]);
  const rendered = cachedRows(f.page), oldCurrent = f.page.current;
  await f.page.loadMessages(true); await tick();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '9007199254740993'}]);
  assert.equal(f.page.sessionsSource.getData(0).unread, 0);
  assert.equal(rendered.get(5).unread, 0);
  assert.notEqual(f.page.current, oldCurrent);
});

test('successful empty history still confirms the conversation cursor', async () => {
  const f = fixture({getPrivateMessages: async () => messages()}, [session(5, '9223372036854775807', 7)]);
  const rendered = cachedRows(f.page);
  await f.page.loadMessages(true); await tick();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '9223372036854775807'}]);
  assert.equal(rendered.get(5).unread, 0);
});

test('an explicit zero cursor is valid but missing cursors cannot clear unread', async () => {
  const zero = fixture({getPrivateMessages: async () => messages()}, [session(5, '0')]);
  await zero.page.loadMessages(true); await tick();
  assert.deepEqual(zero.calls, [{talkerId: 5, ackSeqno: '0'}]);
  assert.equal(zero.page.sessionsSource.getData(0).unread, 0);
  const missing = fixture({getPrivateMessages: async () => messages()}, [session(5, '')]);
  await missing.page.loadMessages(true); await tick();
  assert.deepEqual(missing.calls, []);
  assert.equal(missing.page.sessionsSource.getData(0).unread, 3);
});

test('empty history acknowledges its opening cursor without reading a later incoming message', async () => {
  const response = deferred(), f = fixture({getPrivateMessages: () => response.promise});
  const loading = f.page.loadMessages(true);
  f.page.current = session(5, '101', 4); f.page.sessionsSource.reset([f.page.current]);
  response.resolve(messages()); await loading; await tick();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '100'}]);
  assert.equal(f.page.sessionsSource.getData(0).unread, 4);
});

test('failed read acknowledgement preserves the badge and retries on reopening', async () => {
  let reads = 0;
  const f = fixture({markPrivateMessagesRead: async () => ({ok: ++reads === 2})});
  const rendered = cachedRows(f.page);
  await f.page.openSession(f.page.current); await tick();
  assert.equal(rendered.get(5).unread, 3);
  await f.page.openSession(f.page.current); await tick();
  assert.equal(reads, 2); assert.equal(rendered.get(5).unread, 0);
});

test('late first-page session response cannot restore an acknowledged badge', async () => {
  const response = deferred(), f = fixture({getMessageSessions: () => response.promise});
  const loading = f.page.loadSessions(true);
  await f.page.loadMessages(true); await tick();
  response.resolve(sessions([session(5, '100', 7), session(6, '20', 2)])); await loading;
  assert.deepEqual(f.page.sessionsSource.getAll().map(row => row.unread), [0, 2]);
});

test('newer exact int64 sequence survives a stale read confirmation and later refresh', async () => {
  const ack = deferred(), f = fixture({getPrivateMessages: async () => messages([message('9007199254740992')]),
    markPrivateMessagesRead: () => ack.promise}, [session(5, '9007199254740992')]);
  await f.page.loadMessages(true);
  f.page.current = session(5, '9007199254740993', 4); f.page.sessionsSource.reset([f.page.current]);
  ack.resolve({ok: true}); await tick();
  assert.equal(f.page.sessionsSource.getData(0).unread, 4);
  f.api.getMessageSessions = async () => sessions([session(5, '9007199254740993', 4)]);
  await f.page.loadSessions(true);
  assert.equal(f.page.sessionsSource.getData(0).unread, 4);
});

test('out-of-order read responses never lower the remembered confirmation cursor', async () => {
  const older = deferred(), newer = deferred(); let calls = 0;
  const f = fixture({markPrivateMessagesRead: () => ++calls === 1 ? older.promise : newer.promise});
  await f.page.loadMessages(true);
  f.page.current = session(5, '101', 2); f.page.sessionsSource.reset([f.page.current]);
  f.api.getPrivateMessages = async () => messages([message('101')]);
  await f.page.loadMessages(true);
  newer.resolve({ok: true}); await tick(); older.resolve({ok: true}); await tick();
  f.api.getMessageSessions = async () => sessions([session(5, '000101', 2)]);
  await f.page.loadSessions(true);
  assert.equal(f.page.sessionsSource.getData(0).unread, 0);
});

test('a previous account read response cannot clear the new account conversation', async () => {
  const ack = deferred(), f = fixture({markPrivateMessagesRead: () => ack.promise});
  await f.page.loadMessages(true);
  f.auth.version++; f.page.current = session(5, '100', 4); f.page.sessionsSource.reset([f.page.current]);
  ack.resolve({ok: true}); await tick();
  assert.equal(f.page.sessionsSource.getData(0).unread, 4);
});

test('a previous account history response neither displays messages nor reports them read', async () => {
  const response = deferred(), f = fixture({getPrivateMessages: () => response.promise});
  const loading = f.page.loadMessages(true); f.auth.version++;
  response.resolve(messages([message('100')])); await loading; await tick();
  assert.deepEqual(f.calls, []); assert.equal(f.page.messagesSource.totalCount(), 0);
});

test('all-read sends every explicit conversation cursor including zero and retains cursorless badges', async () => {
  const f = fixture({}, [session(5, '9223372036854775807'), session(6, '0'), session(7, '')]);
  const rendered = cachedRows(f.page);
  await f.page.markAllRead();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '9223372036854775807'}, {talkerId: 6, ackSeqno: '0'}]);
  assert.deepEqual([5, 6, 7].map(id => rendered.get(id).unread), [0, 0, 3]);
  assert.deepEqual(f.toasts, ['部分消息标记失败，请稍后重试']);
});

test('all-read cancels account-specific work when the account changes during notification acknowledgement', async () => {
  const notify = deferred(), f = fixture({markAllNotificationsRead: () => notify.promise});
  const reading = f.page.markAllRead(); f.auth.version++;
  notify.resolve({ok: true}); await reading;
  assert.deepEqual(f.calls, []); assert.deepEqual(f.clears, []); assert.deepEqual(f.toasts, []);
});

test('old account session responses cannot overwrite a new request or carry its read map forward', async () => {
  const old = deferred(), fresh = deferred(); let requests = 0;
  const f = fixture({getMessageSessions: () => ++requests === 1 ? old.promise : fresh.promise});
  await f.page.loadMessages(true); await tick();
  const first = f.page.loadSessions(true); f.auth.version++;
  const second = f.page.loadSessions(true);
  assert.equal(requests, 2);
  old.resolve(sessions([session(5, '100', 9)])); await first;
  assert.equal(f.page.sessionLoading, true);
  fresh.resolve(sessions([session(5, '100', 4)])); await second;
  assert.equal(f.page.sessionsSource.getData(0).unread, 4);
  assert.equal(f.page.sessionLoading, false);
});

test('pagination preserves cleared duplicates and applies confirmations to reintroduced conversations', async () => {
  const f = fixture(); await f.page.loadMessages(true); await tick();
  f.page.sessionsSource.reset([session(6, '50', 2)]);
  f.api.getMessageSessions = async () => sessions([session(6, '50', 7), session(5, '100', 3)]);
  await f.page.loadSessions(false);
  assert.deepEqual(f.page.sessionsSource.getAll().map(row => [row.talkerId, row.unread]), [[6, 2], [5, 0]]);
});

test('message pagination forwards the exact cursor and retains distinct adjacent int64 messages', async () => {
  const requests = [], last = message('9007199254740993'), older = message('9007199254740992');
  const f = fixture({getPrivateMessages: async (id, beginSeqno) => {
    requests.push(beginSeqno);
    return requests.length === 1 ? {...messages([last]), hasMore: true,
      minSeqno: last.seqno, minSeqnoText: last.seqnoText} : messages([older, last]);
  }});
  await f.page.loadMessages(true); await tick();
  await f.page.loadMessages(false);
  assert.deepEqual(requests, [0, '9007199254740993']);
  assert.deepEqual(f.page.messagesSource.getAll().map(item => item.seqnoText), [older.seqnoText, last.seqnoText]);
  assert.notEqual(messageKey.call(f.page, older), messageKey.call(f.page, last));
  assert.notEqual(f.page.richMediaId(older), f.page.richMediaId(last));
  assert.notEqual(f.page.richCardId(older), f.page.richCardId(last));
  const local = Object.assign(new models.PrivateMessageItem(), {seqno: 123});
  assert.notEqual(messageKey.call(f.page, local), messageKey.call(f.page, message('123')));
  await f.page.openSession(session(6, '20')); await tick();
  assert.equal(requests[2], 0); assert.equal(f.page.minSeqnoText, '');
});

test('same-conversation refresh also rebuilds cached changed display information', async () => {
  const f = fixture(), rendered = cachedRows(f.page);
  const next = Object.assign(session(5, '100'), {name: 'New name', preview: 'New preview', avatar: 'avatar', pinned: true});
  f.api.getMessageSessions = async () => sessions([next]);
  await f.page.loadSessions(true);
  assert.equal(rendered.get(5).name, 'New name');
  assert.equal(rendered.get(5).preview, 'New preview');
});
