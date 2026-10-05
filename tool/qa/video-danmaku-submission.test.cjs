const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred} = require('./arkts-module.cjs');

function fixture() {
  const pending = [], echoes = [], notices = [];
  const state = {destroyed: false, login: true, draft: '  我发的弹幕  ', draftVersion: 0, sending: false, progress: 12.375,
    target: {aid: 170001, bvid: 'BV17x411w7KC', cid: 279786, version: 1}};
  const load = createArktsLoader({mocks: {'api/BiliApi': {BiliApi: {sendDanmaku(...args) {
    const request = deferred(); pending.push({args, ...request}); return request.promise;
  }}}}});
  const controller = new (load('components/video/VideoDanmakuSubmissionController').VideoDanmakuSubmissionController)({
    isDestroyed: () => state.destroyed, getTarget: () => ({...state.target}), getProgress: () => state.progress,
    getDraft: () => state.draft, getDraftVersion: () => state.draftVersion,
    setDraft: value => state.draft = value, setSending: value => state.sending = value,
    ensureLogin: () => state.login, showLocal: (...args) => echoes.push(args), toast: text => notices.push(text),
  });
  return {controller, state, pending, echoes, notices, auth: load('services/auth/AuthSession').AuthSession};
}
const success = {ok: true, message: '', data: {dmid_str: '1234567890123456789'}};

test('confirmed video send echoes once with exact ID and submitted time, even when playback has advanced', async () => {
  const f = fixture(), sending = f.controller.send(); await f.controller.send();
  assert.equal(f.pending.length, 1); assert.equal(f.state.sending, true);
  assert.deepEqual(f.pending[0].args, [170001, 'BV17x411w7KC', 279786, 12.375, '我发的弹幕']);
  f.state.progress = 15; f.pending[0].resolve(success); await sending;
  assert.deepEqual(f.echoes, [['我发的弹幕', 12.375, '1234567890123456789']]);
  assert.equal(f.state.draft, ''); assert.equal(f.state.sending, false);
});

test('typing the next message does not get erased by a successful previous submission', async () => {
  const f = fixture(), sending = f.controller.send(); f.state.draft = '下一条';
  f.pending[0].resolve(success); await sending;
  assert.equal(f.state.draft, '下一条'); assert.equal(f.echoes.length, 1);
});

test('editing the draft away and back to the same text preserves the new draft', async () => {
  const f = fixture(), sending = f.controller.send();
  f.state.draft = '另一个'; f.state.draftVersion++;
  f.state.draft = '  我发的弹幕  '; f.state.draftVersion++;
  f.pending[0].resolve(success); await sending;
  assert.equal(f.state.draft, '  我发的弹幕  '); assert.equal(f.echoes.length, 1);
});

for (const failure of [{ok: false, message: '拒绝发送', data: {}}, Error('offline')]) {
  test('failed video send preserves draft, produces no echo and permits retry: ' + (failure.message || 'network'), async () => {
    const f = fixture(), sending = f.controller.send();
    if (failure instanceof Error) f.pending[0].reject(failure); else f.pending[0].resolve(failure);
    await sending; assert.equal(f.state.draft, '  我发的弹幕  ');
    assert.equal(f.state.sending, false); assert.deepEqual(f.echoes, []);
    const retry = f.controller.send(); assert.equal(f.pending.length, 2);
    f.pending[1].resolve(success); await retry; assert.equal(f.echoes.length, 1);
  });
}

for (const [name, change] of [
  ['part', f => f.state.target.cid++],
  ['video', f => f.state.target = {...f.state.target, aid: 2, bvid: 'BVnew'}],
  ['same video source reset', f => f.state.target.version++],
  ['account', f => f.auth.advance()],
  ['page disposal', f => f.state.destroyed = true],
]) {
  test('stale send cannot show a local echo, clear draft or toast after ' + name, async () => {
    const f = fixture(), sending = f.controller.send(); change(f); f.state.draft = '新上下文';
    f.pending[0].resolve(success); await sending;
    assert.deepEqual(f.echoes, []); assert.deepEqual(f.notices, []); assert.equal(f.state.draft, '新上下文');
  });
}

test('an old finally cannot unlock a fresh operation after a page returns to the same video', async () => {
  const f = fixture(), old = f.controller.send(); f.controller.reset();
  f.state.draft = '新请求'; const fresh = f.controller.send();
  f.pending[0].resolve(success); await old;
  assert.equal(f.state.sending, true); assert.deepEqual(f.echoes, []);
  f.pending[1].resolve(success); await fresh; assert.equal(f.state.sending, false);
  assert.deepEqual(f.echoes[0], ['新请求', 12.375, '1234567890123456789']);
});

test('source/account changes release the old lock before a watcher has run', async () => {
  for (const change of [f => f.state.target.cid++, f => f.auth.advance()]) {
    const f = fixture(), old = f.controller.send(); change(f); f.state.draft = '新请求';
    const fresh = f.controller.send(); assert.equal(f.pending.length, 2);
    f.pending[0].reject(Error('old')); await old; assert.equal(f.state.sending, true);
    f.pending[1].resolve(success); await fresh; assert.equal(f.echoes.length, 1);
  }
});

test('invalid IDs never round a large server ID into a different remote danmaku identity', async () => {
  for (const [data, expected] of [[{dmid: 1234}, '1234'], [{dmid: 1234567890123456789}, ''],
    [{dmid_str: 'wrong'}, ''], [{}, '']]) {
    const f = fixture(), sending = f.controller.send(); f.pending[0].resolve({ok: true, data}); await sending;
    assert.equal(f.echoes[0][2], expected);
  }
});

test('empty drafts, missing video, logged-out and destroyed pages make no send request', async () => {
  for (const change of [f => f.state.draft = ' ', f => f.state.target.cid = 0,
    f => f.state.login = false, f => f.state.destroyed = true]) {
    const f = fixture(); change(f); await f.controller.send(); assert.equal(f.pending.length, 0);
  }
});
