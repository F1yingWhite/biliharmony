const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const candidates = [process.env.CXX, 'clang++', 'c++'].filter(Boolean);
const compiler = process.platform === 'win32' ? undefined : candidates.find(command => {
  const result = spawnSync(command, ['--version'], {encoding: 'utf8', timeout: 10000});
  return !result.error && result.status === 0;
});
const skip = process.platform === 'win32' ? 'Native host fixture requires a POSIX C++ toolchain; OHOS production uses the NDK.'
  : !compiler ? 'No clang++/c++ compiler is available for the native host fixture.' : false;
let temporary;
let executable;

test.before(() => {
  if (skip) return;
  temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'biliharmony-mpv-native-'));
  const include = path.join(temporary, 'include', 'napi');
  fs.mkdirSync(include, {recursive: true});
  fs.copyFileSync(path.join(__dirname, 'player-mpv-native-napi-fixture.h'), path.join(include, 'native_api.h'));
  // Compile both complete current production translation units. Only external
  // N-API and mpv boundaries are replaced; no production function is duplicated
  // in the fixture and no source-string assertion stands in for execution.
  for (const filename of ['bilimpv.cpp', 'mpv_session.cpp', 'mpv_session.h']) {
    fs.copyFileSync(path.join(root, 'entry/src/main/cpp', filename), path.join(temporary, filename));
  }
  fs.copyFileSync(path.join(__dirname, 'player-mpv-native-fixture.cpp'), path.join(temporary, 'fixture.cpp'));
  executable = path.join(temporary, 'fixture');
  const result = spawnSync(compiler, ['-std=c++17', '-O1', '-pthread', '-I', path.join(temporary, 'include'),
    '-I', path.join(root, 'entry/src/main/cpp/third_party/mpv/include'), path.join(temporary, 'fixture.cpp'), '-o', executable],
  {encoding: 'utf8', timeout: 120000, maxBuffer: 2 * 1024 * 1024});
  assert.equal(result.status, 0, `Native fixture failed to compile: ${result.error?.message ?? ''}\n${result.stderr}`);
});

test.after(() => {
  if (temporary) fs.rmSync(temporary, {recursive: true, force: true});
});

const cases = [
  ['seek ownership requires command acceptance and actual native SEEK before restart', 'seek-order'],
  ['native seek zero and subsequent seeks retain the exact caller request', 'zero-serial-seek'],
  ['a failed native seek command cannot label a later restart as success', 'seek-command-error'],
  ['pause then play preserves separate acknowledgements despite coalesced properties', 'pause-play-acks'],
  ['concurrent native release joins the event thread and waits for one actual destruction', 'native-release-barrier'],
  ['async-work scheduling failure resolves release only after TSFN delivers real destruction', 'async-release-fallback'],
  ['release notification failure rejects and retains ownership instead of reporting completion', 'release-fallback-unavailable'],
  ['native source loading preserves URL punctuation and exact typed headers with verified TLS', 'exact-source-options'],
  ['file-loaded accepts a required selected external audio track', 'selected-external-audio'],
  ['missing external audio emits audio-error without preparing a silent video', 'missing-external-audio'],
  ['unselected external audio cannot be substituted by a selected main audio track', 'unselected-external-audio'],
  ['file-loaded accepts a selected video track with the initialized GPU output', 'selected-video-output'],
  ['failed or incompatible video output cannot prepare an audio-only playback', 'failed-video-output'],
  ['an initialized output cannot substitute for an unselected video track', 'unselected-video-track'],
  ['seek completion reads the actual native landing before delayed position notifications', 'actual-seek-landing'],
];
for (const [title, name] of cases) {
  test(title, {skip}, () => {
    const result = spawnSync(executable, [name], {encoding: 'utf8', timeout: 10000});
    assert.equal(result.status, 0, `${name}: ${result.error?.message ?? ''}\n${result.stdout}\n${result.stderr}`);
  });
}
