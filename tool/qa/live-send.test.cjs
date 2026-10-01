const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const ROOT = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
const ANCHORS = [['  aboutToAppear():', '  async loadRoom():'], ['  async sendDanmaku(', '  appendMessage(']];
function deferred() {let resolve, reject; const promise = new Promise((yes, no) => {resolve = yes; reject = no;}); return {promise, resolve, reject};}
function fixture() {
  const source = fs.readFileSync(path.join(ROOT, 'pages/LiveRoom.ets'), 'utf8').replace(/\r\n/g, '\n');
  const methods = ANCHORS.map(([a, b]) => {const begin = source.indexOf(a), end = source.indexOf(b, begin); assert.ok(begin >= 0 && end > begin); return source.slice(begin, end);}).join('\n');
  const code = ts.transpileModule('class Harness {\n' + methods + '\n}; return Harness;', {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  const calls = [], notices = [], messages = [], appended = []; let scrolls = 0;
  const user = {current: {uname: 'viewer'}};
  const Harness = new Function('LiveApi', 'LiveChatMessage', 'UserStore', 'Immersive', code)(
    {sendLiveDanmaku: (...args) => {const pending = deferred(); calls.push({args, ...pending}); return pending.promise;}},
    class {constructor() {this.emotes = []; }}, user, {setKeepScreenOn() {}});
  const page = new Harness();
  Object.assign(page, {draft: 'original', sending: false, destroyed: false, lifecycleGeneration: 0, sendRequestId: 0,
    param: {roomId: 1}, roomInfo: {}, client: {close() {}}, flushTimer: -1, historyPollTimer: -1,
    pendingMsgs: [], knownMessageIds: new Set(), emotePanelOpen: true,
    liveFeed: {currentMessages: () => messages, publishMessages: value => {messages.splice(0, messages.length, ...value);}},
    appendChatMessages: batch => appended.push(...batch), scrollChatToEnd: () => {scrolls++;},
    getUIContext: () => ({getPromptAction: () => ({showToast: ({message}) => notices.push(message)})}),
    ensureLogin: () => true, loadRoom: async () => {}, loadEmoticons: async () => {}});
  page.aboutToAppear();
  return {page, calls, notices, messages, appended, scrolls: () => scrolls};
}
test('live send: normal success publishes once, clears submitted draft and releases lock', async () => {
  const f = fixture(); const p = f.page.sendDanmaku(); await f.page.sendDanmaku();
  assert.equal(f.calls.length, 1); assert.equal(f.page.sending, true);
  f.calls[0].resolve({ok: true}); await p;
  assert.equal(f.messages.length, 1); assert.equal(f.messages[0].text, 'original'); assert.equal(f.appended.length, 1);
  assert.equal(f.page.draft, ''); assert.equal(f.page.sending, false); assert.equal(f.scrolls(), 1);
});
test('live send: editing draft in flight preserves the new text after success', async () => {
  const f = fixture(); const p = f.page.sendDanmaku(); f.page.draft = 'new draft';
  f.calls[0].resolve({ok: true}); await p;
  assert.equal(f.messages[0].text, 'original'); assert.equal(f.page.draft, 'new draft'); assert.equal(f.page.sending, false);
});
for (const result of ['success', 'failure', 'rejection']) {
  test(`live send: late ${result} after exit stays silent and preserves draft`, async () => {
    const f = fixture(); const p = f.page.sendDanmaku(); f.page.aboutToDisappear(); f.page.draft = 'new draft';
    if (result === 'rejection') f.calls[0].reject(new Error('offline'));
    else f.calls[0].resolve({ok: result === 'success', message: 'denied'});
    await p; assert.deepEqual(f.messages, []); assert.deepEqual(f.notices, []); assert.equal(f.page.draft, 'new draft');
  });
  test(`live send: old ${result} after room re-entry cannot publish or release a newer lock`, async () => {
    const f = fixture(); const old = f.page.sendDanmaku(); f.page.aboutToDisappear();
    f.page.param.roomId = 2; f.page.aboutToAppear(); f.page.draft = 'room two'; const next = f.page.sendDanmaku();
    assert.equal(f.calls.length, 2, 'new page can send without waiting for old network');
    if (result === 'rejection') f.calls[0].reject(new Error('offline'));
    else f.calls[0].resolve({ok: result === 'success', message: 'denied'});
    await old; assert.equal(f.page.sending, true); assert.equal(f.page.draft, 'room two'); assert.deepEqual(f.messages, []); assert.deepEqual(f.notices, []);
    f.calls[1].resolve({ok: true}); await next; assert.equal(f.page.sending, false); assert.equal(f.messages[0].text, 'room two'); assert.equal(f.calls[1].args[0], 2);
  });
}
test('live send: direct room change suppresses old result but releases its own lock', async () => {
  const f = fixture(); const p = f.page.sendDanmaku(); f.page.param.roomId = 2; f.page.draft = 'new room';
  f.calls[0].resolve({ok: true}); await p;
  assert.deepEqual(f.messages, []); assert.deepEqual(f.notices, []); assert.equal(f.page.draft, 'new room'); assert.equal(f.page.sending, false);
});
test('live send: sync generation invalidates result without leaving sending busy', async () => {
  const f = fixture(); const p = f.page.sendDanmaku(); f.page.lifecycleGeneration++;
  f.calls[0].resolve({ok: true}); await p; assert.deepEqual(f.messages, []); assert.deepEqual(f.notices, []); assert.equal(f.page.sending, false);
});
for (const rejection of [false, true]) test(`live send: current ${rejection ? 'network' : 'API'} failure preserves text and permits retry`, async () => {
  const f = fixture(); const p = f.page.sendDanmaku(); f.page.draft = 'edited';
  if (rejection) f.calls[0].reject(new Error('offline')); else f.calls[0].resolve({ok: false, message: 'denied'});
  await p; assert.equal(f.page.draft, 'edited'); assert.equal(f.page.sending, false); assert.equal(f.notices.length, 1); assert.deepEqual(f.messages, []);
  const next = f.page.sendDanmaku(); f.calls[1].resolve({ok: true}); await next; assert.equal(f.messages[0].text, 'edited');
});
test('live send: exited page cannot start a request', async () => {
  const f = fixture(); f.page.aboutToDisappear(); const pending = f.page.sendDanmaku(); assert.equal(f.calls.length, 0); await pending;
});
test('live send: normal emote payload and local representation remain intact', async () => {
  const f = fixture(); f.page.draft = ''; const emote = {emoji: 'smile', unique: 'official_smile'};
  const p = f.page.sendDanmaku(emote); assert.equal(f.calls[0].args[2], emote);
  f.calls[0].resolve({ok: true}); await p; assert.equal(f.messages[0].text, 'smile'); assert.deepEqual(f.messages[0].emotes, [emote]); assert.equal(f.page.emotePanelOpen, false);
});

test('live send: re-entering the same room also invalidates the old success', async () => {
  const f = fixture(); const old = f.page.sendDanmaku(); f.page.aboutToDisappear(); f.page.aboutToAppear();
  f.page.draft = 'same room new draft'; const next = f.page.sendDanmaku();
  f.calls[0].resolve({ok: true}); await old;
  assert.equal(f.page.sending, true); assert.deepEqual(f.messages, []); assert.equal(f.page.draft, 'same room new draft');
  f.calls[1].resolve({ok: true}); await next; assert.equal(f.messages[0].text, 'same room new draft');
});
test('live send: old completion after a newer success leaves subsequent draft and feed intact', async () => {
  const f = fixture(); const old = f.page.sendDanmaku(); f.page.aboutToDisappear(); f.page.aboutToAppear();
  f.page.draft = 'new submission'; const next = f.page.sendDanmaku(); f.calls[1].resolve({ok: true}); await next;
  f.page.draft = 'third draft'; f.calls[0].resolve({ok: true}); await old;
  assert.equal(f.messages.length, 1); assert.equal(f.messages[0].text, 'new submission'); assert.equal(f.page.draft, 'third draft'); assert.equal(f.notices.length, 1);
});
