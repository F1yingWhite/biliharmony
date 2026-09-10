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

function epoch(env) { return new (env.load('common/RequestEpoch').RequestEpoch)(); }
function source(env, items = []) {
  const s = new (env.load('common/BasicDataSource').BasicDataSource)();
  s.reset(items); return s;
}

test('recommendation reset supersedes old pagination and preserves new loading state', async () => {
  const old = deferred(), latest = deferred(); let calls = 0;
  const env = environment({'api/FeedApi': {FeedApi: {getRecommend: () => ++calls === 1 ? old.promise : latest.promise}}});
  const Harness = env.methodHarness('views/HomeView', '  async loadRecommend(', '  async loadHot(',
    "import { FeedApi } from '../api/FeedApi';");
  const p = new Harness();
  Object.assign(p, {recEpoch:epoch(env), recFetching:false, recHasMore:true, recIdx:10,
    recSource:source(env, [{aid:1}]), recCount:1});
  const first = p.loadRecommend(false), reset = p.loadRecommend(true);
  old.resolve([]); await first;
  assert.equal(calls, 2); assert.equal(p.recFetching, true); assert.equal(p.recHasMore, true);
  latest.resolve([{aid:2}]); await reset;
  assert.deepEqual(p.recSource.getAll(), [{aid:2}]); assert.equal(p.recFetching,false);
});

function qrHarness(api) {
  const env = environment({'api/AuthApi':{AuthApi:api}});
  const Harness = env.methodHarness('pages/Login','  async requestCode():','  // ===== 密码登录',
    "import { AuthApi } from '../api/AuthApi'; const AppTheme={DANGER:'#f00'};");
  const p = new Harness();
  Object.assign(p,{destroyed:false,loggedIn:false,tab:0,authCode:'OLD',qrGeneration:0,
    pollInflight:false,pollTimer:-1,expired:false,isDark:false});
  return p;
}

test('old QR expiry cannot stop a refreshed QR or clear its inflight guard', async () => {
  const old = deferred(), latest = deferred(); let calls = 0;
  const p = qrHarness({getTVCode:async()=>({authCode:'NEW',url:'new-qr'}),
    pollTVCode:()=>++calls === 1 ? old.promise : latest.promise});
  try {
    const first = p.poll(); await p.requestCode(); const second = p.poll();
    old.resolve({code:86038}); await first;
    assert.equal(p.expired,false); assert.equal(p.pollInflight,true); assert.notEqual(p.pollTimer,-1);
    latest.resolve({code:86090}); await second;
    assert.equal(p.statusText,'已扫码，请在手机上确认登录');
  } finally { p.stopPoll(); }
});

test('out-of-order QR creation cannot replace the newer code', async () => {
  const old = deferred(), latest = deferred(); let calls=0;
  const p=qrHarness({getTVCode:()=>++calls===1?old.promise:latest.promise});
  try {
    const a=p.requestCode(), b=p.requestCode();
    latest.resolve({authCode:'NEW',url:'new'}); await b;
    old.resolve({authCode:'OLD',url:'old'}); await a;
    assert.equal(p.authCode,'NEW'); assert.equal(p.qrUrl,'new');
  } finally {p.stopPoll();}
});

test('stopping QR polling ignores a late login success', async () => {
  const pending=deferred(); const p=qrHarness({pollTVCode:()=>pending.promise});
  const running=p.poll(); p.stopPoll(); p.tab=1;
  pending.resolve({code:0,cookies:[],accessToken:''}); await running;
  assert.equal(p.loggedIn,false);
});

function liveHarness(create) {
  const env=environment({'@kit.MediaKit':{media:{createAVPlayer:create,createMediaSourceWithUrl:()=>({})}}});
  const Harness=env.methodHarness('components/live/LivePlayerView','  async restartForSource():','  togglePlay():',
    "import { media } from '@kit.MediaKit'; const Constants={browserUa:'test'};");
  const p=new Harness(); Object.assign(p,{destroyed:false,player:null,playerCreating:false,
    playerRestartPending:false,surfaceId:'test',playInfo:{urls:['first','backup']},playerGeneration:0,sourceIndex:0,
    dmRenderer:{setPlayback(){},release(){}},hideTimer:-1,fullscreenTimer:-1});
  return p;
}
function fakePlayer(setSource=async()=>{},release=async()=>{}) {
  const handlers={};
  return {handlers,on:(name,fn)=>handlers[name]=fn,release,setVolume(){},
    setMediaSource:()=>setSource(handlers)};
}

for (const failure of ['event','rejection']) {
  test(`live initialization ${failure} retries backup after creation unwinds`, async () => {
    let creations=0,releases=0;
    const first=fakePlayer(async handlers=>{
      if (failure==='event') await handlers.error({message:'failed'});
      else throw new Error('failed');
    },async()=>{releases++;});
    const backup=fakePlayer();
    const p=liveHarness(async()=>++creations===1?first:backup);
    await p.initPlayer();
    assert.equal(creations,2); assert.equal(p.player,backup); assert.equal(p.sourceIndex,1);
    assert.equal(releases,1); assert.equal(p.playerCreating,false);
  });
}

test('live source switch during creation starts the newest source without polling timers', async () => {
  const pending=deferred(); let creations=0,releases=0;
  const first=fakePlayer(async()=>{},async()=>{releases++;}), next=fakePlayer();
  const p=liveHarness(()=>++creations===1?pending.promise:Promise.resolve(next));
  const creating=p.initPlayer();
  p.playInfo={urls:['new']}; await p.restartForSource();
  pending.resolve(first); await creating;
  assert.equal(p.player,next); assert.equal(creations,2); assert.equal(releases,1);
});

test('live error cannot advance a new source while old release is pending', async () => {
  const release=deferred(); let creations=0;
  const old=fakePlayer(async()=>{},()=>release.promise), next=fakePlayer();
  const p=liveHarness(async()=>{creations++;return next;}); p.player=old;
  const failed=p.handleError(old,'failed');
  p.playInfo={urls:['new-first','new-backup']}; await p.restartForSource();
  release.resolve(); await failed;
  assert.equal(p.player,next); assert.equal(p.sourceIndex,0); assert.equal(creations,1);
});

test('live release during creation cleans late player and never retries', async () => {
  const pending=deferred(); let creations=0,releases=0;
  const p=liveHarness(()=>{creations++;return pending.promise;});
  const creating=p.initPlayer(); p.destroyed=true; p.release();
  pending.resolve(fakePlayer(async()=>{},async()=>{releases++;})); await creating;
  assert.equal(p.player,null); assert.equal(creations,1); assert.equal(releases,1);
});

test('late live PixelMap is released without overwriting a new renderer generation', async () => {
  const old=deferred(),latest=deferred(); let released=0,calls=0;
  const env=environment({'@kit.ImageKit':{},'services/network/HttpClient':{},'common/Constants':{}});
  const {LiveDanmakuRenderer}=env.load('components/live/LiveDanmakuRenderer');
  const r=new LiveDanmakuRenderer({clearRect(){}});
  r.loadEmote=()=>++calls===1?old.promise:latest.promise;
  const message={emotes:[{url:'https://test/image.png'}]};
  r.prefetchEmote(message); r.release(); r.prefetchEmote(message);
  old.resolve({release:async()=>{released++;}}); await tick();
  assert.equal(r.emoteCache.size,0); assert.equal(released,1); assert.equal(r.emoteLoading.size,1);
  const map={release:async()=>{released++;}}; latest.resolve(map); await tick();
  assert.equal(r.emoteCache.get(message.emotes[0].url),map);
  r.release(); await tick(); assert.equal(released,2);
});

function sessionHarness(create) {
  const env=environment({'@kit.AbilityKit':{},'@kit.AVSessionKit':{avSession:{createAVSession:create,
    BackgroundPlayMode:{ENABLE_BACKGROUND_PLAY:1},PlaybackState:{PLAYBACK_STATE_PLAY:1}}},
    '@kit.BackgroundTasksKit':{},'@kit.PerformanceAnalysisKit':{hilog:{}},'BuildProfile':{DEBUG:false}});
  return new (env.load('components/player/PlayerAvSessionHelper').PlayerAvSessionHelper)({});
}
function fakeSession() {
  const count={activate:0,deactivate:0,destroy:0}; const handlers={};
  const session={on:(name,fn)=>handlers[name]=fn,activate:async()=>{count.activate++;},
    setBackgroundPlayMode:async()=>{},setAVMetadata:async()=>{},setAVPlaybackState:async()=>{},
    deactivate:async()=>{count.deactivate++;},destroy:async()=>{count.destroy++;}};
  return {session,count,handlers};
}
for (const stage of ['create','activate','background']) {
  test(`AVSession release during ${stage} destroys the late result`, async () => {
    const pending=deferred(); const {session,count}=fakeSession();
    if (stage==='activate') session.activate=()=>pending.promise;
    if (stage==='background') session.setBackgroundPlayMode=()=>pending.promise;
    const h=sessionHarness(()=>stage==='create'?pending.promise:Promise.resolve(session));
    const creating=h.ensure(()=>{},()=>{},()=>{},{},{state:0});
    await tick(); h.release(); pending.resolve(stage==='create'?session:undefined); await creating;
    assert.equal(h.active,false); assert.equal(h.session,null); assert.equal(count.destroy,1);
    if (stage==='create') assert.equal(count.activate,0);
    h.release(); await tick(); assert.equal(count.destroy,1);
  });
}

test('AVSession normal release destroys once and ignores stale system controls', async () => {
  const {session,count,handlers}=fakeSession();let played=0;
  const h=sessionHarness(async()=>session);
  await h.ensure(()=>{played++;},()=>{},()=>{},{},{state:0});
  handlers.play(); assert.equal(played,1);
  h.release();h.release();await tick(); handlers.play();
  assert.equal(played,1);assert.equal(count.destroy,1);assert.equal(h.active,false);
});

test('AVSession partial initialization failure destroys created session', async () => {
  const {session,count}=fakeSession();
  session.setBackgroundPlayMode=async()=>{throw new Error('unsupported');};
  const h=sessionHarness(async()=>session);
  await h.ensure(()=>{},()=>{},()=>{},{},{state:0});
  assert.equal(h.active,false);assert.equal(count.destroy,1);
});

for (const action of ['clear','remove']) {
  test(`WatchLater ${action} success invalidates old list response`, async () => {
    const pending=deferred();
    const env=environment({'api/HistoryApi':{HistoryApi:{getWatchLaterList:()=>pending.promise,
      clearWatchLater:async()=>({ok:true}),delWatchLater:async()=>({ok:true})}}});
    const Harness=env.methodHarness('pages/library/WatchLaterPage','  async load():','  @Builder\n  ClearAction()',
      "import { HistoryApi } from '../../api/HistoryApi';");
    const item={video:{aid:123}};
    const p=new Harness();Object.assign(p,{listEpoch:epoch(env),loading:false,actionBusy:false,
      itemCount:1,itemsSource:source(env,[item]),toast(){}});
    const loading=p.load();
    if(action==='clear') await p.clearAll(); else await p.removeItem(item);
    pending.resolve([item]); await loading;
    assert.equal(p.itemCount,0);assert.equal(p.itemsSource.totalCount(),0);assert.equal(p.loading,false);
  });
}

test('dynamic category change supersedes an inflight feed', async () => {
  const old=deferred(),latest=deferred();const calls=[];
  const env=environment({'api/DynamicApi':{DynamicApi:{getDynamicFeed:(offset,type)=>{
    calls.push(type);return calls.length===1?old.promise:latest.promise;
  }}}});
  const Change=env.methodHarness('views/DynamicView','  private changeDynType(','  @Builder\n  DynTypeChip(');
  const Load=env.methodHarness('views/DynamicView','  async loadFeed(','  /** 并行拉取',
    "import { DynamicApi } from '../api/DynamicApi';");
  const p=new Change();p.loadFeed=Load.prototype.loadFeed;
  Object.assign(p,{feedEpoch:epoch(env),dynType:'all',feedLoading:false,dynTab:0,hostMid:0,
    dynHasMore:true,dynOffset:'',dynSource:source(env),dynCount:0});
  const first=p.loadFeed(false);p.dynTab=1;p.changeDynType('video');
  old.resolve({items:[{dynId:'old'}],offset:'old',hasMore:false});await first;
  assert.equal(p.dynType,'video');assert.equal(p.feedLoading,true);assert.deepEqual(calls,['all','video']);
  latest.resolve({items:[{dynId:'new'}],offset:'new',hasMore:true});await tick();
  assert.deepEqual(p.dynSource.getAll(),[{dynId:'new'}]);assert.equal(p.dynOffset,'new');
});

test('download removal settles task, clears listeners and never retries backup', async () => {
  const handlers=new Map();let calls=0;
  const task={on:(name,fn)=>handlers.set(name,fn),off:(name)=>handlers.delete(name)};
  const env=environment({'@kit.AbilityKit':{},'@kit.BasicServicesKit':{request:{downloadFile:async()=>{calls++;return task;}}},
    '@kit.CoreFileKit':{fileIo:{unlinkSync(){}}}});
  const {VideoDownloadService}=env.load('services/media/VideoDownloadService');
  const pending=VideoDownloadService.downloadToUri({cacheDir:'/fake'},['https://first','https://backup'],
    'file://target','test',{},()=>{});
  const rejected=assert.rejects(pending,/下载已取消/);
  await tick();assert.equal(handlers.has('remove'),true);handlers.get('remove')();await rejected;
  assert.equal(VideoDownloadService.isActive(),false);assert.equal(calls,1);assert.equal(handlers.size,0);
});

for (const page of ['VideoDetail','DynamicDetail','BangumiDetail']) {
  test(`${page} root switch ignores old replies, cursor and loading completion`, async () => {
    const old=deferred(),latest=deferred();const calls=[];
    const env=environment({'api/CommentApi':{CommentApi:{getReplyReplies:(oid,type,root)=>{
      calls.push(root);return root===100?old.promise:latest.promise;
    }}}});
    const video=page==='VideoDetail';
    const Harness=env.methodHarness('pages/'+page,
      video?'  async loadThreadReplies(':'  private async loadThreadReplies(',
      video?'  @Builder\n  VideoThreadEmotePanel()':'  private sentThreadReply(',
      "import { CommentApi } from '../api/CommentApi'; const CommentLog={warn(){},info(){},error(){},elapsed(){return 0;}};");
    const p=new Harness();Object.assign(p,{threadEpoch:epoch(env),threadLoading:false,threadHasMore:true,
      threadCursor:'',threadAllReplies:[],threadReplies:[],threadPrefetchCount:0,threadOpen:true,
      replyThreadRoot:{rpid:100,count:2},threadRoot:{rpid:100,count:2},detail:{aid:1},
      item:{commentId:1,commentType:17},replyOid:()=>1,destroyed:false,mergeUniqueReplies:(a,b)=>a.concat(b)});
    const first=p.loadThreadReplies(true,false);
    p.replyThreadRoot={rpid:200,count:2};p.threadRoot={rpid:200,count:2};
    const second=p.loadThreadReplies(true,false);
    old.resolve({replies:[{rpid:101,rootRpid:100}],cursor:'old',hasMore:false});await first;
    assert.equal(p.threadLoading,true);assert.equal(p.threadCursor,'');assert.deepEqual(calls,[100,200]);
    latest.resolve({replies:[{rpid:201,rootRpid:200}],cursor:'new',hasMore:true});await second;
    assert.deepEqual((video?p.threadAllReplies:p.threadReplies).map(r=>r.rootRpid),[200]);
    assert.equal(p.threadCursor,'new');assert.equal(p.threadLoading,false);
  });
}
