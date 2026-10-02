const test = require('node:test');
const assert = require('node:assert/strict');
const { createArktsLoader, deferred, tick } = require('./arkts-module.cjs');

// Real saver and optional player controller; only native media/file APIs and unrelated IO are fake.
function fixture(hooks = {}) {
  const files = new Map(), handles = new Map();
  const calls = { opens: [], writes: [], closes: [], unlinks: [], dialogs: [], toasts: [], released: [] };
  let nextFd = 0;
  const io = {
    OpenMode: { READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
    async open(path) {
      const fd = ++nextFd;
      calls.opens.push(path); handles.set(fd, path); files.set(path, []);
      return { fd };
    },
    async write(fd, bytes) {
      const path = handles.get(fd);
      calls.writes.push(path);
      if (hooks.write) await hooks.write(path, bytes);
      files.set(path, Array.from(new Uint8Array(bytes)));
      return bytes.byteLength;
    },
    closeSync(file) { calls.closes.push(file.fd); handles.delete(file.fd); },
    async unlink(path) {
      calls.unlinks.push(path);
      if (hooks.unlink) await hooks.unlink(path);
      files.delete(path);
    }
  };
  const packer = {
    packToData: async () => new Uint8Array([7, 8]).buffer,
    release: async () => calls.released.push('packer')
  };
  const load = createArktsLoader({
    globals: { Date: class extends Date { static now() { return 1234; } } },
    mocks: {
      '@kit.CoreFileKit': { fileIo: io, fileUri: { getUriFromPath: path => path }, picker: {} },
      '@kit.MediaLibraryKit': { photoAccessHelper: {
        PhotoType: { IMAGE: 1 },
        getPhotoAccessHelper: () => ({
          async showSingleAssetCreationDialogEx(path, options, confirmed) {
            const selected = deferred();
            calls.dialogs.push({ path, options, confirmed, selected });
            return selected.promise;
          }
        })
      } },
      '@kit.ImageKit': { image: { createImagePacker: () => packer } },
      '@kit.ArkTS': { collections: { Array }, util: {}, taskpool: {} },
      '@kit.PerformanceAnalysisKit': { hilog: { debug() {}, info() {}, warn() {}, error() {} } },
      '@kit.CryptoArchitectureKit': { cryptoFramework: {} },
      'api/BiliApi': { BiliApi: {} },
      'services/network/HttpClient': { HttpClient: {} },
      'services/media/DownloadCenter': { DownloadCenter: {}, DOWNLOAD_KIND_AUDIO: 1, DOWNLOAD_KIND_VIDEO: 0 },
      'services/media/VideoDownloadService': { VideoDownloadService: { isActive: () => false, currentProgress: () => -1 } }
    }
  });
  const context = { cacheDir: '/cache' };
  const Saver = load('services/media/PhotoLibrarySaver').PhotoLibrarySaver;
  const save = (bytes = [1], current) => Saver.saveImage(context, new Uint8Array(bytes).buffer,
    'jpeg', 'BiliHarmony_17s', current);
  return { load, save, calls, files, handles, context };
}

test('same-time same-title saves own separate preview files and preserve native display options', async () => {
  const f = fixture();
  const first = f.save([1]); await tick();
  const second = f.save([2]); await tick();
  const [a, b] = f.calls.dialogs;
  assert.notEqual(a.path, b.path);
  assert.deepEqual(f.files.get(a.path), [1]);
  assert.deepEqual(f.files.get(b.path), [2]);
  assert.deepEqual(a.options, { title: 'BiliHarmony_17s', fileNameExtension: 'jpeg', photoType: 1 });
  assert.equal(a.confirmed, true);
  a.selected.resolve(''); assert.equal(await first, false);
  assert.equal(f.files.has(a.path), false);
  assert.deepEqual(f.files.get(b.path), [2]);
  b.selected.resolve('content://second'); assert.equal(await second, true);
  assert.deepEqual(f.files.get('content://second'), [2]);
  assert.equal(f.files.has(b.path), false);
  assert.equal(f.handles.size, 0);
});

test('already invalid save creates neither temporary file nor native dialog', async () => {
  const f = fixture();
  assert.equal(await f.save([1], () => false), false);
  assert.deepEqual(f.calls.opens, []);
  assert.deepEqual(f.calls.dialogs, []);
});

test('invalidation during temporary write cleans up without opening late native UI', async () => {
  const written = deferred(), f = fixture({ write: () => written.promise });
  let current = true;
  const work = f.save([1], () => current); await tick();
  current = false; written.resolve();
  assert.equal(await work, false);
  assert.equal(f.calls.dialogs.length, 0);
  assert.equal(f.files.size, 0);
  assert.equal(f.handles.size, 0);
  assert.equal(f.calls.unlinks.length, 1);
});

test('invalidation while native dialog is pending never opens its late destination', async () => {
  const f = fixture();
  let current = true;
  const work = f.save([1], () => current); await tick();
  current = false; f.calls.dialogs[0].selected.resolve('content://stale');
  assert.equal(await work, false);
  assert.equal(f.calls.opens.includes('content://stale'), false);
  assert.equal(f.files.size, 0);
});

test('temporary write failure closes its handle and removes the partial file', async () => {
  const f = fixture({ write: async () => { throw Error('disk full'); } });
  await assert.rejects(f.save(), /disk full/);
  assert.equal(f.calls.dialogs.length, 0);
  assert.equal(f.calls.closes.length, 1);
  assert.equal(f.calls.unlinks.length, 1);
  assert.equal(f.files.size, 0);
});

test('destination write failure propagates while closing both handles and removing only the preview', async () => {
  const f = fixture({ write: async path => { if (path.startsWith('content:')) throw Error('album full'); } });
  const work = f.save(); await tick();
  f.calls.dialogs[0].selected.resolve('content://failed');
  await assert.rejects(work, /album full/);
  assert.equal(f.calls.closes.length, 2);
  assert.deepEqual(f.calls.unlinks, [f.calls.dialogs[0].path]);
  assert.equal(f.handles.size, 0);
});

test('native dialog failure cleans its temporary source and retains the original error', async () => {
  const f = fixture({ unlink: async () => { throw Error('already consumed'); } });
  const work = f.save(); await tick();
  f.calls.dialogs[0].selected.reject(Error('permission denied'));
  await assert.rejects(work, /permission denied/);
  assert.equal(f.calls.unlinks.length, 1);
  assert.equal(f.handles.size, 0);
});

test('real screenshot controller passes cancellation through the real saver and releases image resources', async () => {
  const written = deferred(), f = fixture({ write: () => written.promise });
  const Controller = f.load('components/player/PlayerMediaExportController').PlayerMediaExportController;
  const state = { destroyed: false };
  const controller = new Controller({
    getContext: () => f.context, isDestroyed: () => state.destroyed,
    snapshot: () => ({ aid: 1, bvid: 'BV1', cid: 10, epId: 0, title: 'Video', partTitle: '', cover: '',
      duration: 100, playhead: 17.8, quality: 80, qualityOptions: [], subtitle: null }),
    closePanels() {}, toast: message => f.calls.toasts.push(message), publishDownload() {}
  }, async () => ({ release: async () => f.calls.released.push('frame') }));
  const work = controller.captureScreenshot(); await tick();
  assert.equal(f.calls.writes.length, 1);
  controller.invalidate(); state.destroyed = true; written.resolve(); await work;
  assert.deepEqual(f.calls.dialogs, []);
  assert.deepEqual(f.calls.toasts, []);
  assert.deepEqual(f.calls.released, ['packer', 'frame']);
  assert.equal(f.files.size, 0);
});
