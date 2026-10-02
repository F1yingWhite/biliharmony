const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const { createArktsLoader } = require('./arkts-module.cjs');
const ROOT = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');
function fixture() {
  const source = fs.readFileSync(path.join(ROOT, 'pages/LiveRoom.ets'), 'utf8').replace(/\r\n/g, '\n');
  const start = source.indexOf('  private scrollChatToEnd(');
  const end = source.indexOf('  /** 全屏切换', start);
  assert.ok(start >= 0 && end > start, 'production chat method anchors');
  const code = ts.transpileModule('class Harness {\n' + source.slice(start, end) + '\n}; return Harness;', {compilerOptions: {target: ts.ScriptTarget.ES2020}}).outputText;
  let now = 0, sequence = 0;
  const timers = [], scrolls = [];
  const Harness = new Function('setTimeout', 'ScrollAlign', 'Edge', code)((callback, delay) => {timers.push({callback, time: now + delay, sequence: sequence++}); return sequence;}, {END: 'end'}, {End: 'end'});
  const page = new Harness();
  Object.assign(page, {destroyed: false, lifecycleGeneration: 1, chatAtBottom: true,
    chatScroller: {scrollToIndex: index => scrolls.push(index), scrollEdge() {}}});
  function advance(ms) {
    const until = now + ms;
    timers.sort((a, b) => a.time - b.time || a.sequence - b.sequence);
    while (timers.length && timers[0].time <= until) {const t = timers.shift(); now = t.time; t.callback();}
    now = until;
  }
  // The native scroll scheduler and buffer scheduler have independent fake clocks:
  // append() advances one real production 220ms batch before checking UI layout passes.
  let batchId=0;
  const batches=new Map();
  const load=createArktsLoader({globals:{setTimeout:callback=>{
    const id=++batchId;batches.set(id,callback);return id;
  },clearTimeout:id=>batches.delete(id)}});
  const {LiveChatBuffer}=load('components/live/LiveChatBuffer');
  const buffer=new LiveChatBuffer({resetMessages(){},publishMessages(){},publishSuperChats(){}},
    baseline=>{if(page.chatAtBottom)page.scrollChatToEnd(baseline);},()=>{});
  let id=0;
  const message=()=>({id:'msg-'+id++,type:'danmaku'});
  buffer.activate(()=>!page.destroyed);
  buffer.establishBaseline(Array.from({length:10},message));
  page.chatSource=buffer.source;timers.length=0;
  const append=n=>{
    for(let i=0;i<n;i++)buffer.append(message());
    for(const [id,callback] of [...batches]){batches.delete(id);callback();}
  };
  return {page, append, advance, scrolls, setCount:n=>buffer.source.reset(Array.from({length:n},message))};
}
test('chat: reading history before delayed scroll prevents follow and preserves intent', () => {
  const {page, append, advance, scrolls} = fixture(); append(1);
  page.chatAtBottom = false; advance(150);
  assert.deepEqual(scrolls, []); assert.equal(page.chatAtBottom, false);
});
test('chat: scrolling up between layout passes prevents the second jump', () => {
  const {page, append, advance, scrolls} = fixture(); page.scrollChatToEnd(); advance(40);
  page.chatAtBottom = false; advance(100); assert.deepEqual(scrolls, [9]);
});
for (const reenter of [false, true]) test(`chat: ${reenter ? 're-entry' : 'exit'} invalidates previous scheduled callbacks`, () => {
  const {page, append, advance, scrolls} = fixture(); page.scrollChatToEnd(true);
  page.destroyed = true; page.lifecycleGeneration++;
  if (reenter) {page.destroyed = false; page.lifecycleGeneration++;}
  advance(500); assert.deepEqual(scrolls, []);
});
test('chat: room synchronization invalidates old callbacks but keeps new ones', () => {
  const {page, append, advance, scrolls} = fixture(); page.scrollChatToEnd(true);
  page.lifecycleGeneration++; page.scrollChatToEnd(); advance(500);
  assert.deepEqual(scrolls, [9, 9]);
});
test('chat: message burst while reading history never scrolls', () => {
  const {page, append, advance, scrolls} = fixture(); append(1);
  page.chatAtBottom = false;
  for (let i = 0; i < 5; i++) {append(1);}
  advance(500); assert.deepEqual(scrolls, []); assert.equal(page.chatAtBottom, false);
});
test('chat: returning to bottom resumes follow using the newest message index', () => {
  const {page, append, advance, scrolls} = fixture(); page.chatAtBottom = false; append(1);
  advance(150); assert.deepEqual(scrolls, []);
  page.chatAtBottom = true; append(2); advance(150);
  assert.deepEqual(scrolls, [12, 12]);
});
test('chat: initial layout still settles and empty lists do not scroll', () => {
  const {page, advance, scrolls, setCount} = fixture(); page.scrollChatToEnd(true); advance(500);
  assert.deepEqual(scrolls, [9, 9, 9]); setCount(0); page.scrollChatToEnd(); advance(150);
  assert.deepEqual(scrolls, [9, 9, 9]);
});
