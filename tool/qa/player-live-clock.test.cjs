const test = require('node:test');
const assert = require('node:assert/strict');
const {fixture} = require('./player-session-fixture.cjs');

function clockHarness() {
  const f = fixture();
  const {PlayerAudioSync} = f.load('components/player/PlayerAudioSync');
  const {PlayerPlaybackState} = f.load('components/player/PlayerPlaybackState');
  const {PlayerTrackPair} = f.load('components/player/PlayerTrackPair');
  const pair = new PlayerTrackPair(() => {});
  const state = Object.assign(new PlayerPlaybackState(), {playing: true});
  const queries = [], resyncs = [], rates = [], plays = [];
  function player(name) {
    return {state: 'playing', currentTime: 10000, position: 10000,
      getPlaybackPosition() {queries.push(name); return this.position;},
      setPlaybackRate(rate) {rates.push(rate);}, setVolume() {},
      play() {plays.push(name); return Promise.resolve();},
    };
  }
  pair.video = player('video'); pair.audio = player('audio');
  pair.prepared = pair.audioPrepared = true;
  const sync = new PlayerAudioSync(pair, state, {canPlay: () => true, muted: () => false,
    isSeeking: () => false, changed() {}, clock() {}, rate() {},
    resync: target => resyncs.push(target), error() {assert.fail('unexpected playback error');}});
  const sample = (count = 3) => {for (let i = 0; i < count; i++) sync.checkAudioSync(pair.video.currentTime);};
  return {sync, pair, state, queries, resyncs, rates, plays, sample};
}

test('live clocks: differing cached positions do not correct aligned playback', () => {
  const f = clockHarness();
  f.pair.video.currentTime = 12000; f.pair.audio.currentTime = 10000;
  f.pair.video.position = f.pair.audio.position = 12100;
  f.sample(9);
  assert.deepEqual(f.rates, []); assert.deepEqual(f.resyncs, []);
  assert.equal(f.queries.filter(name => name === 'video').length, 9);
  assert.equal(f.queries.filter(name => name === 'audio').length, 9);
});

test('live clocks: hidden drift resynchronizes to the sampled live video position', () => {
  const f = clockHarness();
  let videoQueries = 0;
  f.pair.video.getPlaybackPosition = () => {videoQueries++; return videoQueries === 3 ? 12345 : 12000;};
  f.pair.audio.position = 10000;
  f.sample();
  assert.deepEqual(f.resyncs, [12345]);
  assert.equal(videoQueries, 3, 'the correction target must reuse the drift measurement rather than querying again');
  assert.deepEqual(f.rates, []);
});

test('live clocks: the startup gate plays aligned audio despite stale cached positions', () => {
  const f = clockHarness();
  f.pair.video.currentTime = 5000; f.pair.audio.currentTime = 0;
  f.pair.video.position = f.pair.audio.position = 5100;
  f.pair.audio.state = 'paused';
  f.sync.gateAudioStart(); f.sync.tryStartGatedAudio();
  assert.deepEqual(f.resyncs, []); assert.deepEqual(f.plays, ['audio']);
  assert.deepEqual(f.queries, ['video', 'audio']);
  assert.equal(f.sync.audioStartPending, false);
});

test('live clocks: failed queries safely fall back to cached positions for correction and startup', () => {
  const f = clockHarness();
  f.pair.video.getPlaybackPosition = f.pair.audio.getPlaybackPosition = () => {throw new Error('unsupported');};
  f.pair.video.currentTime = 9000; f.pair.audio.currentTime = 7000;
  assert.doesNotThrow(() => f.sample());
  assert.deepEqual(f.resyncs, [9000]);
  f.pair.audio.currentTime = 9000; f.pair.audio.state = 'paused';
  f.sync.gateAudioStart();
  assert.doesNotThrow(() => f.sync.tryStartGatedAudio());
  assert.deepEqual(f.plays, ['audio']);
});

test('live clocks: unprepared tracks never receive a playback position query', () => {
  const f = clockHarness();
  f.pair.prepared = false;
  f.pair.video.currentTime = 10000; f.pair.video.position = 20000;
  f.pair.audio.position = 10000;
  f.sample();
  assert.deepEqual(f.queries, ['audio', 'audio', 'audio']);
  assert.deepEqual(f.rates, []); assert.deepEqual(f.resyncs, []);
  f.pair.audioPrepared = false; f.sample();
  assert.equal(f.queries.length, 3);
});

test('live clocks: alternating drift directions cannot accumulate into a correction', () => {
  const f = clockHarness();
  for (const drift of [600, -600, 600, -600, 600, -600]) {
    f.pair.audio.position = f.pair.audio.currentTime = 10000 + drift;
    f.sample(1);
  }
  assert.deepEqual(f.rates, []); assert.deepEqual(f.resyncs, []);
  f.pair.audio.position = 9400; f.sample(2);
  assert.deepEqual(f.rates, [1.03], 'three consecutive samples in the new direction still correct sustained drift');
});

test('live clocks: sustained 200ms lag at double speed corrects until it enters the 80ms band', () => {
  const f = clockHarness(); f.state.playbackRate = 2;
  f.pair.audio.position = 9800;
  f.sample(2);
  assert.deepEqual(f.rates, [], 'two same-direction samples do not yet correct');
  f.sample(1);
  assert.deepEqual(f.rates, [2.06]); assert.deepEqual(f.resyncs, []);
  f.pair.audio.position = 9910; f.sample(1);
  assert.deepEqual(f.rates, [2.06], '90ms retains the existing correction');
  f.pair.audio.position = 9920; f.sample(1);
  assert.deepEqual(f.rates, [2.06, 2], '80ms restores the selected playback rate');
});

test('live clocks: a fresh 140ms drift does not start a correction', () => {
  const f = clockHarness();
  f.pair.audio.position = 9860; f.sample(9);
  assert.deepEqual(f.rates, []); assert.deepEqual(f.resyncs, []);
});

test('live clocks: alternating 200ms drift remains below the sustained-direction requirement', () => {
  const f = clockHarness();
  for (const drift of [200, -200, 200, -200, 200, -200, 200, -200]) {
    f.pair.audio.position = 10000 + drift; f.sample(1);
  }
  assert.deepEqual(f.rates, []); assert.deepEqual(f.resyncs, []);
});
