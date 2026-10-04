const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader} = require('./arkts-module.cjs');

function fixture(mode = 2) {
  let now = 12, segments = [], notice = null;
  const volumes = [], seeks = [];
  const load = createArktsLoader({mocks: {
    'api/SponsorBlockApi': {SponsorBlockApi: {reportViewed: async () => {}}},
    'common/Utils': {formatDuration: seconds => String(seconds)},
    'common/SponsorBlock': {
      SponsorBlockMode: {DISABLED: -1, SHOW: 0, MANUAL: 1, AUTO: 2},
      SponsorBlockStore: {modeFor: () => mode, recordSkip() {}},
      sponsorBlockCategory: () => ({label: '赞助广告', color: '#00D400'}),
      sponsorBlockActionLabel: action => action,
    },
  }, globals: {setTimeout: () => 1, clearTimeout() {}}});
  const {PlayerSponsorController} = load('components/player/PlayerSponsorController');
  const ctl = new PlayerSponsorController({
    isDestroyed: () => false, getSegments: () => segments, setSegments: value => {segments = value;},
    getSponsorSkipEnabled: () => true, getPlayhead: () => now, applyNotice: value => {notice = value;},
    onFullLabel() {}, seekTo: seconds => seeks.push(seconds),
    muteImmediately: () => volumes.push(0), restoreUserVolume: () => volumes.push(1),
    isFirstFrameMuteArmed: () => false, toast() {}, getBvid: () => 'BV1', getCid: () => 1,
  });
  const segment = (patch = {}) => ({start: 10, end: 30, category: 'sponsor',
    actionType: 'mute', uuid: 'mute-a', ...patch});
  segments = [segment()];
  const tick = seconds => {now = seconds; ctl.maybeSkipSponsor(seconds);};
  const execute = () => {tick(12); if (mode === 1) ctl.noticePrimary();};
  return {ctl, tick, execute, segment, volumes, seeks,
    notice: () => notice, setSegments: value => {segments = value;}};
}

for (const mode of [1, 2]) {
  const label = mode === 1 ? 'manual' : 'auto';
  test(`SponsorBlock ${label}: undo mute persists through progress in the same segment`, () => {
    const f = fixture(mode); f.execute();
    assert.equal(f.ctl.isMuted(), true); assert.equal(f.notice().canUndo, true);
    f.ctl.noticePrimary();
    assert.equal(f.ctl.isMuted(), false); assert.equal(f.notice(), null);
    for (const seconds of [12.2, 18, 29.9, 30]) f.tick(seconds);
    assert.equal(f.ctl.isMuted(), false);
    assert.deepEqual(f.volumes, [0, 1], 'progress must not reapply an undone mute');
  });

  for (const reset of ['resetForReplay', 'resetRuntime']) {
    test(`SponsorBlock ${label}: ${reset} permits the muted segment to execute again`, () => {
      const f = fixture(mode); f.execute(); f.ctl.noticePrimary(); f.tick(12.2);
      assert.equal(f.ctl.isMuted(), false);
      f.ctl[reset](); f.execute();
      assert.equal(f.ctl.isMuted(), true); assert.equal(f.notice().canUndo, true);
    });
  }
}

test('SponsorBlock: undoing one overlapping mute keeps another active mute in effect', () => {
  const f = fixture();
  f.setSegments([f.segment({end: 20}), f.segment({uuid: 'mute-b', start: 12})]);
  f.tick(13); f.tick(13.1); // Execute both; the notice belongs to the second segment.
  f.ctl.noticePrimary();
  assert.equal(f.ctl.isMuted(), true, 'undo applies to one segment, not the other active mute');
  f.tick(19); assert.equal(f.ctl.isMuted(), true);
  f.tick(20); assert.equal(f.ctl.isMuted(), false, 'only the undone segment remains active');
  f.tick(25); assert.equal(f.ctl.isMuted(), false);
});

test('SponsorBlock: a source change clears mute undo even when a new source reuses the same UUID', () => {
  const f = fixture(); f.execute(); f.ctl.noticePrimary();
  f.ctl.invalidateForSourceChange(); f.setSegments([f.segment()]); f.execute();
  assert.equal(f.ctl.isMuted(), true);
});

test('SponsorBlock: undoing a skip keeps it handled until replay', () => {
  const f = fixture(); f.setSegments([f.segment({actionType: 'skip'})]);
  f.execute(); f.ctl.noticePrimary(); f.tick(12.2);
  assert.deepEqual(f.seeks, [30.01, 12]);
  f.ctl.resetForReplay(); f.tick(12);
  assert.deepEqual(f.seeks, [30.01, 12, 30.01]);
});
