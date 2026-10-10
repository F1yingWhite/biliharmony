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

// 评论分页、线程会话与 rev 的回归用例迁入 reply-state.test.cjs，直接加载完整生产模块。

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

async function homeChannels(hot, live) {
  const {homeFeedFixture}=require('./home-feed-fixture.cjs');let priming=true;
  const f=homeFeedFixture({hot:page=>priming?Promise.resolve(Array(20).fill({aid:1,bvid:'BV1'})):hot(page),
    live:page=>priming?Promise.resolve(Array(20).fill({roomId:1})):live(page)});
  await f.ctl.activate();
  await f.ctl.load(1,true);await f.ctl.load(1,false);
  await f.ctl.load(2,true);await f.ctl.load(2,false);await f.ctl.load(2,false);
  priming=false;
  return {feed:f.ctl,hotSource:f.ctl.hot,liveSource:f.ctl.live,
    get hotPage(){return f.state(1).page;},get livePage(){return f.state(2).page;},
    get refreshingChannels(){return f.snapshots.at(-1).channels.map(s=>s.refreshing);},
    get loadingChannels(){return f.snapshots.at(-1).channels.map(s=>s.loading);},
    channelHasMore:index=>f.state(index).hasMore,channelError:index=>f.state(index).error,
    onRefresh:index=>f.ctl.load(index,true),onReachEnd:index=>f.ctl.load(index,false),retryMore:index=>f.ctl.retry(index)};
}

for (const channel of [1,2]) {
  test(`home channel ${channel}: refresh supersedes pagination and ignores its late response`, async () => {
    const old=deferred(), fresh=deferred(); const pages=[];
    const fetch=(page)=>{pages.push(page);return pages.length===1?old.promise:fresh.promise;};
    const p=await homeChannels(fetch,fetch);
    p.onReachEnd(channel);
    p.onRefresh(channel);
    assert.deepEqual(pages,[channel===1?3:4,1]);
    assert.equal(p.loadingChannels[channel],false);
    old.resolve([{aid:99,roomId:99}]); await tick();
    assert.equal(p.refreshingChannels[channel],true);
    const source=channel===1?p.hotSource:p.liveSource;
    assert.equal(source.getData(0)[channel===1?'aid':'roomId'],1);
    fresh.resolve([{aid:2,roomId:2}]); await tick();
    assert.equal(source.getData(0)[channel===1?'aid':'roomId'],2);
    assert.equal(p.refreshingChannels[channel],false);
  });

  test(`home channel ${channel}: failure preserves cursor and retry mode`, async () => {
    const pages=[]; let fail=true;
    const fetch=async(page)=>{pages.push(page);if(fail)throw new Error('offline');return [{aid:2,roomId:2}];};
    const p=await homeChannels(fetch,fetch);
    p.onReachEnd(channel);await tick();
    assert.equal(channel===1?p.hotPage:p.livePage,channel===1?3:4);
    assert.equal(p.channelHasMore(channel),true);
    assert.ok(p.channelError(channel));
    p.onReachEnd(channel);await tick();assert.equal(pages.length,1);
    fail=false;p.retryMore(channel);await tick();
    assert.deepEqual(pages,[channel===1?3:4,channel===1?3:4]);
    assert.equal(p.channelError(channel),'');
    fail=true;p.onRefresh(channel);await tick();
    fail=false;p.retryMore(channel);await tick();
    assert.deepEqual(pages.slice(-2),[1,1]);
  });
}

test('home refresh and paging indicators belong to their own channel and newest operation', async () => {
  const first=deferred(), second=deferred(), other=deferred();let calls=0;
  const p=await homeChannels(()=>++calls===1?first.promise:second.promise,()=>other.promise);
  p.onRefresh(1);p.onRefresh(1);p.onReachEnd(2);
  assert.deepEqual(p.refreshingChannels,[false,true,false]);
  assert.deepEqual(p.loadingChannels,[false,false,true]);
  first.resolve([]);await tick();assert.equal(p.refreshingChannels[1],true);
  other.resolve([{roomId:5}]);await tick();assert.equal(p.loadingChannels[2],false);
  assert.equal(p.refreshingChannels[1],true);
  second.resolve([{aid:5}]);await tick();assert.equal(p.refreshingChannels[1],false);
});

test('home disappearing invalidates outstanding pages and clears activity indicators', async () => {
  const pending=deferred();const p=await homeChannels(()=>pending.promise,()=>pending.promise);
  const env=environment();
  const Lifecycle=env.methodHarness('views/HomeView','  aboutToDisappear(): void {','  async onLoginChanged():',
    '', 'export struct HomeView {');
  const savedChannels=[];
  p.saveFeedScroll=index=>savedChannels.push(index);
  p.recoveryActive=true;
  p.recoveryOffsets=[{scrollY:100},{scrollY:200},{scrollY:300}];
  let dialogClosed=false;
  p.videoReportDialog={close:()=>{dialogClosed=true;}};
  p.onRefresh(1);p.onReachEnd(2);
  Lifecycle.prototype.aboutToDisappear.call(p);
  assert.deepEqual(savedChannels,[0,1,2]);
  assert.equal(p.recoveryActive,false);
  assert.deepEqual(p.recoveryOffsets,[undefined,undefined,undefined]);
  assert.equal(dialogClosed,true);
  assert.equal(p.videoReportDialog,null);
  pending.resolve([{aid:99,roomId:99}]);await tick();
  assert.equal(p.hotSource.getData(0).aid,1);
  assert.equal(p.liveSource.getData(0).roomId,1);
  // Re-entry publishes cleared flags without allowing detached results to update rows.
  const reenter=p.feed.activate();
  assert.deepEqual(p.refreshingChannels,[false,false,false]);assert.deepEqual(p.loadingChannels,[false,false,false]);
  await reenter;
});

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
    new Function('require', 'module', 'exports', 'AppStorage', 'PersistentStorage', 'Builder', 'RefreshStatus', code)(
      localRequire, module, module.exports,
      { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
      { persistProp() {} },
      (target) => target,
      { Inactive: 0 }
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
  function methodHarness(file, start, end, imports = '', scope = '') {
    const source = readSource(path.join(root, file + '.ets'));
    const scopeBegin = scope ? source.indexOf(scope) : 0;
    assert.ok(scopeBegin >= 0, `锚点未命中 scope（${file}.ets）：${JSON.stringify(scope)}`);
    const begin = source.indexOf(start, scopeBegin);
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


test('recommendation reset supersedes old pagination and preserves new loading state', async () => {
  const old = deferred(), latest = deferred(); let calls = 0;
  const {homeFeedFixture}=require('./home-feed-fixture.cjs');let priming=true;
  const f=homeFeedFixture({recommend:()=>priming?Promise.resolve([{aid:1}]):++calls===1?old.promise:latest.promise});
  await f.ctl.activate();priming=false;
  const first = f.ctl.load(0,false), reset = f.ctl.load(0,true);
  old.resolve([]); await first;
  assert.equal(calls, 2); assert.equal(f.state(0).refreshing, true); assert.equal(f.state(0).hasMore, true);
  latest.resolve([{aid:2}]); await reset;
  assert.deepEqual(f.ctl.recommend.getAll(), [{aid:2}]); assert.equal(f.state(0).refreshing,false);
});

function qrHarness(api, userStore = {}) {
  const env = environment({'api/AuthApi':{AuthApi:api}, 'services/auth/UserStore': {UserStore:userStore}});
  const Harness = env.methodHarness('pages/Login','  async requestCode():','  // ===== 密码登录',
    "import { AuthApi } from '../api/AuthApi'; const AppTheme={DANGER:'#f00'};");
  const p = new Harness();
  const Finish = env.methodHarness('pages/Login','  async finishLogin(', '  // ===== 登录方式切换',
    "import { UserStore } from '../services/auth/UserStore';");
  p.finishLogin = Finish.prototype.finishLogin;
  Object.assign(p,{destroyed:false,loggedIn:false,tab:0,authCode:'OLD',qrGeneration:0,
    pollInflight:false,pollTimer:-1,expired:false,isDark:false});
  return p;
}

test('QR confirmation waits for account verification before success and navigation', async () => {
  const ready = deferred(); const user = {current:null, applyLoginCookies:()=>ready.promise};
  const p=qrHarness({pollWebQRCode:async()=>({code:0,refreshToken:'test-token'})},user);
  let popped=0, toasted=0;p.schedulePop=()=>popped++;p.toast=()=>toasted++;
  const run=p.poll();await tick();
  assert.equal(p.authCompleting,true);assert.equal(p.loggedIn,false);assert.equal(popped,0);
  user.current={isLogin:true};ready.resolve();await run;
  assert.equal(p.authCompleting,false);assert.equal(p.loggedIn,true);assert.equal(popped,1);assert.equal(toasted,1);
});

test('QR guest verification or network failure restores the retry entry without false success', async () => {
  for(const fail of [false,true]) {
    const user={current:{isLogin:false},applyLoginCookies:async()=>{if(fail)throw Error('offline');}};
    const p=qrHarness({pollWebQRCode:async()=>({code:0,refreshToken:'test-token'}),
      getWebQRCode:async()=>({qrcodeKey:'RETRY',url:'retry-url'})},user);
    let popped=0;p.schedulePop=()=>popped++;p.toast=()=>{throw Error('unexpected success');};
    await p.poll();
    assert.equal(p.loggedIn,false);assert.equal(p.authCompleting,false);assert.equal(p.qrError,true);assert.equal(popped,0);
    try {await p.requestCode();assert.equal(p.authCode,'RETRY');assert.equal(p.qrError,false);} finally {p.stopPoll();}
  }
});

test('closing login while account verification is pending does not navigate', async () => {
  const ready=deferred();const p=qrHarness({pollWebQRCode:async()=>({code:0})},
    {current:{isLogin:true},applyLoginCookies:()=>ready.promise});
  let popped=0;p.schedulePop=()=>popped++;p.toast=()=>{};
  const run=p.poll();await tick();p.destroyed=true;p.stopPoll();ready.resolve();await run;
  assert.equal(popped,0);assert.equal(p.loggedIn,false);assert.equal(p.authCompleting,false);
});

test('old QR expiry cannot stop a refreshed QR or clear its inflight guard', async () => {
  const old = deferred(), latest = deferred(); let calls = 0;
  const p = qrHarness({getWebQRCode:async()=>({qrcodeKey:'NEW',url:'new-qr'}),
    pollWebQRCode:()=>++calls === 1 ? old.promise : latest.promise});
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
  const p=qrHarness({getWebQRCode:()=>++calls===1?old.promise:latest.promise});
  try {
    const a=p.requestCode(), b=p.requestCode();
    latest.resolve({qrcodeKey:'NEW',url:'new'}); await b;
    old.resolve({qrcodeKey:'OLD',url:'old'}); await a;
    assert.equal(p.authCode,'NEW'); assert.equal(p.qrUrl,'new');
  } finally {p.stopPoll();}
});

test('stopping QR polling ignores a late login success', async () => {
  const pending=deferred(); const p=qrHarness({pollWebQRCode:()=>pending.promise});
  const running=p.poll(); p.stopPoll(); p.tab=1;
  pending.resolve({code:0,refreshToken:'r'}); await running;
  assert.equal(p.loggedIn,false);
});

function liveClock() {
  const pending = new Map(); let nextId = 1;
  return {
    pending,
    setTimeout(callback, delay) { const id = nextId++; pending.set(id, { callback, delay }); return id; },
    clearTimeout(id) { pending.delete(id); },
    fire(delay) {
      const entry = [...pending].find(([, timer]) => timer.delay === delay);
      assert.ok(entry, 'expected pending timer at ' + delay);
      pending.delete(entry[0]); entry[1].callback();
    },
  };
}

function liveHarness(create, clock = liveClock()) {
  const env=environment({'@kit.MediaKit':{media:{createAVPlayer:create,createMediaSourceWithUrl:()=>({}),
    VideoScaleType: {VIDEO_SCALE_TYPE_SCALED_ASPECT: 0}}}, 'test:liveClock': clock});
  const Harness=env.methodHarness('components/live/LivePlayerView','  async restartForSource():','  togglePlay():',
    "import { media } from '@kit.MediaKit'; import {setTimeout, clearTimeout} from 'test:liveClock'; const Constants={browserUa:'test'};");
  const p=new Harness(); Object.assign(p,{destroyed:false,player:null,playerCreating:false,
    playerRestartPending:false,surfaceId:'test',playInfo:{urls:['first','backup']},playerGeneration:0,sourceIndex:0,
    dmRenderer:{setPlayback(){},release(){}},hideTimer:-1,fullscreenTimer:-1,
    startupHintTimer:-1,startupTimer:-1,slowLoading:false,testClock:clock,releasingPlayers:new Set()});
  return p;
}
function fakePlayer(setSource=async()=>{},release=async()=>{}) {
  const handlers={};
  return {handlers,on:(name,fn)=>handlers[name]=fn,release,setVolume(){},
    prepare:async()=>{},play:async()=>{},setMediaSource:()=>setSource(handlers)};
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

test('live backup clears the failure overlay once prepared and playing', async () => {
  let starts = 0;
  const backup = Object.assign(fakePlayer(), { play: async () => { starts++; } });
  const p = liveHarness(async () => backup);
  p.scheduleHide = () => {};
  await p.initPlayer();
  p.errorText = '正在切换备用线路…';
  p.buffering = true;
  const queued = [...p.testClock.pending.values()].map(t => t.callback);
  backup.handlers.stateChange('prepared');
  assert.equal(p.errorText, '');
  assert.equal(p.buffering, true);
  assert.equal(starts, 1);
  backup.handlers.stateChange('playing');
  assert.equal(p.playing, true);
  assert.equal(p.buffering, true, 'playing alone cannot uncover a blank Surface');
  backup.handlers.startRenderFrame();
  assert.equal(p.buffering, false);
  assert.equal(p.errorText, '');
  assert.equal(p.testClock.pending.size, 0);
  queued.forEach(callback => callback());
  await tick();
  assert.equal(p.player, backup);
  assert.equal(p.slowLoading, false);
});

test('live startup timeout can recover while setMediaSource is still pending', async () => {
  const source = deferred(); let creations = 0;
  const first = fakePlayer(() => source.promise, async () => source.reject(new Error('released')));
  const backup = fakePlayer();
  const p = liveHarness(async () => ++creations === 1 ? first : backup);
  const creating = p.initPlayer();
  await tick();
  assert.equal(p.playerCreating, true);
  p.testClock.fire(15000);
  await creating;
  await tick();
  assert.equal(p.player, backup);
  assert.equal(creations, 2);
  assert.equal(p.playerCreating, false);
  p.release();
});

test('live startup warns then advances once to a backup when no playback event arrives', async () => {
  let creations = 0, releases = 0;
  const first = fakePlayer(async () => {}, async () => { releases++; });
  const backup = fakePlayer();
  const p = liveHarness(async () => ++creations === 1 ? first : backup);
  await p.initPlayer();
  p.testClock.fire(5000);
  assert.equal(p.slowLoading, true);
  p.testClock.fire(15000);
  await tick();
  assert.equal(releases, 1);
  assert.equal(creations, 2);
  assert.equal(p.player, backup);
  assert.equal(p.sourceIndex, 1);
  assert.equal(p.slowLoading, false);
  assert.equal(p.buffering, true);
  await first.handlers.error({ message: 'late native error' });
  assert.equal(creations, 2);
  p.testClock.fire(15000);
  await tick();
  assert.equal(p.player, null);
  assert.equal(p.buffering, false);
  assert.match(p.errorText, /超时/);
  assert.equal(p.testClock.pending.size, 0);
});

test('live startup timers cannot affect a new source or an unmounted player', async () => {
  const players = [fakePlayer(), fakePlayer()]; let creations = 0;
  const p = liveHarness(async () => players[creations++]);
  await p.initPlayer();
  const stale = [...p.testClock.pending.values()].map(t => t.callback);
  p.playInfo = { urls: ['new'] };
  await p.restartForSource();
  stale.forEach(callback => callback());
  await tick();
  assert.equal(p.player, players[1]);
  assert.equal(p.sourceIndex, 0);
  assert.equal(p.slowLoading, false);
  const leaving = [...p.testClock.pending.values()].map(t => t.callback);
  p.destroyed = true; p.release();
  leaving.forEach(callback => callback());
  await tick();
  assert.equal(creations, 2);
  assert.equal(p.testClock.pending.size, 0);
});

for (const failedMethod of ['prepare', 'play']) {
  test(`live ${failedMethod} rejection advances instead of leaving an unhandled promise`, async () => {
    let creations = 0;
    const first = fakePlayer(), backup = fakePlayer();
    first[failedMethod] = async () => { throw new Error('native failure'); };
    const p = liveHarness(async () => ++creations === 1 ? first : backup);
    await p.initPlayer();
    first.handlers.stateChange(failedMethod === 'prepare' ? 'initialized' : 'prepared');
    await tick();
    assert.equal(p.player, backup);
    assert.equal(p.sourceIndex, 1);
    p.release();
  });
}

test('live error cannot advance a new source while old release is pending', async () => {
  const release=deferred(); let creations=0;
  const old=fakePlayer(async()=>{},()=>release.promise), next=fakePlayer();
  const p=liveHarness(async()=>{creations++;return next;}); p.player=old;
  const failed=p.handleError(old,'failed');
  p.playInfo={urls:['new-first','new-backup']}; const restarting=p.restartForSource();
  await tick(); assert.equal(creations,0,'new Surface must wait for old release');
  release.resolve(); await Promise.all([failed,restarting]);
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
  const {DynamicFeedController}=env.load('components/dynamic/DynamicFeedController');
  const feed=new DynamicFeedController(()=>0,()=>{});
  const first=feed.load(false),second=feed.select('video');
  old.resolve({items:[{dynId:'old'}],offset:'old',hasMore:false});await first;
  assert.equal(feed.activeType,'video');assert.equal(feed.state().loading,true);
  assert.deepEqual(calls,['all','video']);assert.deepEqual(feed.source('video').getAll(),[]);
  latest.resolve({items:[{dynId:'new'}],offset:'new',hasMore:true});await second;
  assert.deepEqual(feed.source('video').getAll(),[{dynId:'new'}]);assert.equal(feed.state().offset,'new');
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




test('recommendation empty batches remain retryable and duplicate batches do not stall pagination', async () => {
  const batches = [[], [], [], [{aid: 1, bvid: 'BV1'}], [{aid: 2, bvid: 'BV2'}]];
  let calls = 0;
  const {homeFeedFixture}=require('./home-feed-fixture.cjs');let priming=true;
  const f=homeFeedFixture({recommend:async()=>{if(priming)return [{aid:1,bvid:'BV1'}];calls++;return batches.shift();}});
  await f.ctl.activate();priming=false;
  await f.ctl.load(0,false);
  assert.equal(calls, 3);
  assert.equal(f.state(0).hasMore, true);
  assert.equal(f.state(0).count, 1);
  assert.ok(f.state(0).error.length > 0);
  await f.ctl.retry(0);
  assert.equal(calls, 5);
  assert.equal(f.state(0).count, 2);
  assert.equal(f.state(0).error, '');
  assert.deepEqual(f.ctl.recommend.getAll().map(v => v.aid), [1, 2]);
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
  const env = environment({ 'api/SearchApi': { SearchApi: {
    searchAll: async () => ({ sections: [], totals: new Map() }),
    searchUsers: async (keyword, page) => {
      pages.push(page);
      if (page === 1) return { users: [{ mid: 1 }], numResults: 2 };
      if (!failed) { failed = true; throw new Error('offline'); }
      return { users: [{ mid: 2 }], numResults: 2 };
    }
  } } });
  const {SearchResultsController}=env.load('components/search/SearchResultsController');
  const {SearchQuery,SearchCategory}=env.load('components/search/SearchQuery');
  const search=new SearchResultsController(),query=new SearchQuery();
  await search.submit('test',query);await search.select(SearchCategory.User,query);
  assert.equal(search.view.hasMore,true);
  await search.loadMore();
  assert.equal(search.view.error,'');assert.equal(search.view.moreError,'offline');
  assert.equal(search.store.users.totalCount(),1);
  await search.loadMore();assert.deepEqual(pages,[1,2],'automatic paging stops until an explicit retry');
  await search.loadMore(true);
  assert.deepEqual(pages,[1,2,2]);assert.equal(search.view.moreError,'');
  assert.equal(search.store.users.totalCount(),2);assert.equal(search.view.hasMore,false);
  await search.loadMore();assert.equal(pages.length,3);
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




test('image return: zoomed picture starts a hero from its current transform', () => {
  const env = environment();
  const Parent = env.methodHarness('pages/ImageViewer', '  goBack(): void {', '  private finishBack():',
    "import { MotionTokens } from '../common/MotionTokens';");
  const parent = new Parent(); let flights = 0;
  Object.assign(parent, {closing: false, interactionReady: true, currentZoomed: true,
    resetZoomForExit: false, finishBack: () => flights++});
  parent.goBack();
  assert.equal(parent.resetZoomForExit, true);
  assert.equal(parent.exitWasZoomed, true);
  assert.equal(flights, 0);
  const Child = env.methodHarness('pages/ImageViewer', '  private prepareExit(): void {', '  private clampScale(',
    "import { MotionTokens } from '../common/MotionTokens';");
  const child = new Child(); let start;
  Object.assign(child, {exitRequested: true, useSystemGeometry: false,
    scaleValue: 3, offsetX: 100, offsetY: -50,
    onExitReady: (scale, x, y) => {start = [scale, x, y]; parent.finishBack();}});
  child.prepareExit();
  assert.deepEqual(start, [3, 100, -50]);
  assert.deepEqual([child.scaleValue, child.offsetX, child.offsetY], [3, 100, -50]);
  assert.equal(flights, 1);
});
test('shared image exit resets zoom and pops within the same animation transaction', () => {
  const Child = environment().methodHarness('pages/ImageViewer',
    '  private prepareExit(): void {', '  private clampScale(',
    "import { MotionTokens } from '../common/MotionTokens';");
  const child = new Child(); let finished = 0, duration = 0, start;
  Object.assign(child, {exitRequested: true, useSystemGeometry: true,
    scaleValue: 2.5, offsetX: 50, offsetY: -20,
    getUIContext: () => ({animateTo: (options, update) => {
      duration = options.duration; update(); finished++;
    }}),
    onExitReady: (scale, x, y) => {start = [scale, x, y]; assert.equal(finished, 0);}});
  global.Curve = {EaseInOut: 0};
  try {
    child.prepareExit();
    assert.equal(duration, 300);
    assert.deepEqual(start, [2.5, 50, -20]);
    assert.deepEqual([child.scaleValue, child.offsetX, child.offsetY], [1, 0, 0]);
  } finally {delete global.Curve;}
});
test('manual image hero starts from the zoomed position and keeps the source thumbnail target', () => {
  const Exit = environment().methodHarness('pages/ImageViewer',
    '  private finishBack(): void {', '  private startHeroExitFlight():',
    "import { MotionTokens } from '../common/MotionTokens';");
  const page = new Exit(); let captured;
  Object.assign(page, {exitStarted: false, exitWasZoomed: true, exitScale: 3,
    exitOffsetX: 50, exitOffsetY: -20, heroFallbackTimer: -1,
    interactionReadyTimer: -1, heroHandoffTimer: -1, heroExitTimer: -1,
    param: {initialIndex: 0}, currentIndex: 0, naturalSizes: new Map([[0, {w: 1000, h: 500}]]),
    entryFromRect: true, heroVisible: false, heroSource: '',
    hasSystemGeometryTransition: () => false,
    exitSourceRectFor: () => ({x: 8, y: 9, w: 70, h: 40}),
    containRect: () => ({x: 10, y: 20, w: 200, h: 100}),
    freezeCurrentGifFrame: rect => {captured = rect;},
    sourcePreviewFor: () => 'preview'});
  page.finishBack();
  assert.deepEqual(captured, {x: -140, y: -100, w: 600, h: 300});
  assert.deepEqual([page.heroX, page.heroY, page.heroWidth, page.heroHeight], [-140, -100, 600, 300]);
  assert.deepEqual(page.heroExitTarget, {x: 8, y: 9, w: 70, h: 40});
  assert.equal(page.heroExitPending, true);
  clearTimeout(page.heroExitTimer);
});

test('live quality: failed requests preserve playback and release busy state; late failure stays silent', async () => {
  const original = {url:'current', currentQn:80};
  let task = Promise.resolve(original); const notices = [], states = [];
  const env = environment({
    'api/LiveApi': {LiveApi: {getLivePlayInfo:()=>task, getLiveRoomInfo:async()=>null,
      getLiveDanmakuHistory:async()=>[], getLiveSuperChats:async()=>[]}},
    'common/LiveDanmakuClient': {LiveDanmakuClient:class {async connect() {} close() {}}},
  });
  const {LiveChatBuffer} = env.load('components/live/LiveChatBuffer');
  const {LiveRoomSession} = env.load('components/live/LiveRoomSession');
  const chat = new LiveChatBuffer({resetMessages(){},publishMessages(){},publishSuperChats(){}},()=>{},()=>{});
  const session = new LiveRoomSession(chat, state=>states.push(state), message=>notices.push(message));
  session.activate({roomId:1,uid:1,title:'room',uname:'host',face:'',cover:''});
  try {
    await session.load();
    task = Promise.resolve(null);
    await session.changeQuality(80);
    assert.equal(states.at(-1).play, original);
    assert.equal(states.at(-1).qualityLoading, false);
    assert.equal(notices.length, 1);
    task = Promise.resolve({url:'new',currentQn:80});
    await session.changeQuality(80); assert.equal(states.at(-1).play.url,'new');
    const pending=deferred(); task=pending.promise;
    const request=session.changeQuality(80), count=states.length;
    session.dispose(); pending.reject(new Error('offline')); await request;
    assert.equal(notices.length,1); assert.equal(states.length,count);
    assert.equal(states.at(-1).play.url,'new');
  } finally {session.dispose();}
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



test('dynamic feed: failed continuation keeps cards and offset, then retries the same page',async()=>{
  let failed=false;const offsets=[];const env=environment({'api/DynamicApi':{DynamicApi:{getDynamicFeed:async off=>{
    offsets.push(off);
    if(off==='')return {items:[{dynId:'1'}],offset:'next',hasMore:true};
    if(!failed){failed=true;throw Error('offline');}
    return {items:[{dynId:'2'}],offset:'end',hasMore:false};
  }}}});
  const {DynamicFeedController}=env.load('components/dynamic/DynamicFeedController');
  const feed=new DynamicFeedController(()=>0,()=>{});
  await feed.load(true);await feed.load(false);
  assert.equal(feed.state().moreFailed,true);assert.equal(feed.state().offset,'next');
  assert.deepEqual(feed.source('all').getAll(),[{dynId:'1'}]);await feed.load(false);
  assert.deepEqual(offsets,['','next','next']);assert.equal(feed.state().moreFailed,false);
  assert.deepEqual(feed.source('all').getAll(),[{dynId:'1'},{dynId:'2'}]);
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

test('dynamic recovery: expired login navigates to login while pagination retains its retry mode',async()=>{
  let error='登录已失效，请重新登录后查看动态';
  const env=environment({'api/DynamicApi':{DynamicApi:{getDynamicFeed:async offset=>{
    if(offset==='')return {items:[{dynId:'1'}],offset:'next',hasMore:true};
    throw Error(error);
  }}}});
  const {DynamicFeedController}=env.load('components/dynamic/DynamicFeedController');
  const feed=new DynamicFeedController(()=>0,()=>{});await feed.load(true);await feed.load(false);
  const Harness=env.methodHarness('views/DynamicView','  private recoverFeed(', '  private onRefresh(',
    "const NAV_LOGIN='Login'; const AppNavStack={pushPathByName:()=>globalThis.__dynamicLoginCount++};");
  globalThis.__dynamicLoginCount=0;const page=new Harness(),resets=[];
  Object.assign(page,{feed,loadFeed:reset=>resets.push(reset)});
  page.recoverFeed();assert.equal(globalThis.__dynamicLoginCount,1);assert.deepEqual(resets,[]);
  error='offline';await feed.load(false);page.recoverFeed();assert.deepEqual(resets,[false]);
  delete globalThis.__dynamicLoginCount;
});

test('feed filtering never restores a hidden item or drops the following visible item', () => {
  const {homeFeedFixture}=require('./home-feed-fixture.cjs');
  const f=homeFeedFixture({filter:items=>items.filter(item=>item.aid!==2)});
  const {freshHomeVideos}=f.load('components/home/HomeFeedItems');
  const rows = [{aid:2,bvid:'BV2'}, {aid:3,bvid:'BV3'}, {aid:3,bvid:'BV3'}, {aid:4,bvid:'BV4'}];
  assert.deepEqual(freshHomeVideos([{aid:4,bvid:'BV4'}], rows).map(v=>v.aid), [3]);
  assert.deepEqual(freshHomeVideos([], rows).map(v=>v.aid), [3,4]);
  assert.deepEqual(freshHomeVideos([{aid:3,bvid:'BV3'}], [{aid:3,bvid:''}]), [],
    'App aid and Web bvid must identify the same video');
});

test('refresh skips filtered batches and replaces the old feed with the first usable batch', async () => {
  const batches = [[{aid:2,bvid:'BV2'}], [{aid:3,bvid:'BV3'},{aid:3,bvid:'BV3'}]];
  const {homeFeedFixture}=require('./home-feed-fixture.cjs');let priming=true;
  const f=homeFeedFixture({recommend:async()=>priming?[{aid:1,bvid:'BV1'}]:batches.shift()||[],
    filter:items=>items.filter(item=>item.aid!==2)});
  await f.ctl.activate();priming=false;await f.ctl.load(0,true);
  assert.deepEqual(f.ctl.recommend.getAll().map(v=>v.aid), [3]);assert.equal(f.state(0).count,1);
});

test('removing one feed item preserves other objects and sends only a delete notification', () => {
  const env=environment();
  const a={aid:1},b={aid:2},c={aid:3};
  const data=source(env,[a,b,c]);
  const events=[];
  data.registerDataChangeListener({onDataDelete:i=>events.push(['delete',i]),onDataReloaded:()=>events.push(['reload'])});
  data.removeAt(1);
  data.removeAt(-1);
  data.removeAt(9);
  assert.deepEqual(data.getAll(),[a,c]);
  assert.equal(data.getData(1),c);
  assert.deepEqual(events,[['delete',1]]);
});
