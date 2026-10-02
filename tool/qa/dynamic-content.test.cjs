const test = require('node:test');
const assert = require('node:assert/strict');
const { environment, deferred } = require('./dynamic-test-env.cjs');
const item = (values = {}) => ({ dynId: 'one', content: 'hello [x]', emotes: [], richNodes: [], ...values });
const emote = (text, url, size = 1) => ({ text, size, displayUrl: () => url });
function fixture(request = async () => null) {
  return environment({ 'api/DynamicApi': { DynamicApi: { getDynamicDetail: request } },
    'common/EmoteResolver': { EmoteResolver: { lookup: () => '' } },
  }).load('components/dynamic/DynamicContent');
}

test('same dynamic id with richer emote metadata produces new image spans rather than stale text', () => {
  const content = fixture();
  assert.equal(content.contentPartsOf(item(), 0).at(-1).text, 'hello [x]');
  const rich = content.contentPartsOf(item({ emotes: [emote('[x]', 'x.gif', 2)] }), 0);
  assert.equal(rich.at(-1).image, 'x.gif'); assert.equal(rich.at(-1).imageSize, 2);
});

test('rich node topic and image size metadata invalidate the rendering cache', () => {
  const content = fixture();
  const plain = item({ richNodes: [{ text: '#topic#', emote: null, isTopic: false }] });
  const topic = item({ richNodes: [{ text: '#topic#', emote: null, isTopic: true }] });
  assert.equal(content.contentPartsOf(plain, 0)[0].isTopic, false);
  assert.equal(content.contentPartsOf(topic, 0)[0].isTopic, true);
  const small = item({ richNodes: [{ text: '[x]', emote: emote('[x]', 'x.gif', 1) }] });
  const large = item({ richNodes: [{ text: '[x]', emote: emote('[x]', 'x.gif', 2) }] });
  assert.equal(content.contentPartsOf(small, 0)[0].imageSize, 1);
  assert.equal(content.contentPartsOf(large, 0)[0].imageSize, 2);
});

test('empty emote tokens cannot trap parsing and overlapping tokens prefer the longest match', () => {
  const content = fixture();
  const parts = content.contentPartsOf(item({ content: 'abc', emotes: [emote('', 'bad'), emote('a', 'short'), emote('ab', 'long')] }), 0);
  assert.equal(parts[0].image, 'long'); assert.equal(parts[1].text, 'c');
});

test('rich detail requests coalesce and failures release the pending slot for retry', async () => {
  const requests = []; const content = fixture(() => { const next = deferred(); requests.push(next); return next.promise; });
  const first = content.ensureDynamicRichDetail('one'), same = content.ensureDynamicRichDetail('one');
  assert.equal(first, same); assert.equal(requests.length, 1);
  requests[0].reject(Error('offline')); assert.equal(await first, null);
  const retry = content.ensureDynamicRichDetail('one'), result = item(); requests[1].resolve(result);
  assert.equal(await retry, result); assert.equal(await content.ensureDynamicRichDetail('one'), result);
  assert.equal(requests.length, 2);
});
