const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');

function response(body, ok = true) {
  return {body, ok, status: ok ? 200 : 500, json: () => JSON.parse(body)};
}
function fixture(responder) {
  const calls = [], modules = new Map();
  class ActionResult {
    constructor(ok, message) {Object.assign(this, {ok, message});}
  }
  const common = {
    ActionResult,
    getData: resp => resp.ok && resp.json().code === 0 ? resp.json().data : null,
    failureText: () => 'request failed',
    actionWithCsrf: async (_, success, failure, action) => {
      const result = await action('mock-csrf');
      return new ActionResult(result.ok && result.json().code === 0, result.ok ? success : failure);
    },
  };
  for (const method of ['webGet', 'webGetSigned', 'webPost']) {
    common[method] = async (url, params) => {
      calls.push({method, url, params});
      return responder ? responder(url, params) : response('{"code":0,"data":{}}');
    };
  }
  const mocks = {
    '@kit.PerformanceAnalysisKit': {hilog: {warn() {}, info() {}}},
    BuildProfile: {DEBUG: false},
    'api/internal/ApiCommon': common,
    'services/network/HttpClient': {HttpClient: {}},
    'common/WbiSign': {WbiSign: {encWbi: async () => {throw Error('ACK must use official unsigned POST');}}},
  };
  function load(name) {
    if (name in mocks) return mocks[name];
    if (modules.has(name)) return modules.get(name);
    const filename = path.join(root, name + '.ets');
    const module = {exports: {}};
    modules.set(name, module.exports);
    const code = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020},
    }).outputText;
    new Function('require', 'module', 'exports', code)(dependency => {
      if (dependency in mocks) return mocks[dependency];
      assert.ok(dependency.startsWith('.'), 'unexpected dependency ' + dependency);
      return load(path.relative(root, path.resolve(path.dirname(filename), dependency)).replaceAll('\\', '/'));
    }, module, module.exports);
    modules.set(name, module.exports);
    return module.exports;
  }
  return {api: load('api/MessageApi').MessageApi, load, calls};
}

test('private ACK always sends the exact explicit sequence and never signs an official POST', async () => {
  const f = fixture();
  assert.equal((await f.api.markPrivateMessagesRead(42, '9007199254740993')).ok, true);
  assert.equal(f.calls[0].method, 'webPost');
  assert.equal(f.calls[0].params.ack_seqno, '9007199254740993');
  assert.equal((await f.api.markPrivateMessagesRead(42, '0')).ok, true);
  assert.equal(f.calls[1].params.ack_seqno, '0');
  assert.equal((await f.api.markPrivateMessagesRead(42, '')).ok, false);
  assert.equal(f.calls.length, 2, 'A missing sequence cannot silently ACK latest');
});

test('all-read does not send an old account system cursor after switching accounts during the fetch', async () => {
  const f = fixture();
  const {AuthSession} = f.load('services/auth/AuthSession');
  let resolve;
  f.api.getMsgFeedNotify = async () => ({error: ''});
  f.api.getSysNotifications = () => new Promise(yes => {resolve = yes;});
  const receipts = [];
  f.api.updateSysMsgCursor = async cursor => {receipts.push(cursor); return {ok: true};};
  const reading = f.api.markAllNotificationsRead();
  AuthSession.advance();
  resolve({error: '', items: [{sysCursor: '9007199254740993'}]});
  assert.equal((await reading).ok, false);
  assert.deepEqual(receipts, [], 'Account checks in the caller run too late to protect this API write');
});

test('all-read cannot report success after the account changes during the system receipt', async () => {
  const f = fixture();
  const {AuthSession} = f.load('services/auth/AuthSession');
  let resolve;
  f.api.getMsgFeedNotify = async () => ({error: ''});
  f.api.getSysNotifications = async () => ({error: '', items: [{sysCursor: '200'}]});
  f.api.updateSysMsgCursor = () => new Promise(yes => {resolve = yes;});
  const reading = f.api.markAllNotificationsRead();
  await new Promise(yes => setImmediate(yes));
  AuthSession.advance();
  resolve({ok: true});
  assert.equal((await reading).ok, false);
});

test('session and history JSON retain adjacent int64 sequences before parsing', async () => {
  const f = fixture(url => response(url.endsWith('get_sessions') ?
    '{"code":0,"data":{"session_list":[{"talker_id":42,"max_seqno":9007199254740993,"account_info":{"name":"test"}}]}}' :
    '{"code":0,"data":{"messages":[{"msg_seqno":9007199254740993},{"msg_seqno":9007199254740992}]}}'));
  const sessions = await f.api.getMessageSessions();
  assert.equal(sessions.sessions[0].maxSeqno, '9007199254740993');
  const history = await f.api.getPrivateMessages(42);
  assert.deepEqual(history.messages.map(item => item.seqnoText), ['9007199254740992', '9007199254740993']);
  assert.equal(history.minSeqnoText, '9007199254740992');
  await f.api.getPrivateMessages(42, history.minSeqnoText);
  assert.equal(f.calls.at(-1).params.begin_seqno, '9007199254740992');
});

test('system first page merges both official sources and ACKs the precise newest cursor', async () => {
  const f = fixture(url => response(url.endsWith('query_unified_notify') ?
    '{"code":0,"data":{"system_notify_list":[{"id":1,"cursor": 9007199254740992}]}}' :
    url.endsWith('query_user_notify') ?
    '{"code":0,"data":{"system_notify_list":[{"id":2,"cursor":"9007199254740993"},{"id":1,"cursor":9007199254740992}]}}' :
    '{"code":0,"data":{}}'));
  const page = await f.api.getSysNotifications();
  assert.equal(f.calls.length, 2);
  assert.equal(page.error, '');
  assert.deepEqual(page.items.map(item => item.sysCursor), ['9007199254740993', '9007199254740992']);
  assert.equal(page.sysCursor, '9007199254740992');
  assert.equal(page.hasMore, true, 'A short merged first page can still have older notifications');
  await f.api.updateSysMsgCursor(page.items[0].sysCursor);
  assert.equal(f.calls[2].params.cursor, '9007199254740993');
});

test('system pagination sends the exact oldest cursor with data_type=1', async () => {
  const f = fixture(() => response('{"code":0,"data":[{"id":3,"cursor":9007199254740991}]}'));
  const page = await f.api.getSysNotifications('9007199254740992');
  assert.equal(f.calls.length, 1);
  assert.ok(f.calls[0].url.endsWith('query_notify_list'));
  assert.equal(f.calls[0].params.data_type, '1');
  assert.equal(f.calls[0].params.cursor, '9007199254740992');
  assert.equal(page.sysCursor, '9007199254740991');
  assert.equal(page.hasMore, true, 'A short generic page does not prove the history is exhausted');
});

test('system history ends on an empty or nonadvancing page', async () => {
  const empty = fixture(() => response('{"code":0,"data":[]}'));
  assert.equal((await empty.api.getSysNotifications('200')).hasMore, false);
  const stuck = fixture(() => response('{"code":0,"data":[{"id":1,"cursor":"200"}]}'));
  assert.equal((await stuck.api.getSysNotifications('200')).hasMore, false);
});

test('failure in either system source does not masquerade as an empty read page', async () => {
  const f = fixture(url => url.endsWith('query_unified_notify') ?
    response('{"code":-1}', false) : response('{"code":0,"data":{"system_notify_list":[]}}'));
  const page = await f.api.getSysNotifications();
  assert.notEqual(page.error, '');
});

test('lossless parsing accepts whitespace and string cursors without changing message content', () => {
  const {parseMessageJson, compareMessageCursor} = fixture().load('common/MessageCursor');
  const body = '{"cursor": 9007199254740993, "max_seqno": "123", "content":"{\\"cursor\\":999}"}';
  const json = parseMessageJson(body);
  assert.equal(json.cursor, '9007199254740993');
  assert.equal(json.max_seqno, '123');
  assert.equal(json.content, '{"cursor":999}');
  assert.equal(compareMessageCursor('9007199254740993', '9007199254740992'), 1);
  assert.equal(compareMessageCursor('000123', '123'), 0);
});
