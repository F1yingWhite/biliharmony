const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

// Load the complete controller, vote model and auth epoch. Only API IO/login/time are controlled.
function fixture(hooks = {}) {
  const state = { destroyed: false, login: true, mid: 777, clock: 1000, source: { oid: 100, type: 1, rpid: 200, sourceKey: 'video:100:200' }, vote: null };
  const calls = [], snapshots = [], toasts = [];
  let detail;
  const load = createArktsLoader({ mocks: {
    'api/ReplyVoteApi': { ReplyVoteApi: {
      load: card => { calls.push(['load', card]); return hooks.load ? hooks.load(card) : Promise.resolve(detail(card)); },
      submit: (source, card, ids) => {
        calls.push(['submit', source, card, ids]);
        return hooks.submit ? hooks.submit(source, card, ids) : Promise.resolve({ ok: true, message: '', card: detail(card, { selectedIds: ids }) });
      },
    } },
    'services/auth/UserStore': { UserStore: { get isLogin() { return state.login; }, get current() { return state.login ? { mid: state.mid } : null; } } },
  }, globals: { Date: { now: () => state.clock } } });
  const { ReplyVoteCard, ReplyVoteOption } = load('model/reply/ReplyVoteModels');
  const { AuthSession } = load('services/auth/AuthSession');
  const { ReplyVoteController } = load('components/reply/ReplyVoteController');
  const option = (id, count = id + 1) => Object.assign(new ReplyVoteOption(), { id, text: '答案' + id, count });
  const card = patch => Object.assign(new ReplyVoteCard(), { id: '19160335', kind: 'dynamic', title: '选择方案', ...patch });
  detail = (ref = state.vote, patch = {}) => card({ id: ref.id, kind: ref.kind, loaded: true, maxSelect: 1,
    endTime: 10000, count: 33, options: [option(3, 4), option(9, 12), option(17, 8)], ...patch });
  const ctl = new ReplyVoteController({ isDestroyed: () => state.destroyed, getSource: () => state.source,
    getVote: () => state.vote, applyState: value => snapshots.push(value), toast: value => toasts.push(value) });
  function bind(sourcePatch = {}, cardPatch = {}) {
    state.source = { ...state.source, ...sourcePatch };
    state.vote = card(cardPatch);
    ctl.bind(state.source, state.vote);
  }
  bind();
  return { ctl, state, calls, snapshots, toasts, card, detail, option, bind, AuthSession,
    ui: () => snapshots.at(-1), count: method => calls.filter(call => call[0] === method).length };
}

test('complete vote controller loads cloned real results and deduplicates reads', async () => {
  const pending = deferred(); const f = fixture({ load: () => pending.promise });
  const response = f.detail(); const work = f.ctl.load(); await f.ctl.load();
  assert.equal(f.count('load'), 1); assert.equal(f.ui().loading, true);
  pending.resolve(response); await work;
  assert.equal(f.ui().loading, false); assert.equal(f.ui().detail.title, '选择方案');
  assert.deepEqual(f.ui().detail.options.map(option => option.count), [4, 12, 8]);
  response.options[0].count = 999; f.ui().detail.options[1].count = 999;
  f.ctl.toggle(3); assert.deepEqual(f.ui().detail.options.map(option => option.count), [4, 12, 8]);
  await f.ctl.load(); assert.equal(f.count('load'), 1);
});

test('header vote permits rpid zero but invalid source and vote identities suppress every operation', async () => {
  const header = fixture(); header.bind({ rpid: 0 }, { kind: 'reply' }); await header.ctl.load();
  header.ctl.toggle(3); assert.equal(await header.ctl.submit(), true);
  assert.equal(header.calls.find(call => call[0] === 'submit')[1].rpid, 0);
  for (const patch of [{ oid: 0 }, { oid: NaN }, { type: -1 }, { type: 1.2 }, { rpid: -1 }, { sourceKey: '' }]) {
    const f = fixture(); f.bind(patch); await f.ctl.load(); assert.equal(f.ctl.toggle(3), false);
    assert.equal(await f.ctl.submit(), false); assert.equal(f.calls.length, 0); assert.equal(f.ui().detail, null);
  }
  for (const patch of [{ id: '' }, { id: '1.5' }, { kind: 'unknown' }]) {
    const f = fixture(); f.bind({}, patch); await f.ctl.load(); assert.equal(f.calls.length, 0);
  }
});

test('single-choice replaces selections and multiple-choice toggles up to the real server limit', async () => {
  const single = fixture(); await single.ctl.load();
  assert.equal(single.ctl.toggle(3), true); assert.equal(single.ctl.toggle(9), true);
  assert.deepEqual(single.ui().selectedOptionIds, [9]); single.ctl.toggle(9); assert.deepEqual(single.ui().selectedOptionIds, []);
  const f = fixture({ load: card => Promise.resolve(f.detail(card, { maxSelect: 2 })) }); await f.ctl.load();
  f.ctl.toggle(3); f.ctl.toggle(9); assert.equal(f.ctl.toggle(17), false);
  assert.deepEqual(f.ui().selectedOptionIds, [3, 9]); assert.match(f.ui().message, /最多选择 2/);
  f.ctl.toggle(3); f.ctl.toggle(17); assert.deepEqual(f.ui().selectedOptionIds, [9, 17]);
  assert.equal(await f.ctl.submit(), true); assert.deepEqual(f.calls.find(call => call[0] === 'submit')[3], [9, 17]);
});

test('reply endpoint stays single-choice and malformed option IDs never become a draft', async () => {
  const f = fixture({ load: card => Promise.resolve(f.detail(card, { maxSelect: 3 })) }); f.bind({}, { kind: 'reply' }); await f.ctl.load();
  f.ctl.toggle(3); f.ctl.toggle(9); assert.deepEqual(f.ui().selectedOptionIds, [9]);
  for (const id of [0, -1, 1.5, 4, NaN, Infinity]) assert.equal(f.ctl.toggle(id), false);
  assert.deepEqual(f.ui().selectedOptionIds, [9]);
});

test('metadata cannot submit before a current-account detail read, including unknown choice count', async () => {
  const pending = deferred(); const f = fixture({ load: () => pending.promise });
  f.bind({}, { loaded: true, options: [f.option(3)], maxSelect: 0, selectedIds: [3] });
  assert.equal(f.ctl.toggle(3), false); assert.equal(await f.ctl.submit(), false);
  const work = f.ctl.load(); assert.equal(f.ctl.toggle(3), false);
  pending.resolve(f.detail(undefined, { maxSelect: 0 })); await work;
  assert.equal(f.ctl.toggle(3), false); assert.equal(await f.ctl.submit(), false); assert.equal(f.count('submit'), 0);
});

test('expired/deleted and already-voted details show results without allowing another vote', async () => {
  for (const patch of [{ ended: true }, { deleted: true }, { endTime: 1 }, { selectedIds: [9] }]) {
    const f = fixture({ load: card => Promise.resolve(f.detail(card, patch)) }); await f.ctl.load();
    assert.equal(f.ctl.toggle(3), false); assert.equal(await f.ctl.submit(), false); assert.equal(f.count('submit'), 0);
    if (!patch.deleted) assert.equal(f.ui().resultsVisible, true);
    if (patch.selectedIds) assert.deepEqual(f.ui().selectedOptionIds, [9]);
  }
});

test('deadline reached after choosing blocks POST even if loaded ended flag was false', async () => {
  const f = fixture({ load: card => Promise.resolve(f.detail(card, { endTime: 2 })) }); await f.ctl.load(); f.ctl.toggle(3);
  f.state.clock = 2000; assert.equal(await f.ctl.submit(), false); assert.equal(f.ctl.toggle(9), false);
  assert.equal(f.count('submit'), 0); await f.ctl.viewResults(); assert.equal(f.ui().resultsVisible, true);
});

test('view results uses loaded counts first and refresh results really issues a new GET while preserving the draft', async () => {
  const f = fixture(); await f.ctl.load(); f.ctl.toggle(9);
  await f.ctl.viewResults(); assert.equal(f.ui().resultsVisible, true); assert.equal(f.count('load'), 1);
  await f.ctl.viewResults(); assert.equal(f.count('load'), 2); assert.equal(f.count('submit'), 0);
  assert.deepEqual(f.ui().selectedOptionIds, [9]);
});

test('guests may choose but cannot write, and empty draft cannot write', async () => {
  const f = fixture(); await f.ctl.load(); assert.equal(await f.ctl.submit(), false);
  f.state.login = false; f.ctl.toggle(3); assert.equal(await f.ctl.submit(), false);
  assert.equal(f.count('submit'), 0); assert.deepEqual(f.ui().selectedOptionIds, [3]); assert.match(f.toasts[0], /登录/);
});

test('vote publisher sees real results and cannot choose or submit their own vote', async () => {
  const f = fixture({ load: card => Promise.resolve(f.detail(card, { publisherMid: 777 })) }); await f.ctl.load();
  assert.equal(f.ui().resultsVisible, true); assert.deepEqual(f.ui().detail.selectedIds, []);
  assert.deepEqual(f.ui().detail.options.map(option => option.count), [4, 12, 8]);
  assert.equal(f.ctl.toggle(9), false); assert.equal(await f.ctl.submit(), false); assert.equal(f.count('submit'), 0);
});

test('submit deduplicates writes, freezes the submitted draft and preserves immutable source arguments', async () => {
  const pending = deferred(); const f = fixture({ submit: () => pending.promise }); await f.ctl.load(); f.ctl.toggle(3);
  const work = f.ctl.submit(); assert.equal(f.ui().submitting, true);
  assert.equal(f.ctl.toggle(9), false); assert.equal(await f.ctl.submit(), false); await f.ctl.load(true);
  assert.equal(f.count('submit'), 1); assert.equal(f.count('load'), 1);
  const call = f.calls.find(call => call[0] === 'submit');
  assert.deepEqual(call[1], { oid: 100, type: 1, rpid: 200, sourceKey: 'video:100:200' }); assert.deepEqual(call[3], [3]);
  pending.resolve({ ok: true, message: '', card: f.detail(undefined, { selectedIds: [3], count: 100,
    options: [f.option(3, 47), f.option(9, 42), f.option(17, 11)] }) });
  assert.equal(await work, true); assert.equal(f.ui().submitting, false); assert.equal(await f.ctl.submit(), false);
  assert.deepEqual(f.ui().detail.options.map(option => option.count), [47, 42, 11]); assert.equal(f.ui().detail.count, 100);
});

for (const throwing of [false, true]) test('failed vote preserves selection and can retry: throw=' + throwing, async () => {
  let writes = 0; const f = fixture({ submit: async (_source, card, ids) => {
    if (++writes === 1) { if (throwing) throw Error('offline'); return { ok: false, message: '服务器暂时不可用', card: null }; }
    return { ok: true, message: '', card: f.detail(card, { selectedIds: ids }) };
  } }); await f.ctl.load(); f.ctl.toggle(9);
  assert.equal(await f.ctl.submit(), false); assert.deepEqual(f.ui().selectedOptionIds, [9]);
  assert.deepEqual(f.ui().detail.options.map(option => option.count), [4, 12, 8]); assert.equal(f.ui().submitting, false);
  assert.match(f.ui().message, throwing ? /失败/ : /服务器暂时不可用/);
  assert.equal(await f.ctl.submit(), true); assert.equal(writes, 2); assert.deepEqual(f.ui().detail.selectedIds, [9]);
});

test('successful POST with failed refresh locks the confirmed vote, retains real counts and retries only GET', async () => {
  let reads = 0; const f = fixture({ load: async card => {
    if (++reads === 2) throw Error('offline refresh');
    return f.detail(card, reads > 2 ? { selectedIds: [9], count: 101, options: [f.option(3, 50), f.option(9, 51)] } : {});
  }, submit: async () => ({ ok: true, message: '', card: null }) });
  await f.ctl.load(); f.ctl.toggle(9); assert.equal(await f.ctl.submit(), true);
  assert.deepEqual(f.ui().detail.selectedIds, [9]); assert.deepEqual(f.ui().detail.options.map(option => option.count), [4, 12, 8]);
  assert.equal(f.ui().resultsVisible, true); assert.match(f.ui().message, /已投票.*刷新失败/);
  assert.equal(f.ctl.toggle(3), false); assert.equal(await f.ctl.submit(), false);
  await f.ctl.viewResults(); assert.deepEqual(f.ui().detail.selectedIds, [9]); assert.match(f.ui().message, /刷新失败/);
  await f.ctl.viewResults(); assert.deepEqual(f.ui().detail.options.map(option => option.count), [50, 51]);
  assert.equal(f.ui().message, ''); assert.equal(f.count('submit'), 1);
});

test('briefly stale refresh and repeated comment model snapshots never discard a confirmed choice', async () => {
  const f = fixture({ submit: async () => ({ ok: true, message: '', card: null }) }); await f.ctl.load(); f.ctl.toggle(9); await f.ctl.submit();
  f.bind({}, { selectedIds: [], loaded: true, count: 1 });
  assert.deepEqual(f.ui().detail.selectedIds, [9]); await f.ctl.load();
  assert.deepEqual(f.ui().detail.selectedIds, [9]); assert.deepEqual(f.ui().selectedOptionIds, [9]);
  assert.equal(await f.ctl.submit(), false); assert.equal(f.count('submit'), 1);
});

test('successful vote with returned results can refresh later totals without another POST', async () => {
  let reads = 0; const f = fixture({ load: async card => f.detail(card, ++reads > 1 ? {
    selectedIds: [9], count: 300, options: [f.option(3, 100), f.option(9, 200)],
  } : {}) });
  await f.ctl.load(); f.ctl.toggle(9); assert.equal(await f.ctl.submit(), true);
  assert.equal(f.ui().detail.count, 33); await f.ctl.viewResults();
  assert.equal(f.ui().detail.count, 300); assert.deepEqual(f.ui().detail.options.map(option => option.count), [100, 200]);
  assert.deepEqual(f.ui().detail.selectedIds, [9]); assert.equal(f.count('load'), 2);
  assert.equal(await f.ctl.submit(), false); assert.equal(f.count('submit'), 1);
});

test('same-source model rebinding preserves the chosen draft and in-flight request lock', async () => {
  const pending = deferred(); const f = fixture({ submit: () => pending.promise }); await f.ctl.load(); f.ctl.toggle(3);
  f.bind({}, { title: 'new comment snapshot' }); assert.deepEqual(f.ui().selectedOptionIds, [3]);
  const work = f.ctl.submit(); f.bind({}, { title: 'old snapshot' }); assert.equal(f.ui().submitting, true);
  const duplicate = f.ctl.submit(); assert.equal(f.count('submit'), 1);
  assert.equal(await duplicate, false); pending.resolve({ ok: false, message: 'retry', card: null }); await work;
  assert.deepEqual(f.ui().selectedOptionIds, [3]); assert.equal(f.ui().submitting, false);
});

test('failed initial load remains retryable and malformed detail cannot authorize a vote', async () => {
  let reads = 0; const f = fixture({ load: async card => {
    if (++reads === 1) throw Error('offline');
    return f.detail(card, reads === 2 ? { id: 'wrong' } : {});
  } }); await f.ctl.load(); assert.match(f.ui().message, /加载失败/); assert.equal(f.ui().loading, false);
  await f.ctl.load(); assert.equal(f.ui().detail, null); assert.equal(f.ctl.toggle(3), false);
  await f.ctl.load(); assert.equal(f.ui().detail.id, '19160335'); assert.equal(f.ui().message, '');
});

for (const field of ['oid', 'type', 'rpid', 'sourceKey', 'id', 'kind']) {
  test('changed ' + field + ' rejects old read and its finally cannot clear the new loading lock', async () => {
    const old = deferred(), latest = deferred(); let reads = 0;
    const f = fixture({ load: () => ++reads === 1 ? old.promise : latest.promise }); const oldCard = f.state.vote.clone();
    const work = f.ctl.load();
    f.bind(['id', 'kind'].includes(field) ? {} : { [field]: field === 'sourceKey' ? 'other' : f.state.source[field] + 1 },
      field === 'id' ? { id: '19160336' } : field === 'kind' ? { kind: 'reply' } : {});
    const next = f.ctl.load(); old.resolve(f.detail(oldCard, { selectedIds: [9] })); await work;
    assert.equal(f.ui().detail, null); assert.equal(f.ui().loading, true); await f.ctl.load(); assert.equal(reads, 2);
    latest.resolve(f.detail()); await next; assert.deepEqual(f.ui().detail.selectedIds, []);
  });
  test('changed ' + field + ' rejects old POST confirmation', async () => {
    const pending = deferred(); const f = fixture({ submit: () => pending.promise }); await f.ctl.load(); f.ctl.toggle(3);
    const oldCard = f.state.vote.clone(); const work = f.ctl.submit();
    f.bind(['id', 'kind'].includes(field) ? {} : { [field]: field === 'sourceKey' ? 'other' : f.state.source[field] + 1 },
      field === 'id' ? { id: '19160336' } : field === 'kind' ? { kind: 'reply' } : {});
    await f.ctl.load(); pending.resolve({ ok: true, message: '', card: f.detail(oldCard, { selectedIds: [3] }) });
    assert.equal(await work, false); assert.deepEqual(f.ui().detail.selectedIds, []); assert.equal(f.ui().submitting, false);
  });
}

test('source A B A rejects the original read even when every visible identity matches again', async () => {
  const old = deferred(), latest = deferred(); let reads = 0;
  const f = fixture({ load: () => ++reads === 1 ? old.promise : latest.promise }); const work = f.ctl.load();
  f.bind({ oid: 101 }); f.bind({ oid: 100 }); const next = f.ctl.load();
  old.resolve(f.detail(undefined, { selectedIds: [3] })); await work;
  assert.equal(f.ui().detail, null); assert.equal(f.ui().loading, true);
  latest.resolve(f.detail()); await next; assert.deepEqual(f.ui().selectedOptionIds, []);
});

for (const transition of ['source ABA', 'account']) test('old POST finally cannot unlock a new POST after ' + transition, async () => {
  const old = deferred(), latest = deferred(); let writes = 0;
  const f = fixture({ submit: () => ++writes === 1 ? old.promise : latest.promise }); await f.ctl.load(); f.ctl.toggle(3);
  const first = f.ctl.submit();
  if (transition === 'source ABA') { f.bind({ oid: 101 }); f.bind({ oid: 100 }); await f.ctl.load(); }
  else { f.AuthSession.advance(); f.ctl.onAccountChanged(); await tick(); }
  f.ctl.toggle(9); const second = f.ctl.submit();
  old.resolve({ ok: true, message: '', card: f.detail(undefined, { selectedIds: [3] }) });
  assert.equal(await first, false); assert.equal(f.ui().submitting, true); assert.equal(f.ctl.toggle(17), false);
  const duplicate = f.ctl.submit(); assert.equal(f.count('submit'), 2); assert.equal(await duplicate, false);
  latest.resolve({ ok: true, message: '', card: f.detail(undefined, { selectedIds: [9] }) });
  assert.equal(await second, true); assert.deepEqual(f.ui().detail.selectedIds, [9]); assert.equal(f.ui().submitting, false);
});

test('dispose and reuse of the same card reject old read and POST operations', async () => {
  const old = deferred(), latest = deferred(); let reads = 0;
  const f = fixture({ load: () => ++reads === 1 ? old.promise : latest.promise }); const work = f.ctl.load();
  f.ctl.dispose(); f.bind(); const next = f.ctl.load(); old.resolve(f.detail(undefined, { selectedIds: [9] })); await work;
  assert.equal(f.ui().detail, null); assert.equal(f.ui().loading, true); latest.resolve(f.detail()); await next;
  const pending = deferred(); const post = fixture({ submit: () => pending.promise }); await post.ctl.load(); post.ctl.toggle(9);
  const write = post.ctl.submit(); post.ctl.dispose(); post.bind(); await post.ctl.load();
  pending.resolve({ ok: true, message: '', card: post.detail(undefined, { selectedIds: [9] }) }); assert.equal(await write, false);
  assert.deepEqual(post.ui().detail.selectedIds, []);
});

test('live host prop changes are checked before a delayed watcher has rebound the controller', async () => {
  for (const field of ['oid', 'type', 'rpid', 'sourceKey', 'id', 'kind']) {
    const pending = deferred(); const f = fixture({ load: () => pending.promise }); const oldCard = f.state.vote.clone(); const work = f.ctl.load();
    if (field === 'id') f.state.vote.id = '19160336'; else if (field === 'kind') f.state.vote.kind = 'reply';
    else f.state.source[field] = field === 'sourceKey' ? 'new' : f.state.source[field] + 1;
    const writes = f.snapshots.length; pending.resolve(f.detail(oldCard)); await work;
    assert.equal(f.snapshots.length, writes); assert.equal(f.count('load'), 1); assert.equal(await f.ctl.submit(), false);
  }
});

test('destroyed host and cleared vote suppress late results and all further operations', async () => {
  for (const destroy of [true, false]) {
    const pending = deferred(); const f = fixture({ load: () => pending.promise }); const work = f.ctl.load();
    if (destroy) f.state.destroyed = true; else { f.state.vote = null; f.ctl.bind(f.state.source, null); }
    const writes = f.snapshots.length; pending.resolve(f.detail(f.card())); await work;
    assert.equal(f.snapshots.length, writes); await f.ctl.load(); assert.equal(f.ctl.toggle(3), false);
    assert.equal(await f.ctl.submit(), false); assert.equal(f.count('load'), 1);
  }
});

for (const operation of ['load', 'submit']) test('auth epoch is checked on ' + operation + ' completion before any watcher runs', async () => {
  const pending = deferred(); const f = fixture({ [operation]: () => pending.promise });
  if (operation === 'submit') { await f.ctl.load(); f.ctl.toggle(9); }
  const work = f.ctl[operation](); f.AuthSession.advance(); const writes = f.snapshots.length;
  pending.resolve(operation === 'load' ? f.detail(undefined, { selectedIds: [9] }) :
    { ok: true, message: '', card: f.detail(undefined, { selectedIds: [9] }) });
  await work; assert.equal(f.snapshots.length, writes);
  if (operation === 'submit') assert.deepEqual(f.ui().detail.selectedIds, []); else assert.equal(f.ui().detail, null);
});

test('account A B A rejects old read and completed-login watcher forcibly reloads the same epoch', async () => {
  const old = deferred(); let reads = 0;
  const f = fixture({ load: card => ++reads === 1 ? old.promise : Promise.resolve(f.detail(card, { selectedIds: reads === 2 ? [9] : [] })) });
  const work = f.ctl.load(); f.AuthSession.advance(); f.AuthSession.advance();
  assert.equal(f.ctl.toggle(3), false); await tick(); assert.deepEqual(f.ui().detail.selectedIds, [9]);
  f.ctl.onAccountChanged(); assert.equal(f.ui().detail, null); await tick(); assert.deepEqual(f.ui().detail.selectedIds, []);
  old.resolve(f.detail(undefined, { selectedIds: [3] })); await work;
  assert.deepEqual(f.ui().detail.selectedIds, []); assert.equal(reads, 3);
});

test('account watcher clears confirmed votes and drafts, then restores only the current account server state', async () => {
  let selected = [9]; const f = fixture({ load: card => Promise.resolve(f.detail(card, { selectedIds: selected })) }); await f.ctl.load();
  assert.equal(f.ctl.toggle(3), false); f.AuthSession.advance(); selected = []; f.ctl.onAccountChanged();
  assert.equal(f.ui().detail, null); assert.deepEqual(f.ui().selectedOptionIds, []); await tick();
  f.ctl.toggle(3); assert.deepEqual(f.ui().selectedOptionIds, [3]);
  f.AuthSession.advance(); selected = [17]; f.ctl.onAccountChanged(); await tick();
  assert.deepEqual(f.ui().selectedOptionIds, [17]); assert.equal(await f.ctl.submit(), false);
});
