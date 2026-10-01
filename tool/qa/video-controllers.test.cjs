const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.ARKTS_TEST_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = process.env.ARKTS_TEST_SOURCE_ROOT || path.resolve(__dirname, '../../entry/src/main/ets');

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

// Load the complete production controllers and their pure dependencies, replacing only external inputs.
function loader(overrides) {
  const cache = new Map();
  function load(name) {
    if (Object.hasOwn(overrides, name)) return overrides[name];
    if (cache.has(name)) return cache.get(name).exports;
    const mod = {exports: {}};
    cache.set(name, mod);
    const source = fs.readFileSync(path.join(root, name + '.ets'), 'utf8');
    const code = ts.transpileModule(source, {
      compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS}
    }).outputText;
    new Function('require', 'module', 'exports', code)(specifier => {
      assert.ok(specifier.startsWith('.'), 'unexpected platform dependency: ' + specifier);
      return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), specifier)));
    }, mod, mod.exports);
    return mod.exports;
  }
  return load;
}

function playback() {
  const requests = [], heartbeats = [], published = [], failures = [], notices = [];
  const state = {destroyed: false, cid: 0, switching: 0, hasUrls: false, resumeCid: 0, resume: 0};
  const detail = {aid: 1, bvid: 'BVcurrent', cid: 10, epId: 0, pages: [{cid: 10}, {cid: 20}, {cid: 30}]};
  const load = loader({
    'api/BiliApi': {BiliApi: {
      getPlayUrl(_aid, _bvid, cid) {
        const pending = deferred(); requests.push({cid, ...pending}); return pending.promise;
      },
      reportHeartbeat(...args) { heartbeats.push(args); return Promise.resolve(); }
    }},
    'common/PlayerQualityPreference': {PlayerQualityPreference: {requested: () => 80}}
  });
  const {VideoPlaybackController} = load('components/video/VideoPlaybackController');
  const ctl = new VideoPlaybackController({
    isDestroyed: () => state.destroyed, getDetail: () => detail,
    getCurrentCid: () => state.cid, hasPlaybackUrls: () => state.hasUrls,
    getSwitchingCid: () => state.switching, getResumeCid: () => state.resumeCid,
    getResumePosition: () => state.resume,
    beginInitial: cid => { state.cid = cid; },
    publish: (info, cid, index, seek) => {
      state.cid = cid; state.hasUrls = true; published.push({info, cid, index, seek});
    },
    initialFailed: message => failures.push(message), initialSelected() {},
    setSwitchingCid: cid => { state.switching = cid; }, pageSwitched() {},
    toast: message => notices.push(message)
  });
  return {ctl, state, detail, requests, heartbeats, published, failures, notices};
}

test('video controller: a manual part selection supersedes a pending initial response', async () => {
  const f = playback();
  const initial = f.ctl.loadInitial(f.detail);
  const manual = f.ctl.switchPage(f.detail.pages[1], 1);
  f.requests[1].resolve({urls: ['selected']}); await manual;
  f.requests[0].resolve({urls: ['initial'], lastPlayCid: 30}); await initial;
  assert.equal(f.requests.length, 2, 'discarded initial response must not request the server resume part');
  assert.deepEqual(f.published.map(x => x.cid), [20]);
  assert.equal(f.state.switching, 0);
  assert.deepEqual(f.failures, []);
});

test('video controller: stale part failure cannot clear the newer switch or show its error', async () => {
  const f = playback();
  const older = f.ctl.switchPage(f.detail.pages[1], 1);
  const newer = f.ctl.switchPage(f.detail.pages[2], 2);
  f.requests[0].reject(Error('old request')); await older;
  assert.equal(f.state.switching, 30);
  assert.deepEqual(f.notices, []);
  f.requests[1].resolve({urls: ['new']}); await newer;
  assert.deepEqual(f.published.map(x => x.cid), [30]);
});

test('video controller: disposal invalidates in-flight playback results', async () => {
  const f = playback();
  const pending = f.ctl.loadInitial(f.detail);
  f.state.destroyed = true; f.ctl.invalidate();
  f.requests[0].reject(Error('late network failure')); await pending;
  assert.deepEqual(f.published, []);
  assert.deepEqual(f.failures, []);
});

test('video controller: local resume keeps its part and position despite server progress', async () => {
  const f = playback(); f.state.resumeCid = 20; f.state.resume = 42.8;
  const pending = f.ctl.loadInitial(f.detail);
  assert.equal(f.requests[0].cid, 20);
  f.requests[0].resolve({urls: ['resume'], lastPlayCid: 30, lastPlayTime: 90000}); await pending;
  assert.deepEqual(f.published.map(x => [x.cid, x.index, x.seek]), [[20, 1, 42]]);
});

test('video controller: rewinding resumes heartbeat reporting without waiting for the old position', () => {
  const f = playback(); f.state.cid = 10;
  for (const seconds of [100, 101, 20, 21, 25]) f.ctl.reportHeartbeat(seconds, true);
  f.ctl.reportHeartbeat(26, false);
  f.ctl.reportHeartbeat(26, false, true);
  assert.deepEqual(f.heartbeats.map(x => x[3]), [100, 20, 25, 26]);
});

test('video controller: malformed playhead values never become history reports', () => {
  const f = playback();
  for (const seconds of [NaN, Infinity, -1, 0]) f.ctl.reportHeartbeat(seconds, true, true);
  assert.deepEqual(f.heartbeats, []);
});

function recommendations() {
  const requests = [], states = [];
  const state = {destroyed: false, detail: {aid: 1, bvid: 'BVcurrent', upName: 'Author', ugcSeason: null}};
  const request = () => {
    const pending = deferred(); requests.push(pending); return pending.promise;
  };
  const load = loader({
    'api/BiliApi': {BiliApi: {getRelated: request}},
    'api/FeedApi': {FeedApi: {getRecommend: request}},
    'common/LocalVideoFilter': {LocalVideoFilter: {contains: aid => aid === 9}}
  });
  const {VideoRecommendations} = load('components/video/VideoRecommendations');
  const ctl = new VideoRecommendations(() => state.destroyed, () => state.detail,
    status => states.push({...status}));
  return {ctl, state, requests, states};
}

test('recommendations: reset discards old rows and old completion cannot settle the new loading state', async () => {
  const f = recommendations();
  const older = f.ctl.loadInitial(1, 'BVcurrent');
  f.ctl.reset();
  const newer = f.ctl.loadInitial(2, 'BVnext');
  const stateCount = f.states.length;
  f.requests[0].resolve([{aid: 3, bvid: 'BVstale'}]); await older;
  assert.equal(f.ctl.related.totalCount(), 0);
  assert.equal(f.states.length, stateCount);
  assert.equal(f.states.at(-1).loading, true);
  f.requests[1].resolve([{aid: 4, bvid: 'BVfresh'}]); await newer;
  assert.deepEqual(f.ctl.related.getAll().map(x => x.aid), [4]);
  assert.equal(f.states.at(-1).loading, false);
});

test('recommendations: disposal discards late rows and failure notifications', async () => {
  const f = recommendations();
  const pending = f.ctl.loadMore();
  f.state.destroyed = true; f.ctl.dispose();
  const stateCount = f.states.length;
  f.requests[0].reject(Error('late request')); await pending;
  assert.equal(f.states.length, stateCount);
  assert.equal(f.ctl.related.totalCount(), 0);
});

test('recommendations: hiding a candidate updates only its row and preserves a pagination error', async () => {
  const f = recommendations(), pending = f.ctl.loadInitial(1, 'BVcurrent');
  const kept = {aid: 3, bvid: 'BVkept'};
  f.requests[0].resolve([{aid: 2, bvid: 'BVhidden'}, kept]); await pending;
  const more = f.ctl.loadMore(); f.requests[1].reject(Error('offline')); await more;
  const error = f.states.at(-1).error;
  const removed = [];
  f.ctl.related.registerDataChangeListener({
    onDataDelete: index => removed.push(index), onDataReloaded() { assert.fail('unrelated rows were reloaded'); }
  });
  f.ctl.hide({aid: 0, bvid: 'BVhidden'});
  assert.deepEqual(removed, [0]);
  assert.equal(f.ctl.related.getData(0), kept);
  assert.deepEqual(f.states.at(-1), {loading: false, error, count: 1});
});

test('recommendations: excludes current, filtered and duplicate videos and prioritizes the next episode', async () => {
  const f = recommendations();
  f.state.detail.ugcSeason = {sections: [{title: 'Season', episodes: [
    {aid: 1, bvid: 'BVcurrent', cid: 10, title: 'Current'},
    {aid: 2, bvid: 'BVepisode', cid: 20, title: 'Next'}
  ]}]};
  f.ctl.setEpisodes(f.state.detail);
  const pending = f.ctl.loadInitial(1, 'BVcurrent');
  f.requests[0].resolve([
    {aid: 1, bvid: 'BVcurrent'}, {aid: 9, bvid: 'BVblocked'}, {aid: 0, bvid: ''},
    {aid: 2, bvid: 'BVepisode'}, {aid: 3, bvid: 'BVother'},
    {aid: 3, bvid: 'BVduplicateAid'}, {aid: 4, bvid: 'BVother'},
    ...Array.from({length: 10}, (_, i) => ({aid: 10 + i, bvid: 'BV' + i}))
  ]); await pending;
  assert.deepEqual(f.ctl.related.getAll().slice(0, 2).map(x => x.aid), [2, 3]);
  assert.equal(f.ctl.related.totalCount(), 12);
  const end = f.ctl.endList(f.state.detail, 10);
  assert.equal(end[0].cid, 20);
  assert.deepEqual(end.slice(0, 2).map(x => x.bvid), ['BVepisode', 'BVother']);
  assert.equal(end.length, 8);
});
