const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const ROOT = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
function fixture() {
  const source = fs.readFileSync(path.join(ROOT, 'pages/LiveRoom.ets'), 'utf8').replace(/\r\n/g, '\n');
  const start = source.indexOf('  private appendChatMessages(');
  const end = source.indexOf('  /** 全屏切换', start);
  assert.ok(start >= 0 && end > start, 'production chat method anchors');
  const code = ts.transpileModule('class Harness {\n' + source.slice(start, end) + '\n}; return Harness;', {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  let now = 0, sequence = 0, count = 10;
  const timers = [], scrolls = [];
  const Harness = new Function('setTimeout', 'ScrollAlign', 'Edge', code)((callback, delay) => {timers.push({callback, time: now + delay, sequence: sequence++}); return sequence;}, {END: 'end'}, {End: 'end'});
  const page = new Harness();
  Object.assign(page, {destroyed: false, lifecycleGeneration: 1, chatAtBottom: true, pendingMsgs: [],
    liveFeed: {currentMessages: () => [], publishMessages() {}},
    chatSource: {totalCount: () => count, append: batch => {count += batch.length;}, trimHead: n => {count -= n;}},
    chatScroller: {scrollToIndex: index => scrolls.push(index), scrollEdge() {}}});
  function advance(ms) {
    const until = now + ms;
    timers.sort((a, b) => a.time - b.time || a.sequence - b.sequence);
    while (timers.length && timers[0].time <= until) {const t = timers.shift(); now = t.time; t.callback();}
    now = until;
  }
  return {page, advance, scrolls, setCount: n => {count = n;}};
}
test('chat: reading history before delayed scroll prevents follow and preserves intent', () => {
  const {page, advance, scrolls} = fixture(); page.pendingMsgs = [{}]; page.flushMessages();
  page.chatAtBottom = false; advance(150);
  assert.deepEqual(scrolls, []); assert.equal(page.chatAtBottom, false);
});
test('chat: scrolling up between layout passes prevents the second jump', () => {
  const {page, advance, scrolls} = fixture(); page.scrollChatToEnd(); advance(40);
  page.chatAtBottom = false; advance(100); assert.deepEqual(scrolls, [9]);
});
for (const reenter of [false, true]) test(`chat: ${reenter ? 're-entry' : 'exit'} invalidates previous scheduled callbacks`, () => {
  const {page, advance, scrolls} = fixture(); page.scrollChatToEnd(true);
  page.destroyed = true; page.lifecycleGeneration++;
  if (reenter) {page.destroyed = false; page.lifecycleGeneration++;}
  advance(500); assert.deepEqual(scrolls, []);
});
test('chat: room synchronization invalidates old callbacks but keeps new ones', () => {
  const {page, advance, scrolls} = fixture(); page.scrollChatToEnd(true);
  page.lifecycleGeneration++; page.scrollChatToEnd(); advance(500);
  assert.deepEqual(scrolls, [9, 9]);
});
test('chat: message burst while reading history never scrolls', () => {
  const {page, advance, scrolls} = fixture(); page.pendingMsgs = [{}]; page.flushMessages();
  page.chatAtBottom = false;
  for (let i = 0; i < 5; i++) {page.pendingMsgs = [{}]; page.flushMessages();}
  advance(500); assert.deepEqual(scrolls, []); assert.equal(page.chatAtBottom, false);
});
test('chat: returning to bottom resumes follow using the newest message index', () => {
  const {page, advance, scrolls} = fixture(); page.chatAtBottom = false; page.pendingMsgs = [{}]; page.flushMessages();
  advance(150); assert.deepEqual(scrolls, []);
  page.chatAtBottom = true; page.pendingMsgs = [{}, {}]; page.flushMessages(); advance(150);
  assert.deepEqual(scrolls, [12, 12]);
});
test('chat: initial layout still settles and empty lists do not scroll', () => {
  const {page, advance, scrolls, setCount} = fixture(); page.scrollChatToEnd(true); advance(500);
  assert.deepEqual(scrolls, [9, 9, 9]); setCount(0); page.scrollChatToEnd(); advance(150);
  assert.deepEqual(scrolls, [9, 9, 9]);
});
