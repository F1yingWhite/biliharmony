const test=require('node:test');
const assert=require('node:assert/strict');
const {homeFeedFixture}=require('./home-feed-fixture.cjs');
const {deferred,tick}=require('./arkts-module.cjs');

test('home login restore after departure cannot start or publish a feed request',async()=>{
  const login=deferred();const f=homeFeedFixture({login:()=>login.promise});const work=f.ctl.activate();
  f.ctl.dispose();const count=f.snapshots.length;login.resolve();await work;
  assert.equal(f.snapshots.length,count);assert.deepEqual(f.calls,[]);
});

test('home account change resets all channel requests and leaves stale completion silent',async()=>{
  const old=deferred();const f=homeFeedFixture({hot:()=>old.promise});await f.ctl.activate();
  const work=f.ctl.load(1,true);f.account.version++;await f.ctl.accountChanged();
  const count=f.snapshots.length;old.resolve([{aid:9}]);await work;
  assert.equal(f.snapshots.length,count);assert.equal(f.ctl.hot.totalCount(),0);assert.equal(f.state(1).refreshing,false);
});

test('home restore reentry invalidates an earlier request before the next login read resolves',async()=>{
  const old=deferred(),login=deferred();let loginReads=0,requests=0;
  const f=homeFeedFixture({login:()=>++loginReads===1?Promise.resolve():login.promise,
    recommend:()=>++requests===1?old.promise:Promise.resolve([{aid:2}])});
  const first=f.ctl.activate();await tick();const second=f.ctl.activate();old.resolve([{aid:1}]);await first;
  assert.equal(f.ctl.recommend.totalCount(),0);login.resolve();await second;
  assert.equal(f.ctl.recommend.getData(0).aid,2);
});

test('home exposure remembers visible rows, bounds its history, and resets on mode changes',async()=>{
  const f=homeFeedFixture();const {HomeExposureWindow}=f.load('components/home/HomeFeedItems');
  const exposure=new HomeExposureWindow();exposure.remember(Array.from({length:401},(_,aid)=>({aid:aid+1})));
  assert.deepEqual(exposure.filter([{aid:1},{aid:2},{aid:401},{aid:402}]).map(v=>v.aid),[1,402]);
  await f.ctl.activate();f.ctl.exposure.remember([{aid:1}]);await f.ctl.recommendModeChanged();
  assert.equal(f.ctl.recommend.totalCount(),1);assert.ok(f.calls.some(c=>c[0]==='reset'));
});

test('home live resets deduplicate server rows and hide preserves other video objects',async()=>{
  const f=homeFeedFixture({live:async()=>[{roomId:1},{roomId:1},{roomId:2}],
    recommend:async()=>[{aid:1},{aid:2},{aid:3}]});await f.ctl.activate();await f.ctl.load(2,true);
  assert.equal(f.ctl.live.totalCount(),2);const keep=f.ctl.recommend.getData(1),events=[];
  f.ctl.recommend.registerDataChangeListener({onDataDelete:i=>events.push(i)});
  assert.equal(f.ctl.hide({aid:1},0),true);assert.equal(f.ctl.recommend.getData(0),keep);
  assert.deepEqual(events,[0]);assert.equal(f.state(0).count,2);
});

test('home published channel snapshots cannot mutate internal pagination or error state',async()=>{
  const f=homeFeedFixture({hot:async()=>[{aid:2}]});await f.ctl.activate();
  f.state(1).page=999;f.state(1).error='outside';await f.ctl.load(1,false);
  assert.deepEqual(f.calls.filter(c=>c[0]==='hot'),[['hot',1]]);assert.equal(f.state(1).error,'');
});

for(const channel of [1,2]) {
  test(`home account change and return resume the selected channel ${channel}`,async()=>{
    const f=homeFeedFixture({hot:async()=>[{aid:2}],live:async()=>[{roomId:3}]});
    await f.ctl.activate(channel);f.account.version++;await f.ctl.accountChanged(channel);
    assert.equal(f.state(channel).count,1);assert.equal(f.state(channel).refreshing,false);
    f.ctl.dispose();await f.ctl.accountChanged(channel);await f.ctl.activate(channel);
    assert.equal(f.state(channel).count,1);
    assert.equal(f.calls.filter(c=>c[0]===(channel===1?'hot':'live')).length,3);
    assert.equal(f.calls.some(c=>c[0]==='recommend'),false);
  });
}

for (const channel of [0, 1, 2]) {
  test(`home channel ${channel} distinguishes pending, completed empty, and failed requests`, async () => {
    const pending = deferred();
    let failure = false;
    const result = () => failure ? Promise.reject(Error('offline')) : pending.promise;
    const f = homeFeedFixture({ recommend: result, hot: result, live: result });
    const { homeFeedPhase, HomeFeedPhase } = f.load('components/home/HomeFeedController');
    const work = f.ctl.activate(channel); await tick();
    assert.equal(homeFeedPhase(f.state(channel)), HomeFeedPhase.LOADING);
    pending.resolve([]); await work;
    assert.equal(f.state(channel).settled, true);
    assert.equal(f.state(channel).error, '');
    assert.equal(homeFeedPhase(f.state(channel)), HomeFeedPhase.EMPTY);
    failure = true;
    await f.ctl.retryEmpty(channel);
    assert.equal(homeFeedPhase(f.state(channel)), HomeFeedPhase.ERROR);
    assert.equal(f.state(channel).loading, false);
    assert.equal(f.state(channel).refreshing, false);
    failure = false;
    await f.ctl.retry(channel);
    assert.equal(homeFeedPhase(f.state(channel)), HomeFeedPhase.EMPTY);
  });
}

test('filtered first hot page settles as empty and its explicit next attempt advances the retained cursor', async () => {
  const pending = deferred();
  const f = homeFeedFixture({
    hot: page => page === 1 ? Promise.resolve(Array.from({ length: 20 }, (_,i) => ({ aid: i + 1 }))) : pending.promise,
    filter: items => items.filter(item => item.aid > 20)
  });
  const { homeFeedPhase, HomeFeedPhase } = f.load('components/home/HomeFeedController');
  await f.ctl.activate(1);
  assert.equal(homeFeedPhase(f.state(1)), HomeFeedPhase.EMPTY);
  assert.equal(f.state(1).hasMore, true);
  assert.equal(f.state(1).page, 2);
  assert.equal(f.state(1).error, '');
  const retry = f.ctl.retryEmpty(1);
  assert.equal(homeFeedPhase(f.state(1)), HomeFeedPhase.LOADING);
  assert.deepEqual(f.calls.filter(call => call[0] === 'hot'), [['hot', 1], ['hot', 2]]);
  pending.resolve([{ aid: 21 }]); await retry;
  assert.equal(homeFeedPhase(f.state(1)), HomeFeedPhase.CONTENT);
  assert.equal(f.state(1).page, 3);
  assert.equal(f.state(1).hasMore, false);
});

test('fully filtered recommendation attempts remain bounded and finish in retryable empty state', async () => {
  let hidden = true;
  const f = homeFeedFixture({ recommend: async () => [{ aid: 1 }], filter: items => hidden ? [] : items });
  const { homeFeedPhase, HomeFeedPhase } = f.load('components/home/HomeFeedController');
  await f.ctl.activate();
  assert.equal(f.calls.filter(call => call[0] === 'recommend').length, 3);
  assert.equal(homeFeedPhase(f.state(0)), HomeFeedPhase.EMPTY);
  hidden = false; await f.ctl.retryEmpty(0);
  assert.equal(homeFeedPhase(f.state(0)), HomeFeedPhase.CONTENT);
  assert.deepEqual(f.calls.at(-1), ['recommend', false]);
});

for (const channel of [0, 1]) {
  test(`hiding the last channel ${channel} video shows empty and can request replacement content`, async () => {
    let aid = 1;
    const f = homeFeedFixture({ recommend: async () => [{ aid }], hot: async () => [{ aid }] });
    const { homeFeedPhase, HomeFeedPhase } = f.load('components/home/HomeFeedController');
    await f.ctl.activate(channel);
    const page = f.state(channel).page, hasMore = f.state(channel).hasMore;
    f.ctl.hide({ aid: 1 }, channel);
    assert.equal(homeFeedPhase(f.state(channel)), HomeFeedPhase.EMPTY);
    assert.equal(f.state(channel).page, page);
    assert.equal(f.state(channel).hasMore, hasMore);
    aid = 2; await f.ctl.retryEmpty(channel);
    assert.equal(homeFeedPhase(f.state(channel)), HomeFeedPhase.CONTENT);
    assert.equal((channel === 0 ? f.ctl.recommend : f.ctl.hot).getData(0).aid, 2);
    if (channel === 1) assert.deepEqual(f.calls.filter(call => call[0] === 'hot'), [['hot', 1], ['hot', 1]]);
  });
}

test('discarded empty completion cannot settle an active replacement account request', async () => {
  const old = deferred(), current = deferred(); let calls = 0;
  const f = homeFeedFixture({ hot: () => ++calls === 1 ? old.promise : current.promise });
  const { homeFeedPhase, HomeFeedPhase } = f.load('components/home/HomeFeedController');
  const first = f.ctl.activate(1); await tick();
  f.account.version++; const second = f.ctl.accountChanged(1); await tick();
  old.resolve([]); await first;
  assert.equal(f.state(1).settled, false);
  assert.equal(homeFeedPhase(f.state(1)), HomeFeedPhase.LOADING);
  current.resolve([]); await second;
  assert.equal(homeFeedPhase(f.state(1)), HomeFeedPhase.EMPTY);
});
