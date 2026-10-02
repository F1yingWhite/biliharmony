const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function fixture(patch = {}) {
  let now = 10000, timerId = 0;
  const timers = new Map(), players = [], creations = [], createQueue = [], states = [], events = [], progress = [], apiCalls = [];
  const policy = {background: false, allowBackground: false, pipKeepsAlive: false, pipVisible: false, muted: false, ...patch};
  const globals = {
    Date: class extends Date {static now() {return now;}},
    setTimeout(fn, ms) {const id = ++timerId; timers.set(id, {fn, ms, at: now + ms}); return id;},
    clearTimeout(id) {timers.delete(id);},
    AppStorage: {get() {}, setOrCreate() {}},
  };
  function advance(ms) {
    const end = now + ms;
    for (;;) {
      const next = [...timers.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      timers.delete(next[0]); now = next[1].at; next[1].fn();
    }
    now = end;
  }
  function player(name = 'player-' + players.length) {
    const handlers = {}, calls = [];
    const value = {name, handlers, calls, state: 'idle', currentTime: 0, width: 1920, height: 1080,
      on(event, fn) {handlers[event] = fn;},
      onMetricsEvent(fn) {handlers.metrics = fn;},
      emit(event, ...args) {if (event === 'stateChange') value.state = args[0]; handlers[event]?.(...args);},
      async setMediaSource(source, strategy) {value.source = source; value.strategy = strategy; calls.push(['source', source.url]);},
      async prepare() {calls.push(['prepare']);},
      async play() {calls.push(['play']); value.state = 'playing';},
      async pause() {calls.push(['pause']); value.state = 'paused'; value.emit('stateChange', 'paused');},
      async release() {calls.push(['release']); value.state = 'released';},
      seek(ms, mode) {calls.push(['seek', ms, mode]);},
      setVolume(volume) {calls.push(['volume', volume]);},
      setPlaybackRate(rate) {calls.push(['rate', rate]);},
    };
    players.push(value); return value;
  }
  const media = {
    createAVPlayer() {const next = createQueue.length ? createQueue.shift() : Promise.resolve(player()); creations.push(next); return next;},
    createMediaSourceWithUrl(url, headers) {return {url, headers};},
    VideoScaleType: {VIDEO_SCALE_TYPE_SCALED_ASPECT: 0},
    SeekMode: {SEEK_CLOSEST: 0, SEEK_PREV_SYNC: 1},
    BufferingInfoType: {BUFFERING_START: 0, BUFFERING_END: 1},
  };
  const load = createArktsLoader({globals, mocks: {
    '@kit.MediaKit': {media}, '@kit.BasicServicesKit': {}, '@kit.PerformanceAnalysisKit': {hilog: {info() {}, error() {}}},
    BuildProfile: {DEBUG: false},
    'api/BiliApi': {BiliApi: {getPlayUrl(...args) {const request = {...deferred(), args}; apiCalls.push(request); return request.promise;}}},
  }});
  const {PlayerPlaybackSession} = load('components/player/PlayerPlaybackSession');
  const {PlayerPlaybackSource} = load('components/player/PlayerPlaybackState');
  const session = new PlayerPlaybackSession({policy: () => policy,
    state: state => states.push(state), event: event => events.push(event),
    progress: (seconds, background) => {progress.push({seconds, background}); return false;}});
  const source = (patch = {}) => Object.assign(new PlayerPlaybackSource(), {
    aid: 1, bvid: 'BV1', cid: 1, urls: ['video-primary', 'video-backup'],
    audioUrls: ['audio-primary', 'audio-backup'], quality: 80, ...patch,
  });
  async function boot(input = source()) {session.activate(input); await session.setSurface('surface'); await tick(); return {video: session.pair.video, audio: session.pair.audio};}
  function prepared() {session.pair.video?.emit('stateChange', 'prepared'); session.pair.audio?.emit('stateChange', 'prepared');}
  function playing() {prepared(); session.pair.video.emit('stateChange', 'playing'); session.pair.video.emit('startRenderFrame');}
  const calls = (player, kind) => player.calls.filter(call => call[0] === kind);
  return {load, session, policy, states, events, progress, apiCalls, timers, advance, players, player, createQueue,
    creations, source, boot, prepared, playing, calls, state: () => states.at(-1), globals, media};
}
module.exports = {fixture, deferred, tick};
