const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');
function shots(name = 'old') {
  return { index: [0, 10, 20, 30, 40], images: [name + '-0', name + '-1'], xLen: 2, yLen: 2 };
}

// Execute the complete controller. Mocks own only OS resources, HTTP, and the 180 ms timer boundary.
function fixture(hooks = {}) {
  const calls = { shots: [], bytes: [], sources: [], pixels: [], extractors: [], sprites: [], frames: [] };
  const timers = new Map(); let timerId = 0;
  const makePixel = name => {
    const pixel = { name, releases: 0, crops: [],
      getImageInfo: async () => hooks.info ? hooks.info(pixel) : { size: { width: 640, height: 360 } },
      crop: async rect => { pixel.crops.push(rect); if (hooks.crop) await hooks.crop(pixel, rect); },
      release: async () => { pixel.releases++; }
    };
    calls.pixels.push(pixel); return pixel;
  };
  const makeExtractor = name => {
    const extractor = { name, releases: 0, urls: [], fetches: [],
      setUrlSource(url, headers) { extractor.urls.push([url, headers]); if (hooks.setSource) hooks.setSource(extractor); },
      fetchFrameByTimeWithTimeout: async (...args) => {
        extractor.fetches.push(args);
        return hooks.fetch ? hooks.fetch(extractor, ...args) : makePixel('frame-' + name);
      },
      release: async () => { extractor.releases++; if (hooks.releaseExtractor) await hooks.releaseExtractor(extractor); }
    };
    calls.extractors.push(extractor); return extractor;
  };
  const dependencies = {
    '@kit.ImageKit': { image: { createImageSource: () => {
      const source = { releases: 0,
        createPixelMap: async () => hooks.pixel ? hooks.pixel(makePixel) : makePixel('sprite'),
        release: async () => { source.releases++; if (hooks.releaseSource) await hooks.releaseSource(); }
      };
      calls.sources.push(source); return source;
    } } },
    '@kit.MediaKit': { media: {
      AVImageQueryOptions: { AV_IMAGE_QUERY_CLOSEST_SYNC: 0 },
      createAVMetadataExtractor: async () => {
        const extractor = makeExtractor('extractor-' + calls.extractors.length);
        return hooks.extractor ? hooks.extractor(extractor) : extractor;
      }
    } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
    'BuildProfile': { DEBUG: false },
    'api/BiliApi': { BiliApi: { getVideoShots: async (...args) => {
      calls.shots.push(args); return hooks.shots ? hooks.shots(...args) : shots(String(args[2]));
    } } },
    'services/network/HttpClient': { HttpClient: { getBytes: async url => {
      calls.bytes.push(url); return hooks.bytes ? hooks.bytes(url) : new ArrayBuffer(1);
    } } }
  };
  const load = createArktsLoader({ mocks: dependencies, globals: {
    setTimeout: (callback, delay) => {
      assert.equal(delay, 180); timers.set(++timerId, callback); return timerId;
    },
    clearTimeout: id => timers.delete(id)
  } });
  const controller = new (load('components/player/PlayerSeekPreviewController').PlayerSeekPreviewController)();
  const request = (seconds, id = 10, url = 'video-' + id, headers = { Referer: 'source-' + id }) => controller.request(
    seconds, id, 'BV' + id, id, url, headers,
    (...args) => calls.sprites.push(args), frame => calls.frames.push(frame));
  const fire = async () => {
    const pending = [...timers.values()]; timers.clear(); pending.forEach(callback => callback()); await tick();
  };
  return { controller, request, fire, calls, timers, makePixel };
}

test('capture crops the requested sprite cell, releases ImageSource and transfers only PixelMap ownership', async () => {
  const f = fixture(); f.controller.preload(10, 'BV10', 10); await tick();
  const frame = await f.controller.captureAt(29);
  assert.equal(frame, f.calls.pixels[0]);
  assert.deepEqual(frame.crops, [{ x: 0, y: 180, size: { width: 320, height: 180 } }]);
  assert.deepEqual(f.calls.bytes, ['10-0']);
  assert.equal(f.calls.sources[0].releases, 1); assert.equal(frame.releases, 0);
  await frame.release(); assert.equal(frame.releases, 1);
});

test('late capture shot metadata cannot replace a different video preload cache', async () => {
  const old = deferred();
  const f = fixture({ shots: async (_aid, _bvid, cid) => cid === 10 ? old.promise : shots('new') });
  f.controller.preload(10, 'BV10', 10);
  const capture = f.controller.captureAt(20);
  f.controller.preload(20, 'BV20', 20); await tick();
  old.resolve(shots('old')); assert.equal(await capture, null);
  const latest = await f.controller.captureAt(20);
  assert.deepEqual(f.calls.bytes, ['new-0']);
  assert.ok(latest); await latest.release();
});

for (const boundary of ['bytes', 'pixel', 'info', 'crop', 'releaseSource']) {
  test(`capture invalidation during ${boundary} releases all resources without returning an obsolete frame`, async () => {
    const pending = deferred(); let created;
    const hooks = {};
    if (boundary === 'bytes') hooks.bytes = () => pending.promise;
    if (boundary === 'pixel') hooks.pixel = makePixel => { created = makePixel('pending'); return pending.promise; };
    if (boundary === 'info') hooks.info = () => pending.promise;
    if (boundary === 'crop') hooks.crop = () => pending.promise;
    if (boundary === 'releaseSource') hooks.releaseSource = () => pending.promise;
    const f = fixture(hooks); f.controller.preload(10, 'BV10', 10); await tick();
    const capture = f.controller.captureAt(20); await tick();
    f.controller.preload(20, 'BV20', 20);
    pending.resolve(boundary === 'pixel' ? created : boundary === 'info' ? { size: { width: 640, height: 360 } } : new ArrayBuffer(1));
    assert.equal(await capture, null);
    assert.ok(f.calls.sources.every(source => source.releases === 1));
    assert.ok(f.calls.pixels.every(pixel => pixel.releases === 1));
    if (boundary === 'bytes') assert.equal(f.calls.sources.length, 0);
  });
}

for (const boundary of ['pixel', 'info', 'crop', 'smallImage']) {
  test(`capture ${boundary} failure closes ImageSource and any allocated PixelMap`, async () => {
    const hooks = {};
    if (boundary === 'pixel') hooks.pixel = async () => { throw Error('decode failed'); };
    if (boundary === 'info') hooks.info = async () => { throw Error('info failed'); };
    if (boundary === 'crop') hooks.crop = async () => { throw Error('crop failed'); };
    if (boundary === 'smallImage') hooks.info = async () => ({ size: { width: 1, height: 1 } });
    const f = fixture(hooks); f.controller.preload(10, 'BV10', 10); await tick();
    assert.equal(await f.controller.captureAt(20), null);
    assert.equal(f.calls.sources[0].releases, 1);
    assert.ok(f.calls.pixels.every(pixel => pixel.releases === 1));
  });
}

test('invalid sprite grid is rejected before allocating image resources', async () => {
  const f = fixture({ shots: async () => ({ ...shots(), xLen: 0 }) });
  f.controller.preload(10, 'BV10', 10); await tick();
  assert.equal(await f.controller.captureAt(20), null); assert.deepEqual(f.calls.bytes, []);
});

test('preload and request adopt new video identities before checking old cached/loading metadata', async () => {
  const f = fixture(); f.controller.preload(10, 'BV10', 10); await tick();
  f.request(20, 20); await tick();
  assert.deepEqual(f.calls.shots.map(args => args[2]), [10, 20]);
  assert.equal(f.calls.sprites.at(-1)[0], '20-0');
  f.controller.preload(30, 'BV30', 30); await tick();
  const frame = await f.controller.captureAt(40);
  assert.equal(f.calls.bytes.at(-1), '30-1'); await frame.release();
});

test('preview keeps 180 ms coalescing and uses the most recent target before starting extraction', async () => {
  const f = fixture({ shots: async () => null });
  f.request(1); f.request(2); f.request(3);
  assert.equal(f.timers.size, 1); assert.equal(f.calls.extractors.length, 0);
  await f.fire();
  assert.equal(f.calls.extractors.length, 1);
  assert.equal(f.calls.extractors[0].fetches[0][0], 3000000);
  f.controller.close(); assert.equal(f.timers.size, 0);
  f.controller.release(); await tick();
  assert.equal(f.calls.pixels[0].releases, 1); assert.equal(f.calls.extractors[0].releases, 1);
});

test('old in-flight extraction does not block a new source or unlock its active extraction', async () => {
  const old = deferred(), latest = deferred();
  const f = fixture({ shots: async () => null,
    fetch: extractor => extractor.name === 'extractor-0' ? old.promise : latest.promise });
  f.request(1, 10); await f.fire();
  f.request(2, 20); await f.fire();
  assert.equal(f.calls.extractors.length, 2);
  const oldFrame = f.makePixel('old'); old.resolve(oldFrame); await tick();
  f.request(3, 20); assert.equal(f.timers.size, 0, 'old finally must not clear new extraction lock');
  const superseded = f.makePixel('superseded'); latest.resolve(superseded); await tick();
  assert.equal(oldFrame.releases, 1); assert.equal(superseded.releases, 1);
  assert.equal(f.timers.size, 1, 'latest target is retried through the same throttle');
  assert.ok(f.calls.frames.every(frame => frame === null));
});

test('extractor created after a source switch is released without configuring it from the new source', async () => {
  const pending = deferred(); let first;
  const f = fixture({ shots: async () => null, extractor: extractor => {
    if (!first) { first = extractor; return pending.promise; }
    return extractor;
  } });
  f.request(1, 10); await f.fire();
  f.request(2, 20); await f.fire();
  pending.resolve(first); await tick();
  assert.equal(first.releases, 1); assert.deepEqual(first.urls, []);
  assert.equal(f.calls.extractors[1].urls[0][0], 'video-20');
});

test('extractor setup captures source headers before awaits and releases a failed setup', async () => {
  const pending = deferred(); let created;
  const f = fixture({ shots: async () => null, extractor: extractor => { created = extractor; return pending.promise; } });
  const headers = { Referer: 'original' };
  f.request(1, 10, 'url', headers); await f.fire(); headers.Referer = 'mutated';
  pending.resolve(created); await tick();
  assert.equal(created.urls[0][1].Referer, 'original');
  const failure = fixture({ shots: async () => null, setSource: () => { throw Error('bad URL'); } });
  failure.request(1); await failure.fire();
  assert.equal(failure.calls.extractors[0].releases, 1);
  assert.equal(failure.calls.extractors[0].fetches.length, 0);
});

test('same-video source replacement retains loaded sprites while clearing old frame ownership', async () => {
  const f = fixture(); f.request(1, 10, 'cdn-a'); await tick();
  const metadataCalls = f.calls.shots.length;
  f.request(30, 10, 'cdn-b');
  assert.equal(f.calls.shots.length, metadataCalls);
  assert.equal(f.calls.sprites.at(-1)[0], '10-0');
  assert.equal(f.calls.sprites.at(-1)[1], 3);
});

test('release clears capture identity and close discards an in-flight frame', async () => {
  const pending = deferred();
  const f = fixture({ shots: async () => null, fetch: () => pending.promise });
  f.request(1); await f.fire(); f.controller.close();
  const frame = f.makePixel('late'); pending.resolve(frame); await tick();
  assert.equal(frame.releases, 1); assert.ok(f.calls.frames.every(value => value === null));
  f.controller.release();
  assert.equal(await f.controller.captureAt(1), null);
});
