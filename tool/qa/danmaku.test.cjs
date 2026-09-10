// Run actual ArkTS service code with fake platform boundaries. No network, credentials or device required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceOverride = process.env.ARKTS_TEST_SOURCE_ROOT;
function readSource(filename) {
  const override = sourceOverride && path.join(sourceOverride, path.relative(root, filename));
  return fs.readFileSync(override && fs.existsSync(override) ? override : filename, 'utf8');
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
      throw new Error('Missing platform mock: ' + name);
    };
    new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage', code)(
      localRequire, module, module.exports,
      { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
      { persistProp() {} }
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
  return env.load('common/DanmakuProto').parseDanmakuSegment;
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
