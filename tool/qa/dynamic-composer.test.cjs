const test = require('node:test');
const assert = require('node:assert/strict');
const { environment, deferred, tick } = require('./dynamic-test-env.cjs');
function fixture(overrides = {}) {
  const notices = [], cleaned = [], requests = [], states = [];
  let published = 0;
  const request = (kind, args) => {
    const next = deferred(); requests.push({ ...next, kind, args }); return next.promise;
  };
  const env = environment({
    'common/DynImagePreparer': { DynImagePreparer: {
      prepare: async (_context, uri) => ({ key: uri, cachePath: uri, fileName: uri + '.jpg', mimeType: 'image/jpeg' }),
      readBytes: async () => new ArrayBuffer(1), cleanup: images => cleaned.push(...images.map(image => image.key)),
      ...overrides,
    } },
    'api/DynamicApi': { DynamicApi: {
      publish: (...args) => request('text', args),
      publishWithImages: (...args) => request('images', args),
      uploadDynImage: (...args) => request('upload', args),
    } },
  });
  const { DynamicComposerController } = env.load('components/dynamic/DynamicComposerController');
  const controller = new DynamicComposerController(() => published++, value => notices.push(value));
  controller.attach(state => states.push(state));
  return { controller, notices, cleaned, requests, states, state: () => states.at(-1),
    published: () => published, session: env.load('services/auth/AuthSession').AuthSession };
}

test('closing and reopening the panel retains draft text and images; removing by key frees the resource', async () => {
  const f = fixture(); f.controller.setText('draft'); await f.controller.pick({}, async () => ['a', 'b']);
  f.controller.detach(); f.controller.attach(state => f.states.push(state));
  assert.equal(f.state().text, 'draft'); assert.deepEqual(f.state().images.map(i => i.key), ['a', 'b']);
  f.controller.removeImage('a'); assert.deepEqual(f.cleaned, ['a']); assert.equal(f.state().images.length, 1);
  f.controller.reset(); assert.deepEqual(f.cleaned, ['a', 'b']); assert.equal(f.state().text, '');
});

test('picker lock prevents duplicate selection and late prepared resources are cleaned after reset', async () => {
  const prepared = deferred(), selected = deferred(); const f = fixture({ prepare: () => prepared.promise });
  const picking = f.controller.pick({}, () => selected.promise);
  await f.controller.pick({}, () => { throw Error('second picker must not run'); });
  assert.equal(f.state().busy, true); selected.resolve(['a']); await tick();
  f.controller.reset(); prepared.resolve({ key: 'a', cachePath: 'a' }); await picking;
  assert.deepEqual(f.cleaned, ['a']); assert.equal(f.state().images.length, 0); assert.equal(f.state().busy, false);
});

test('validation rejects empty and oversized drafts before publishing', async () => {
  const f = fixture(); await f.controller.submit(); f.controller.setText('a'.repeat(2001)); await f.controller.submit();
  assert.equal(f.requests.length, 0); assert.ok(f.notices[0].includes('2000'));
});

test('image publication is sequential, busy edits are ignored, and success clears resources once', async () => {
  const f = fixture(); f.controller.setText('  text  '); await f.controller.pick({}, async () => ['a', 'b']);
  const publishing = f.controller.submit(); await tick();
  f.controller.setText('changed'); f.controller.removeImage('a'); await f.controller.submit();
  assert.equal(f.requests.length, 1); assert.equal(f.state().text, '  text  '); assert.deepEqual(f.cleaned, []);
  f.requests[0].resolve({ ok: true, image: { imgSrc: 'up-a' } }); await tick();
  assert.equal(f.requests[1].kind, 'upload'); assert.ok(f.state().stage.includes('2/2'));
  f.requests[1].resolve({ ok: true, image: { imgSrc: 'up-b' } }); await tick();
  assert.equal(f.requests[2].kind, 'images'); assert.equal(f.requests[2].args[0], 'text');
  assert.equal(f.requests[2].args[1].length, 2); f.requests[2].resolve({ ok: true }); await publishing;
  assert.equal(f.published(), 1); assert.deepEqual(f.cleaned, ['a', 'b']);
  assert.equal(f.state().text, ''); assert.equal(f.state().busy, false);
});

test('failed upload preserves the draft and stops publication', async () => {
  const f = fixture(); await f.controller.pick({}, async () => ['a', 'b']);
  const publishing = f.controller.submit(); await tick();
  f.requests[0].resolve({ ok: false, message: 'upload failed', image: null }); await publishing;
  assert.equal(f.requests.length, 1); assert.equal(f.state().images.length, 2); assert.equal(f.state().busy, false);
  assert.deepEqual(f.cleaned, []); assert.deepEqual(f.notices, ['upload failed']);
});

test('account replacement between file read and upload prevents any request with the new account', async () => {
  const reading = deferred(), f = fixture({ readBytes: () => reading.promise });
  await f.controller.pick({}, async () => ['a']); const publishing = f.controller.submit();
  f.session.advance(); reading.resolve(new ArrayBuffer(1)); await publishing;
  assert.equal(f.requests.length, 0); assert.equal(f.published(), 0); assert.deepEqual(f.notices, []);
});

test('late publish success after reset cannot clear a new draft, close the new panel or release a new operation', async () => {
  const f = fixture(); f.controller.setText('old'); const old = f.controller.submit();
  f.controller.reset(); f.controller.setText('new'); const current = f.controller.submit();
  f.requests[0].resolve({ ok: true }); await old;
  assert.equal(f.state().text, 'new'); assert.equal(f.state().busy, true); assert.equal(f.published(), 0);
  f.requests[1].resolve({ ok: false, message: 'retry' }); await current;
  assert.equal(f.state().text, 'new'); assert.equal(f.state().busy, false); assert.deepEqual(f.notices, ['retry']);
});
