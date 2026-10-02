const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

// Only clock and IO are replaced. Session, buffer, models, auth and data source
// execute as complete production modules in an isolated module graph per case.
function fixture() {
  let now = 0, sequence = 0;
  const timers = new Map(), calls = [], clients = [], events = [], states = [], notices = [];
  const schedule = (callback, delay, interval = 0) => {
    const id = ++sequence; timers.set(id, {callback, at: now + delay, interval}); return id;
  };
  const globals = {
    Date: class extends Date {static now() {return now;}},
    setTimeout: (callback, delay) => schedule(callback, delay), clearTimeout: id => timers.delete(id),
    setInterval: (callback, delay) => schedule(callback, delay, delay), clearInterval: id => timers.delete(id),
  };
  function advance(ms) {
    const end = now + ms;
    for (;;) {
      const next = [...timers.entries()].filter(([, timer]) => timer.at <= end)
        .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
      if (!next) break;
      const [id, timer] = next; now = timer.at;
      if (timer.interval) timer.at += timer.interval; else timers.delete(id);
      timer.callback();
    }
    now = end;
  }
  const api = {};
  for (const name of ['getLiveRoomInfo', 'getLivePlayInfo', 'getLiveDanmakuHistory', 'getLiveSuperChats']) {
    api[name] = (...args) => {const request = {name, args, ...deferred()}; calls.push(request); return request.promise;};
  }
  class Client {
    constructor() {this.closed = false; this.reconnects = 0; clients.push(this);}
    async connect(roomId) {this.roomId = roomId;}
    close() {this.closed = true; this.onConnected(false);}
    manualReconnect() {this.reconnects++;}
  }
  const load = createArktsLoader({globals, mocks: {
    'api/LiveApi': {LiveApi: api}, 'common/LiveDanmakuClient': {LiveDanmakuClient: Client},
  }});
  const {LiveChatBuffer} = load('components/live/LiveChatBuffer');
  const {LiveRoomSession} = load('components/live/LiveRoomSession');
  const {LiveChatMessage, LivePlayInfo, LiveRoomInfo} = load('model/LiveModels');
  const {AuthSession} = load('services/auth/AuthSession');
  const record = kind => messages => events.push({kind, messages: messages.slice()});
  const buffer = new LiveChatBuffer({resetMessages: record('baseline'), publishMessages: record('messages'),
    publishSuperChats: record('sc')}, baseline => events.push({kind: 'layout', baseline}), () => {});
  const session = new LiveRoomSession(buffer, state => {
    states.push(state); events.push({kind: 'state', state});
  }, message => notices.push(message));
  const message = (id, extra = {}) => Object.assign(new LiveChatMessage(), {id, text: id}, extra);
  const play = (url = 'stream-one', qn = 10000) => Object.assign(new LivePlayInfo(), {url, currentQn: qn});
  const info = (roomId = 1) => Object.assign(new LiveRoomInfo(), {roomId, liveStatus: 1});
  const activate = (roomId = 1) => session.activate({roomId, uid: 10, title: 'room ' + roomId,
    uname: 'host', face: '', cover: ''});
  const requests = name => calls.filter(call => call.name === name);
  const last = name => requests(name).at(-1);
  const state = () => states.at(-1);
  async function boot(history = [message('history')], resolveSnapshot = true) {
    activate(); const loading = session.load(); last('getLiveRoomInfo').resolve(info()); await tick();
    last('getLivePlayInfo').resolve(play()); await tick();
    last('getLiveDanmakuHistory').resolve(history); await loading;
    if (resolveSnapshot) {last('getLiveSuperChats').resolve([]); await tick();}
  }
  return {session, buffer, LiveChatBuffer, AuthSession, events, states, notices, clients, timers, calls,
    advance, message, play, info, activate, requests, last, state, boot};
}

test('live buffer: initial history establishes a deduplicated baseline without replay', () => {
  const f = fixture(); f.buffer.activate(() => true);
  f.buffer.establishBaseline([f.message('a'), f.message('a'), f.message('b')], true);
  assert.deepEqual(f.buffer.source.getAll().map(m => m.id), ['a', 'b']);
  assert.equal(f.events.filter(e => e.kind === 'messages').length, 0);
  f.buffer.append(f.message('a')); f.advance(220);
  assert.equal(f.events.filter(e => e.kind === 'messages').length, 0);
  assert.equal(f.timers.size, 0);
});

test('live buffer: a burst commits once at 220ms and local echo preserves arrival order', () => {
  const f = fixture(); f.buffer.activate(() => true); f.buffer.establishBaseline([]);
  f.buffer.append(f.message('a')); f.advance(100); f.buffer.append(f.message('b'));
  f.advance(119); assert.equal(f.buffer.source.totalCount(), 0); assert.equal(f.timers.size, 1);
  f.advance(1); assert.deepEqual(f.buffer.source.getAll().map(m => m.id), ['a', 'b']);
  assert.equal(f.events.filter(e => e.kind === 'messages').length, 1);
  f.buffer.append(f.message('c')); f.buffer.appendLocal(f.message('local'));
  assert.deepEqual(f.buffer.source.getAll().map(m => m.id), ['a', 'b', 'c', 'local']);
  f.advance(220); assert.equal(f.events.filter(e => e.kind === 'messages').length, 3);
  assert.equal(f.timers.size, 0);
});

test('live buffer: pending, recent IDs, player and chat windows stay bounded during a flood', () => {
  const f = fixture(); f.buffer.activate(() => true); f.buffer.establishBaseline([f.message('baseline')]);
  for (let i = 0; i < 2500; i++) f.buffer.append(f.message('remote-' + i));
  assert.equal(f.buffer.pending.length, 240); assert.equal(f.buffer.known.size, 2000);
  assert.equal(f.buffer.baselineIds.size, 1); assert.equal(f.timers.size, 1);
  f.advance(220);
  assert.equal(f.buffer.source.totalCount(), 200);
  assert.equal(f.events.filter(e => e.kind === 'messages').at(-1).messages.length, 200);
  const before = f.events.length;
  f.buffer.append(f.message('baseline')); f.buffer.append(f.message('remote-2499')); f.advance(220);
  assert.equal(f.events.length, before, 'initial history stays suppressed after the recent-ID window rolls');
  assert.equal(f.buffer.source.getData(199).id, 'remote-2499');
});

test('live buffer: large baseline has bounded IDs and keeps only the visible windows', () => {
  const f = fixture(); f.buffer.activate(() => true);
  f.buffer.establishBaseline(Array.from({length: 5000}, (_, i) => f.message('h-' + i)));
  assert.equal(f.buffer.known.size, 2000); assert.equal(f.buffer.baselineIds.size, 2000);
  assert.equal(f.buffer.source.totalCount(), 200);
  assert.equal(f.events.find(e => e.kind === 'baseline').messages.length, 240);
});

test('live buffer: SC newest-first cap and realtime-over-snapshot precedence survive polling', () => {
  const f = fixture(); f.buffer.activate(() => true); f.buffer.establishBaseline([]);
  f.buffer.append(f.message('same', {type: 'sc', text: 'realtime', timestamp: 100}));
  f.buffer.mergeSnapshot([f.message('same', {type: 'sc', text: 'snapshot', timestamp: 101}),
    ...Array.from({length: 70}, (_, i) => f.message('sc-' + i, {type: 'sc', timestamp: i}))]);
  const sc = f.events.filter(e => e.kind === 'sc').at(-1).messages;
  assert.equal(sc.length, 50); assert.equal(sc[0].text, 'realtime');
  assert.equal(sc[1].id, 'sc-69'); assert.equal(sc.at(-1).id, 'sc-21');
  assert.equal(new Set(sc.map(m => m.id)).size, 50);
});

test('live buffer: invalidation before flush discards queued work and future messages', () => {
  const f = fixture(); let active = true; f.buffer.activate(() => active);
  f.buffer.append(f.message('queued')); active = false; f.advance(220);
  f.buffer.appendLocal(f.message('local')); f.buffer.mergeSnapshot([f.message('sc', {type: 'sc'})]);
  assert.equal(f.buffer.source.totalCount(), 0); assert.deepEqual(f.events, []);
  active = true; f.buffer.activate(() => active); f.buffer.append(f.message('next')); f.buffer.dispose();
  assert.equal(f.timers.size, 0); f.advance(220); assert.equal(f.buffer.source.totalCount(), 0);
});

test('live session: baseline precedes playable state and slow/failing SC never delays the connection', async () => {
  const f = fixture(); await f.boot(undefined, false);
  assert.equal(f.clients.length, 1); assert.equal(f.state().loading, false); assert.equal(f.state().play.url, 'stream-one');
  const baseline = f.events.findIndex(e => e.kind === 'baseline' && e.messages[0]?.id === 'history');
  const playable = f.events.findIndex(e => e.kind === 'state' && e.state.play.url === 'stream-one');
  assert.ok(baseline >= 0 && baseline < playable);
  assert.equal(f.events.filter(e => e.kind === 'messages').length, 0);
  f.clients[0].onConnected(true); assert.equal(f.state().connected, true);
  f.last('getLiveSuperChats').reject(Error('offline')); await tick();
  assert.equal(f.state().error, ''); assert.equal(f.state().play.url, 'stream-one');
  f.session.dispose(); assert.equal(f.timers.size, 0);
});

for (const stage of ['info', 'play', 'history']) for (const boundary of ['exit', 'room', 'account']) {
  test(`live session: late ${stage} after ${boundary} cannot advance the request chain or publish`, async () => {
    const f = fixture(); f.activate(); const work = f.session.load();
    if (stage !== 'info') {f.last('getLiveRoomInfo').resolve(f.info()); await tick();}
    if (stage === 'history') {f.last('getLivePlayInfo').resolve(f.play()); await tick();}
    const pending = f.calls.at(-1);
    if (boundary === 'exit') f.session.dispose();
    if (boundary === 'room') f.activate(2);
    if (boundary === 'account') f.AuthSession.advance();
    const eventCount = f.events.length, callCount = f.calls.length;
    pending.resolve(stage === 'info' ? f.info() : stage === 'play' ? f.play() : [f.message('old')]);
    await work;
    assert.equal(f.calls.length, callCount); assert.equal(f.events.length, eventCount);
    assert.equal(f.clients.length, 0); assert.equal(f.buffer.source.totalCount(), 0);
  });
}

test('live session: offline and rejected loading terminate loading without starting a socket', async () => {
  for (const rejected of [false, true]) {
    const f = fixture(); f.activate(); const work = f.session.load();
    if (rejected) f.last('getLiveRoomInfo').reject(Error('offline'));
    else {
      f.last('getLiveRoomInfo').resolve(Object.assign(f.info(), {liveStatus: 0})); await tick();
      f.last('getLivePlayInfo').resolve(null);
    }
    await work; assert.equal(f.state().loading, false); assert.equal(f.clients.length, 0);
    assert.match(f.state().error, rejected ? /加载失败/ : /未开播/);
  }
});

test('live session: sync cancels old socket/quality/batch and resets history without replay', async () => {
  const f = fixture(); await f.boot(undefined, false);
  const oldSnapshot = f.last('getLiveSuperChats'), oldClient = f.clients[0];
  oldClient.onMessage(f.message('pending'));
  const quality = f.session.changeQuality(400), qualityRequest = f.last('getLivePlayInfo');
  const sync = f.session.sync(); const syncPlay = f.last('getLivePlayInfo'), syncHistory = f.last('getLiveDanmakuHistory');
  assert.equal(oldClient.closed, true); assert.equal(f.state().qualityLoading, false); assert.equal(f.state().refreshing, true);
  assert.notEqual(syncPlay, qualityRequest); assert.equal(syncPlay.args[1], 10000);
  qualityRequest.resolve(f.play('obsolete-quality', 400)); await quality;
  oldClient.onMessage(f.message('stale-socket')); oldClient.onGiveUp();
  oldSnapshot.resolve([f.message('stale-sc', {type: 'sc'})]); await tick();
  syncHistory.resolve([f.message('new-baseline')]); syncPlay.resolve(f.play('synced')); await sync;
  f.advance(220);
  assert.equal(f.state().play.url, 'synced'); assert.equal(f.state().refreshing, false); assert.equal(f.clients.length, 2);
  assert.equal(f.state().gaveUp, false); assert.equal(f.buffer.source.getData(0).id, 'new-baseline');
  assert.equal(f.events.filter(e => e.kind === 'messages').length, 0);
  assert.deepEqual(f.events.filter(e => e.kind === 'sc').at(-1).messages, []);
  f.clients[1].onMessage(f.message('new-socket')); f.advance(220);
  assert.equal(f.buffer.source.getData(1).id, 'new-socket'); f.session.dispose();
});

for (const failure of ['empty', 'both-reject']) test(`live session: sync ${failure} preserves playback and reconnects`, async () => {
  const f = fixture(); await f.boot(); const sync = f.session.sync();
  const play = f.last('getLivePlayInfo'), history = f.last('getLiveDanmakuHistory');
  if (failure === 'empty') {play.resolve(null); history.resolve([]);}
  else {play.reject(Error('play failed')); await tick(); history.reject(Error('history failed'));}
  await sync; await tick();
  assert.equal(f.state().play.url, 'stream-one'); assert.equal(f.state().refreshing, false);
  assert.equal(f.clients.length, 2); assert.equal(f.clients[0].closed, true);
  assert.equal(f.buffer.source.getData(0).id, 'history'); assert.match(f.notices.at(-1), /同步失败/);
  f.session.dispose();
});

test('live session: fallback waits for remote silence, suppresses overlap and deduplicates history', async () => {
  const f = fixture(); await f.boot(); f.advance(5000);
  assert.equal(f.requests('getLiveDanmakuHistory').length, 1);
  f.clients[0].onMessage(f.message('remote')); f.advance(5000);
  assert.equal(f.requests('getLiveDanmakuHistory').length, 1);
  f.advance(5000); assert.equal(f.requests('getLiveDanmakuHistory').length, 2);
  f.advance(15000); assert.equal(f.requests('getLiveDanmakuHistory').length, 2, 'one request per active poll');
  f.last('getLiveDanmakuHistory').resolve([f.message('history'), f.message('remote'), f.message('fallback')]);
  f.last('getLiveSuperChats').resolve([]); await tick(); f.advance(220);
  assert.deepEqual(f.buffer.source.getAll().map(m => m.id), ['history', 'remote', 'fallback']);
  f.session.dispose(); assert.equal(f.timers.size, 0);
});

test('live session: an old fallback completion cannot release the new room poll lock', async () => {
  const f = fixture(); await f.boot(); f.advance(10000);
  const oldHistory = f.last('getLiveDanmakuHistory'), oldSC = f.last('getLiveSuperChats');
  await f.boot(); f.advance(10000);
  const newHistory = f.last('getLiveDanmakuHistory'), newSC = f.last('getLiveSuperChats');
  const count = f.requests('getLiveDanmakuHistory').length;
  oldHistory.resolve([f.message('old')]); oldSC.resolve([f.message('old-sc', {type: 'sc'})]); await tick();
  f.advance(10000); assert.equal(f.requests('getLiveDanmakuHistory').length, count);
  assert.equal(f.buffer.source.totalCount(), 1);
  newHistory.resolve([f.message('new')]); newSC.resolve([]); await tick(); f.advance(220);
  assert.deepEqual(f.buffer.source.getAll().map(m => m.id), ['history', 'new']); f.session.dispose();
});

for (const trigger of ['message', 'timer']) test(`live session: account change ${trigger} closes old connection before UI broadcast`, async () => {
  const f = fixture(); await f.boot(); const client = f.clients[0];
  client.onMessage(f.message('queued')); const eventCount = f.events.length;
  f.AuthSession.advance();
  if (trigger === 'message') client.onMessage(f.message('late')); else f.advance(5000);
  f.advance(220); assert.equal(client.closed, true); assert.equal(f.timers.size, 0);
  assert.equal(f.events.length, eventCount); assert.deepEqual(f.buffer.source.getAll().map(m => m.id), ['history']);
  await f.session.sync(); await f.session.changeQuality(400); assert.equal(f.clients.length, 1);
});

test('live session: manual reconnect only follows give-up and late closed callbacks stay inert', async () => {
  const f = fixture(); await f.boot(); const client = f.clients[0];
  f.session.manualReconnect(); assert.equal(client.reconnects, 0);
  client.onGiveUp(); assert.equal(f.state().gaveUp, true);
  f.session.manualReconnect(); assert.equal(client.reconnects, 1); assert.equal(f.state().gaveUp, false);
  f.session.manualReconnect(); assert.equal(client.reconnects, 1);
  client.onConnected(true); assert.equal(f.state().connected, true);
  f.session.dispose(); const count = f.states.length;
  client.onConnected(false); client.onGiveUp(); client.onMessage(f.message('late'));
  assert.equal(f.states.length, count); assert.equal(f.timers.size, 0);
});

for (const boundary of ['exit', 'room', 'account']) test(`live session: sync completing after ${boundary} cannot reconnect or publish`, async () => {
  const f = fixture(); await f.boot(); const sync = f.session.sync();
  const play = f.last('getLivePlayInfo'), history = f.last('getLiveDanmakuHistory');
  if (boundary === 'exit') f.session.dispose();
  if (boundary === 'room') f.activate(2);
  if (boundary === 'account') f.AuthSession.advance();
  const count = f.events.length;
  play.resolve(f.play('obsolete')); history.resolve([f.message('obsolete')]); await sync;
  assert.equal(f.events.length, count); assert.equal(f.clients.length, 1);
  assert.equal(f.timers.size, 0); assert.deepEqual(f.notices, []);
});
