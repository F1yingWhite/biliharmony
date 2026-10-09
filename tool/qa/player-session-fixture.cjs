const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function fixture(patch = {}) {
  let now = 10000, timerId = 0;
  const timers = new Map(), engines = [], opens = [], openQueue = [], states = [], events = [], progress = [], apiCalls = [];
  const policy = {background: false, allowBackground: false, pipKeepsAlive: false, muted: false, ...patch};
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
  function createEngine(notify) {
    const calls = [];
    let generation = 0, opening = null, closing = null;
    const value = {name: 'engine-' + engines.length, calls, state: 'idle', currentTime: 0, width: 1920, height: 1080,
      async open(surfaceId, videoUrl, audioUrl, headers) {
        const token = ++generation;
        const pending = openQueue.length ? openQueue.shift() : Promise.resolve();
        opens.push(pending);
        opening = (async () => {
          await pending;
          if (token !== generation) return;
          Object.assign(value, {surfaceId, videoUrl, audioUrl, headers, state: 'initialized'});
        })();
        return opening;
      },
      emit(kind, ...args) {
        const {PlayerEngineEvent} = load('components/player/PlayerEngine');
        const event = new PlayerEngineEvent(kind);
        if (kind === 'state') {
          value.state = event.state = args[0];
        } else if (kind === 'error' || kind === 'audio-error') {
          event.message = args[0] ?? 'native error';
        } else {
          event.value = args[0] ?? 0;
          event.second = args[1] ?? (kind === 'seek' ? value.currentTime : 0);
        }
        notify(event);
      },
      async play() {calls.push(['play']); value.state = 'playing';},
      async pause() {calls.push(['pause']); value.emit('state', 'paused');},
      release() {
        if (closing) return closing;
        ++generation; calls.push(['release']); value.state = 'released';
        closing = opening ? opening.catch(() => {}) : Promise.resolve();
        return closing;
      },
      seek(ms, mode) {calls.push(['seek', ms, mode]);},
      resize(width, height) {calls.push(['resize', width, height]);},
      setVolume(volume) {calls.push(['volume', volume]);},
      setPlaybackRate(rate) {calls.push(['rate', rate]);},
    };
    engines.push(value); return value;
  }
  const load = createArktsLoader({globals, mocks: {
    '@kit.BasicServicesKit': {}, '@kit.PerformanceAnalysisKit': {hilog: {info() {}, error() {}}},
    BuildProfile: {DEBUG: false},
    // Session/controller behavior is exercised with one controllable engine.
    // Native MPV creation/events are covered independently by player-native.test.cjs.
    'components/player/PlayerMpvEngine': {PlayerMpvEngine: class {
      constructor(notify) {return createEngine(notify);}
    }},
    'api/BiliApi': {BiliApi: {getPlayUrl(...args) {const request = {...deferred(), args}; apiCalls.push(request); return request.promise;}}},
  }});
  const {PlayerPlaybackSession} = load('components/player/PlayerPlaybackSession');
  const {PlayerPlaybackSource} = load('components/player/PlayerPlaybackState');
  const {PlayerBuffering} = load('components/player/PlayerEngine');
  const session = new PlayerPlaybackSession({policy: () => policy,
    state: state => states.push(state), event: event => events.push(event),
    progress: (seconds, background) => {progress.push({seconds, background});}});
  const source = (patch = {}) => Object.assign(new PlayerPlaybackSource(), {
    aid: 1, bvid: 'BV1', cid: 1, urls: ['video-primary', 'video-backup'],
    audioUrls: [], quality: 80, ...patch,
  });
  function dashSource(patch = {}) {
    return source({urls: ['https://video.test/main', 'https://video.test/backup'],
      audioUrls: ['https://audio.test/main', 'https://audio.test/backup'], ...patch});
  }
  async function boot(input = source()) {session.activate(input); await session.setSurface('surface'); await tick(); return {engine: session.core.engine};}
  function prepared() {
    const engine = session.core.engine;
    if (!engine) return;
    engine.emit('state', 'prepared');
    engine.emit('size', engine.width, engine.height);
  }
  function playing() {prepared(); session.core.engine.emit('state', 'playing'); session.core.engine.emit('frame');}
  const calls = (engine, kind) => engine.calls.filter(call => call[0] === kind);
  return {load, session, policy, states, events, progress, apiCalls, timers, advance, engines, openQueue,
    opens, source, dashSource, boot, prepared, playing, calls, state: () => states.at(-1), globals,
    PlayerBuffering};
}
module.exports = {fixture, deferred, tick};
