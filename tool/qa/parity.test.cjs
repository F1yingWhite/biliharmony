// Run actual ArkTS service code with fake platform boundaries. No network, credentials or device required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
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

function searchHarness(data) {
  const calls=[];
  const env=environment({
    'common/WbiSign': {WbiSign:{async encWbi(){}}},
    'api/internal/ApiCommon':{webGet:async(url,params)=>{calls.push({url,params});return data;},
      webGetSigned:async(url,params)=>{calls.push({url,params});return data;},
      getData:x=>x,failureText:()=> 'Request failed'},
  });
  return {api:env.load('api/SearchApi').SearchApi,calls};
}

test('comprehensive search preserves mixed article/video results with default ordering',async()=>{
  const {api,calls}=searchHarness({result:[
    {result_type:'article',data:[{id:10,title:'Article',author:'Author'}]},
    {result_type:'video',data:[{aid:20,bvid:'BV20',title:'Video'}]},
  ]});
  const result=await api.searchAll('query',1);
  assert.deepEqual(result.sections.map(s=>s.type),['article','video']);
  assert.equal(result.sections[0].articles[0].id,10);
  assert.equal(result.sections[1].videos[0].aid,20);
  assert.equal(calls[0].params.keyword,'query');
});

for (const order of ['click','pubdate','dm','stow']) {
  test(`comprehensive search ${order} requests server ranking and forwards every filter`,async()=>{
    const {api,calls}=searchHarness({numResults:42,result:[{aid:20,bvid:'BV20',title:'Video'}]});
    const result=await api.searchAll('query',2,order,3,1000,21);
    assert.equal(result.sections[0].videos[0].aid,20);
    assert.equal(result.totals.get('video'),42);
    const params=calls[0].params;
    assert.equal(params.search_type,'video');assert.equal(params.order,order);
    assert.equal(params.page,'2');assert.equal(params.duration,'3');
    assert.equal(params.pubtime_begin_s,'1000');assert.equal(params.tids,'21');
  });
}

test('filtering default comprehensive search uses the video filter API',async()=>{
  const {api,calls}=searchHarness({numResults:0,result:[]});
  const result=await api.searchAll('query',1,'totalrank',1);
  assert.equal(calls[0].params.search_type,'video');
  assert.equal(result.sections.length,0);assert.equal(result.totals.get('video'),0);
});

function backgroundHarness(enabled,playing) {
  const env=environment();
  const Harness=env.methodHarness('components/player/PlayerView','  onAppBackgroundChanged():','  private setBackgroundPlayback(');
  const actions=[];
  const view=Object.assign(new Harness(),{appInBackground:true,backgroundPlaybackEnabled:enabled,playing,
    togglePlay(){actions.push('pause');},enterBackgroundAudioOnly(){actions.push('audio');},leaveBackgroundAudioOnly(){actions.push('foreground');}});
  return {view,actions};
}
test('disabled background playback pauses active playback and leaves already-paused playback alone',()=>{
  for (const playing of [true,false]) {
    const {view,actions}=backgroundHarness(false,playing);view.onAppBackgroundChanged();
    assert.deepEqual(actions,playing?['pause']:[]);
  }
});
test('enabled background playback enters audio mode and restores video on foreground',()=>{
  const {view,actions}=backgroundHarness(true,true);view.onAppBackgroundChanged();
  view.appInBackground=false;view.onAppBackgroundChanged();
  assert.deepEqual(actions,['audio','foreground']);
});
test('background playback choice updates reactive storage and persistent preference together',()=>{
  const writes=[];const env=environment({'common/AppTheme':{AppTheme:{persistBackgroundPlayback:v=>writes.push(v)}}});
  const Harness=env.methodHarness('components/player/PlayerView','  private setBackgroundPlayback(','  private enterBackgroundAudioOnly(',
    "import { AppTheme } from '../../common/AppTheme';");
  const view=new Harness();
  for (const value of [true,false]) {view.setBackgroundPlayback(value);assert.equal(env.storage.get('backgroundPlaybackEnabled'),value);}
  assert.deepEqual(writes,[true,false]);
});


test('search failure is distinct from a successful empty result',async()=>{
  const {api}=searchHarness(null);
  await assert.rejects(api.searchAll('query',1),/Request failed/);
  await assert.rejects(api.searchAll('query',1,'click'),/Request failed/);
});

test('live SC snapshot merge keeps newer messages and removes duplicate IDs',()=>{
  const env=environment();
  const Harness=env.methodHarness('pages/LiveRoom','  private mergeSuperChats(','  private startHistoryFallback(');
  const view=new Harness();
  const newest={id:'sc_2',text:'Newest',timestamp:20};
  const existing={id:'sc_1',text:'Already received',timestamp:10};
  const result=view.mergeSuperChats([newest,existing],[{...existing,text:'Stale copy'},{id:'sc_0',timestamp:1}]);
  assert.deepEqual(result.map(x=>x.id),['sc_2','sc_1','sc_0']);
  assert.equal(result[1].text,'Already received');
});

test('SC selection, countdown and expiry follow message deadlines',()=>{
  const env=environment();
  const Harness=env.methodHarness('components/live/LiveSuperChatShelf','  private refreshActive():','  @Builder',
    "import { LiveChatMessage } from '../../model/LiveModels';");
  const now=Math.floor(Date.now()/1000);
  const current={id:'new',endTime:now+65},expired={id:'old',endTime:now-1};
  const view=Object.assign(new Harness(),{messages:[current,expired],selectedId:'new'});
  view.refreshActive();assert.equal(view.selected().id,'new');
  assert.deepEqual(view.activeMessages.map(x=>x.id),['new']);
  assert.equal(view.remaining(current),'01:05');
  view.messages=[expired];view.refreshActive();
  assert.equal(view.selectedId,'');assert.equal(view.activeMessages.length,0);
});

test('SC model preserves end time and supports duration fallback',()=>{
  const {LiveChatMessage}=environment().load('model/LiveModels');
  assert.equal(LiveChatMessage.superChat({id:1,start_time:100,end_time:200,time:300}).endTime,200);
  assert.equal(LiveChatMessage.superChat({id:2,start_time:100,time:300}).endTime,400);
});


test('window insets follow asynchronous fullscreen hide and portrait restore events', () => {
  let top = 120;
  const listeners = new Map();
  const win = {
    on: (type, callback) => listeners.set(type, callback),
    getWindowAvoidArea: () => ({topRect: {height: top}, bottomRect: {height: 0}}),
  };
  const env = environment({'@kit.ArkUI': {
    display: {getDefaultDisplaySync: () => ({densityPixels: 3})},
    window: {AvoidAreaType: {TYPE_SYSTEM: 0}},
  }});
  const {Immersive} = env.load('common/Immersive');
  Immersive.attach({getMainWindowSync: () => win});
  assert.equal(env.storage.get(Immersive.STATUS_BAR_HEIGHT_KEY), 40);
  top = 0;
  listeners.get('avoidAreaChange')();
  assert.equal(env.storage.get(Immersive.STATUS_BAR_HEIGHT_KEY), 0);
  top = 120;
  listeners.get('avoidAreaChange')();
  assert.equal(env.storage.get(Immersive.STATUS_BAR_HEIGHT_KEY), 40);
  top = 150;
  listeners.get('windowSizeChange')();
  assert.equal(env.storage.get(Immersive.STATUS_BAR_HEIGHT_KEY), 50);
});


function liveClientHarness(getInfo, connectSocket = async () => {}) {
  const sockets = [];
  const env = environment({
    '@kit.NetworkKit': {webSocket: {createWebSocket() {
      const handlers = new Map();
      const ws = {handlers, closed: false, on: (type, callback) => handlers.set(type, callback),
        connect: connectSocket, close() {this.closed = true;}, send() {}};
      sockets.push(ws); return ws;
    }}},
    '@kit.ArkTS': {util: {TextEncoder: class {encodeInto(text) {return new TextEncoder().encode(text);}},
      TextDecoder: {create: () => ({decodeToString: bytes => new TextDecoder().decode(bytes)})}}},
    '@kit.BasicServicesKit': {}, 'api/BiliApi': {},
    'services/network/HttpClient': {HttpClient: {getCookie: () => ''}},
    'api/LiveApi': {LiveApi: {getLiveDanmakuInfo: getInfo}},
  });
  return {client: new (env.load('common/LiveDanmakuClient').LiveDanmakuClient)(), sockets};
}
const liveServer = {token: 'test', servers: [{host: 'example.invalid', wssPort: 443}]};

test('live connection ignores a previous room info request that completes after a new room', async () => {
  const old = deferred();
  const {client, sockets} = liveClientHarness(room => room === 1 ? old.promise : Promise.resolve(liveServer));
  const previous = client.connect(1);
  await client.connect(2);
  old.resolve(liveServer); await previous;
  assert.equal(sockets.length, 1); assert.equal(client.roomId, 2); assert.equal(client.socket, sockets[0]);
  client.close();
});

test('closing live room while info is pending cannot create a late socket', async () => {
  const info = deferred(); const {client, sockets} = liveClientHarness(() => info.promise);
  const connecting = client.connect(1); client.close(); info.resolve(liveServer); await connecting;
  assert.equal(sockets.length, 0); assert.equal(client.retryTimer, -1);
});

for (const failure of ['empty', 'request', 'socket']) {
  test(`live ${failure} failure schedules retry and explicit close cancels it`, async () => {
    const {client} = liveClientHarness(async () => {
      if (failure === 'request') throw Error('offline');
      return failure === 'empty' ? null : liveServer;
    }, async () => {if (failure === 'socket') throw Error('connect failed');});
    await client.connect(1);
    assert.notEqual(client.retryTimer, -1);
    client.close(); assert.equal(client.retryTimer, -1);
  });
}

test('late decompression from a closed live connection cannot emit old messages', async () => {
  const {client} = liveClientHarness(async () => liveServer);
  await client.connect(1);
  const inflated = deferred(); client.inflateZlib = () => inflated.promise;
  const packet = client.packet(5, 'compressed'); new DataView(packet).setUint16(6, 2);
  const messages = []; client.onMessage = message => messages.push(message);
  const parsing = client.parsePackets(packet, client.generation);
  client.close(); await client.connect(2);
  inflated.resolve(client.packet(5, JSON.stringify({cmd: 'DANMU_MSG', info: [[], 'old room', [1, 'User']]})));
  await parsing; assert.equal(messages.length, 0); client.close();
});

test('live history identity survives movement within a later snapshot and receives a fresh queue time', () => {
  const {LiveChatMessage} = environment().load('model/LiveModels');
  const raw = {timeline: '2026-09-09 21:00:00', nickname: 'User', text: 'hello'};
  const first = LiveChatMessage.history(raw, 9), second = LiveChatMessage.history(raw, 2);
  assert.equal(first.id, second.id);
  assert.ok(Date.now() - second.timestamp * 1000 < 1500);
  assert.ok(new LiveChatMessage().timestamp > 0);
});


test('followed live page excludes offline/invalid rooms and preserves covers and paging', () => {
  const {FollowedLivePage} = environment().load('model/LiveModels');
  const result = FollowedLivePage.from({live_count: 12, totalPage: 3, list: [
    {roomid: 10, live_status: 1, uname: 'Following', room_cover: '//example.invalid/cover'},
    {roomid: 11, live_status: 0}, {roomid: 0, live_status: 1},
    {roomid: 10, live_status: 1},
  ]}, 1);
  assert.equal(result.rooms.length, 1); assert.equal(result.rooms[0].uname, 'Following');
  assert.equal(result.rooms[0].cover, 'https://example.invalid/cover');
  assert.equal(result.liveCount, 12); assert.equal(result.hasMore, true);
  assert.equal(FollowedLivePage.from({totalPage: 3}, 3).hasMore, false);
});

function followedStripHarness(request) {
  const user = {isLogin: true, ensureLoaded: async () => {}};
  const env = environment({'api/LiveApi': {LiveApi: {getFollowedLiveRooms: request}},
    'services/auth/UserStore': {UserStore: user}});
  const Harness = env.methodHarness('components/live/FollowedLiveStrip', '  private async load(', '  private openRoom(',
    "import {UserStore} from '../../services/auth/UserStore'; import {LiveApi} from '../../api/LiveApi';");
  return {user, view: Object.assign(new Harness(), {destroyed: false, loading: false, hasMore: false,
    rooms: [], page: 1, liveCount: 0, epoch: new (env.load('common/RequestEpoch').RequestEpoch)()})};
}

test('followed live strip drops a previous account response after logout', async () => {
  const pending = deferred(); const {view, user} = followedStripHarness(() => pending.promise);
  const old = view.load(true); await tick();
  user.isLogin = false; await view.load(true);
  pending.resolve({rooms: [{roomId: 1}], liveCount: 1, hasMore: false}); await old;
  assert.deepEqual(view.rooms, []); assert.equal(view.signedIn, false); assert.equal(view.loading, false);
});

test('followed live pagination deduplicates rooms and a failure preserves existing entries', async () => {
  let calls = 0;
  const {view} = followedStripHarness(async () => {
    if (++calls === 3) throw Error('offline');
    return {rooms: calls === 1 ? [{roomId: 1}] : [{roomId: 1}, {roomId: 2}], liveCount: 4, hasMore: true};
  });
  await view.load(true); await view.load(false); await view.load(false);
  assert.deepEqual(view.rooms.map(room => room.roomId), [1, 2]);
  assert.equal(view.page, 3); assert.ok(view.errorText.length > 0);
});


test('standalone live emote labels are not duplicated beside the image in history and realtime', () => {
  const {LiveChatMessage} = environment().load('model/LiveModels');
  const emoticon = {url: 'https://example.invalid/emote.png', emoticon_unique: 'room_123', width: 100};
  const history = LiveChatMessage.history({text: '不理解', emoticon});
  const meta = Array(14).fill(0); meta[13] = emoticon;
  const realtime = LiveChatMessage.danmaku({info: [meta, '不理解', [1, 'User']]});
  for (const message of [history, realtime]) {
    assert.equal(message.emotes.length, 1);
    assert.equal(LiveChatMessage.textWithoutEmotes(message), '');
    assert.equal(message.text, '不理解');
  }
});

test('inline emote cleanup preserves real text and unmatched brackets', () => {
  const {LiveChatMessage} = environment().load('model/LiveModels');
  const message = LiveChatMessage.history({text: '我不理解[doge] [这是正文]',
    emots: {'[doge]': {url: 'https://example.invalid/doge', emoji: '[doge]'}}});
  assert.equal(message.emoteOnly, false);
  assert.equal(LiveChatMessage.textWithoutEmotes(message), '我不理解 [这是正文]');
});


test('chapter title and segment end track boundaries, gaps, missing ends and final frame', () => {
  const {chapterTitleAt, chapterEnd} = environment().load('components/player/PlayerChapterSupport');
  const chapters = [{from: 10, to: 20, title: 'One'}, {from: 30, to: 0, title: 'Two'},
    {from: 60, to: 90, title: 'Three'}];
  assert.equal(chapterTitleAt(chapters, 0, 90), '');
  assert.equal(chapterTitleAt(chapters, 19.9, 90), 'One');
  assert.equal(chapterTitleAt(chapters, 20, 90), '');
  assert.equal(chapterTitleAt(chapters, 30, 90), 'Two');
  assert.equal(chapterEnd(chapters, 1, 90), 60);
  assert.equal(chapterTitleAt(chapters, 60, 90), 'Three');
  assert.equal(chapterTitleAt(chapters, 90, 90), 'Three');
});


test('live controls stay visible while reading SC or adjusting playback settings', () => {
  const env = environment();
  const Harness = env.methodHarness('components/live/LivePlayerView', '  private canAutoHideControls()', '  scheduleHide()');
  const view = Object.assign(new Harness(), {playing: true, showQuality: false, showDmSettings: false, scExpanded: false});
  assert.equal(view.canAutoHideControls(), true);
  for (const field of ['scExpanded', 'showQuality', 'showDmSettings']) {
    view[field] = true; assert.equal(view.canAutoHideControls(), false); view[field] = false;
  }
  view.playing = false; assert.equal(view.canAutoHideControls(), false);
});


test('system media volume reads real levels, quantizes requests and unregisters only its listener', () => {
  let current=4, max=15, listener;
  const calls=[];
  const manager={
    getVolumeByStream:()=>current, getMinVolumeByStream:()=>0, getMaxVolumeByStream:()=>max,
    on:(event,usage,cb)=>{listener=cb;calls.push(['on',usage]);},
    off:(event,cb)=>{assert.equal(cb,listener);calls.push(['off']);}
  };
  const env=environment({'@kit.AudioKit':{audio:{getAudioManager:()=>({getVolumeManager:()=>manager}),StreamUsage:{STREAM_USAGE_MOVIE:3}}}});
  const {SystemMediaVolume}=env.load('components/player/SystemMediaVolume');
  const volume=new SystemMediaVolume();
  assert.equal(volume.percent(),27);
  assert.equal(volume.levelForPercent(40),6);
  assert.equal(volume.levelForPercent(-10),0);
  assert.equal(volume.levelForPercent(120),15);
  const seen=[];volume.start(x=>seen.push(x));
  current=6;listener({});assert.deepEqual(seen,[40]);
  // Changing output devices can change the number of available steps.
  max=30;assert.equal(volume.levelForPercent(40),12);
  volume.stop();listener({});assert.deepEqual(seen,[40]);
  assert.deepEqual(calls,[['on',3],['off']]);
});

test('live vertical gestures work without duration and begin from system volume; horizontal drag cannot seek', () => {
  const env=environment({'common/Immersive':{Immersive:{windowBrightness:()=>0.4}},'common/AppTheme':{AppTheme:{loadLastBrightness:()=>0.5}}});
  const {PlayerGestureController}=env.load('components/player/PlayerGestureController');
  const volumes=[], brightness=[], seeks=[];
  const ctl=new PlayerGestureController(()=>{},v=>seeks.push(v),()=>{},()=>{},v=>volumes.push(v),()=>{},v=>brightness.push(v));
  ctl.gestureVolume=27;
  ctl.beginPan(700,800,0,0);ctl.updatePan(0,-100,800,0);ctl.endPan();
  assert.ok(volumes.at(-1)>27 && volumes.at(-1)<50);
  ctl.beginPan(100,800,0,0);ctl.updatePan(0,-100,800,0);ctl.endPan();
  assert.ok(brightness.at(-1)>0.4);
  ctl.beginPan(700,800,0,0);ctl.updatePan(200,0,800,0);ctl.endPan();
  assert.deepEqual(seeks,[]);
});


test('manual quality persists across videos and temporary fallback; selecting a strategy resets the override', () => {
  const env=environment();const {PlayerQualityPreference:pref}=env.load('common/PlayerQualityPreference');
  assert.equal(pref.requested(),80);
  pref.remember(116);assert.equal(pref.requested(),116);
  // New video/page instances read the same stored preference, not a previous response quality.
  assert.equal(env.storage.get('videoManualQuality'),116);
  assert.equal(pref.requested(),116);
  pref.useMode(3);assert.equal(pref.requested(),64);
  pref.remember(80);assert.equal(pref.requested(),80);
  pref.useMode(1);assert.equal(pref.requested(),127);
});

test('MP4 optimization cannot downgrade an available DASH stream', async () => {
  let count=0;
  const dash={quality:80,dash:{video:[{id:80,base_url:'https://example.com/1080.m4s',codecs:'avc1'}],audio:[{base_url:'https://example.com/audio.m4s'}]}};
  const mp4={quality:64,durl:[{url:'https://example.com/720.mp4'}]};
  const env=environment({
    'services/network/HttpClient':{RequestPriority:{CRITICAL:0},HttpClient:{getCookie:()=>'',merge:(a,b)=>({...a,...b}),
      buildQuery:p=>new URLSearchParams(p).toString(),get:async url=>{count++;return new URL(url).searchParams.get('fnval')==='1'?mp4:dash;}}},
    'common/WbiSign':{WbiSign:{}},
    'common/AppSign':{appSign:()=>{}},
    'common/CommentLog':{CommentLog:{}},
    'common/DanmakuProto':{parseDanmakuSegment:()=>[]},
    'api/internal/ApiCommon':{getData:x=>x},
  });
  const {BiliApi}=env.load('api/BiliApi');
  const result=await BiliApi.getPlayUrl(1,'BVtest',2,80);
  assert.equal(count,2);assert.equal(result.quality,80);assert.equal(result.isDash,true);
  assert.equal(result.url,'https://example.com/1080.m4s');
  assert.deepEqual(result.audioUrls,['https://example.com/audio.m4s']);
});

function qualityResponse(ids, mixed = false) {
  return {quality:80, ...(mixed ? {durl:[{url:'https://example.com/1080.mp4'}]} : {}),
    support_formats:[120,116,112,80,64].map(quality=>({quality})),
    dash:{video:ids.map(id=>({id,base_url:`https://example.com/${id}.m4s`,codecs:'avc1'})),
      audio:[{base_url:'https://example.com/audio.m4s'}]}};
}
test('4K preference selects 1080P60 over ordinary MP4 and remains saved across fallback', () => {
  const env=environment(); const {PlayUrlInfo}=env.load('model/Models');
  const {PlayerQualityPreference:pref}=env.load('common/PlayerQualityPreference');
  pref.remember(120);
  const fallback=PlayUrlInfo.fromPlayUrl(qualityResponse([80,116,112],true),pref.requested());
  assert.equal(fallback.quality,116); assert.equal(fallback.isDash,true);
  assert.equal(fallback.url,'https://example.com/116.m4s'); assert.equal(pref.requested(),120);
  assert.equal(PlayUrlInfo.fromPlayUrl(qualityResponse([120,116,80]),pref.requested()).quality,120);
});
test('quality selection honors explicit lower preference and keeps same-quality MP4', () => {
  const {PlayUrlInfo}=environment().load('model/Models');
  assert.equal(PlayUrlInfo.fromPlayUrl(qualityResponse([116,112,80]),112).quality,112);
  const info=PlayUrlInfo.fromPlayUrl(qualityResponse([116,80],true),80);
  assert.equal(info.quality,80);assert.equal(info.isDash,false);
});
function qualityApi(handler) {
  const calls=[];
  const env=environment({
    'services/network/HttpClient':{RequestPriority:{CRITICAL:0},HttpClient:{getCookie:()=>'',
      merge:(a,b)=>({...a,...b}),buildQuery:p=>new URLSearchParams(p).toString(),get:async url=>{
        const params=new URL(url).searchParams;
        calls.push([Number(params.get('qn')),params.get('fnval')]); return handler(params);
      }}},
    'common/WbiSign':{WbiSign:{}},'common/AppSign':{appSign:()=>{}},
    'common/CommentLog':{CommentLog:{}},'common/DanmakuProto':{parseDanmakuSegment:()=>[]},
    'api/internal/ApiCommon':{getData:x=>x},
  });
  return {calls,api:env.load('api/BiliApi').BiliApi};
}
test('missing 4K requests advertised 1080P60 once before accepting server 1080P fallback', async () => {
  const e=qualityApi(p=>qualityResponse(p.get('qn')==='116'?[116,80]:[80]));
  const result=await e.api.getPlayUrl(1,'BVtest',2,120);
  assert.equal(result.quality,116);assert.equal(result.isDash,true);
  assert.deepEqual(e.calls,[[120,'4048'],[116,'4048']]);
});
test('denied quality retry is bounded and preserves an existing playable source', async () => {
  const e=qualityApi(p=>p.get('fnval')==='1'?null:qualityResponse([80]));
  const result=await e.api.getPlayUrl(1,'BVtest',2,120);
  assert.equal(result.quality,80);assert.ok(result.url.length>0);
  assert.deepEqual(e.calls.filter(x=>x[1]==='4048'),[[120,'4048'],[116,'4048']]);
  assert.equal(e.calls.filter(x=>x[1]==='1').length,1);
});
test('a failed higher-quality retry does not prevent playback', async () => {
  const e=qualityApi(p=>{
    if(p.get('qn')==='116') throw new Error('network unavailable');
    return p.get('fnval')==='1'?null:qualityResponse([80]);
  });
  const result=await e.api.getPlayUrl(1,'BVtest',2,120);
  assert.equal(result.quality,80);assert.ok(result.url.length>0);
});


test('return home clears a deep video stack once, stops playback and selects the root home tab', () => {
  const calls=[];
  const stack=['Search','VideoDetail','VideoDetail','VideoDetail'];
  const env=environment({
    'common/AppRouter':{AppNavStack:{clear:animated=>{calls.push(['clear',animated]);stack.length=0;}},
      HERO_NAV_TRANSITION_ACTIVE_KEY:'heroNavTransitionActive'},
    'common/PlayerCommandBus':{PlayerCommandBus:{stop:()=>calls.push(['stop'])}},
    'common/Immersive':{Immersive:{setFullscreen:value=>calls.push(['fullscreen',value])}},
  });
  const Harness=env.methodHarness('pages/Index','  private returnToHome(): void {','  switchTab(index:',
    "import { AppNavStack, HERO_NAV_TRANSITION_ACTIVE_KEY } from '../common/AppRouter';\n"+
    "import { PlayerCommandBus } from '../common/PlayerCommandBus';\n"+
    "import { Immersive } from '../common/Immersive';");
  const h=new Harness();h.currentTab=2;
  h.finishHeroNavTransition=()=>calls.push(['finishTransition']);
  h.switchTab=index=>{h.currentTab=index;};h.syncBarColors=()=>{};
  h.returnToHome();
  assert.deepEqual(stack,[]);assert.equal(h.currentTab,0);
  assert.deepEqual(calls,[['stop'],['fullscreen',false],['finishTransition'],['clear',false]]);
  assert.equal(env.storage.get('heroNavTransitionActive'),false);
});


test('keyword highlighting preserves text and emphasizes every literal Chinese match', () => {
  const {KeywordHighlight:h}=environment().load('common/KeywordHighlight');
  const parts=h.split('明日方舟：期待明日','明日');
  assert.equal(parts.map(p=>p.text).join(''),'明日方舟：期待明日');
  assert.deepEqual(parts.filter(p=>p.matched).map(p=>p.text),['明日','明日']);
  assert.deepEqual(h.split('明日明日','明日').map(p=>p.matched),[true,true]);
});
test('keyword highlighting handles empty, missing and regex-like input literally', () => {
  const {KeywordHighlight:h}=environment().load('common/KeywordHighlight');
  for(const kw of ['', '  ', '后天']) assert.equal(h.split('明日',kw).some(p=>p.matched),false);
  assert.deepEqual(h.split('a+b 与 aab','a+b').filter(p=>p.matched).map(p=>p.text),['a+b']);
  assert.equal(h.split('🌅明日','明日').map(p=>p.text).join(''),'🌅明日');
});

test('PiP starting, active and restoring preserve background video even when background audio is disabled', () => {
  for (const flag of ['pipStarting', 'pipActive', 'pipRestoring']) {
    for (const enabled of [false, true]) {
      const {view, actions} = backgroundHarness(enabled, true);
      view[flag] = true;
      view.onAppBackgroundChanged();
      assert.deepEqual(actions, []);
      view.appInBackground = false;
      view.onAppBackgroundChanged();
      assert.deepEqual(actions, ['foreground']);
      assert.equal(view.pipRestoring, false);
    }
  }
});

function pipHarness(create) {
  const PiPState = { ABOUT_TO_START:1, STARTED:2, STOPPED:4, ABOUT_TO_RESTORE:5, ERROR:6 };
  const platform = {isPiPEnabled:()=>true,create,PiPState,PiPTemplateType:{VIDEO_PLAY:0},
    PiPControlType:{VIDEO_PLAY_PAUSE:0},PiPControlStatus:{PLAY:1,PAUSE:0}};
  const env = environment({'@kit.ArkUI':{PiPWindow:platform}});
  const Harness = env.methodHarness('components/player/PlayerView',
    '  private async startPictureInPicture()', '  onAppBackgroundChanged():',
    "import { PiPWindow as pictureInPicture } from '@kit.ArkUI';");
  const events = [], actions = [];
  const view = Object.assign(new Harness(), {pipController:null,pipActive:false,pipStarting:false,
    pipRestoring:false,pipGeneration:0,destroyed:false,prepared:true,player:{},surfaceId:'surface',
    realVideoWidth:1920,realVideoHeight:1080,playing:true,appInBackground:false,
    getUIContext:()=>({getHostContext:()=>({})}),closeSettingPanels(){},
    toast:message=>events.push(message),onAppBackgroundChanged:()=>actions.push('background'),
    togglePlay(){this.playing=!this.playing;actions.push('toggle');}});
  return {view, events, actions, PiPState};
}
function fakePipController() {
  const callbacks = {}, states = [];
  return {callbacks,states,stops:0,starts:0,
    setAutoStartEnabled(){},on:(key,cb)=>{callbacks[key]=cb;},off:key=>{delete callbacks[key];},
    updatePiPControlStatus:(_type,state)=>states.push(state),updateContentSize(){},
    async startPiP(){this.starts++;callbacks.stateChange(2);},async stopPiP(){this.stops++;}};
}
test('PiP handles playback controls, restoration and background close without losing state', async () => {
  const controller=fakePipController();const {view,actions}=pipHarness(async()=>controller);
  await view.startPictureInPicture();assert.equal(view.pipActive,true);
  controller.callbacks.controlEvent({controlType:0,status:0});assert.equal(view.playing,false);
  controller.callbacks.controlEvent({controlType:0,status:0});assert.equal(actions.length,1);
  controller.callbacks.controlEvent({controlType:0,status:1});assert.equal(view.playing,true);
  view.appInBackground=true;
  controller.callbacks.stateChange(5);controller.callbacks.stateChange(4);
  assert.equal(view.pipRestoring,true);assert.deepEqual(actions,['toggle','toggle']);
  view.pipRestoring=false;controller.callbacks.stateChange(4);
  assert.deepEqual(actions,['toggle','toggle','background']);
});
test('PiP creation after player disposal cannot start an orphan window', async () => {
  const pending=deferred(),controller=fakePipController();const {view}=pipHarness(()=>pending.promise);
  const starting=view.startPictureInPicture();view.releasePictureInPicture();view.destroyed=true;
  pending.resolve(controller);await starting;assert.equal(controller.starts,0);assert.equal(view.pipController,null);
});
test('PiP failed start re-applies background policy and allows retry', async () => {
  const controller=fakePipController();controller.startPiP=async()=>{throw new Error('denied');};
  const {view,actions,events}=pipHarness(async()=>controller);view.appInBackground=true;
  await view.startPictureInPicture();assert.equal(view.pipStarting,false);assert.equal(view.pipActive,false);
  assert.deepEqual(actions,['background']);assert.equal(events.length,1);
});

function videoReportHarness() {
  const cookies = new Map([['SESSDATA','test-session'],['bili_jct','test-csrf']]);
  const calls=[];let payload={code:0,data:[]};
  const env=environment({'common/WbiSign':{WbiSign:{encWbi:async()=>{},invalidate:()=>{}}},
    'services/network/HttpClient':{RequestPriority:{NORMAL:1},HttpClient:{
    getCookie:key=>cookies.get(key)||'',setCookie:(key,value)=>cookies.set(key,value),
    merge:(a,b)=>({...a,...b}),buildQuery:p=>new URLSearchParams(p).toString(),
    get:async()=>({ok:true,json:()=>payload}),
    post:async(url,body,headers)=>{calls.push({url,body,headers});return {ok:true,json:()=>payload};}}}});
  return {api:env.load('api/VideoReportApi').VideoReportApi,cookies,calls,setPayload:p=>{payload=p;}};
}
test('video report reasons retain server IDs and exclude required structured evidence forms', async () => {
  const {api,setPayload}=videoReportHarness();setPayload({code:0,data:[
    {tid:10040,name:'含AI生成',remark:'描述位置',controls:null},
    {tid:8,name:'撞车',controls:[{required:1}]},{tid:0,name:'invalid'}]});
  const reasons=await api.reasons();assert.equal(reasons.length,1);assert.equal(reasons[0].id,10040);
  setPayload({code:-1,message:'failed'});await assert.rejects(()=>api.reasons());
});
test('video report checks login and content, sends selected reason, and only acknowledges server success', async () => {
  const {api,calls,cookies,setPayload}=videoReportHarness();
  assert.equal((await api.submit(1,2,' ')).ok,false);assert.equal(calls.length,0);
  cookies.delete('SESSDATA');assert.equal((await api.submit(1,2,'问题')).ok,false);assert.equal(calls.length,0);
  cookies.set('SESSDATA','test-session');setPayload({code:-412,message:'请求被拦截'});
  assert.equal((await api.submit(123,10040,'  01:20 问题描述  ')).ok,false);
  const form=new URLSearchParams(calls[0].body);
  assert.equal(form.get('aid'),'123');assert.equal(form.get('tid'),'10040');
  assert.equal(form.get('desc'),'01:20 问题描述');assert.equal(form.get('csrf'),'test-csrf');
  assert.equal(calls[0].headers.buid,cookies.get('Buid'));
  setPayload({code:0});assert.equal((await api.submit(123,10040,'描述')).ok,true);
});

test('PiP start completing after release is stopped again and leaves no orphan window', async () => {
  const pending=deferred(),controller=fakePipController();
  controller.startPiP=()=>pending.promise;
  const {view}=pipHarness(async()=>controller);
  const starting=view.startPictureInPicture();await tick();
  view.releasePictureInPicture();view.destroyed=true;
  pending.resolve();await starting;
  assert.equal(controller.stops,2);assert.equal(view.pipController,null);
});

test('disabled player gesture preferences suppress playback, seeking and speed changes', () => {
  const env=environment();
  for (const [start,end,method,flag] of [
    ['  private handleDoubleTap():','  @Builder\n  PlayerGestureArea()', 'handleDoubleTap','doubleTapEnabled'],
    ['  private beginHoldSpeed():','  private endHoldSpeed():','beginHoldSpeed','holdEnabled'],
    ['  private beginPlayerPan(','  private updatePlayerPan(','beginPlayerPan','panEnabled'],
    ['  private updatePlayerPan(','  private endPlayerPan():','updatePlayerPan','panEnabled'],
  ]) {
    const Harness=env.methodHarness('components/player/PlayerView',start,end);
    const view=Object.assign(new Harness(),{[flag]:false});
    // No player/controllers exist: reaching any side effect would throw.
    assert.doesNotThrow(()=>view[method]({fingerList:[],offsetX:50,offsetY:10}));
  }
});

test('turning off scheduled dark mode immediately reapplies the current theme policy', () => {
  const {AppTheme}=environment({'@kit.ArkUI':{},'@kit.AbilityKit':{},'@kit.ArkData':{},'@kit.BasicServicesKit':{deviceInfo:{}}}).load('common/AppTheme');
  const applied=[];
  AppTheme.getMode=()=>AppTheme.MODE_SYSTEM;
  AppTheme.applyCurrentMode=()=>applied.push('apply');
  AppTheme.setAutoDarkEnabled(false);
  assert.deepEqual(applied,['apply']);
});

test('manual quality and gesture preferences survive a fresh app storage instance', async () => {
  const disk = new Map();
  const store = {getSync:(key,fallback)=>disk.has(key)?disk.get(key):fallback,
    putSync:(key,value)=>disk.set(key,value),flush:async()=>{}};
  const mocks = {'@kit.ArkUI':{}, '@kit.AbilityKit':{},
    '@kit.ArkData':{preferences:{getPreferencesSync:()=>store}},
    '@kit.BasicServicesKit':{deviceInfo:{}}};
  const first=environment(mocks);
  await first.load('common/AppTheme').AppTheme.initThemeStore({});
  first.load('common/PlayerQualityPreference').PlayerQualityPreference.remember(120);
  first.load('common/AppTheme').AppTheme.setPlayerGesture('playerDoubleTapEnabled',false);
  const restarted=environment(mocks);
  await restarted.load('common/AppTheme').AppTheme.initThemeStore({});
  const pref=restarted.load('common/PlayerQualityPreference').PlayerQualityPreference;
  assert.equal(pref.requested(),120);
  assert.equal(restarted.storage.get('playerDoubleTapEnabled'),false);
  pref.useMode(3);
  const third=environment(mocks);
  await third.load('common/AppTheme').AppTheme.initThemeStore({});
  assert.equal(third.load('common/PlayerQualityPreference').PlayerQualityPreference.requested(),64);
});

test('quality ceiling never silently selects a stream above the saved choice', () => {
  const {PlayUrlInfo}=environment().load('model/Models');
  assert.equal(PlayUrlInfo.fromPlayUrl(qualityResponse([120,116]),80).url,'');
  assert.equal(PlayUrlInfo.fromPlayUrl({quality:80,durl:[{url:'https://test/1080.mp4'}]},64).url,'');
});

test('emote package cache deduplicates requests, restores on restart and isolates accounts', async () => {
  const disk=new Map(); let requests=0;
  function fresh() {
    const cache=environment().load('common/EmotePackageCache').EmotePackageCache;
    cache.configure(k=>disk.get(k)||'',(k,v)=>disk.set(k,v)); return cache;
  }
  const pending=deferred(); const cache=fresh();
  const fetch=()=>{requests++;return pending.promise;};
  const a=cache.get('u1_reply',fetch),b=cache.get('u1_reply',fetch);
  pending.resolve('[{"text":"表情","emote":[]}]');
  assert.deepEqual(await a,await b);assert.equal(requests,1);
  const restarted=fresh();
  assert.deepEqual(await restarted.get('u1_reply',()=>{throw Error('must not fetch');}),await a);
  assert.deepEqual(await restarted.get('u2_reply',async()=>{requests++;return '[{"text":"other"}]';}), [{"text":"other"}]);
  assert.equal(requests,2);
});

test('stale emote directories display immediately offline and corrupt cache retries', async () => {
  const disk=new Map([['u_reply',JSON.stringify({at:1,data:'[{"text":"saved"}]'})],['broken','bad json']]);
  const cache=environment().load('common/EmotePackageCache').EmotePackageCache;
  cache.configure(k=>disk.get(k)||'',(k,v)=>disk.set(k,v));
  const never=deferred();
  assert.deepEqual(await cache.get('u_reply',()=>never.promise),[{text:'saved'}]);
  never.reject(Error('offline'));await tick();
  assert.deepEqual(await cache.get('u_reply',()=>{throw Error('retry throttled');}),[{text:'saved'}]);
  assert.deepEqual(await cache.get('broken',async()=>'[{"text":"new"}]'),[{text:'new'}]);
});

test('video back broadcast closes only the targeted destination once, including duplicate video pages', () => {
  const env=environment();
  const Page=env.methodHarness('pages/VideoDetail','  onCloseRequested(): void {','  aboutToDisappear(): void {');
  const hidden=new Page(),shown=new Page();
  hidden.queryNavDestinationInfo=()=>({index:0});shown.queryNavDestinationInfo=()=>({index:1});
  hidden.closeRequest=shown.closeRequest=7;
  let hiddenPops=0,shownPops=0;
  hidden.goBack=()=>{hiddenPops++;};shown.goBack=()=>{shownPops++;};
  env.storage.set('videoDetailCloseTargetIndex',1);
  hidden.onCloseRequested();shown.onCloseRequested();
  // Even if destination indices change during pop, the request has already been consumed.
  hidden.queryNavDestinationInfo=()=>({index:1});
  hidden.onCloseRequested();shown.onCloseRequested();
  assert.equal(hiddenPops,0);assert.equal(shownPops,1);
});

test('missing entrance animation callback restores full page and releases data gate', async () => {
  // 入场闸门已抽到 VideoHeroTransitionController：经 access 闭包驱动一个假页面状态。
  const env=environment({
    '@kit.ArkUI':{FrameCallback:class FrameCallback{},UIContext:class UIContext{}},
    '@kit.ImageKit':{image:{}},
    'common/AppRouter':{AppNavStack:{},releasePixelMap(){}},
  });
  const Hero=env.load('components/video/VideoHeroTransitionController').VideoHeroTransitionController;
  const state={contentOpacity:0,heroOpacity:0,wholeCardAnimating:true,wholeCardScale:.45,
    wholeCardTranslateX:0,wholeCardTranslateY:0,wholeCardRadius:0,wholeCardSnapshotOpacity:0,
    snapshot:null,fromWholeCard:false,fromRect:false,entranceArmed:false,destroyed:false,closing:false};
  const access={
    setContentOpacity:v=>{state.contentOpacity=v;},
    setHeroVisible:()=>{},setHeroSource:()=>{},setHeroX:()=>{},setHeroY:()=>{},
    setHeroWidth:()=>{},setHeroHeight:()=>{},setHeroRadius:()=>{},setHeroOpacity:v=>{state.heroOpacity=v;},
    setWholeCardAnimating:v=>{state.wholeCardAnimating=v;},
    getWholeCardSnapshot:()=>state.snapshot,setWholeCardSnapshot:v=>{state.snapshot=v;},
    setWholeCardSnapshotOpacity:v=>{state.wholeCardSnapshotOpacity=v;},
    setWholeCardScale:v=>{state.wholeCardScale=v;},
    setWholeCardTranslateX:v=>{state.wholeCardTranslateX=v;},
    setWholeCardTranslateY:v=>{state.wholeCardTranslateY=v;},
    setWholeCardClipHeight:()=>{},setWholeCardRadius:v=>{state.wholeCardRadius=v;},
    setWholeCardSnapshotHeight:()=>{},
    setFromWholeCard:v=>{state.fromWholeCard=v;},isFromWholeCard:()=>state.fromWholeCard,
    setFromRect:v=>{state.fromRect=v;},isFromRect:()=>state.fromRect,
    isEntranceArmed:()=>state.entranceArmed,setEntranceArmed:v=>{state.entranceArmed=v;},
  };
  let timer;
  const hero=new Hero({},{gateFallbackMs:600},access,
    ()=>undefined,()=>'',()=>0,()=>0,()=>undefined,()=>undefined,()=>false,
    ()=>state.destroyed,()=>state.closing,()=>({}),fn=>{timer=fn;});
  hero.armEntranceGate();
  let gateOpen=false;
  hero.waitEntranceGate().then(()=>{gateOpen=true;});
  assert.equal(gateOpen,false);
  timer();await tick();
  assert.equal(state.wholeCardScale,1);assert.equal(state.wholeCardAnimating,false);
  assert.equal(state.contentOpacity,1);
  assert.equal(gateOpen,true,'fallback must release the data gate');
  state.closing=true;state.wholeCardScale=.45;
  hero.armEntranceGate();timer();await tick();
  assert.equal(state.wholeCardScale,.45,'exit animation must not be reset by entrance timeout');
});
