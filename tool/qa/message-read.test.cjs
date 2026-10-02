// Complete private-message controllers and models; only network/account boundaries are mocked.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');
const models = createArktsLoader()('model/message/MessageModels');
const identity = createArktsLoader()('components/message/MessageIdentity');
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
  const auth = {version: 1}, calls = [], toasts = [], clears = [], scrolls = [];
  const user = {current: {mid: 7}, isLogin: true};
  const boundary = {
    getPrivateMessages: async () => messages([message('100')]),
    getMessageSessions: async () => sessions(rows),
    markPrivateMessagesRead: async (talkerId, ackSeqno) => {calls.push({talkerId, ackSeqno}); return {ok: true};},
    markAllNotificationsRead: async () => ({ok: true}),
    sendPrivateMessage: async () => ({ok: true}),
    pinSession: async () => ({ok: true, message: 'pinned'}),
    removeSession: async () => ({ok: true}), reportImMessage: async () => ({ok: true}),
    ...api,
  };
  const load = createArktsLoader({mocks: {
    'api/MessageApi': {MessageApi: boundary},
    'services/auth/AuthSession': {AuthSession: auth}, 'services/auth/UserStore': {UserStore: user},
    'services/message/MsgUnreadStore': {MsgUnreadStore: {clearAll: () => clears.push('all')}}
  }});
  const {SessionListController} = load('components/message/SessionListController');
  const {PrivateChatSession} = load('components/message/PrivateChatSession');
  const states = [], chats = [];
  let chat;
  const list = new SessionListController(state => states.push(state), text => toasts.push(text),
    (id, cursor) => chat.confirmRead(id, cursor));
  chat = new PrivateChatSession(state => chats.push(state), text => toasts.push(text),
    event => scrolls.push(event), (id, cursor) => list.acknowledge(id, cursor));
  list.activate(); list.source.reset(rows);
  return {list, chat, api: boundary, auth, user, calls, toasts, clears, scrolls, states, chats,
    open: (item = list.source.getData(0)) => chat.open(item),
    get chatState() {return chats.at(-1);}};
}
function cachedRows(list) {
  const cache = new Map(), rendered = new Map();
  const render = () => {
    rendered.clear();
    for (const row of list.source.getAll()) {
      const key = identity.sessionRowIdentity(row);
      if (!cache.has(key)) cache.set(key, {unread: row.unread, name: row.name, preview: row.preview});
      rendered.set(row.talkerId, cache.get(key));
    }
  };
  list.source.registerDataChangeListener({onDataChange: render, onDataReloaded: render, onDataAdd: render, onDataDelete: render});
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
  const rendered = cachedRows(f.list);
  await f.open(); await tick();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '9007199254740993'}]);
  assert.equal(f.list.source.getData(0).unread, 0);
  assert.equal(rendered.get(5).unread, 0);
  assert.equal(f.chatState.current.unread, 0);
  assert.notEqual(f.chats.at(-2).current, f.chatState.current);
});

test('successful empty history still confirms the conversation cursor', async () => {
  const f = fixture({getPrivateMessages: async () => messages()}, [session(5, '9223372036854775807', 7)]);
  const rendered = cachedRows(f.list);
  await f.open(); await tick();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '9223372036854775807'}]);
  assert.equal(rendered.get(5).unread, 0);
});

test('an explicit zero cursor is valid but missing cursors cannot clear unread', async () => {
  const zero = fixture({getPrivateMessages: async () => messages()}, [session(5, '0')]);
  await zero.open(); await tick();
  assert.deepEqual(zero.calls, [{talkerId: 5, ackSeqno: '0'}]);
  assert.equal(zero.list.source.getData(0).unread, 0);
  const missing = fixture({getPrivateMessages: async () => messages()}, [session(5, '')]);
  await missing.open(); await tick();
  assert.deepEqual(missing.calls, []);
  assert.equal(missing.list.source.getData(0).unread, 3);
});

test('empty history acknowledges its opening cursor without reading a later incoming message', async () => {
  const response = deferred(), f = fixture({getPrivateMessages: () => response.promise});
  const loading = f.open();
  f.list.source.reset([session(5, '101', 4)]);
  response.resolve(messages()); await loading; await tick();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '100'}]);
  assert.equal(f.list.source.getData(0).unread, 4);
});

test('failed read acknowledgement preserves the badge and retries on reopening', async () => {
  let reads = 0;
  const f = fixture({markPrivateMessagesRead: async () => ({ok: ++reads === 2})});
  const rendered = cachedRows(f.list);
  await f.open(); await tick();
  assert.equal(rendered.get(5).unread, 3);
  await f.open(); await tick();
  assert.equal(reads, 2); assert.equal(rendered.get(5).unread, 0);
});

test('late first-page session response cannot restore an acknowledged badge', async () => {
  const response = deferred(), f = fixture({getMessageSessions: () => response.promise});
  const loading = f.list.load(true);
  await f.open(); await tick();
  response.resolve(sessions([session(5, '100', 7), session(6, '20', 2)])); await loading;
  assert.deepEqual(f.list.source.getAll().map(row => row.unread), [0, 2]);
});

test('newer exact int64 sequence survives a stale read confirmation and later refresh', async () => {
  const ack = deferred(), f = fixture({getPrivateMessages: async () => messages([message('9007199254740992')]),
    markPrivateMessagesRead: () => ack.promise}, [session(5, '9007199254740992')]);
  await f.open();
  f.list.source.reset([session(5, '9007199254740993', 4)]);
  ack.resolve({ok: true}); await tick();
  assert.equal(f.list.source.getData(0).unread, 4);
  f.api.getMessageSessions = async () => sessions([session(5, '9007199254740993', 4)]);
  await f.list.load(true);
  assert.equal(f.list.source.getData(0).unread, 4);
});

test('out-of-order read responses never lower the remembered confirmation cursor', async () => {
  const older = deferred(), newer = deferred(); let calls = 0;
  const f = fixture({markPrivateMessagesRead: () => ++calls === 1 ? older.promise : newer.promise});
  await f.open();
  f.list.source.reset([session(5, '101', 2)]);
  f.api.getPrivateMessages = async () => messages([message('101')]);
  await f.open();
  newer.resolve({ok: true}); await tick(); older.resolve({ok: true}); await tick();
  f.api.getMessageSessions = async () => sessions([session(5, '000101', 2)]);
  await f.list.load(true);
  assert.equal(f.list.source.getData(0).unread, 0);
});

test('a previous account read response cannot clear the new account conversation', async () => {
  const ack = deferred(), f = fixture({markPrivateMessagesRead: () => ack.promise});
  await f.open();
  f.auth.version++; f.list.activate(); f.list.source.reset([session(5, '100', 4)]);
  ack.resolve({ok: true}); await tick();
  assert.equal(f.list.source.getData(0).unread, 4);
});

test('a previous account history response neither displays messages nor reports them read', async () => {
  const response = deferred(), f = fixture({getPrivateMessages: () => response.promise});
  const loading = f.open(); f.auth.version++;
  response.resolve(messages([message('100')])); await loading; await tick();
  assert.deepEqual(f.calls, []); assert.equal(f.chat.source.totalCount(), 0);
});

test('all-read sends every explicit conversation cursor including zero and retains cursorless badges', async () => {
  const f = fixture({}, [session(5, '9223372036854775807'), session(6, '0'), session(7, '')]);
  const rendered = cachedRows(f.list);
  await f.list.markAllRead();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '9223372036854775807'}, {talkerId: 6, ackSeqno: '0'}]);
  assert.deepEqual([5, 6, 7].map(id => rendered.get(id).unread), [0, 0, 3]);
  assert.deepEqual(f.toasts, ['部分消息标记失败，请稍后重试']);
});

test('all-read cancels account-specific work when the account changes during notification acknowledgement', async () => {
  const notify = deferred(), f = fixture({markAllNotificationsRead: () => notify.promise});
  const reading = f.list.markAllRead(); f.auth.version++;
  notify.resolve({ok: true}); await reading;
  assert.deepEqual(f.calls, []); assert.deepEqual(f.clears, []); assert.deepEqual(f.toasts, []);
});

test('old account session responses cannot overwrite a new request or carry its read map forward', async () => {
  const old = deferred(), fresh = deferred(); let requests = 0;
  const f = fixture({getMessageSessions: () => ++requests === 1 ? old.promise : fresh.promise});
  await f.open(); await tick();
  const first = f.list.load(true); f.auth.version++;
  f.list.activate();
  const second = f.list.load(true);
  assert.equal(requests, 2);
  old.resolve(sessions([session(5, '100', 9)])); await first;
  assert.equal(f.list.snapshot().loading, true);
  fresh.resolve(sessions([session(5, '100', 4)])); await second;
  assert.equal(f.list.source.getData(0).unread, 4);
  assert.equal(f.list.snapshot().loading, false);
});

test('pagination preserves cleared duplicates and applies confirmations to reintroduced conversations', async () => {
  const f = fixture(); await f.open(); await tick();
  f.list.source.reset([session(6, '50', 2)]);
  f.api.getMessageSessions = async () => sessions([session(6, '50', 7), session(5, '100', 3)]);
  await f.list.load(false);
  assert.deepEqual(f.list.source.getAll().map(row => [row.talkerId, row.unread]), [[6, 2], [5, 0]]);
});

test('message pagination forwards the exact cursor and retains distinct adjacent int64 messages', async () => {
  const requests = [], last = message('9007199254740993'), older = message('9007199254740992');
  const f = fixture({getPrivateMessages: async (id, beginSeqno) => {
    requests.push(beginSeqno);
    return requests.length === 1 ? {...messages([last]), hasMore: true,
      minSeqno: last.seqno, minSeqnoText: last.seqnoText} : messages([older, last]);
  }});
  await f.open(); await tick();
  await f.chat.load(false);
  assert.deepEqual(requests, [0, '9007199254740993']);
  assert.deepEqual(f.chat.source.getAll().map(item => item.seqnoText), [older.seqnoText, last.seqnoText]);
  assert.notEqual(identity.privateMessageIdentity(older), identity.privateMessageIdentity(last));
  const local = Object.assign(new models.PrivateMessageItem(), {seqno: 123});
  assert.notEqual(identity.privateMessageIdentity(local), identity.privateMessageIdentity(message('123')));
  await f.chat.open(session(6, '20')); await tick();
  assert.equal(requests[2], 0);
});

test('same-conversation refresh also rebuilds cached changed display information', async () => {
  const f = fixture(), rendered = cachedRows(f.list);
  const next = Object.assign(session(5, '100'), {name: 'New name', preview: 'New preview', avatar: 'avatar', pinned: true});
  f.api.getMessageSessions = async () => sessions([next]);
  await f.list.load(true);
  assert.equal(rendered.get(5).name, 'New name');
  assert.equal(rendered.get(5).preview, 'New preview');
});

test('same-account refresh supersedes a pending page without its finally unlocking the newer request', async () => {
  const first = deferred(), second = deferred(); let requests = 0;
  const f = fixture({getMessageSessions: () => ++requests === 1 ? first.promise : second.promise});
  const a = f.list.load(true), b = f.list.load(true);
  first.resolve(sessions([session(1, '1')])); await a;
  assert.equal(f.list.snapshot().loading, true);
  assert.equal(f.list.source.getData(0).talkerId, 5);
  second.resolve(sessions([session(2, '2')])); await b;
  assert.equal(f.list.snapshot().loading, false); assert.equal(f.list.source.getData(0).talkerId, 2);
});

test('session pagination keeps a server cursor independent of pin ordering and only appends fresh rows', async () => {
  const requests = [], f = fixture({getMessageSessions: async cursor => {
    requests.push(cursor);
    return requests.length === 1 ? {...sessions([
      Object.assign(session(5, '100'), {sessionTs: 30}), Object.assign(session(6, '90'), {sessionTs: 20})]), hasMore: true} :
      {...sessions([session(6, '90'), Object.assign(session(7, '80'), {sessionTs: 10})]), hasMore: true};
  }});
  const source = f.list.source, events = [];
  source.registerDataChangeListener({onDataReloaded: () => events.push('reset'),
    onDataChange: () => events.push('change'), onDataAdd: () => events.push('add')});
  await f.list.load(true);
  await f.list.togglePin(f.list.captureAction(source.getData(1)));
  assert.deepEqual(source.getAll().map(item => item.talkerId), [6, 5]);
  events.length = 0;
  await f.list.load(false);
  assert.equal(f.list.source, source); assert.deepEqual(requests, [0, 20]);
  assert.deepEqual(events, ['add']); assert.deepEqual(source.getAll().map(item => item.talkerId), [6, 5, 7]);
});

test('session network failures preserve rows and retry the failed request rather than changing its cursor', async () => {
  const requests = [], f = fixture({getMessageSessions: async cursor => {
    requests.push(cursor);
    if (requests.length === 1) return {...sessions([session(5, '100')]), hasMore: true};
    if (requests.length === 2) throw Error('offline');
    return sessions([Object.assign(session(6, '90'), {sessionTs: 10})]);
  }});
  await f.list.load(true); await f.list.load(false);
  assert.match(f.list.snapshot().error, /加载失败/); assert.equal(f.list.source.totalCount(), 1);
  assert.equal(f.list.snapshot().loading, false);
  await f.list.retry();
  assert.deepEqual(requests, [0, 20, 20]); assert.equal(f.list.source.totalCount(), 2);
  assert.equal(f.list.snapshot().error, '');
});

test('leaving invalidates session loading, unread acknowledgements and all-read notices', async () => {
  const loading = deferred(), ack = deferred(), all = deferred();
  const f = fixture({getMessageSessions: () => loading.promise, markPrivateMessagesRead: () => ack.promise,
    markAllNotificationsRead: () => all.promise});
  const a = f.list.load(true), b = f.list.acknowledge(5, '100'), c = f.list.markAllRead();
  f.list.dispose(); const count = f.states.length;
  loading.resolve(sessions([session(6, '100')])); ack.resolve({ok: true}); all.reject(Error('offline'));
  await Promise.all([a, b, c]);
  assert.equal(f.states.length, count); assert.equal(f.list.source.getData(0).unread, 3);
  assert.deepEqual(f.toasts, []); assert.deepEqual(f.clears, []);
});

test('all-read freezes the clicked conversation cursors before awaiting notification read', async () => {
  const notify = deferred(), f = fixture({markAllNotificationsRead: () => notify.promise});
  const reading = f.list.markAllRead();
  f.list.source.reset([session(5, '101', 4), session(6, '20', 2)]);
  notify.resolve({ok: true}); await reading;
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '100'}]);
  assert.deepEqual(f.list.source.getAll().map(item => item.unread), [4, 2]);
});

test('one failed conversation acknowledgement does not prevent the remaining explicit confirmations', async () => {
  const calls = [], f = fixture({markPrivateMessagesRead: async id => {
    calls.push(id); if (id === 5) throw Error('offline'); return {ok: true};
  }}, [session(5, '100'), session(6, '90')]);
  await f.list.markAllRead();
  assert.deepEqual(calls, [5, 6]); assert.deepEqual(f.list.source.getAll().map(item => item.unread), [3, 0]);
  assert.deepEqual(f.toasts, ['部分消息标记失败，请稍后重试']);
});

test('an older all-read finally cannot unlock a reactivated account operation', async () => {
  const old = deferred(), next = deferred(); let requests = 0;
  const f = fixture({markAllNotificationsRead: () => ++requests === 1 ? old.promise : next.promise});
  const a = f.list.markAllRead(); f.list.dispose(); f.list.activate();
  const b = f.list.markAllRead(); old.resolve({ok: true}); await a;
  assert.equal(f.list.snapshot().readAllLoading, true); assert.deepEqual(f.clears, []);
  next.resolve({ok: true}); await b; assert.equal(f.list.snapshot().readAllLoading, false);
});

test('menu snapshot freezes desired pin state, supersedes earlier menus and cannot be reused', async () => {
  const pins = [], f = fixture({pinSession: async (...args) => {pins.push(args); return {ok: true, message: 'ok'};}});
  const row = f.list.source.getData(0), old = f.list.captureAction(row), action = f.list.captureAction(row);
  row.pinned = true;
  await f.list.togglePin(old); await f.list.togglePin(action); await f.list.togglePin(action);
  assert.deepEqual(pins, [[5, true]]); assert.equal(f.list.source.getData(0).pinned, true);
});

test('unpinning a stale menu target does not clear a different currently pinned conversation', async () => {
  const f = fixture({}, [Object.assign(session(5, '100'), {pinned: true}), session(6, '90')]);
  const action = f.list.captureAction(f.list.source.getData(0));
  f.list.source.reset([session(5, '100'), Object.assign(session(6, '90'), {pinned: true})]);
  await f.list.togglePin(action);
  assert.equal(f.list.source.getData(0).talkerId, 6); assert.equal(f.list.source.getData(0).pinned, true);
});

test('delete cancels stale list publication and sends a targeted data-source deletion', async () => {
  const response = deferred(), f = fixture({getMessageSessions: () => response.promise});
  const events = [];
  f.list.source.registerDataChangeListener({onDataDelete: index => events.push(index), onDataReloaded: () => events.push('reset')});
  const loading = f.list.load(true);
  await f.list.remove(f.list.captureAction(f.list.source.getData(0)));
  response.resolve(sessions([session(5, '100')])); await loading;
  assert.deepEqual(events, [0]); assert.equal(f.list.snapshot().count, 0); assert.equal(f.list.snapshot().loading, false);
});

test('account change or leaving makes pending native confirmation snapshots inert', async () => {
  const calls = [], f = fixture({pinSession: async () => {calls.push('pin'); return {ok: true};},
    removeSession: async () => {calls.push('remove'); return {ok: true};}});
  const old = f.list.captureAction(f.list.source.getData(0));
  f.auth.version++; f.list.activate();
  await f.list.remove(old); await f.list.togglePin(old);
  f.list.source.reset([session(6, '90')]); const next = f.list.captureAction(f.list.source.getData(0));
  f.list.dispose(); await f.list.remove(next);
  assert.deepEqual(calls, []); assert.deepEqual(f.toasts, []);
});

test('late mutation failure cannot emit a toast or unlock a newer mutation', async () => {
  const old = deferred(), next = deferred(); let requests = 0;
  const f = fixture({removeSession: () => ++requests === 1 ? old.promise : next.promise});
  const a = f.list.remove(f.list.captureAction(f.list.source.getData(0)));
  f.list.activate(); const b = f.list.remove(f.list.captureAction(f.list.source.getData(0)));
  old.reject(Error('offline')); await a;
  assert.deepEqual(f.toasts, []); assert.equal(f.list.captureAction(f.list.source.getData(0)), null);
  next.resolve({ok: false, message: 'denied'}); await b;
  assert.equal(f.list.source.totalCount(), 1); assert.deepEqual(f.toasts, ['denied']);
  assert.notEqual(f.list.captureAction(f.list.source.getData(0)), null);
});

test('two refreshes of the same chat isolate loading completion and read acknowledgement', async () => {
  const old = deferred(), next = deferred(); let requests = 0;
  const f = fixture({getPrivateMessages: () => ++requests === 1 ? old.promise : next.promise});
  const a = f.open(), b = f.chat.load(true);
  old.resolve(messages([message('100')])); await a;
  assert.equal(f.chat.snapshot().loading, true); assert.equal(f.chat.source.totalCount(), 0);
  next.resolve(messages([message('101')])); await b; await tick();
  assert.deepEqual(f.calls, [{talkerId: 5, ackSeqno: '101'}]);
});

test('closing chat during history loading suppresses messages, scroll requests, read calls and state publication', async () => {
  const response = deferred(), f = fixture({getPrivateMessages: () => response.promise});
  const loading = f.open(); f.chat.close(); const publications = f.chats.length;
  response.resolve(messages([message('100')])); await loading;
  assert.equal(f.chats.length, publications); assert.equal(f.chat.source.totalCount(), 0);
  assert.deepEqual(f.calls, []); assert.deepEqual(f.scrolls, []);
});

test('prepending distinct older messages requests the current reading anchor before data-source notifications', async () => {
  let requests = 0; const f = fixture({getPrivateMessages: async () => ++requests === 1 ?
    {...messages([message('100')]), hasMore: true, minSeqnoText: '100'} : messages([message('99'), message('99'), message('100')])});
  await f.open(); const source = f.chat.source, events = [];
  f.scrolls.length = 0;
  source.registerDataChangeListener({onDataAdd: index => events.push(['add', index, f.scrolls.at(-1)?.added]),
    onDataReloaded: () => events.push(['reset'])});
  await f.chat.load(false);
  assert.equal(f.chat.source, source); assert.deepEqual(events, [['add', 0, 1]]);
  assert.equal(f.scrolls.length, 1); assert.equal(f.scrolls[0].latest, false);
  assert.deepEqual(source.getAll().map(item => item.seqnoText), ['99', '100']);
});

test('chat history failure preserves existing messages and clears loading for an explicit retry', async () => {
  let requests = 0; const f = fixture({getPrivateMessages: async () => {
    if (++requests === 1) return {...messages([message('100')]), hasMore: true, minSeqnoText: '100'};
    if (requests === 2) throw Error('offline');
    return messages([message('99')]);
  }});
  await f.open(); await f.chat.load(false);
  assert.equal(f.chat.source.totalCount(), 1); assert.match(f.chat.snapshot().error, /消息加载失败/);
  assert.equal(f.chat.snapshot().loading, false); await f.chat.load(false);
  assert.deepEqual(f.chat.source.getAll().map(item => item.seqnoText), ['99', '100']);
});

for (const change of ['auth', 'mid', 'logout', 'close']) {
  test(`pending send ignores ${change} changes without appending, clearing draft or issuing old notices`, async () => {
    const response = deferred(), f = fixture({sendPrivateMessage: () => response.promise});
    await f.open(); f.chat.setDraft('hello'); const sending = f.chat.send();
    if (change === 'auth') f.auth.version++;
    else if (change === 'mid') f.user.current = {mid: 8};
    else if (change === 'logout') f.user.isLogin = false;
    else f.chat.close();
    const count = f.chats.length, scrollCount = f.scrolls.length;
    response.resolve({ok: true}); await sending;
    assert.equal(f.chat.source.totalCount(), 1); assert.equal(f.chat.snapshot().draft, 'hello');
    assert.equal(f.chats.length, count); assert.equal(f.scrolls.length, scrollCount); assert.deepEqual(f.toasts, []);
  });
}

test('old send cannot clear a new conversation draft or unlock its pending send', async () => {
  const old = deferred(), next = deferred(), submitted = [];
  const f = fixture({sendPrivateMessage: (...args) => {submitted.push(args); return submitted.length === 1 ? old.promise : next.promise;}});
  await f.open(); f.chat.setDraft('first'); const a = f.chat.send();
  await f.open(session(6, '20')); f.chat.setDraft('second'); const b = f.chat.send();
  old.resolve({ok: true}); await a;
  assert.equal(f.chat.snapshot().sending, true); assert.equal(f.chat.snapshot().draft, 'second');
  assert.equal(f.chat.source.totalCount(), 1);
  next.resolve({ok: true}); await b;
  assert.deepEqual(submitted, [[7, 5, 'first'], [7, 6, 'second']]);
  assert.equal(f.chat.snapshot().sending, false); assert.equal(f.chat.snapshot().draft, '');
  assert.equal(f.chat.source.getData(1).receiverId, 6);
});

test('duplicate send is locked and later identical typed text is retained as a new draft', async () => {
  const response = deferred(); let requests = 0;
  const f = fixture({sendPrivateMessage: () => {requests++; return response.promise;}});
  await f.open(); f.chat.setDraft('hello'); const sending = f.chat.send();
  await f.chat.send(); f.chat.setDraft(''); f.chat.setDraft('hello');
  response.resolve({ok: true}); await sending;
  assert.equal(requests, 1); assert.equal(f.chat.snapshot().draft, 'hello'); assert.equal(f.chat.snapshot().sending, false);
});

test('failed send keeps the original draft and permits retry with unique local row identities', async () => {
  let requests = 0; const f = fixture({sendPrivateMessage: async () => {
    if (++requests === 1) throw Error('offline'); return {ok: true};
  }});
  await f.open(); f.chat.setDraft('hello'); await f.chat.send();
  assert.equal(f.chat.snapshot().draft, 'hello'); assert.equal(f.chat.snapshot().sending, false);
  await f.chat.send(); f.chat.setDraft('again'); await f.chat.send();
  const local = f.chat.source.getAll().slice(1);
  assert.equal(new Set(local.map(identity.privateMessageIdentity)).size, 2);
  assert.equal(f.chat.snapshot().draft, ''); assert.deepEqual(f.toasts, ['发送失败，请检查网络']);
});

test('first history response retains messages sent successfully while it was waiting', async () => {
  const response = deferred(), f = fixture({getPrivateMessages: () => response.promise});
  const opening = f.open(); f.chat.setDraft('new'); await f.chat.send();
  response.resolve(messages([message('100')])); await opening;
  assert.deepEqual(f.chat.source.getAll().map(item => item.text), ['hello', 'new']);
});

test('report confirmation binds the opened peer and rejects an old conversation or account', async () => {
  const requests = [], f = fixture({reportImMessage: async (...args) => {requests.push(args); return {ok: true};}});
  await f.open(); const old = f.chat.captureAction();
  await f.open(session(6, '20')); await f.chat.report(old, 6, '垃圾广告');
  const fresh = f.chat.captureAction(); await f.chat.report(fresh, 8, '人身攻击');
  f.auth.version++; await f.chat.report(fresh, 7, '骚扰');
  assert.deepEqual(requests, [[6, 8, '人身攻击']]); assert.deepEqual(f.toasts, ['已提交举报，感谢反馈']);
});

test('report failure after leaving is silent and published chat snapshots cannot mutate controller state', async () => {
  const response = deferred(), f = fixture({reportImMessage: () => response.promise});
  await f.open(); const snapshot = f.chat.snapshot(); snapshot.current.talkerId = 999; snapshot.draft = 'external';
  assert.equal(f.chat.snapshot().current.talkerId, 5); assert.equal(f.chat.snapshot().draft, '');
  const reporting = f.chat.report(f.chat.captureAction(), 6, '垃圾广告'); f.chat.close();
  response.reject(Error('offline')); await reporting; assert.deepEqual(f.toasts, []);
});

test('restored cookie session can finish loading and acquire its sender id when nav arrives later', async () => {
  const response = deferred(), sent = [], f = fixture({getPrivateMessages: () => response.promise,
    sendPrivateMessage: async (...args) => {sent.push(args); return {ok: true};}});
  f.user.current = null; f.list.activate(); f.list.source.reset([session(5, '100')]);
  const opening = f.open(); f.user.current = {mid: 7};
  response.resolve(messages([message('100')])); await opening;
  assert.equal(f.chat.snapshot().loading, false); assert.equal(f.chat.source.totalCount(), 1);
  f.chat.setDraft('hello'); await f.chat.send();
  assert.deepEqual(sent, [[7, 5, 'hello']]);
});
