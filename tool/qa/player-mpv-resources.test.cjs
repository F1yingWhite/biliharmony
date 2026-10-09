const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, tick} = require('./arkts-module.cjs');

function fixture() {
  const writes = [], closes = [], calls = [];
  let fail = false;
  const fs = {OpenMode: {CREATE: 1, TRUNC: 2, READ_WRITE: 4},
    async open(path, mode) {calls.push([path, mode]); return {fd: 7};},
    async write(fd, bytes) {if (fail) throw Error('disk error'); const b = Buffer.from(bytes); const count = Math.min(2, b.length); writes.push(b.subarray(0, count)); return count;},
    async close(file) {closes.push(file.fd);}};
  const load = createArktsLoader({mocks: {'@kit.CoreFileKit': {fileIo: fs}, '@kit.AbilityKit': {}}});
  const {PlayerMpvResources} = load('components/player/PlayerMpvResources');
  const context = {filesDir: '/app/files', resourceManager: {async getRawFileContent(name) {
    assert.equal(name, 'mpv/cacert.pem'); return Uint8Array.from([99, 1, 2, 3, 4, 88]).subarray(1, 5);
  }}};
  return {resources: PlayerMpvResources, context, writes, closes, calls, setFail(value) {fail = value;}};
}

test('mpv TLS resources: CA copy preserves byte offset and partial writes, closes descriptor and coalesces requests', async () => {
  const f = fixture(); f.resources.configure(f.context);
  const first = f.resources.caFile(), second = f.resources.caFile(); assert.equal(first, second);
  assert.equal(await first, '/app/files/bilimpv-ca-v1.pem');
  assert.deepEqual([...Buffer.concat(f.writes)], [1, 2, 3, 4]); assert.deepEqual(f.closes, [7]); assert.equal(f.calls.length, 1);
});

test('mpv TLS resources: unavailable context fails, and a failed copy can be retried without trusting a partial file', async () => {
  const f = fixture(); await assert.rejects(f.resources.caFile(), /尚未初始化/);
  f.resources.configure(f.context); f.setFail(true); await assert.rejects(f.resources.caFile(), /disk error/); await tick();
  assert.deepEqual(f.closes, [7]); f.setFail(false); await f.resources.caFile();
  assert.equal(f.calls.length, 2); assert.deepEqual([...Buffer.concat(f.writes)], [1, 2, 3, 4]);
});
