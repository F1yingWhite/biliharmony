const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function fixture() {
  const calls = [], requests = [], cache = new Map(), timers = new Map(), published = [];
  let timerId = 0;
  const load = createArktsLoader({mocks: {'services/cache/RemoteAssetCache': {RemoteAssetCache: {
    cachedThumbnail: url => cache.get(url) || url,
    ensureThumbnail: url => {const pending = deferred(); calls.push(url); requests.push({url, ...pending}); return pending.promise;},
  }}}, globals: {
    setTimeout: callback => {const id = ++timerId; timers.set(id, callback); return id;},
    clearTimeout: id => timers.delete(id),
  }});
  const {YouTubeSavedThumbnails} = load('components/youtube/YouTubeSavedThumbnails');
  const thumbnails = new YouTubeSavedThumbnails(local => published.push(local));
  function flush() {const callbacks = [...timers.values()]; timers.clear(); callbacks.forEach(callback => callback());}
  return {thumbnails, calls, requests, cache, timers, published, flush};
}
const urls = count => Array.from({length: count}, (_, index) => 'https://img/' + index);

test('saved thumbnails: only the visible rows plus two neighbours are fetched, with three concurrent requests', async () => {
  const f = fixture(), list = urls(200); f.thumbnails.activate(); f.thumbnails.setItems(list); f.thumbnails.primeVisible(20, 23);
  assert.deepEqual(f.calls, list.slice(18, 21));
  for (let index = 0; index < 8; index++) {
    f.requests[index].resolve('file://' + index); await tick();
  }
  assert.deepEqual(f.calls, list.slice(18, 26));
  assert.equal(f.timers.size, 1); f.flush(); assert.equal(f.published.length, 1); assert.equal(f.published[0].size, 8);
});

test('saved thumbnails: cache hits and adjacent duplicate URLs publish one immutable snapshot', () => {
  const f = fixture(), [a, b] = urls(2); f.cache.set(a, 'file://a'); f.cache.set(b, 'file://b');
  f.thumbnails.activate(); f.thumbnails.setItems([a, a, b]); f.thumbnails.primeVisible(0, 2);
  assert.deepEqual(f.calls, []); assert.equal(f.timers.size, 1); assert.equal(f.published.length, 0);
  f.flush(); assert.deepEqual([...f.published[0]], [[a, 'file://a'], [b, 'file://b']]);
  f.thumbnails.setItems([a]); f.flush();
  assert.equal(f.published[0].size, 2); assert.equal(f.published[1].size, 1);
});

test('saved thumbnails: repeated visibility callbacks share one pending request per URL', async () => {
  const f = fixture(), [a] = urls(1); f.thumbnails.activate(); f.thumbnails.setItems([a, a, a]);
  f.thumbnails.primeVisible(0, 2); f.thumbnails.primeVisible(0, 2);
  assert.deepEqual(f.calls, [a]); f.requests[0].resolve('file://a'); await tick(); f.flush();
  assert.equal(f.published.at(-1).size, 1);
});

test('saved thumbnails: departure cancels an unpublished snapshot and discards late network completion', async () => {
  const f = fixture(), [a, b] = urls(2); f.cache.set(a, 'file://a');
  f.thumbnails.activate(); f.thumbnails.setItems([a, b]); f.thumbnails.primeVisible(0, 1);
  const oldTimer = [...f.timers.values()][0]; f.thumbnails.deactivate();
  assert.equal(f.timers.size, 0); oldTimer(); f.requests[0].resolve('file://late'); await tick(); f.flush();
  assert.deepEqual(f.published, []);
});

test('saved thumbnails: old session completion cannot remove a new session pending request or publish stale files', async () => {
  const f = fixture(), [a] = urls(1); f.thumbnails.activate(); f.thumbnails.setItems([a]); f.thumbnails.primeVisible(0, 0);
  f.thumbnails.activate(); f.thumbnails.setItems([a]); f.thumbnails.primeVisible(0, 0);
  f.requests[0].resolve('file://old'); await tick(); f.thumbnails.primeVisible(0, 0);
  assert.equal(f.requests.length, 2); assert.equal(f.timers.size, 0);
  f.requests[1].resolve('file://new'); await tick(); f.flush();
  assert.equal(f.published.at(-1).get(a), 'file://new');
});

test('saved thumbnails: list replacement invalidates removed requests and preserves an unpublished retained cache hit', async () => {
  const f = fixture(), [a, b, c] = urls(3); f.cache.set(a, 'file://a');
  f.thumbnails.activate(); f.thumbnails.setItems([a, b]); f.thumbnails.primeVisible(0, 1);
  f.thumbnails.setItems([a, c]); f.thumbnails.primeVisible(0, 1);
  f.requests[0].resolve('file://removed'); await tick(); f.flush();
  assert.deepEqual([...f.published.at(-1)], [[a, 'file://a']]);
  f.requests[1].resolve('file://c'); await tick(); f.flush();
  assert.deepEqual([...f.published.at(-1)], [[a, 'file://a'], [c, 'file://c']]);
});

test('saved thumbnails: failures keep remote fallback and do not spin until the viewport changes', async () => {
  const f = fixture(), list = urls(10); f.thumbnails.activate(); f.thumbnails.setItems(list); f.thumbnails.primeVisible(0, 0);
  f.requests[0].reject(Error('offline')); f.requests[1].resolve(list[1]); f.requests[2].resolve(''); await tick();
  f.thumbnails.primeVisible(0, 0); assert.equal(f.calls.length, 3); f.flush(); assert.deepEqual(f.published, []);
  f.thumbnails.primeVisible(8, 8); assert.deepEqual(f.calls.slice(3), list.slice(6, 9));
});

test('saved thumbnails: cleared lists and inactive windows launch no requests', () => {
  const f = fixture(); f.thumbnails.setItems(urls(2)); f.thumbnails.primeVisible(0, 1);
  f.thumbnails.activate(); f.thumbnails.setItems([]); f.thumbnails.primeVisible(0, 1);
  f.thumbnails.setItems(urls(2)); f.thumbnails.primeVisible(NaN, 1); f.thumbnails.primeVisible(0, Infinity);
  assert.deepEqual(f.calls, []);
});
