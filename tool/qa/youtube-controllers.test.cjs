const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');
const video = (id, thumbnail = id) => ({id, thumbnail, channelAvatar:''});
const page = (videos = [], continuation = '', filters = []) => ({videos, continuation, filters});

function fixture(hooks = {}) {
  const calls = [], snapshots = [], suggestions = [], details = [], recorded = [], images = [], timers = new Map(); let timer = 0;
  let history = ['stored'];
  const load = createArktsLoader({ mocks: {
    'api/YouTubeApi': {YouTubeVideo:class {id='';thumbnail='';channelAvatar='';}, YouTubeApi: {
      detailPage: id => {calls.push(['detail',id]);return hooks.detail ? hooks.detail(id) : Promise.resolve({video:video(id),related:[],commentToken:'initial'});},
      comments: token => {calls.push(['comments',token]);return hooks.comments ? hooks.comments(token) : Promise.resolve({comments:[],continuation:'',total:''});},
      search: (...args) => {calls.push(['search', ...args]); return hooks.search ? hooks.search(...args) : Promise.resolve(page());},
      searchMore: token => {calls.push(['more', token]); return hooks.more ? hooks.more(token) : Promise.resolve(page());},
      suggest: term => {calls.push(['suggest',term]); return hooks.suggest ? hooks.suggest(term) : Promise.resolve([term+'!']);},
    }},
    'common/YouTubeHistoryStore': {YouTubeHistoryStore:{record:video=>recorded.push(video.id)}},
    'common/YouTubeSearchHistoryStore': {YouTubeSearchHistoryStore: {
      ensureLoaded: () => hooks.history ? hooks.history() : Promise.resolve(history),
      add: term => history = [term,...history], remove: term => history = history.filter(x=>x!==term), clear: () => {history=[];},
    }},
    'services/cache/RemoteAssetCache': {RemoteAssetCache: {
      cachedThumbnail: url => hooks.cached ? hooks.cached(url) : url,
      ensureThumbnail: url => {images.push(url);return hooks.image ? hooks.image(url) : Promise.resolve('local:'+url);},
    }},
  }, globals: {
    setTimeout: fn => {timers.set(++timer,fn);return timer;}, clearTimeout: id => timers.delete(id),
  }});
  const ctl = new (load('components/youtube/YouTubeSearchController').YouTubeSearchController)(state=>snapshots.push(state));
  const discovery = new (load('components/youtube/YouTubeDiscoveryController').YouTubeDiscoveryController)(state=>suggestions.push(state));
  const detail = new (load('components/youtube/YouTubeDetailController').YouTubeDetailController)(state=>details.push(state));
  return {ctl,discovery,detail,details,recorded,calls,snapshots,suggestions,images,load,timers,
    flush(){for(const [id,fn] of [...timers]){timers.delete(id);fn();}}};
}

test('YouTube comments selected before metadata loads are fetched once its initial token arrives',async()=>{
  const pending=deferred();const f=fixture({detail:()=>pending.promise});
  f.detail.activate(video('first'));const work=f.detail.load();f.detail.ensureComments();
  assert.deepEqual(f.calls,[['detail','first']]);
  pending.resolve({video:video('first'),related:[],commentToken:'start'});await work;await tick();
  assert.deepEqual(f.calls,[['detail','first'],['comments','start']]);assert.equal(f.details.at(-1).commentsLoaded,true);
});

test('YouTube detail replacement cancels metadata, images, and history from the earlier visit',async()=>{
  const pending=deferred(), image=deferred();const f=fixture({detail:()=>pending.promise,image:()=>image.promise});
  f.detail.activate(video('first'));const work=f.detail.load();f.detail.dispose();f.detail.activate(video('second'));
  const count=f.details.length;pending.resolve({video:video('first'),related:[],commentToken:'wrong'});image.resolve('old-image');
  await work;await tick();assert.equal(f.details.length,count+1); // only second video's current image callback
  assert.equal(f.details.at(-1).video.id,'second');assert.deepEqual(f.recorded,[]);
  assert.equal(f.details.at(-1).imageLocal.has('first'),false);
});

test('YouTube comment errors preserve page token, retry appends fresh rows, and reset uses the initial token',async()=>{
  let more=0;const f=fixture({comments:async token=>{
    if(token==='initial')return {comments:[{id:'a',avatar:'a'},{id:'a',avatar:'a'}],continuation:'page2',total:'2'};
    if(++more===1)throw Error('offline');return {comments:[{id:'a',avatar:'a'},{id:'b',avatar:'b'}],continuation:'',total:'2'};
  }});
  f.detail.activate(video('first'));await f.detail.load();await f.detail.loadComments();
  assert.equal(f.detail.comments.totalCount(),1);await f.detail.loadMoreComments();await f.detail.loadMoreComments();
  assert.equal(more,1);assert.equal(f.details.at(-1).commentToken,'page2');
  await f.detail.loadMoreComments(true);assert.equal(f.detail.comments.totalCount(),2);
  await f.detail.loadComments();assert.equal(f.calls.at(-1)[1],'initial');assert.equal(f.detail.comments.totalCount(),1);
});

test('YouTube old comment page cannot mutate a new video or its loading lock',async()=>{
  const pending=deferred();const f=fixture({comments:()=>pending.promise});
  f.detail.activate(video('first'));await f.detail.load();const old=f.detail.loadComments();
  f.detail.activate(video('second'));await f.detail.load();const latest=f.detail.loadComments();
  f.detail.dispose();const count=f.details.length;pending.resolve({comments:[{id:'old',avatar:''}],continuation:'',total:'1'});
  await Promise.all([old,latest]);assert.equal(f.details.length,count);assert.equal(f.detail.comments.totalCount(),0);
});

test('YouTube unavailable comments finish as an empty list and metadata failure records fallback history',async()=>{
  const f=fixture({detail:async()=>{throw Error('offline');}});f.detail.activate(video('first'));await f.detail.load();
  assert.deepEqual(f.recorded,['first']);assert.equal(f.details.at(-1).detailError,'offline');
  await f.detail.loadComments();assert.equal(f.details.at(-1).commentsLoaded,true);assert.equal(f.details.at(-1).commentsLoading,false);
});

function webFixture() {
  const effects=[], states=[], timers=new Map();let id=0;const state={background:false,fail:false};
  const load=createArktsLoader({mocks:{
    '@kit.ArkWeb':{webview:{WebviewController:class {
      loadData(html){if(state.fail)throw Error('native');effects.push(['document',html]);}
      loadUrl(url){effects.push(['url',url]);}async runJavaScript(script){effects.push(['script',script]);}
    }}},
    'common/YouTubePlayerHtml':{YOUTUBE_PLAYER_ORIGIN:'https://player',youtubePlayerHtml:id=>'html:'+id,
      youtubeFullscreenProbeHtml:()=>'probe',youtubePlaybackError:title=>title==='YT_NETWORK_ERROR'?'Network error':''},
  },globals:{setTimeout:fn=>{timers.set(++id,fn);return id;},clearTimeout:id=>timers.delete(id)}});
  const ctl=new (load('components/youtube/YouTubeWebPlayback').YouTubeWebPlayback)(s=>states.push(s),
    value=>effects.push(['screen',value]),()=>state.background);
  return {ctl,effects,states,timers,state};
}

test('YouTube web playback waits for attach, deduplicates navigation and cancels timeout when ready',()=>{
  const f=webFixture();f.ctl.activate('first');assert.equal(f.effects.length,0);f.ctl.attach();f.ctl.attach();
  assert.deepEqual(f.effects,[['document','html:first']]);assert.equal(f.timers.size,1);
  f.ctl.title('YT_READY');assert.equal(f.timers.size,0);assert.equal(f.states.at(-1).loading,false);
});

test('YouTube web disposal silences late titles/timers and re-entry navigates a fresh document',()=>{
  const f=webFixture();f.ctl.activate('first');f.ctl.attach();const late=[...f.timers.values()][0];
  f.ctl.dispose();const count=f.states.length;f.ctl.title('YT_STATE_1');late();assert.equal(f.states.length,count);
  assert.deepEqual(f.effects.slice(-3),[['script','pauseVideo()'],['screen',false],['url','about:blank']]);
  f.ctl.activate('second');assert.deepEqual(f.effects.at(-1),['document','html:second']);
});

test('YouTube web native load errors remain retryable and background ready pauses playback',()=>{
  const f=webFixture();f.state.fail=true;f.ctl.activate('first');f.ctl.attach();
  assert.equal(f.states.at(-1).error,'Network error');assert.equal(f.timers.size,0);
  f.state.fail=false;f.ctl.retry();f.state.background=true;f.ctl.title('YT_STATE_1');
  assert.ok(f.effects.some(x=>x[0]==='script'));assert.equal(f.timers.size,0);
  assert.equal(f.effects.some(x=>x[0]==='screen'&&x[1]),false);
});

test('YouTube search supersedes old pagination without retaining its loading flag', async () => {
  const old = deferred(), latest = deferred(); let count=0;
  const f=fixture({search:()=>++count===1?Promise.resolve(page([video('one')],'next')):latest.promise,
    more:()=>old.promise});
  await f.ctl.search('first'); const more=f.ctl.loadMore(); const search=f.ctl.search('second');
  assert.equal(f.snapshots.at(-1).loadingMore,false);
  old.resolve(page([video('old')],'wrong'));await more;
  assert.equal(f.snapshots.at(-1).loading,true); assert.equal(f.ctl.source.totalCount(),0);
  latest.resolve(page([video('two')]));await search;
  assert.equal(f.snapshots.at(-1).searched,'second'); assert.equal(f.ctl.source.getData(0).id,'two');
});

test('YouTube first and following pages deduplicate and prime every new thumbnail', async () => {
  const f=fixture({search:async()=>page([video('one'),video('one'),video('two','same')],'next'),
    more:async()=>page([video('two'),video('three','same')],'end')});
  const source=f.ctl.source, changed=[];
  source.registerDataChangeListener({onDataReloaded(){},onDataAdd(){},onDataChange:index=>changed.push(index)});
  await f.ctl.search('query');await f.ctl.loadMore();await tick();
  assert.equal(f.ctl.source,source);assert.deepEqual(source.getAll().map(v=>v.id),['one','two','three']);
  assert.deepEqual(f.images,['one','same']);assert.equal(f.ctl.thumbnails.resolve('same'),'local:same');
});

test('YouTube pagination failure keeps its cursor and requires explicit retry', async () => {
  let attempts=0;const f=fixture({search:async()=>page([video('one')],'next'),
    more:async()=>{if(++attempts===1)throw Error('offline');return page([video('two')],'next');}});
  await f.ctl.search('query');await f.ctl.loadMore();await f.ctl.loadMore();assert.equal(attempts,1);
  assert.equal(f.snapshots.at(-1).continuation,'next');assert.equal(f.snapshots.at(-1).moreError,'offline');
  await f.ctl.loadMore(true);assert.equal(attempts,2);assert.equal(f.snapshots.at(-1).continuation,'');
  assert.equal(f.snapshots.at(-1).moreError,'');assert.equal(f.ctl.source.totalCount(),2);
});

test('YouTube filter snapshots belong to the submitted keyword and survive same-keyword retry', async () => {
  const filters=[{title:'sort'}];const f=fixture({search:async query=>page([], '',query==='first'?filters:[])});
  await f.ctl.search('first');await f.ctl.search('first','encoded','Recent');
  assert.deepEqual(f.snapshots.at(-1).filterGroups,filters);assert.equal(f.snapshots.at(-1).filterLabel,'Recent');
  await f.ctl.search('second');assert.deepEqual(f.snapshots.at(-1).filterGroups,[]);
  assert.deepEqual(f.calls.filter(c=>c[0]==='search'),[['search','first',''],['search','first','encoded'],['search','second','']]);
});

for (const action of ['clear','dispose']) {
  test(`YouTube ${action} invalidates in-flight results and image callbacks`,async()=>{
    const pending=deferred(),image=deferred();let n=0;
    const f=fixture({search:()=>++n===1?Promise.resolve(page([video('one')])):pending.promise,image:()=>image.promise});
    await f.ctl.search('first'); const work=f.ctl.search('second');f.ctl[action]();
    const count=f.snapshots.length;pending.resolve(page([video('late')]));image.resolve('late-file');await work;await tick();
    assert.equal(f.snapshots.length,count);assert.equal(f.ctl.thumbnails.resolve('one'),'one');
    f.ctl.activate(); assert.equal(f.snapshots.at(-1).loading,false);
  });
}

test('YouTube thumbnail A B A replacement cannot unlock the newer download',async()=>{
  const old=deferred(),fresh=deferred();let n=0;
  const f=fixture({image:()=>++n===1?old.promise:fresh.promise});const updates=[];
  const Cache=f.load('components/youtube/YouTubeThumbnailCache').YouTubeThumbnailCache;
  const cache=new Cache(url=>updates.push(url));cache.prime(['same']);cache.reset();cache.prime(['same']);
  old.resolve('old-file');await tick();cache.prime(['same']);assert.equal(n,2);assert.deepEqual(updates,[]);
  fresh.resolve('new-file');await tick();assert.equal(cache.resolve('same'),'new-file');assert.deepEqual(updates,['same']);
});

test('YouTube late thumbnail notifies all current rows sharing the source URL',async()=>{
  const image=deferred();const f=fixture({search:async()=>page([video('a','same'),video('b','same')]),image:()=>image.promise});
  const changes=[];f.ctl.source.registerDataChangeListener({onDataReloaded(){},onDataAdd(){},onDataChange:i=>changes.push(i)});
  await f.ctl.search('query');image.resolve('file:same');await tick();assert.deepEqual(changes,[0,1]);
});

test('YouTube discovery debounces and submission invalidates in-flight suggestions',async()=>{
  const pending=deferred();const f=fixture({suggest:()=>pending.promise});await f.discovery.activate();
  f.discovery.suggest('a');f.discovery.suggest('ab');assert.equal(f.timers.size,1);f.flush();
  f.discovery.submit('ab');pending.resolve(['late']);await tick();assert.deepEqual(f.suggestions.at(-1).suggestions,[]);
  f.discovery.suggest('ab');assert.equal(f.timers.size,0);assert.deepEqual(f.calls,[['suggest','ab']]);
});

for (const action of ['submit','clearHistory','removeHistory','dispose']) {
  test(`YouTube history ${action} supersedes its unfinished disk read`,async()=>{
    const pending=deferred();const f=fixture({history:()=>pending.promise});const work=f.discovery.activate();
    f.discovery[action]('query');const before=f.suggestions.at(-1), count=f.suggestions.length;
    pending.resolve(['obsolete']);await work;assert.equal(f.suggestions.length,count);
    assert.equal(f.suggestions.at(-1),before);
  });
}
