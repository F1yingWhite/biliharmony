// Run actual ArkTS service code with fake platform boundaries. No network, credentials or device required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {fixture: playbackFixture} = require('./player-session-fixture.cjs');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceOverride = process.env.ARKTS_TEST_SOURCE_ROOT;
function readSource(filename) {
  const override = sourceOverride && path.join(sourceOverride, path.relative(root, filename));
  // .ets 是 CRLF 检出，锚点按 \n 书写：统一归一为 LF，避免跨行锚点静默失配。
  return fs.readFileSync(override && fs.existsSync(override) ? override : filename, 'utf8')
    .replace(/\r\n/g, '\n');
}
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

function environment(mocks = {}) {
  const cache = new Map();
  const storage = new Map();
  function compile(source, filename) {
    const module = { exports: {} };
    const code = ts.transpileModule(source, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const localRequire = name => {
      if (name.startsWith('.')) {
        return load(path.relative(root, path.resolve(path.dirname(filename), name)).replaceAll('\\', '/'));
      }
      if (name in mocks) return mocks[name];
      // LiveDanmakuClient 等模块引用 hilog：Node 沙箱以静默实现兜底。
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework: {} };
      if (name === '@kit.ArkWeb') return { webview: {} };
      if (name === '@kit.PerformanceAnalysisKit') {
        const noop = () => {};
        return { hilog: { debug: noop, info: noop, warn: noop, error: noop } };
      }
      throw new Error('Missing platform mock: ' + name);
    };
    // Sendable/Concurrent 是 ArkTS 编译期语义（跨线程共享/并发任务）；Node 沙箱里以恒等装饰器替代。
    new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage', 'Sendable', 'Concurrent', code)(
      localRequire, module, module.exports,
      { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
      { persistProp() {} },
      (target) => target,
      (target) => target
    );
    return module.exports;
  }
  function load(name) {
    name = name.replace(/\.ets$/, '');
    if (name in mocks) return mocks[name];
    if (!cache.has(name)) {
      const filename = path.join(root, name + '.ets');
      cache.set(name, compile(readSource(filename), filename));
    }
    return cache.get(name);
  }
  // Extract the unchanged production method body; ArkUI's build DSL is verified separately by CompileArkTS.
  function methodHarness(file, start, end, imports = '') {
    const source = readSource(path.join(root, file + '.ets'));
    const begin = source.indexOf(start);
    const finish = source.indexOf(end, begin);
    assert.ok(begin >= 0 && finish > begin);
    return compile(imports + '\nexport class Harness {\n' + source.slice(begin, finish) + '\n}',
      path.join(root, file + '.ets')).Harness;
  }
  return { load, storage, methodHarness };
}

function dm(id,time=10,mode=1,text='弹幕') {
  return {id,idStr:String(id),time,mode,text,color:16777215,fontsize:25,weight:10};
}
function engine(density=30) {
  const env=environment({'api/BiliApi':{}});
  const Engine=env.load('components/player/PlayerDanmakuEngine').PlayerDanmakuEngine;
  const ctx={measureText:text=>({width:text.length*24}),clearRect(){},strokeText(){},fillText(){}};
  const e=new Engine(ctx);e.fullscreen=true;e.width=844;e.height=391;e.density=density;
  return e;
}

function pausedCanvasFixture() {
  const syncs = [], pixels = [];
  const env = environment({'api/BiliApi': {}, '@kit.ArkGraphics2D': {displaySync: {create() {
    const sync = {setExpectedFrameRateRange() {}, start() {}, stop() {},
      on(_event, callback) {this.callback = callback;}, off() {this.callback = null;}};
    syncs.push(sync);
    return sync;
  }}}});
  const Engine = env.load('components/player/PlayerDanmakuEngine').PlayerDanmakuEngine;
  const Clock = env.load('components/player/PlayerDanmakuClock').PlayerDanmakuClock;
  const Harness = env.methodHarness('components/player/PlayerView',
    '  togglePlay(): void {', '  /** UI 的结束画面');
  const Events = env.methodHarness('components/player/PlayerView',
    '  private onPlaybackEvent(', '  private onPlaybackProgress(', 'const Immersive = {setKeepScreenOn() {}};');
  const ctx = {measureText: text => ({width: text.length * 12}),
    clearRect() {pixels.length = 0;}, strokeText() {},
    fillText(text, x, y) {pixels.push({text, x, y});}};
  const e = new Engine(ctx);
  Object.assign(e, {width: 844, height: 391, fullscreen: true, density: 30, lastPlayerTime: 10});
  e.list = [dm(1, 10, 1, '滚动'), dm(2, 10, 6, '逆向'), dm(3, 10, 5, '顶部'),
    dm(4, 10, 4, '底部'), dm(5, 10, 1, '已固定')];
  e.spawn(10);
  e.active.forEach((item, index) => {if (!item.isFixed) item.x = 180 + index * 30;});
  e.pinned = e.active.find(item => item.item.id === 5);
  const view = new Harness();
  let pauseRequests = 0, pinClears = 0;
  Object.assign(view, {playing: true, prepared: true,
    appInBackground: false, danmakuOn: true, danmakuFixedHeight: e.height, ctx,
    onPlaybackEvent: Events.prototype.onPlaybackEvent,
    onPlayingChange() {}, updateAVSessionPlaybackState() {}});
  const clock = new Clock({isPlaying: () => view.playing,
    isDanmakuOn: () => view.danmakuOn && !view.appInBackground, getFrameRate: () => 60,
    getEngine: () => e, clearPinned() {pinClears++; e.pinned = null;}});
  view.dmClock = clock;
  const playback = playbackFixture();
  playback.session.activate(playback.source());
  playback.session.pair.video = {state: 'playing', setVolume() {}, pause() {pauseRequests++; return Promise.resolve();}};
  playback.session.pair.prepared = true;
  playback.session.state.prepared = true;
  playback.session.state.playing = true;
  playback.session.observer.state = state => {view.playing = state.playing;};
  playback.session.observer.event = event => view.onPlaybackEvent(event);
  view.playback = playback.session;
  clock.start();
  syncs[0].callback({timestamp: 1_000_000_000});
  syncs[0].callback({timestamp: 1_200_000_000});
  const positions = () => e.active.map(item => ({id: item.item.id, x: item.x, lane: item.lane,
    fixedUntil: item.fixedUntil, born: item.born}));
  return {env, e, clock, ctx, view, pixels, syncs, positions,
    pauseRequests: () => pauseRequests, pinClears: () => pinClears};
}

// Execute the production Canvas modifier chain to capture its real lifecycle callback.
// ArkUI clears the backing buffer before onReady on creation and native size changes.
function bindProductionCanvasReady(view) {
  const source = readSource(path.join(root, 'components/player/PlayerView.ets'));
  const begin = source.indexOf('        Canvas(this.ctx)');
  const end = source.indexOf("\n      }\n      .id('qa_player_danmaku_viewport')", begin);
  assert.ok(begin >= 0 && end > begin, 'player Canvas modifier chain must be present');
  const code = ts.transpileModule('function bindCanvas() {\n' + source.slice(begin, end) + '\n}', {
    compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
  }).outputText;
  let ready;
  const canvas = {id() {return this;}, width() {return this;}, height() {return this;},
    hitTestBehavior() {return this;}, onReady(callback) {ready = callback; return this;}};
  new Function('Canvas', 'HitTestMode', code + '\nreturn bindCanvas;')(
    () => canvas, {None: 0}).call(view);
  assert.equal(typeof ready, 'function', 'Canvas must restore its pixels after native buffer clears');
  return ready;
}

test('first user pause freezes and restores visible danmaku before the native paused event', () => {
  const f = pausedCanvasFixture();
  const positions = f.positions(), pixels = f.pixels.slice(), pinned = f.e.pinned, cursor = f.e.cursor;
  assert.equal(pixels.length, 5);
  f.ctx.clearRect();
  f.view.togglePlay(); // The fake player submits pause but emits no stateChange yet.
  assert.equal(f.pauseRequests(), 1);
  assert.equal(f.view.playing, false);
  assert.equal(f.clock.isRunning(), false, 'stop the frame source at the user action');
  assert.deepEqual(f.pixels, pixels, 'retain scroll, reverse, top, bottom and pinned text');
  assert.deepEqual(f.positions(), positions);
  assert.equal(f.e.cursor, cursor);
  assert.equal(f.e.pinned, pinned);
  f.syncs[0].callback({timestamp: 8_000_000_000});
  assert.deepEqual(f.positions(), positions, 'a queued frame cannot move paused comments');
  f.clock.release();
});

test('Canvas onReady restores the paused frame after initial and later native buffer resets', () => {
  const f = pausedCanvasFixture();
  f.view.playing = false;
  f.clock.pause();
  const ready = bindProductionCanvasReady(f.view);
  const pixels = f.pixels.slice(), positions = f.positions(), cursor = f.e.cursor;
  for (let reset = 0; reset < 2; reset++) {
    f.ctx.clearRect();
    assert.equal(f.pixels.length, 0);
    ready();
    assert.deepEqual(f.pixels, pixels);
    assert.deepEqual(f.positions(), positions);
    assert.equal(f.e.cursor, cursor);
    assert.equal(f.clock.isRunning(), false);
  }
  f.clock.release();
});

test('resuming after a long pause excludes paused wall time from movement and keeps pinned text frozen', () => {
  const f = pausedCanvasFixture();
  f.view.playing = false;
  f.clock.pause();
  const positions = f.positions(), cursor = f.e.cursor, pinned = f.e.pinned;
  f.view.playing = true;
  f.clock.start();
  f.syncs[0].callback({timestamp: 31_200_000_000});
  assert.deepEqual(f.positions(), positions, 'the first resumed frame starts a fresh time baseline');
  f.syncs[0].callback({timestamp: 31_220_000_000});
  for (const item of f.e.active) {
    const old = positions.find(position => position.id === item.item.id);
    const expected = item.isFixed || item === pinned ? old.x :
      old.x + (item.reverse ? 1 : -1) * item.speed * 0.02;
    assert.ok(Math.abs(item.x - expected) < 1e-8);
  }
  assert.equal(f.e.cursor, cursor);
  assert.equal(f.e.pinned, pinned);
  f.clock.release();
});

test('Canvas recovery respects hidden and background states and clock teardown preserves clear semantics', () => {
  const f = pausedCanvasFixture(), ready = bindProductionCanvasReady(f.view);
  f.view.playing = false;
  f.clock.pause();
  const positions = f.positions();
  for (const hidden of ['danmakuOff', 'background']) {
    f.view.danmakuOn = hidden !== 'danmakuOff';
    f.view.appInBackground = hidden === 'background';
    f.ctx.clearRect();
    ready();
    f.clock.pause();
    assert.equal(f.pixels.length, 0);
    assert.deepEqual(f.positions(), positions);
  }
  f.view.danmakuOn = true;
  f.view.appInBackground = false;
  ready();
  const pixels = f.pixels.slice();
  f.clock.release();
  assert.deepEqual(f.pixels, pixels, 'release detaches the clock without erasing the retained frame');
  assert.deepEqual(f.positions(), positions);
  f.clock.stop(false);
  assert.equal(f.pixels.length, 0);
  assert.deepEqual(f.positions(), positions, 'stop(false) clears pixels but retains active comments');
  assert.equal(f.pinClears(), 0);
  ready();
  assert.deepEqual(f.pixels, pixels);
  f.clock.stop(true);
  assert.equal(f.pixels.length, 0);
  assert.equal(f.e.active.length, 0);
  assert.equal(f.e.pinned, null);
  assert.equal(f.pinClears(), 1);
  ready();
  assert.equal(f.pixels.length, 0, 'empty active state stays clear');
});

test('overlap density displays all 180 simultaneous comments without 24-per-update or 96-onscreen caps',()=>{
  const e=engine();e.list=Array.from({length:180},(_,i)=>dm(i+1));
  e.spawn(10);
  assert.equal(e.active.length,180);assert.equal(e.cursor,180);
  assert.equal(new Set(e.active.map(x=>x.item.idStr)).size,180);
});

test('fixed comments use more than three rows and scrolling does not reserve their slots',()=>{
  const e=engine(22);
  e.list=Array.from({length:12},(_,i)=>dm(i+1,10,1));e.spawn(10);
  e.list.push(...Array.from({length:12},(_,i)=>dm(i+13,10,5)));
  e.spawn(10);
  const fixed=e.active.filter(x=>x.isFixed);
  assert.equal(fixed.length,12);assert.equal(new Set(fixed.map(x=>x.lane)).size,12);
  assert.equal(e.active.filter(x=>!x.isFixed).length,12);
});

test('bottom fixed comments grow upwards beyond three rows',()=>{
  const e=engine(22);e.list=Array.from({length:12},(_,i)=>dm(i+1,10,4));e.spawn(10);
  assert.equal(e.active.length,12);
  assert.equal(new Set(e.active.map(x=>x.lane)).size,12);
  assert.ok(e.active[0].lane>e.active[11].lane);
});

test('filtered comments do not consume the update budget of visible comments',()=>{
  const e=engine();e.blockColorDm=true;
  e.list=[...Array.from({length:400},(_,i)=>({...dm(i+1),color:255})),
    ...Array.from({length:20},(_,i)=>dm(i+401))];
  e.spawn(10);
  assert.equal(e.active.length,20);assert.equal(e.cursor,420);
  assert.ok(e.active.every(x=>x.item.color===16777215));
});

test('high density keeps the timeline: old comments are skipped and future comments are not shown early',()=>{
  const e=engine();e.list=[dm(1,8),dm(2,9.4),dm(3,10),dm(4,12)];e.spawn(10);
  assert.deepEqual(e.active.map(x=>x.item.id),[2,3]);assert.equal(e.cursor,3);
  e.spawn(10.2);assert.equal(e.active.length,2);
});

test('more density permits later catch-up overlap while normal keeps collision avoidance',()=>{
  const e=engine(22);e.width=1000;e.height=60;e.list=[dm(1)];e.spawn(10);
  const first=e.active[0];first.x=600;first.textWidth=200;first.speed=50;e.rebuildLaneBuckets();
  assert.equal(e.laneSafeForScroll(first.lane,1014,180),false);
  e.density=27;
  assert.equal(e.laneSafeForScroll(first.lane,1014,180),true);
  assert.equal(e.laneSafeForScroll(first.lane,801,180),false); // entry overlap is still avoided
});

test('fixed comments do not block a scrolling or reverse lane',()=>{
  const e=engine(22);e.height=60;e.list=[dm(1,10,5)];e.spawn(10);e.rebuildLaneBuckets();
  assert.equal(e.laneSafeForScroll(0,2862,300),true);
  assert.equal(e.laneSafeForReverse(0,-20,300),true);
});

function varint(n) {const bytes=[];do{let b=n&127;n=Math.floor(n/128);bytes.push(b|(n?128:0));}while(n);return bytes;}
function bytesField(field,bytes) {return [...varint((field<<3)|2),...varint(bytes.length),...bytes];}
function intField(field,n) {return [...varint(field<<3),...varint(n)];}
function protoParser() {
  const env=environment({'@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:b=>new TextDecoder().decode(b)})}}}});
  // 解析核心已迁至 taskpool 任务文件（DanmakuProto 的 @Concurrent 薄封装）；纯函数在 DanmakuProtoCore。
  return env.load('common/DanmakuProtoCore').decodeDanmakuSegBuffer;
}

test('protobuf unknown length-delimited fields cannot swallow subsequent comments or their content',()=>{
  const parse=protoParser();
  const comment=(id,text)=>bytesField(1,[...intField(1,id),...intField(2,10000),
    ...bytesField(30,[7,8,9]),...bytesField(7,new TextEncoder().encode(text))]);
  const wire=new Uint8Array([...bytesField(20,new Array(130).fill(0)),...comment(1,'第一条'),...comment(2,'第二条')]);
  const items=parse(wire.buffer);
  assert.deepEqual(items.map(x=>x.text),['第一条','第二条']);
  assert.deepEqual(items.map(x=>x.time),[10,10]);
});


test('video danmaku use vp font and a line pitch close to the visible glyph height',()=>{
  const e=engine(22);
  assert.equal(e.fontSize(),14);
  assert.ok(e.lineHeight()>=e.fontSize() && e.lineHeight()<e.fontSize()*1.2);
  assert.ok(e.laneCount()>=20,'phone landscape should have at least 20 rows, not about 8');
  e.measure('文字',14);assert.equal(e.ctx.font,'600 14vp sans-serif');
});

function liveRenderer(density=22) {
  const env=environment({'@kit.ImageKit':{image:{}},'services/network/HttpClient':{HttpClient:{}}});
  const Renderer=env.load('components/live/LiveDanmakuRenderer').LiveDanmakuRenderer;
  const ctx={measureText:text=>({width:text.length*7}),clearRect(){},strokeText(){},fillText(){}};
  const renderer=new Renderer(ctx);renderer.width=844;renderer.height=391;renderer.fullscreen=true;renderer.density=density;
  return renderer;
}

test('live danmaku use vp line spacing and can display more than the density selector value',()=>{
  const r=liveRenderer(22);const timestamp=Math.floor(Date.now()/1000);
  r.pending=Array.from({length:40},(_,i)=>({id:String(i),timestamp,text:'实时弹幕',emotes:[],type:'danmaku'}));
  r.drainQueue();
  assert.ok(r.active.length>22);assert.ok(r.lineHeight()<17);assert.equal(r.ctx.font,'600 14vp sans-serif');
});

test('live overlap density drains a burst without the old 30-active and 48-pending limits',()=>{
  const r=liveRenderer(30);const timestamp=Math.floor(Date.now()/1000);
  r.pending=Array.from({length:180},(_,i)=>({id:String(i),timestamp,text:'实时弹幕',emotes:[],type:'danmaku'}));
  r.drainQueue();assert.equal(r.active.length,180);assert.equal(r.pending.length,0);
});

// 用户报告：直播间永远显示「重连中」而聊天靠历史轮询兜底照常流动。根因：解码核心是
// 异步的（zlib 解压只有 Promise API），taskpool 任务返回未决 Promise 被真机运行时拒绝
// （Can't return Promise in pending state），异常被入队 catch 吞掉、鉴权永不完成。
// 现生产路径走长驻 Worker；当 Worker 不可用（创建失败/崩坏）时必须回退主线程同步解码，
// 保证 op=8 鉴权仍然完成（onConnected(true)）。
test('live danmaku auth completes via main-thread decode fallback when worker unavailable', async () => {
  const env = environment({
    '@kit.NetworkKit': { webSocket: {} },
    '@kit.BasicServicesKit': { BusinessError: class {}, zlib: {} },
    '@kit.ArkTS': { collections: { Array },
      worker: { ThreadWorker: class {
        constructor() { throw new Error('worker unavailable'); }
      } },
      util: {} },
    'api/BiliApi': { BiliApi: {} },
    'api/LiveApi': { LiveApi: {} },
    'services/network/HttpClient': { HttpClient: { getCookie: () => '' } },
  });
  const { LiveDanmakuClient } = env.load('common/LiveDanmakuClient');
  const client = new LiveDanmakuClient();
  const seen = [];
  client.onConnected = (value) => seen.push(value);
  client.closed = false;
  // op=8 鉴权回包：16 字节头（packetLength=16, headerLength=16, protocol=1, operation=8, seq=1）。
  const buffer = new ArrayBuffer(16);
  const view = new DataView(buffer);
  view.setUint32(0, 16); view.setUint16(4, 16); view.setUint16(6, 1);
  view.setUint32(8, 8); view.setUint32(12, 1);
  await client.decodeAndDispatch(buffer, client.generation);
  assert.deepEqual(seen, [true]);
  client.stopHeartbeat();
});

// 真机 jscrash：宿主侧 on('message') 回调在不同 API 版本下可能是 MessageEvent 包装
// （数据在 data 字段）也可能是裸响应；按裸数据取值时 events 为 undefined 直接崩掉应用。
test('worker message handler accepts both raw payload and MessageEvent envelope', () => {
  const env = environment({
    '@kit.NetworkKit': { webSocket: {} },
    '@kit.BasicServicesKit': { BusinessError: class {}, zlib: {} },
    '@kit.ArkTS': { collections: { Array }, worker: {}, util: {} },
    'api/BiliApi': { BiliApi: {} },
    'api/LiveApi': { LiveApi: {} },
    'services/network/HttpClient': { HttpClient: { getCookie: () => '' } },
  });
  const { LiveDanmakuClient } = env.load('common/LiveDanmakuClient');
  const client = new LiveDanmakuClient();
  const seen = [];
  client.onConnected = (value) => seen.push(value);
  client.closed = false;
  const response = { seq: 1, generation: 0, events: [{ operation: 8, payload: null }] };
  client.handleWorkerMessage(response);                     // 裸响应形态
  client.handleWorkerMessage({ data: response });           // MessageEvent 包装形态
  client.handleWorkerMessage({ data: { seq: 2 } });         // 坏包：不崩、不分发
  assert.deepEqual(seen, [true, true]);
  client.stopHeartbeat();
});


test('live history fallback renders only newly received messages after initial baseline', () => {
  const {LiveChatMessage} = environment().load('model/LiveModels');
  const old = LiveChatMessage.history({id_str: 'old', text: 'already on entry'});
  const fresh = LiveChatMessage.history({id_str: 'new', text: 'new fallback message'});
  const r = liveRenderer(22);
  r.setBaseline([old]);
  r.onMessagesChanged([old, fresh]);
  r.drainQueue();
  assert.deepEqual(r.active.map(item => item.message.id), [fresh.id]);
  r.onMessagesChanged([old, fresh]);
  r.drainQueue();
  assert.equal(r.active.length, 1);
});


test('independent spacing adjusts live and video row gaps without changing density or font size', () => {
  for (const renderer of [engine(22), liveRenderer(22)]) {
    const normal = renderer.lineHeight(), font = renderer.fontSize();
    renderer.setSpacing(0.5);
    const compact = renderer.lineHeight();
    renderer.setSpacing(2);
    assert.ok(compact < normal); assert.ok(renderer.lineHeight() > normal);
    assert.equal(renderer.fontSize(), font); assert.equal(renderer.density, 22);
    renderer.setSpacing(1); assert.equal(renderer.lineHeight(), normal);
  }
});
