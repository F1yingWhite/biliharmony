const test = require('node:test');
const assert = require('node:assert/strict');
const {createArktsLoader, deferred, tick} = require('./arkts-module.cjs');

function fixture({orientation = '6', propertyError = false, packingError = false, packing = null} = {}) {
  const events = [], properties = [], rotations = [], closed = [], deleted = [], opened = [], writes = [];
  const orientationKey = Symbol('PropertyKey.ORIENTATION');
  const pixel = {
    rotate: async degrees => {events.push('rotate'); rotations.push(degrees);},
    getImageInfo: async () => ({size: {width: rotations.at(-1) % 180 ? 1024 : 2048,
      height: rotations.at(-1) % 180 ? 2048 : 1024}}),
    release: async () => events.push('release pixel'),
  };
  const source = {
    getImageInfo: async () => {events.push('info'); return {size: {width: 4096, height: 2048}};},
    createPixelMap: async options => {events.push('decode'); assert.deepEqual(options, {desiredSize: {width: 2048, height: 1024}}); return pixel;},
    getImageProperty: async (key, options) => {
      events.push('property'); properties.push({key, options});
      if (propertyError) throw Error('no EXIF'); return orientation;
    },
    release: async () => events.push('release source'),
  };
  const fs = {
    OpenMode: {READ_ONLY: 1, READ_WRITE: 2, CREATE: 4, TRUNC: 8},
    openSync: (path, mode) => {const file = {fd: 10 + opened.length}; opened.push({path, mode, file}); return file;},
    closeSync: file => {closed.push(file.fd); events.push('close ' + file.fd);},
    readSync: (_fd, buffer) => {new Uint8Array(buffer).set([255, 216, 255]); return 3;},
    mkdir: async () => {}, unlinkSync: path => deleted.push(path),
    writeSync: (fd, bytes) => {writes.push({fd, bytes}); return bytes.byteLength;},
  };
  const load = createArktsLoader({mocks: {
    '@kit.CoreFileKit': {fileIo: fs},
    '@kit.ImageKit': {image: {PropertyKey: {ORIENTATION: orientationKey},
      createImageSource: fd => {events.push('source ' + fd); return source;},
      createImagePacker: () => ({
        packToData: async (_pixel, options) => {events.push('pack'); assert.deepEqual(options, {format: 'image/jpeg', quality: 85});
          if (packingError) throw Error('encode'); return packing ? packing.promise : new ArrayBuffer(12);},
        release: async () => events.push('release packer'),
      }),
    }},
  }});
  const {DynImagePreparer} = load('common/DynImagePreparer');
  return {preparer: DynImagePreparer, events, properties, rotations, closed, deleted, opened, writes, orientationKey};
}

for (const [orientation, rotation] of [['3', 180], ['6', 90], ['8', 270], ['1', null], ['unknown', null]]) {
  test('image preparer: PropertyKey orientation ' + orientation + ' is applied before packing and all native resources release', async () => {
    const f = fixture({orientation}); const draft = await f.preparer.prepare({cacheDir: '/cache'}, 'photo://selected');
    assert.ok(draft); assert.equal(draft.mimeType, 'image/jpeg'); assert.equal(draft.byteSize, 12);
    assert.deepEqual(f.properties, [{key: f.orientationKey, options: {index: 0, defaultValue: '1'}}]);
    assert.deepEqual(f.rotations, rotation === null ? [] : [rotation]);
    assert.ok(f.events.indexOf('property') < f.events.indexOf('pack'));
    if (rotation !== null) assert.ok(f.events.indexOf('rotate') < f.events.indexOf('pack'));
    assert.deepEqual(f.events.filter(event => event.startsWith('release')), ['release pixel', 'release packer', 'release source']);
    assert.deepEqual(f.closed, [11, 10]); assert.deepEqual(f.deleted, []);
    assert.deepEqual([draft.width, draft.height], rotation !== null && rotation % 180 ? [1024, 2048] : [2048, 1024]);
  });
}

test('image preparer: missing EXIF retains original orientation and still produces a valid draft', async () => {
  const f = fixture({propertyError: true}); const draft = await f.preparer.prepare({cacheDir: '/cache'}, 'photo://selected');
  assert.ok(draft); assert.deepEqual(f.rotations, []); assert.deepEqual(f.closed, [11, 10]);
});

test('image preparer: source file descriptor stays open until orientation/encoding and releases complete', async () => {
  const packing = deferred(), f = fixture({packing});
  const preparing = f.preparer.prepare({cacheDir: '/cache'}, 'photo://selected'); await tick();
  assert.deepEqual(f.closed, []); assert.equal(f.events.at(-1), 'pack');
  packing.resolve(new ArrayBuffer(12)); assert.ok(await preparing);
  assert.ok(f.events.indexOf('release source') < f.events.indexOf('close 10')); assert.deepEqual(f.closed, [11, 10]);
});

test('image preparer: failed encoding removes incomplete output and releases source, pixel map, packer and file', async () => {
  const f = fixture({packingError: true});
  assert.equal(await f.preparer.prepare({cacheDir: '/cache'}, 'photo://selected'), null);
  assert.equal(f.deleted.length, 1); assert.ok(f.deleted[0].startsWith('/cache/dyn_publish/'));
  assert.deepEqual(f.events.filter(event => event.startsWith('release')), ['release pixel', 'release packer', 'release source']);
  assert.deepEqual(f.closed, [10]); assert.deepEqual(f.writes, []);
});
