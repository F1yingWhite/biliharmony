const test = require('node:test');
const assert = require('node:assert/strict');
const { environment } = require('./dynamic-test-env.cjs');
function fixture(reduced) {
  const routes = [], flags = [], snapshots = [];
  let reads = 0;
  const env = environment({
    'common/MotionTokens': { MotionTokens: { isReduced: () => reduced } },
    'common/ImageUrl': { biliImageThumbnail: (url, width) => url + '@' + width },
    'common/AppRouter': {
      AppNavStack: { pushPathByName: (...args) => routes.push(args) },
      NAV_VIDEO_DETAIL: 'video', NAV_DYNAMIC_DETAIL: 'dynamic', NAV_IMAGE_VIEWER: 'images',
      NAV_LIVE_ROOM: 'live', NAV_BANGUMI_DETAIL: 'bangumi',
      HERO_NAV_TRANSITION_ACTIVE_KEY: 'active', HERO_NAV_TRANSITION_DURATION_KEY: 'duration',
      setHeroBgSnapshot: value => snapshots.push(value),
    },
  }, { AppStorage: { setOrCreate: (...args) => flags.push(args) }, Curve: { EaseInOut: 'curve' } });
  const item = { dynId: 'd1', bvid: 'BV-source', aid: 123, title: 'title', cover: 'cover.jpg',
    images: Array.from({ length: 11 }, (_, index) => 'original-' + index + '.jpg') };
  const context = () => {
    reads++;
    return { px2vp: value => value,
      getComponentUtils: () => ({ getRectangleById: () => ({
        size: { width: 100, height: 80 }, windowOffset: { x: 1, y: 2 } }) }),
      getComponentSnapshot: () => ({ getSync: () => ({ snapshot: true }) }),
      animateTo: (_options, callback) => callback(),
    };
  };
  const { DynamicCardNavigation } = env.load('components/dynamic/DynamicCardNavigation');
  const nav = new DynamicCardNavigation(item, false, false, 'feed-', context);
  return { nav, item, routes, flags, snapshots, reads: () => reads };
}

test('reduced motion preserves navigation data without reading or snapshotting source geometry', () => {
  const f = fixture(true); f.nav.openVideo(f.item); f.nav.openDetail(true); f.nav.openItemImage(f.item, 10);
  assert.deepEqual(f.routes.map(call => [call[0], call[2]]), [['video', false], ['dynamic', false], ['images', false]]);
  assert.equal(f.routes[0][1].bvid, f.item.bvid); assert.equal(f.routes[0][1].cover, 'cover.jpg@480');
  assert.equal(f.routes[1][1].item, f.item); assert.equal(f.routes[1][1].focusComments, true);
  assert.deepEqual(f.routes[2][1], { images: f.item.images, initialIndex: 10 });
  assert.equal(f.reads(), 0); assert.deepEqual(f.flags, []); assert.deepEqual(f.snapshots, []);
});

test('normal video navigation captures card rectangle and enables hero transition', () => {
  const f = fixture(false); f.nav.openVideo(f.item);
  assert.deepEqual(f.routes[0][1].cardRect, { x: 1, y: 2, w: 100, h: 80 });
  assert.deepEqual(f.snapshots, [{ snapshot: true }]);
  assert.ok(f.flags.some(([key, value]) => key === 'active' && value === true));
});

test('overflow images return to ninth cell and rebind uses the new host prefix', () => {
  const f = fixture(false); f.nav.bind(f.item, false, true, 'other-'); f.nav.openItemImage(f.item, 10);
  const viewer = f.routes[0][1];
  assert.equal(viewer.srcIds[10], viewer.srcIds[8]); assert.equal(viewer.transitionIds[10], viewer.transitionIds[8]);
  assert.equal(viewer.srcRects[10], viewer.srcRects[8]); assert.match(viewer.srcIds[0], /^other-/);
  assert.equal(f.routes[0][2], false); assert.deepEqual(f.flags, []);
});

test('major content dispatch keeps live and episode precedence over generic video', () => {
  const f = fixture(true);
  f.nav.openMajor({ ...f.item, liveRoomId: 10, liveUid: 20 });
  f.nav.openMajor({ ...f.item, seasonId: 30, epId: 40 });
  f.nav.openMajor(f.item);
  assert.deepEqual(f.routes.map(route => route[0]), ['live', 'bangumi', 'video']);
  assert.equal(f.routes[0][1].roomId, 10); assert.equal(f.routes[1][1].epId, 40);
});
