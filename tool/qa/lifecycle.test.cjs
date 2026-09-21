// Run actual ArkTS service code with fake platform boundaries. No network, credentials or device required.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const sourceOverride = process.env.ARKTS_TEST_SOURCE_ROOT;
// 源码缓存：methodHarness 会反复切片同一个大文件（VideoDetail 3k+ 行），
// 每次用例都重新读盘是纯浪费；测试期间源码不会变化。
const sourceCache = new Map();
function readSource(filename) {
  const override = sourceOverride && path.join(sourceOverride, path.relative(root, filename));
  const target = override && fs.existsSync(override) ? override : filename;
  if (!sourceCache.has(target)) {
    // 锚点里的多行字符串用 \n 书写，但仓库 .ets 是 CRLF 检出（core.autocrlf）。
    // 不规范化则任何跨行锚点都会静默失配——这正是此前 6 个用例集体失效的根因。
    // 统一归一为 LF，让锚点只依赖内容、不依赖检出时的行尾。
    sourceCache.set(target, fs.readFileSync(target, 'utf8').replace(/\r\n/g, '\n'));
  }
  return sourceCache.get(target);
}
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');

// ---------------------------------------------------------------------------
// 生产方法切片锚点（methodHarness 的 start/end）
//
// 这些字符串必须逐字存在于入口源码中，一旦重构改动签名或注释就会匹配失败，
// 报成 `assert.ok(begin >= 0 && finish > begin)`——看起来像功能回归，实际是夹具失效。
// 历史上已因此整批静默失效过（`private` 被去掉、注释改名、参数补类型注解）。
//
// 因此：锚点集中在此处，不得内联在用例里；改动锚点指向的方法签名/注释时，
// 必须同步更新这里，并在同一个提交里跑一遍 lifecycle.test.cjs。
//
// 选取原则：start 用方法签名行（含缩进），end 用下一个成员的签名或注释首行——
// 必须唯一、且不会在方法体内提前出现，否则切片会截断。
// ---------------------------------------------------------------------------
const ANCHOR = {
  /** DynamicView：动态分类切换后必须让在途 feed 失效。 */
  dynChangeTypeStart: '  private changeDynType(type: string): void {',
  dynChipStart: '  @Builder\n  DynTypeChip(label: string, type: string) {',
  dynLoadFeedStart: '  async loadFeed(reset: boolean): Promise<void> {',
  /** 关注 UP 横滑栏拉取，紧跟在 loadFeed 之后的成员。 */
  dynLoadFeedEnd: '  /** 并行拉取',
  // 三页评论编排已收敛到 components/reply/RepliesController（原 VideoDetail/DynamicDetail/
  // BangumiDetail 内联的 loadReplies/changeReplySort/loadThreadReplies/mutateReplyItem）。
  /** 主评论分页加载，紧随其后的排序切换成员。 */
  repliesLoadStart: '  async load(reset: boolean): Promise<void> {',
  repliesChangeSortStart: '  changeReplySort(mode: number): void {',
  /** 楼中楼分页加载，紧随其后的 mutate 成员。 */
  repliesLoadThreadStart: '  async loadThread(reset: boolean, allowPrefetch: boolean = true): Promise<void> {',
  repliesMutateStart: '  mutate(rpid: number, mutate: (target: ReplyItem) => void): ReplyItem | null {',
  /** stampServerRevs 定义在 mutate 之后；加载切片要用到它，end 锚点取 share 签名。 */
  repliesShareStart: '  share(item: ReplyItem): void {',
};

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
      if (name === '@kit.PerformanceAnalysisKit') {
        const noop = () => {};
        return { hilog: { debug: noop, info: noop, warn: noop, error: noop } };
      }
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
    // 失败时直接指出是哪个锚点漂了：旧消息只有一个裸断言，定位全靠猜。
    assert.ok(begin >= 0, `锚点未命中 start（${file}.ets）：${JSON.stringify(start)}`);
    assert.ok(finish > begin, `锚点未命中 end（${file}.ets）：${JSON.stringify(end)}`);
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

// ---------------------------------------------------------------------------
// RepliesController 的页面 access 装配（与各页面的注入闭包逐项对应）。
// state 模拟留在页面的 @State 字段（断言从 state 读取，等价于改造前直接读页面字段）；
// p 承接控制器的游标/代际等内部量与 replySource 等页面数据源。
// ---------------------------------------------------------------------------

/** DynamicDetail / BangumiDetail 共用的楼中楼合并口径：reset 整表替换 + concat 追加。 */
function replaceOrConcatMerge(current, incoming, reset) {
  return reset ? (incoming.length > 0 ? incoming : current) : current.concat(incoming);
}

/** 构造指定页面等价的 RepliesAccess；page ∈ 'VideoDetail' | 'DynamicDetail' | 'BangumiDetail'。 */
function repliesAccess(page, state, p) {
  const video = page === 'VideoDetail';
  return {
    isDestroyed: () => state.destroyed,
    toast: () => {},
    getUIContext: () => ({}),
    resolveOid: () => (video ? state.aid : page === 'BangumiDetail' ? state.oid : state.commentId),
    resolveType: () => (page === 'DynamicDetail' ? state.commentType : 1),
    canLoadReplies: () => page !== 'DynamicDetail' || (state.commentId > 0 && state.commentType > 0),
    getMainSource: () => p.replySource,
    getSortMode: () => state.replySortMode,
    setSortMode: value => { state.replySortMode = value; },
    // 视频页的 loading/hasMore 字段叫 replyLoading/replyHasMore，动态/番剧叫 repliesLoading/repliesHasMore。
    getRepliesLoading: () => (video ? state.replyLoading : state.repliesLoading),
    setRepliesLoading: value => { if (video) state.replyLoading = value; else state.repliesLoading = value; },
    getRepliesHasMore: () => (video ? state.replyHasMore : state.repliesHasMore),
    setRepliesHasMore: value => { if (video) state.replyHasMore = value; else state.repliesHasMore = value; },
    // 视频页的响应式计数叫 replyItemCount，动态/番剧叫 repliesCount。
    getRepliesCount: () => (video ? state.replyItemCount : state.repliesCount),
    setRepliesCount: value => { if (video) state.replyItemCount = value; else state.repliesCount = value; },
    clearRepliesError: reset => {
      if (video) { state.replyLoadError = ''; return; }
      state.repliesMoreFailed = false;
      if (reset) state.repliesFailed = false;
    },
    showRepliesError: () => {
      if (video) { state.replyLoadError = '评论加载失败，请检查网络后重试'; return; }
      if (state.repliesCount === 0) state.repliesFailed = true;
      else state.repliesMoreFailed = true;
    },
    applyRepliesReset: items => {
      if (video) { p.replySource.reset(p.mergeUniqueReplies(p.localSentReplies, p.sanitizeReplies(items))); return; }
      p.replySource.reset(items);
    },
    applyRepliesAppend: items => {
      if (video) { p.appendUniqueReplies(p.replySource, items); return; }
      p.replySource.append(items);
    },
    getThreadRoot: () => state.threadRoot,
    setThreadRoot: root => { state.threadRoot = root; },
    getThreadReplies: () => state.threadReplies,
    setThreadReplies: list => { state.threadReplies = list; },
    getThreadLoading: () => state.threadLoading,
    setThreadLoading: value => { state.threadLoading = value; },
    getThreadHasMore: () => state.threadHasMore,
    setThreadHasMore: value => { state.threadHasMore = value; },
    // 动态/番剧在守卫里校验面板仍打开；视频页校验根节点与 aid 均未变。
    isThreadStale: (root, oid) => video
      ? state.threadRoot.rpid !== root || state.aid !== oid
      : !state.threadOpen || state.threadRoot.rpid !== root,
    // 视频页按 rpid 合并保留预览楼层；动态/番剧 reset 整表替换 + concat 追加。
    mergeThreadReplies: (current, incoming, reset) => video
      ? p.mergeUniqueReplies(current, incoming)
      : replaceOrConcatMerge(current, incoming, reset),
    onThreadError: () => {},
    bumpVersion: () => { state.version = (state.version || 0) + 1; },
    getVersion: () => state.version || 0,
    buildShareLink: () => '',
    renderShareCard: () => {},
    ensureShareContext: () => true,
    onShareFailed: () => {},
  };
}

test('recommendation reset supersedes old pagination and preserves new loading state', async () => {
  const old = deferred(), latest = deferred(); let calls = 0;
  const env = environment({'api/FeedApi': {FeedApi: {getRecommend: () => ++calls === 1 ? old.promise : latest.promise}}});
  const Harness = env.methodHarness('views/HomeView', '  async loadRecommend(', '  async loadHot(',
    "import { FeedApi } from '../api/FeedApi';");
  const p = new Harness();
  Object.assign(p, {recEpoch:epoch(env), recFetching:false, recHasMore:true,
    recSource:source(env, [{aid:1}]), recCount:1,
    // 曝光窗口为独立行为，本用例注入恒等桩，聚焦 reset/epoch 语义。
    filterSeen: l => l, rememberSeen: () => {}});
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
  const Change=env.methodHarness('views/DynamicView',ANCHOR.dynChangeTypeStart,ANCHOR.dynChipStart);
  const Load=env.methodHarness('views/DynamicView',ANCHOR.dynLoadFeedStart,ANCHOR.dynLoadFeedEnd,
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
    }}},'@kit.PerformanceAnalysisKit':{hilog:{}},'BuildProfile':{DEBUG:false}});
    const Harness=env.methodHarness('components/reply/RepliesController',
      ANCHOR.repliesLoadThreadStart, ANCHOR.repliesShareStart,
      "import { CommentApi } from '../../api/CommentApi';\nimport { mutateReplyInArray, mutatedReplyClone } from '../../common/ReplyMutation';");
    const p=new Harness();
    p.deliveredRevCeiling=0;
    p.replySource=source(env,[]);
    const state={destroyed:false,threadLoading:false,threadHasMore:true,threadOpen:true,
      threadRoot:{rpid:100,count:2},threadReplies:[],aid:1,oid:1,commentId:1,commentType:17};
    p.threadEpoch=epoch(env);
    p.threadCursor=''; // 控制器内部量由构造函数初始化；切片装配时手动补齐
    if (page==='VideoDetail') p.mergeUniqueReplies=(a,b)=>a.concat(b);
    p.access=repliesAccess(page,state,p);
    const first=p.loadThread(true,false);
    state.threadRoot={rpid:200,count:2};
    const second=p.loadThread(true,false);
    old.resolve({replies:[{rpid:101,rootRpid:100}],cursor:'old',hasMore:false});await first;
    assert.equal(state.threadLoading,true);assert.equal(p.threadCursor,'');assert.deepEqual(calls,[100,200]);
    latest.resolve({replies:[{rpid:201,rootRpid:200}],cursor:'new',hasMore:true});await second;
    assert.deepEqual(state.threadReplies.map(r=>r.rootRpid),[200]);
    assert.equal(p.threadCursor,'new');assert.equal(state.threadLoading,false);
  });
}

for (const page of ['VideoDetail','DynamicDetail','BangumiDetail']) {
  test(`${page} fresh server replies outrank local rev so like mirrors resync (desync regression)`, async () => {
    // 用户报告：本地点赞后重进页面，点赞态错乱/丢失。根因：服务端解析条目 rev 恒为 0，
    // ReplyCard 的镜像守卫（只接受 rev 严格更大的更新）会拒绝同会话内的所有服务端真值刷新。
    // 修复后加载交付必须携带单调递增 rev：高于此前交付值与数据源现存值。
    let serverReplies = [];
    const env = environment({'api/CommentApi': {CommentApi: {
      getReplies: async () => ({replies: serverReplies, cursor: '', hasMore: false}),
      getReplyReplies: async () => ({replies: [], cursor: '', hasMore: false})}},
      '@kit.PerformanceAnalysisKit':{hilog:{}},'BuildProfile':{DEBUG:false}});
    const Models = env.load('model/Models');
    // 服务端解析产物是 ReplyItem 实例（mutate 依赖其 clone 方法），不能用普通对象。
    const makeReply = (rpid, liked, like) => {
      const it = new Models.ReplyItem();
      it.rpid = rpid; it.liked = liked; it.like = like; it.rev = 0;
      return it;
    };
    const Harness = env.methodHarness('components/reply/RepliesController',
      ANCHOR.repliesLoadStart, ANCHOR.repliesShareStart,
      "import { CommentApi } from '../../api/CommentApi';\nimport { mutateReplyInArray, mutatedReplyClone } from '../../common/ReplyMutation';");
    const p = new Harness();
    p.deliveredRevCeiling = 0;
    p.replyCursor = '';
    p.repliesRetryReset = false;
    p.repliesEpoch = epoch(env);
    const state = {destroyed: false, aid: 42, oid: 42, commentId: 42, commentType: 17,
      replyLoading: false, replyHasMore: true, replyItemCount: 0, replySortMode: 0, replyLoadError: '',
      threadRoot: {rpid: 0, rev: 0}, threadReplies: []};
    p.access = repliesAccess(page, state, p);
    p.replySource = source(env, []);
    p.mergeUniqueReplies = (a, b) => a.concat(b);
    p.sanitizeReplies = items => items;
    p.localSentReplies = [];
    p.appendUniqueReplies = (src, items) => { for (const it of items) src.append(it); };
    // 首屏：服务端说未点赞。
    serverReplies = [makeReply(11, false, 5)];
    await p.load(true);
    let row = p.replySource.getAll()[0];
    const revAfterLoad = row.rev;
    assert.ok(revAfterLoad > 0, 'server items must be stamped above raw parse rev 0');
    // 本地点赞：数据源克隆 rev+1（等价于卡片镜像推进到同一值）。
    p.mutate(11, target => { target.liked = true; target.like = 6; });
    row = p.replySource.getAll()[0];
    assert.equal(row.liked, true);
    const revAfterTap = row.rev;
    assert.equal(revAfterTap, revAfterLoad + 1);
    // 同会话重载：服务端真值（已点赞）以更高 rev 交付，必须能通过镜像守卫刷新卡片。
    serverReplies = [makeReply(11, true, 6)];
    await p.load(true);
    row = p.replySource.getAll()[0];
    assert.equal(row.liked, true, 'server truth must survive the reload');
    assert.ok(row.rev > revAfterTap, 'fresh server truth must outrank the card mirror rev');
    // 旧代快照（重载前的旧对象，rev 更低）依然必须被守卫拒绝。
    assert.ok(revAfterTap > revAfterLoad);
  });
}


test('recommendation empty batches remain retryable and duplicate batches do not stall pagination', async () => {
  const batches = [[], [], [], [{aid: 1, bvid: 'BV1'}], [{aid: 2, bvid: 'BV2'}]];
  let calls = 0;
  const env = environment({'api/FeedApi': {FeedApi: {getRecommend: async () => { calls++; return batches.shift(); }}}});
  const Harness = env.methodHarness('views/HomeView', '  private dedupVideos(', '  async loadHot(',
    "import { FeedApi } from '../api/FeedApi';");
  const p = new Harness();
  Object.assign(p, {recEpoch: epoch(env), recFetching: false, recHasMore: true, recIdx: 0,
    recError: '', recSource: source(env, [{aid: 1, bvid: 'BV1'}]), recCount: 1});
  await p.loadRecommend(false);
  assert.equal(calls, 3);
  assert.equal(p.recHasMore, true);
  assert.equal(p.recCount, 1);
  assert.ok(p.recError.length > 0);
  await p.loadRecommend(false);
  assert.equal(calls, 5);
  assert.equal(p.recCount, 2);
  assert.equal(p.recError, '');
  assert.deepEqual(p.recSource.getAll().map(v => v.aid), [1, 2]);
});

test('favorite lists: API failure must not become a successful empty list', async () => {
  let data = null;
  class FolderPage { constructor() { this.folders = []; this.hasMore = false; } }
  class VideoPage { constructor() { this.videos = []; this.hasMore = false; } }
  const env = environment({
    'services/network/HttpClient': {}, 'common/AppSign': {},
    'common/Constants': { Api: {} },
    'common/Utils': { asArray: value => Array.isArray(value) ? value : [],
      asObject: value => value || {}, asBool: (value, fallback) => value ?? fallback,
      asNumber: (value, fallback) => typeof value === 'number' ? value : fallback },
    'model/Models': { FavoriteFolderPageData: FolderPage, FavoriteVideoPageData: VideoPage },
    'api/internal/ApiCommon': { webGet: async () => ({}), getData: () => data }
  });
  const { FavoriteApi } = env.load('api/FavoriteApi');
  for (const method of ['getFavoriteFolders', 'getFavoriteVideos', 'getCollectedFolders', 'getCollectionVideos']) {
    data = null;
    await assert.rejects(() => FavoriteApi[method](1, 1), /加载失败/);
    data = { list: [], medias: [], has_more: false };
    const result = await FavoriteApi[method](1, 1);
    assert.equal((result.folders || result.videos).length, 0);
    assert.equal(result.hasMore, false);
  }
});

test('live zones: returning invalidates old responses; pagination failure retains page for retry', async () => {
  const old = deferred(), fresh = deferred(); let calls = 0;
  const env = environment({
    'api/LiveApi': { LiveApi: { getLiveZoneRooms: () => ++calls === 1 ? old.promise : fresh.promise } },
    'common/Haptic': { Haptic: { tap() {} } }
  });
  const Harness = env.methodHarness('pages/LiveZonePage', '  async loadRooms(', '  @Builder\n  ZoneGrid()',
    "import { LiveApi } from '../api/LiveApi';\nimport { Haptic } from '../common/Haptic';");
  const page = new Harness();
  Object.assign(page, { zoneId: 1, page: 1, hasMore: true, loading: false, roomEpoch: epoch(env),
    roomSource: source(env), failed: false, errorText: '', findZoneName: id => String(id) });
  const pending = page.loadRooms(true);
  page.backToZones();
  page.selectZone(2);
  old.resolve([{ roomId: 10 }]); await pending;
  assert.equal(page.loading, true);
  assert.equal(page.roomSource.totalCount(), 0);
  fresh.resolve(Array.from({ length: 20 }, (_, i) => ({ roomId: 20 + i }))); await tick();
  assert.equal(page.roomSource.getAll()[0].roomId, 20);
  assert.equal(page.loading, false);

  const requests = [];
  const failingEnv = environment({ 'api/LiveApi': { LiveApi: { getLiveZoneRooms: async (zone, pn) => {
    requests.push(pn); if (requests.length === 1) throw new Error('offline'); return [{ roomId: 99 }];
  } } } });
  const RetryHarness = failingEnv.methodHarness('pages/LiveZonePage', '  async loadRooms(', '  selectZone(',
    "import { LiveApi } from '../api/LiveApi';");
  const retry = new RetryHarness();
  Object.assign(retry, { zoneId: 2, page: 1, hasMore: true, loading: false, roomEpoch: epoch(failingEnv),
    roomSource: source(failingEnv, [{ roomId: 20 }]), failed: false, errorText: '' });
  await retry.loadRooms(false);
  assert.equal(retry.failed, true); assert.equal(retry.page, 1);
  assert.equal(retry.roomSource.totalCount(), 1);
  await retry.loadRooms(false);
  assert.deepEqual(requests, [2, 2]);
  assert.equal(retry.failed, false); assert.equal(retry.roomSource.totalCount(), 2);
});

for (const [file, method] of [['RelationList', 'getRelationUsers'], ['BlackListPage', 'getBlackList']]) {
  test(file + ': failed pagination preserves cursor and leaving invalidates response', async () => {
    const pending = deferred(); const pages = []; let count = 0;
    const env = environment({ 'api/UserApi': { UserApi: { [method]: async (...args) => {
      pages.push(args.at(-1)); count++;
      if (count === 1) throw new Error('offline');
      if (count === 2) return { users: [{ mid: 2 }], total: 4 };
      return pending.promise;
    } } } });
    const Harness = env.methodHarness('pages/' + file, '  private async load(', '  private openUser(',
      "import { UserApi } from '../api/UserApi';");
    const view = new Harness();
    // 关注/粉丝与黑名单已改造为 BasicDataSource 增量 append，这里注入真实数据源并按行数断言。
    Object.assign(view, { param: { mid: 1, mode: 'following' }, usersSource: source(env, [{ mid: 1 }]),
      userCount: 1, total: 4,
      page: 2, loading: false, failed: false, destroyed: false, hasMore: true, requestEpoch: epoch(env) });
    await view.load(false);
    assert.equal(view.failed, true); assert.equal(view.page, 2);
    assert.equal(view.usersSource.totalCount(), 1); assert.equal(view.userCount, 1);
    await view.load(false);
    assert.deepEqual(pages, [2, 2]); assert.equal(view.failed, false);
    assert.equal(view.usersSource.totalCount(), 2); assert.equal(view.userCount, 2);
    const old = view.load(false);
    view.requestEpoch.invalidate(); view.destroyed = true;
    pending.resolve({ users: [{ mid: 3 }], total: 4 }); await old;
    assert.equal(view.usersSource.totalCount(), 2); assert.equal(view.userCount, 2);
  });
}

test('watch later: leaving during account preparation prevents a list request', async () => {
  const ready = deferred();
  const env = environment({ 'services/auth/UserStore': { UserStore: { ensureLoaded: () => ready.promise, isLogin: true } } });
  const Harness = env.methodHarness('pages/library/WatchLaterPage', '  private async prepareAndLoad(', '  async load(',
    "import { UserStore } from '../../services/auth/UserStore';");
  const view = new Harness(); let calls = 0;
  Object.assign(view, { prepareEpoch: epoch(env), destroyed: false, preparing: false,
    load: async () => calls++ });
  const pending = view.prepareAndLoad();
  view.destroyed = true; view.prepareEpoch.invalidate(); ready.resolve(); await pending;
  assert.equal(calls, 0);
});

test('precious ranking: loads beyond first page and retries the failed page without losing items', async () => {
  const pages = []; let failedOnce = false;
  const env = environment({ 'api/SearchApi': { SearchApi: { getPopularPrecious: async page => {
    pages.push(page);
    if (page === 1) return Array.from({ length: 100 }, (_, i) => ({ aid: i + 1 }));
    if (!failedOnce) { failedOnce = true; throw new Error('offline'); }
    return [{ aid: 101 }];
  } } } });
  const Harness = env.methodHarness('pages/RankPage', '  async loadPrecious(', '  onTabChanged(',
    "import { SearchApi } from '../api/SearchApi';");
  const view = new Harness();
  Object.assign(view, { destroyed: false, lifecycleGeneration: 0, preciousLoading: false,
    preciousHasMore: true, preciousPage: 0, preciousCount: 0, preciousSource: source(env), preciousError: '' });
  await view.loadPrecious(); assert.equal(view.preciousHasMore, true);
  await view.loadPrecious(false);
  assert.equal(view.preciousCount, 100); assert.equal(view.preciousPage, 1);
  assert.notEqual(view.preciousError, '');
  await view.loadPrecious(false);
  assert.deepEqual(pages, [1, 2, 2]); assert.equal(view.preciousCount, 101);
  assert.equal(view.preciousHasMore, false);
  await view.loadPrecious(false); assert.equal(pages.length, 3);
});

test('video zones: an old category response cannot replace a newer list', async () => {
  const old = deferred(), next = deferred(); let calls = 0;
  const env = environment({ 'api/SearchApi': { SearchApi: {
    getRankVideos: () => ++calls === 1 ? old.promise : next.promise
  } } });
  const Harness = env.methodHarness('pages/ZoneChannelPage', '  async load(', '  @Builder\n  ZoneVideos()',
    "import { SearchApi } from '../api/SearchApi';");
  const view = new Harness();
  Object.assign(view, { loading: false, zoneId: 1, failed: false, errorText: '',
    requestEpoch: epoch(env), videoSource: source(env) });
  const pendingOld = view.load(true);
  view.requestEpoch.invalidate(); view.loading = false; view.zoneId = 3;
  const pendingNext = view.load(true);
  old.resolve([{ aid: 1 }]); await pendingOld;
  assert.equal(view.loading, true); assert.equal(view.videoSource.totalCount(), 0);
  next.resolve([{ aid: 3 }]); await pendingNext;
  assert.equal(view.loading, false); assert.equal(view.videoSource.getAll()[0].aid, 3);
});

test('search pagination: a failed page keeps results; retry reaches a finite end', async () => {
  const pages = []; let failed = false;
  const env = environment({ 'api/SearchApi': { SearchApi: { searchUsers: async (kw, page) => {
    pages.push(page);
    if (page === 1) return { users: [{ mid: 1 }], numResults: 2 };
    if (!failed) { failed = true; throw new Error('offline'); }
    return { users: [{ mid: 2 }], numResults: 2 };
  } } } });
  const Harness = env.methodHarness('pages/Search', '  async doSearch(', '  /** 综合搜索翻页合并',
    "import { SearchApi } from '../api/SearchApi';");
  const page = new Harness();
  Object.assign(page, { keyword: 'test', destroyed: false, searchInflight: false,
    searchRequests: epoch(env), searchTab: 6, userPage: 1, userOrder: '', userType: 0,
    userSource: source(env), hasMoreResults: true, searchError: '', moreError: '' });
  await page.doSearch(true); assert.equal(page.hasMoreResults, true);
  await page.doSearch(false);
  assert.equal(page.searchError, ''); assert.equal(page.moreError, 'offline');
  assert.equal(page.userSource.totalCount(), 1); assert.equal(page.userPage, 2);
  await page.doSearch(false);
  assert.deepEqual(pages, [1, 2, 2]); assert.equal(page.moreError, '');
  assert.equal(page.userSource.totalCount(), 2); assert.equal(page.hasMoreResults, false);
  await page.doSearch(false); assert.equal(pages.length, 3);
});

test('search text: decodes entities once after removing highlight markup', () => {
  const { searchPlainText } = environment().load('common/Utils');
  assert.equal(searchPlainText('<em class="keyword">标题</em> &quot;测试&quot; &amp; &#39;'), '标题 "测试" & \'');
  assert.equal(searchPlainText('&#x1F600; &lt;原文&gt; &amp;quot;'), '😀 <原文> &quot;');
  assert.equal(searchPlainText('&#x110000; &#xD800; &unknown;'), '&#x110000; &#xD800; &unknown;');
});

test('live search: category and broadcaster names contain plain text, not highlight tags', () => {
  const { LiveRoomItem } = environment().load('model/LiveModels');
  const room = LiveRoomItem.fromSearch({ roomid: 1, title: '<em>直播</em>',
    uname: '<em>UP</em>&amp;朋友', cate_name: '<em class="keyword">明日方舟</em>' });
  assert.equal(room.title, '直播'); assert.equal(room.uname, 'UP&朋友'); assert.equal(room.areaName, '明日方舟');
});


test('dynamic detail: failed continuation preserves comments and retries the same cursor', async () => {
  const calls = [];
  const env = environment({'api/CommentApi': {CommentApi: {getReplies: async (_id, _type, cursor) => {
    calls.push(cursor);
    if (calls.length === 1) throw new Error('offline');
    return {replies: [{rpid: 2}], cursor: '3', hasMore: false};
  }}}});
  const Harness = env.methodHarness('components/reply/RepliesController', ANCHOR.repliesLoadStart,
    ANCHOR.repliesChangeSortStart, "import { CommentApi } from '../../api/CommentApi';");
  const page = new Harness();
  const state = {destroyed: false, repliesLoading: false, repliesFailed: false, repliesMoreFailed: false,
    repliesHasMore: true, repliesCount: 1, replySortMode: 3, commentId: 1, commentType: 11,
    threadRoot: {rpid: 0}, threadReplies: [], threadLoading: false, threadHasMore: true, threadOpen: false};
  page.repliesEpoch = epoch(env);
  page.replySource = source(env, [{rpid: 1}]);
  page.stampServerRevs = items => items;
  page.replyCursor = '2';
  page.access = repliesAccess('DynamicDetail', state, page);
  await page.load(false);
  assert.equal(state.repliesMoreFailed, true);
  assert.equal(state.repliesFailed, false);
  assert.equal(page.replyCursor, '2');
  assert.deepEqual(page.replySource.getAll(), [{rpid: 1}]);
  await page.load(false);
  assert.deepEqual(calls, ['2', '2']);
  assert.deepEqual(page.replySource.getAll(), [{rpid: 1}, {rpid: 2}]);
  assert.equal(state.repliesMoreFailed, false);
  assert.equal(state.repliesHasMore, false);
  await page.load(false);
  assert.equal(calls.length, 2);
});


test('image return: zoomed image restores its transform before starting the return transition', () => {
  const env = environment();
  const Parent = env.methodHarness('pages/ImageViewer', '  goBack(): void {', '  private finishBack():');
  const parent = new Parent(); let flights = 0;
  Object.assign(parent, {closing: false, interactionReady: true, currentZoomed: true,
    resetZoomForExit: false, finishBack: () => flights++});
  parent.goBack();
  assert.equal(parent.resetZoomForExit, true);
  assert.equal(flights, 0);
  parent.goBack();
  assert.equal(flights, 0);
  const Child = env.methodHarness('pages/ImageViewer', '  private prepareExit(): void {', '  private clampScale(');
  const child = new Child(); let finish;
  Object.assign(child, {exitRequested: true, scaleValue: 3, offsetX: 100, offsetY: -50,
    getUIContext: () => ({animateTo: (options, update) => {update(); finish = options.onFinish;}}),
    onZoomChange: value => {parent.currentZoomed = value;}, onExitReady: () => parent.finishBack()});
  global.Curve = {EaseOut: 0};
  try {
    child.prepareExit();
    assert.deepEqual([child.scaleValue, child.offsetX, child.offsetY], [1, 0, 0]);
    assert.equal(flights, 0);
    finish();
    assert.equal(flights, 1);
    assert.equal(parent.currentZoomed, false);
  } finally {delete global.Curve;}
});


test('live quality: failed requests preserve playback and release busy state; late failure stays silent', async () => {
  let task = Promise.resolve(null); const notices = [];
  const env = environment({'api/LiveApi': {LiveApi: {getLivePlayInfo: () => task}}});
  const Harness = env.methodHarness('pages/LiveRoom', '  async changeQuality(', '  /** 同步到直播最新状态',
    "import { LiveApi } from '../api/LiveApi';");
  const page = new Harness(); const original = {url: 'current'};
  Object.assign(page, {qualityLoading: false, refreshing: false, loading: false, destroyed: false,
    lifecycleGeneration: 1, param: {roomId: 1}, playInfo: original,
    getUIContext: () => ({getPromptAction: () => ({showToast: value => notices.push(value.message)})})});
  await page.changeQuality(80);
  assert.equal(page.playInfo, original);
  assert.equal(page.qualityLoading, false);
  assert.equal(notices.length, 1);
  task = Promise.resolve({url: 'new'});
  await page.changeQuality(80);
  assert.equal(page.playInfo.url, 'new');
  const pending = deferred(); task = pending.promise;
  const request = page.changeQuality(80);
  page.destroyed = true; page.lifecycleGeneration++;
  pending.reject(new Error('offline')); await request;
  assert.equal(notices.length, 1);
  assert.equal(page.playInfo.url, 'new');
});


test('live fullscreen: re-entry cancels the old delayed portrait callback', async () => {
  const transitions = [];
  const env = environment({'common/Immersive': {Immersive: {setFullscreen() {}}}});
  const Harness = env.methodHarness('components/live/LivePlayerView', '  toggleFullscreen(): void {', '  qualityLabel():',
    "import { Immersive } from '../../common/Immersive';");
  const page = new Harness();
  Object.assign(page, {fullscreen: true, fullscreenTimer: -1, destroyed: false, playing: true,
    dmRenderer: {setPlayback() {}}, onFullscreenChange: value => transitions.push(value)});
  page.exitFullscreen();
  page.toggleFullscreen();
  await new Promise(resolve => setTimeout(resolve, 260));
  assert.equal(page.fullscreen, true);
  assert.deepEqual(transitions, [true]);
  assert.equal(env.storage.get('livePlayerFullscreen'), true);
  page.exitFullscreen();
  await new Promise(resolve => setTimeout(resolve, 260));
  assert.deepEqual(transitions, [true, false]);
  assert.equal(env.storage.get('livePlayerFullscreen'), false);
});


test('bangumi index: latest filter wins and failed pagination retries the same page', async () => {
  const old = deferred(), latest = deferred(); const calls = []; let attempt = 0;
  const env = environment({'api/BangumiApi': {BangumiApi: {getIndex: (_type, _finish, page) => {
    calls.push(page); attempt++;
    if (attempt === 1) return old.promise;
    if (attempt === 2) return latest.promise;
    if (attempt === 3) return Promise.reject(new Error('offline'));
    return Promise.resolve({items: [{seasonId: 3}], hasNext: false, total: 2});
  }}}});
  const Harness = env.methodHarness('pages/BangumiIndexPage', '  async load(reset:', '  @Builder',
    "import { BangumiApi } from '../api/BangumiApi';");
  const page = new Harness();
  Object.assign(page, {destroyed: false, requestEpoch: epoch(env), source: source(env),
    type: 1, finish: -1, loading: false, page: 1, hasMore: true});
  const first = page.load(true);
  page.switchFilter(2, -1);
  latest.resolve({items: [{seasonId: 2}], hasNext: true, total: 2}); await tick();
  old.resolve({items: [{seasonId: 1}], hasNext: false, total: 1}); await first;
  assert.deepEqual(page.source.getAll(), [{seasonId: 2}]);
  await page.load(false);
  assert.equal(page.moreFailed, true); assert.equal(page.page, 1);
  assert.deepEqual(page.source.getAll(), [{seasonId: 2}]);
  await page.load(false);
  assert.deepEqual(calls, [1, 1, 2, 2]);
  assert.equal(page.moreFailed, false); assert.equal(page.hasMore, false);
  assert.deepEqual(page.source.getAll(), [{seasonId: 2}, {seasonId: 3}]);
});


test('timeline: year boundary stays chronological and episode numbers use the published index', () => {
  const env = environment();
  const {TimeLineDay, TimeLineEpisode} = env.load('model/discovery/DiscoveryModels');
  const Harness = env.methodHarness('pages/BangumiTimelinePage', '  private mergeDays(', '  @Builder',
    "import { TimeLineDay } from '../model/discovery/DiscoveryModels';");
  const dec = new TimeLineDay(); Object.assign(dec, {date: '12-31', dateTimestamp: 100, isToday: true,
    episodes: [{pubTime: '18:00'}]});
  const jan = new TimeLineDay(); Object.assign(jan, {date: '1-1', dateTimestamp: 200, episodes: []});
  const extra = new TimeLineDay(); Object.assign(extra, {date: '12-31', dateTimestamp: 100,
    episodes: [{pubTime: '09:00'}]});
  const merged = new Harness().mergeDays([dec, jan], [extra]);
  assert.deepEqual(merged.map(day => day.date), ['12-31', '1-1']);
  assert.equal(merged[0].isToday, true);
  assert.deepEqual(merged[0].episodes.map(ep => ep.pubTime), ['09:00', '18:00']);
  assert.equal(dec.episodes.length, 1);
  assert.equal(TimeLineEpisode.from({pub_index: '第11话'}).index, '第11话');
});

function bangumiRepliesHarness(api) {
  const env = environment({'api/CommentApi': {CommentApi: api}});
  const Harness = env.methodHarness('components/reply/RepliesController', ANCHOR.repliesLoadStart,
    ANCHOR.repliesMutateStart, "import { CommentApi } from '../../api/CommentApi';");
  const p = new Harness();
  const state = {destroyed:false, repliesLoading:false, repliesFailed:false, repliesMoreFailed:false,
    repliesHasMore:true, repliesCount:0, replySortMode:3, oid:1,
    threadRoot:{rpid:0}, threadReplies:[], threadLoading:false, threadHasMore:true, threadOpen:false};
  p.repliesEpoch = epoch(env);
  p.replySource = source(env);
  p.stampServerRevs = items => items;
  // 番剧切排序清空列表与游标（构造参数不在切片内，装配时补齐页面取值）。
  p.clearOnSort = true;
  p.access = repliesAccess('BangumiDetail', state, p);
  return {p, state};
}

test('PGC episode and sort changes supersede pending comments without old loading writes', async () => {
  const old=deferred(), latest=deferred(); const calls=[];
  const {p, state}=bangumiRepliesHarness({getReplies:(oid,type,cursor,mode)=> {
    calls.push({oid,mode}); return calls.length===1 ? old.promise : latest.promise;
  }});
  const first=p.load(true);
  state.oid=2; p.changeReplySort(2);
  assert.deepEqual(calls,[{oid:1,mode:3},{oid:2,mode:2}]);
  old.resolve({replies:[{rpid:1}],cursor:'old',hasMore:false}); await first;
  assert.deepEqual(p.replySource.getAll(),[]); assert.equal(state.repliesLoading,true);
  latest.resolve({replies:[{rpid:2}],cursor:'new',hasMore:true}); await tick();
  assert.deepEqual(p.replySource.getAll(),[{rpid:2}]); assert.equal(p.replyCursor,'new');
  assert.equal(state.repliesLoading,false);
});

test('PGC failed pagination preserves comments and cursor for same-page retry', async () => {
  const cursors=[];
  const {p, state}=bangumiRepliesHarness({getReplies:async(oid,type,cursor)=> {
    cursors.push(cursor); if(cursors.length===1) throw Error('offline');
    return {replies:[{rpid:2}],cursor:'end',hasMore:false};
  }});
  p.replySource.reset([{rpid:1}]); state.repliesCount=1; p.replyCursor='next';
  await p.load(false);
  assert.deepEqual(p.replySource.getAll(),[{rpid:1}]); assert.equal(state.repliesMoreFailed,true);
  assert.equal(state.repliesFailed,false); assert.equal(p.replyCursor,'next');
  await p.load(false);
  assert.deepEqual(cursors,['next','next']); assert.deepEqual(p.replySource.getAll(),[{rpid:1},{rpid:2}]);
  assert.equal(state.repliesMoreFailed,false); assert.equal(state.repliesHasMore,false);
});

function videoRepliesHarness(api) {
  const env=environment({'api/CommentApi':{CommentApi:api}});
  const Harness=env.methodHarness('components/reply/RepliesController',ANCHOR.repliesLoadStart,
    ANCHOR.repliesLoadThreadStart,"import { CommentApi } from '../../api/CommentApi';");
  const p=new Harness();
  const state={destroyed:false, replyLoading:false, replyLoadError:'', replyHasMore:true, replySortMode:3,
    replyItemCount:1, aid:1, threadRoot:{rpid:0}, threadReplies:[], threadLoading:false,
    threadHasMore:true, threadOpen:false};
  p.repliesEpoch=epoch(env);
  p.replySource=source(env,[{rpid:1}]);
  p.replyCursor='next'; // 控制器内部量由构造函数初始化；切片装配时手动补齐
  p.threadCursor='';
  p.localSentReplies=[];
  p.sanitizeReplies=items=>items;
  p.mergeUniqueReplies=(a,b)=>a.concat(b);
  p.appendUniqueReplies=(s,items)=>s.reset(s.getAll().concat(items));
  // 切片不含 stampServerRevs（定义在 mutate 之后），本组断言与打桩无关，恒等桩即可。
  p.stampServerRevs=items=>items;
  // 视频页切排序清空列表与游标（构造参数不在切片内，装配时补齐页面取值）。
  p.clearOnSort=true;
  p.access=repliesAccess('VideoDetail',state,p);
  return {p,state};
}

test('video comments: latest sort wins while an earlier page fails', async()=>{
  const old=deferred(), latest=deferred();const modes=[];
  const {p,state}=videoRepliesHarness({getReplies:(oid,type,cursor,mode)=>{
    modes.push(mode);return modes.length===1?old.promise:latest.promise;
  }});
  const pending=p.load(false);p.changeReplySort(2);
  old.reject(Error('offline'));await pending;
  assert.deepEqual(modes,[3,2]);assert.equal(state.replyLoading,true);assert.equal(state.replyLoadError,'');
  latest.resolve({replies:[{rpid:2}],cursor:'done',hasMore:false});await tick();
  assert.deepEqual(p.replySource.getAll(),[{rpid:2}]);assert.equal(state.replyLoading,false);
});

test('video comments: pagination error retains content and retries the same cursor',async()=>{
  const cursors=[];const {p,state}=videoRepliesHarness({getReplies:async(oid,type,cursor)=>{
    cursors.push(cursor);if(cursors.length===1)throw Error('offline');
    return {replies:[{rpid:2}],cursor:'done',hasMore:false};
  }});
  await p.load(false);
  assert.ok(state.replyLoadError);assert.deepEqual(p.replySource.getAll(),[{rpid:1}]);
  assert.equal(p.replyCursor,'next');assert.equal(state.replyLoading,false);
  await p.load(false);
  assert.deepEqual(cursors,['next','next']);assert.equal(state.replyLoadError,'');
  assert.deepEqual(p.replySource.getAll(),[{rpid:1},{rpid:2}]);
});

 test('article reader: preserves full content and escapes header text',()=>{
  const env=environment();const render=env.load('common/ArticleHtml').articleHtml;
  const html=render({title:'<title>&',author:'A&B',content:'<p>Beginning</p><img src="//i0.hdslb.com/test.jpg"><p>Final paragraph</p>'},true);
  assert.ok(html.includes('&lt;title&gt;&amp;'));assert.ok(html.includes('A&amp;B'));
  assert.ok(html.includes('<p>Final paragraph</p>'));assert.ok(html.includes('src="https://i0.hdslb.com/test.jpg"'));
  assert.ok(html.includes('Content-Security-Policy'));assert.ok(html.includes('max-width:100%'));
 });
 test('article reader: leaving invalidates a pending document response',async()=>{
  const pending=deferred();const env=environment({'api/ArticleApi':{ArticleApi:{getArticle:()=>pending.promise}}});
  const Harness=env.methodHarness('pages/ArticlePage','  private async loadArticle(', '  build()',
    "import { ArticleApi } from '../api/ArticleApi';");
  const p=new Harness();Object.assign(p,{request:epoch(env),param:{id:1},article:null});
  const task=p.loadArticle();p.request.invalidate();pending.resolve({title:'late',content:'late'});await task;
  assert.equal(p.article,null);
 });

 test('article images: failed native download releases the Web response',async()=>{
  const env=environment({'services/network/HttpClient':{HttpClient:{getBinary:async()=>{throw Error('offline')}}}});
  const Harness=env.methodHarness('pages/ArticlePage','  private async loadImage(', '  build()',
    "import { HttpClient } from '../services/network/HttpClient';");
  const p=new Harness();let status=0,ready=false;
  await p.loadImage('https://i0.hdslb.com/a.jpg',{setResponseCode(v){status=v},setReasonMessage(){},setResponseIsReady(v){ready=v}});
  assert.equal(status,502);assert.equal(ready,true);
 });

test('article links: user navigation opens separately while anchors and document loading stay inside',()=>{
  const env=environment();const Harness=env.methodHarness('pages/ArticlePage','  private interceptNavigation(', '  private async loadImage(');
  const p=new Harness();const opened=[];Object.assign(p,{param:{id:123},openArticleLink:url=>opened.push(url)});
  assert.equal(p.interceptNavigation('https://example.com/read?a=B',true,true),true);
  assert.deepEqual(opened,['https://example.com/read?a=B']);
  assert.equal(p.interceptNavigation('https://www.bilibili.com/read/cv123#section',true,true),false);
  assert.equal(p.interceptNavigation('data:text/html;charset=utf-8,test',true,false),false);
  assert.equal(p.interceptNavigation('about:blank',true,false),false);
  assert.equal(p.interceptNavigation('bilibili://article/123',true,true),true);
  assert.equal(opened.length,1);
});

test('article spacing: drops styled empty paragraphs but retains text and inline images',()=>{
  const env=environment();const render=env.load('common/ArticleHtml').articleHtml;
  const html=render({title:'Title',author:'Author',content:'<p style="text-align:left"><strong><br/></strong></p><p><span>Real text</span></p><p><img src="https://i0.hdslb.com/a.jpg"></p>'},false);
  assert.equal(html.includes('<strong><br/></strong>'),false);
  assert.ok(html.includes('<p><span>Real text</span></p>'));
  assert.ok(html.includes('<p><img src="https://i0.hdslb.com/a.jpg"></p>'));
});

test('dynamic comments: sorting during loading drops the old response',async()=>{
  const old=deferred(),latest=deferred();let calls=0;
  const env=environment({'api/CommentApi':{CommentApi:{getReplies:()=>++calls===1?old.promise:latest.promise}}});
  const Harness=env.methodHarness('components/reply/RepliesController',ANCHOR.repliesLoadStart,
    ANCHOR.repliesMutateStart,"import { CommentApi } from '../../api/CommentApi';");
  const p=new Harness();
  const state={destroyed:false,repliesLoading:false,repliesFailed:false,repliesMoreFailed:false,
    repliesHasMore:true,repliesCount:0,replySortMode:3,commentId:1,commentType:11,
    threadRoot:{rpid:0},threadReplies:[],threadLoading:false,threadHasMore:true,threadOpen:false};
  p.repliesEpoch=epoch(env);
  p.replySource=source(env);
  p.stampServerRevs=items=>items;
  // 动态页切排序特意不清列表（构造参数不在切片内，装配时补齐页面取值）。
  p.clearOnSort=false;
  p.access=repliesAccess('DynamicDetail',state,p);
  const pending=p.load(true);p.changeReplySort(2);
  old.resolve({replies:[{rpid:1}],cursor:'old',hasMore:false});await pending;
  assert.equal(calls,2);assert.deepEqual(p.replySource.getAll(),[]);assert.equal(state.repliesLoading,true);
  latest.resolve({replies:[{rpid:2}],cursor:'new',hasMore:false});await tick();
  assert.deepEqual(p.replySource.getAll(),[{rpid:2}]);assert.equal(p.replyCursor,'new');assert.equal(state.repliesLoading,false);
});

test('dynamic comments: changing sort keeps visible rows until replacement and preserves them on failure',async()=>{
  const failed=deferred(),retry=deferred();const calls=[];
  const env=environment({'api/CommentApi':{CommentApi:{getReplies:(id,type,cursor,mode)=>{
    calls.push({cursor,mode});return calls.length===1?failed.promise:retry.promise;
  }}}});
  const Harness=env.methodHarness('components/reply/RepliesController',ANCHOR.repliesLoadStart,
    ANCHOR.repliesMutateStart,"import { CommentApi } from '../../api/CommentApi';");
  const p=new Harness();
  const state={destroyed:false,repliesLoading:false,repliesFailed:false,repliesMoreFailed:false,
    repliesHasMore:false,repliesCount:1,replySortMode:3,commentId:1,commentType:11,
    threadRoot:{rpid:0},threadReplies:[],threadLoading:false,threadHasMore:true,threadOpen:false};
  p.repliesEpoch=epoch(env);
  p.replySource=source(env,[{rpid:9}]);
  p.replyCursor='old';
  p.stampServerRevs=items=>items;
  // 动态页切排序特意不清列表（构造参数不在切片内，装配时补齐页面取值）。
  p.clearOnSort=false;
  p.access=repliesAccess('DynamicDetail',state,p);
  p.changeReplySort(2);assert.deepEqual(p.replySource.getAll(),[{rpid:9}]);assert.equal(state.repliesLoading,true);
  failed.reject(Error('offline'));await tick();
  assert.deepEqual(p.replySource.getAll(),[{rpid:9}]);assert.equal(p.replyCursor,'old');
  assert.equal(state.repliesMoreFailed,true);assert.equal(p.repliesRetryReset,true);
  const pending=p.load(state.repliesMoreFailed&&p.repliesRetryReset);
  retry.resolve({replies:[{rpid:10}],cursor:'new',hasMore:true});await pending;
  assert.deepEqual(calls,[{cursor:'',mode:2},{cursor:'',mode:2}]);assert.deepEqual(p.replySource.getAll(),[{rpid:10}]);
});

test('dynamic feed: failed continuation keeps cards and offset, then retries the same page',async()=>{
  let calls=0;const offsets=[];const env=environment({'api/DynamicApi':{DynamicApi:{getDynamicFeed:async off=>{
    offsets.push(off);if(++calls===1)throw Error('offline');return {items:[{dynId:'2'}],offset:'end',hasMore:false};
  }}}});
  const Harness=env.methodHarness('views/DynamicView',ANCHOR.dynLoadFeedStart,ANCHOR.dynLoadFeedEnd,
    "import { DynamicApi } from '../api/DynamicApi';");
  const p=new Harness();Object.assign(p,{feedEpoch:epoch(env),feedLoading:false,dynHasMore:true,
    dynOffset:'next',dynSource:source(env,[{dynId:'1'}]),hostMid:0,dynType:'all'});
  await p.loadFeed(false);assert.equal(p.feedMoreFailed,true);assert.equal(p.dynOffset,'next');
  assert.deepEqual(p.dynSource.getAll(),[{dynId:'1'}]);await p.loadFeed(false);
  assert.deepEqual(offsets,['next','next']);assert.equal(p.feedMoreFailed,false);
  assert.deepEqual(p.dynSource.getAll(),[{dynId:'1'},{dynId:'2'}]);
});

test('dynamic API: unsuccessful response is not a successful empty feed',()=>{
  const env=environment();const Harness=env.methodHarness('api/DynamicApi','  private static parseDynamicPage(', '\n}',
    "import {asArray,asBool,asNumber,str} from '../common/Utils'; const getData=r=>r.data; class DynamicPageData {items=[];offset='';hasMore=false;}");
  assert.throws(()=>Harness.parseDynamicPage({data:null,status:200,json:()=>({code:-500})}),/动态加载失败/);
  assert.throws(()=>Harness.parseDynamicPage({data:null,status:200,json:()=>({code:-101})}),/登录已失效/);
  assert.throws(()=>Harness.parseDynamicPage({data:null,status:-1,transportCode:2300028,
    transportMessage:'请求超时，请稍后重试',json:()=>({})}),/请求超时/);
  assert.throws(()=>Harness.parseDynamicPage({data:{}}),/响应格式异常/);
  assert.deepEqual(Harness.parseDynamicPage({data:{items:[],has_more:false}}).items,[]);
});

test('dynamic recovery: expired login navigates to login while pagination retains its retry mode',()=>{
  const env=environment();const Harness=env.methodHarness('views/DynamicView','  private recoverFeed(', '  /** 并行拉取关注 UP 主',
    "const NAV_LOGIN='Login'; const AppNavStack={pushPathByName:()=>globalThis.__dynamicLoginCount++};");
  globalThis.__dynamicLoginCount=0;const p=new Harness();const resets=[];
  Object.assign(p,{feedNeedsLogin:true,dynCount:3,feedMoreFailed:true,feedRetryReset:false,loadFeed:r=>resets.push(r)});
  p.recoverFeed();assert.equal(globalThis.__dynamicLoginCount,1);assert.deepEqual(resets,[]);
  p.feedNeedsLogin=false;p.recoverFeed();assert.deepEqual(resets,[false]);
  delete globalThis.__dynamicLoginCount;
});
