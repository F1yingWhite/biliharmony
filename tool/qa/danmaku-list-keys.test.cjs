const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader} = require('./arkts-module.cjs');

function fixture() {
  const {DanmakuListKeys} = createArktsLoader()('components/player/DanmakuListKeys');
  const identity = new DanmakuListKeys();
  return items => items.map((_item, index) => identity.keyFor(items, index));
}
const row = (idStr = '', text = '重复弹幕', timeMs = 1000) => ({idStr, id: Number(idStr), text, timeMs});

test('danmaku keys: exact server IDs distinguish values beyond Number precision', () => {
  const keys = fixture(), first = row('9007199254740992'), second = row('9007199254740993');
  assert.equal(first.id, second.id);
  assert.deepEqual(keys([first, second]), ['dm:9007199254740992', 'dm:9007199254740993']);
});

test('danmaku keys: same time/text legacy records get stable distinct object identities', () => {
  const keys = fixture(), a = row(), b = row(), invalid = row('0');
  const before = keys([a, b, invalid]);
  assert.equal(new Set(before).size, 3);
  assert.deepEqual(keys([invalid, row(), b, a]).filter((_key, index) => index !== 1),
    [before[2], before[1], before[0]]);
  assert.deepEqual(keys([a, b, invalid]), before);
});

test('danmaku keys: replacing model objects preserves unique server keys', () => {
  const keys = fixture();
  assert.deepEqual(keys([row('123'), row('456')]), keys([row('123'), row('456')]));
});

test('danmaku keys: duplicate server IDs survive reorder, prepend and original removal', () => {
  const keys = fixture(), a = row('123'), b = row('123'), c = row('123');
  const initial = keys([a, b]);
  assert.equal(new Set(initial).size, 2);
  const next = keys([c, b, a]);
  assert.equal(new Set(next).size, 3);
  assert.equal(next[1], initial[1]); assert.equal(next[2], initial[0]);
  assert.deepEqual(keys([b, c]), [initial[1], next[0]]);
  const clone = row('123');
  assert.deepEqual(keys([b, clone]), [initial[1], initial[0]]);
});

test('danmaku keys: repeating the same model object remains unique', () => {
  const keys = fixture(), a = row('123'), b = row();
  const result = keys([a, a, b, b]);
  assert.equal(new Set(result).size, 4);
  assert.deepEqual(result, keys([a, a, b, b]));
});

test('danmaku keys: BasicDataSource append and in-place replacement invalidate prepared rows', () => {
  const keys = fixture(), a = row('123'), list = [a];
  assert.deepEqual(keys(list), ['dm:123']);
  list.push(row('456')); assert.deepEqual(keys(list), ['dm:123', 'dm:456']);
  list[0] = row('789'); assert.deepEqual(keys(list), ['dm:789', 'dm:456']);
  list[0].idStr = '987'; assert.deepEqual(keys(list), ['dm:987', 'dm:456']);
});
