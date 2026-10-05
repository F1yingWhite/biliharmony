const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

function loader(overrides = {}, globals = {}) {
  return createArktsLoader({ globals, mocks: {
    '@kit.ArkTS': { collections: { Array }, util: {}, taskpool: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { debug() {}, info() {}, warn() {}, error() {} } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
    ...overrides,
  } });
}
const video = id => ({ bvid: 'BV' + id, aid: id });
const aggregate = (videos, total = 10, others = []) => ({
  sections: [{ type: 'video', videos }, ...others], totals: new Map([['video', total]])
});

test('search aggregate pagination keeps stable data sources and sends only fresh-row notifications', async () => {
  const load = loader({ 'api/SearchApi': { SearchApi: { searchAll: async (_keyword, page) => page === 1
    ? aggregate([video(1), video(1)], 3, [{ type: 'bili_user', users: [{ mid: 7 }] }])
    : aggregate([video(1), video(2), video(2), video(3)], 3) } } });
  const ctl = new (load('components/search/SearchResultsController').SearchResultsController)();
  const query = new (load('components/search/SearchQuery').SearchQuery)();
  const source = ctl.store.allVideos, changes = [], snapshots = [];
  source.registerDataChangeListener({ onDataReloaded() { changes.push('reload'); }, onDataAdd(index) { changes.push(index); } });
  ctl.onChange = snapshot => snapshots.push(snapshot);
  await ctl.submit('query', query);
  const userSection = ctl.view.sections.find(s => s.type === 'bili_user');
  changes.length = 0;
  await ctl.loadMore();
  assert.equal(ctl.store.allVideos, source);
  assert.deepEqual(changes, [1, 2]);
  assert.deepEqual(source.getAll().map(v => v.aid), [1, 2, 3]);
  assert.equal(ctl.view.sections.find(s => s.type === 'bili_user'), userSection);
  assert.equal(ctl.view.hasMore, false);
  assert.equal(snapshots[0].loading, true, 'publishing completion must not mutate old ArkUI snapshot');
  assert.equal(snapshots.at(-1).loading, false);
  assert.notEqual(snapshots.at(-1), snapshots.at(-2));
});

for (const category of ['all', 'video']) {
  for (const terminal of ['empty', 'duplicate']) {
    test(`saturated video total in ${category} search continues past 50 controller pages and stops on ${terminal} results`, async () => {
      const calls = [];
      const pageVideos = page => Array.from({length: 20}, (_value, index) => video((page - 1) * 20 + index + 1));
      const responseVideos = page => page <= 51 ? pageVideos(page) : terminal === 'empty' ? [] : pageVideos(51);
      const load = loader({'api/SearchApi': {SearchApi: {
        searchAll: async (_keyword, page) => {
          calls.push(['all', page]);
          return aggregate(responseVideos(page), 1000, page === 1 ? [{type: 'bili_user', users: [{mid: 7}]}] : []);
        },
        searchVideosByType: async (_keyword, page) => {
          calls.push(['video', page]); return {videos: responseVideos(page), numResults: 1000};
        },
      }}});
      const ctl = new (load('components/search/SearchResultsController').SearchResultsController)();
      const query = new (load('components/search/SearchQuery').SearchQuery)();
      await ctl.submit('openutau', query);
      if (category === 'video') await ctl.select(1, query);
      const source = category === 'all' ? ctl.store.allVideos : ctl.store.videos;
      const firstRow = source.getAll()[0];
      for (let page = 2; page <= 50; page++) await ctl.loadMore();
      assert.deepEqual(calls.filter(([kind]) => kind === category).map(([, page]) => page),
        Array.from({length: 50}, (_value, index) => index + 1), 'controller must drive every page rather than patch private page state');
      assert.equal(source.totalCount(), 1000);
      assert.equal(ctl.view.totals[1], 1000);
      assert.equal(ctl.view.hasMore, true, 'the saturated protocol count is not an exhaustion signal');
      await ctl.loadMore();
      assert.equal(calls.at(-1)[1], 51); assert.equal(source.totalCount(), 1020);
      assert.equal(source.getAll()[0], firstRow, 'pagination preserves existing lazy rows');
      assert.deepEqual(source.getAll().slice(-20).map(item => item.aid), pageVideos(51).map(item => item.aid));
      assert.equal(ctl.view.hasMore, true);
      await ctl.loadMore();
      assert.equal(calls.at(-1)[1], 52); assert.equal(source.totalCount(), 1020);
      assert.equal(ctl.view.hasMore, false, 'an empty or all-duplicate page must terminate capped video pagination');
      const count = calls.length; await ctl.loadMore(); assert.equal(calls.length, count);
    });
  }
}

test('small video totals and non-video totals remain genuine controller pagination limits', async () => {
  for (const category of ['all', 'video', 'user']) {
    const calls = [];
    const pageVideos = page => Array.from({length: 20}, (_value, index) => video((page - 1) * 20 + index + 1));
    const load = loader({'api/SearchApi': {SearchApi: {
      searchAll: async (_keyword, page) => {calls.push(['all', page]); return aggregate(pageVideos(page), 40);},
      searchVideosByType: async (_keyword, page) => {calls.push(['video', page]); return {videos: pageVideos(page), numResults: 40};},
      searchUsers: async (_keyword, page) => {calls.push(['user', page]); return {
        users: Array.from({length: 20}, (_value, index) => ({mid: (page - 1) * 20 + index + 1})), numResults: 1000};},
    }}});
    const ctl = new (load('components/search/SearchResultsController').SearchResultsController)();
    const query = new (load('components/search/SearchQuery').SearchQuery)();
    await ctl.submit('query', query);
    if (category !== 'all') await ctl.select(category === 'video' ? 1 : 6, query);
    for (let page = 2; page <= (category === 'user' ? 50 : 2); page++) await ctl.loadMore();
    assert.equal(ctl.view.hasMore, false);
    const count = calls.length; await ctl.loadMore(); assert.equal(calls.length, count);
    assert.deepEqual(calls.filter(([kind]) => kind === category).map(([, page]) => page),
      Array.from({length: category === 'user' ? 50 : 2}, (_value, index) => index + 1));
  }
});

for (const [tab, field, sourceName, key] of [
  [1, 'videos', 'videos', 'aid'], [2, 'media', 'bangumi', 'seasonId'], [3, 'media', 'films', 'seasonId'],
  [4, 'rooms', 'live', 'roomId'], [5, 'articles', 'articles', 'id'], [6, 'users', 'users', 'mid']
]) {
  test(`search category ${tab}: deduplicates within and across pages while preserving stable source`, () => {
    const load = loader({ 'api/SearchApi': { SearchApi: {} } });
    const { SearchResultsStore, SearchPageResult } = load('components/search/SearchResultsStore');
    const store = new SearchResultsStore(), first = new SearchPageResult(), next = new SearchPageResult();
    const row = id => key === 'aid' ? video(id) : { [key]: id };
    first[field] = [row(1), row(1)]; first.total = 3;
    next[field] = [row(1), row(2), row(2), row(3)]; next.total = 3;
    const source = store[sourceName];
    assert.equal(store.apply(tab, first, true), true);
    assert.equal(store.apply(tab, next, false), false);
    assert.equal(store[sourceName], source);
    assert.deepEqual(source.getAll().map(item => item[key]), [1, 2, 3]);
  });
}

test('clearing or disposing search invalidates pending work without publishing late data or errors', async () => {
  for (const action of ['clear', 'dispose']) {
    const pending = deferred();
    const load = loader({ 'api/SearchApi': { SearchApi: { searchAll: () => pending.promise } } });
    const ctl = new (load('components/search/SearchResultsController').SearchResultsController)();
    const query = new (load('components/search/SearchQuery').SearchQuery)();
    const work = ctl.submit('old', query);
    ctl[action]();
    const view = ctl.view;
    pending.resolve(aggregate([video(9)]));
    await work;
    assert.equal(ctl.view, view);
    assert.equal(ctl.store.allVideos.totalCount(), 0);
    if (action === 'clear') assert.equal(ctl.view.searching, false);
  }
});

test('search query snapshots isolate caller mutations and share only the relevant category filters', () => {
  const load = loader();
  const { SearchQuery } = load('components/search/SearchQuery');
  const query = new SearchQuery(), copy = query.copy();
  query.videoOrder = 'pubdate'; query.duration = 2; query.pubtime = 1; query.tids = 17;
  assert.equal(copy.videoOrder, 'totalrank');
  assert.equal(copy.duration, 0);
  assert.equal(query.key('word', 0), query.key('word', 1));
  assert.equal(query.key('word', 6), copy.key('word', 6));
  assert.notEqual(query.key('word', 0), copy.key('word', 0));
  assert.notEqual(query.key('word', 0), query.key('different', 0));
});

function discoveryFixture(overrides = {}) {
  const timers = new Map(), calls = [], requests = [];
  let timerId = 0, history = ['old'];
  const load = loader({
    'common/HotSearchStore': { HotSearchStore: { load: overrides.hot || (async () => []) } },
    'common/SearchHistoryStore': { SearchHistoryStore: {
      ensureLoaded: overrides.history || (async () => history),
      add: word => (history = [word, ...history.filter(old => old !== word)]),
      remove: word => (history = history.filter(old => old !== word)),
      clear: () => { history = []; }
    } },
    'api/SearchApi': { SearchApi: {
      getSearchTrending: overrides.trending || (async () => []),
      getSearchDefault: overrides.defaultKeyword || (async () => ''),
      searchSuggest: keyword => { const pending = deferred(); requests.push(pending); calls.push(keyword); return pending.promise; }
    } }
  }, {
    setTimeout: (callback, delay) => { assert.equal(delay, 300); timers.set(++timerId, callback); return timerId; },
    clearTimeout: id => timers.delete(id)
  });
  const ctl = new (load('components/search/SearchDiscoveryController').SearchDiscoveryController)();
  const fire = () => { const pending = [...timers.values()]; timers.clear(); pending.forEach(callback => callback()); };
  return { ctl, timers, calls, requests, fire };
}

test('search suggestions debounce input and discard older responses after a newer result', async () => {
  const f = discoveryFixture();
  await f.ctl.activate();
  f.ctl.input('a'); f.ctl.input('ab');
  assert.equal(f.timers.size, 1); assert.deepEqual(f.calls, []);
  f.fire(); f.ctl.input('abc'); f.fire();
  assert.deepEqual(f.calls, ['ab', 'abc']);
  f.requests[1].resolve(['newest']); await tick();
  f.requests[0].resolve(['obsolete']); await tick();
  assert.deepEqual(f.ctl.view.suggests, ['newest']);
  f.ctl.input('');
  assert.deepEqual(f.ctl.view.suggests, []); assert.equal(f.timers.size, 0);
});

for (const action of ['submit', 'dispose']) {
  test(`search ${action} cancels both scheduled and in-flight suggestions`, async () => {
    const f = discoveryFixture();
    await f.ctl.activate();
    f.ctl.input('pending'); f.fire();
    f.ctl.input('scheduled');
    if (action === 'submit') f.ctl.submit('chosen');
    else f.ctl.dispose();
    assert.equal(f.timers.size, 0);
    const snapshot = f.ctl.view;
    f.requests[0].resolve(['late']); await tick();
    assert.equal(f.ctl.view, snapshot);
    assert.deepEqual(f.ctl.view.suggests, []);
    if (action === 'submit') assert.equal(f.ctl.view.history[0], 'chosen');
  });
}

test('discovery loads independent hot/trending/default data and ignores data from a previous appearance', async () => {
  const hot = deferred(), trending = deferred(), defaultKeyword = deferred();
  const f = discoveryFixture({ hot: () => hot.promise, trending: () => trending.promise, defaultKeyword: () => defaultKeyword.promise });
  const defaults = []; f.ctl.onDefault = keyword => defaults.push(keyword);
  await f.ctl.activate();
  assert.deepEqual(f.ctl.view.history, ['old']);
  trending.resolve([{ keyword: 'trend' }]); await tick();
  assert.equal(f.ctl.view.trending[0].keyword, 'trend');
  f.ctl.dispose();
  const snapshot = f.ctl.view;
  hot.resolve([{ keyword: 'late' }]); defaultKeyword.resolve('late placeholder'); await tick();
  assert.equal(f.ctl.view, snapshot); assert.deepEqual(defaults, []);
});

test('history edits supersede an unfinished initial read and publish fresh snapshots', async () => {
  const initial = deferred();
  const f = discoveryFixture({ history: () => initial.promise });
  const activation = f.ctl.activate();
  f.ctl.submit('chosen');
  const submitted = f.ctl.view;
  f.ctl.removeHistory('old');
  assert.deepEqual(f.ctl.view.history, ['chosen']);
  assert.deepEqual(submitted.history, ['chosen', 'old']);
  f.ctl.clearHistory();
  initial.resolve(['stale']); await activation;
  assert.deepEqual(f.ctl.view.history, []);
});
