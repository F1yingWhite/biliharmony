const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const sdkBin = process.env.MPV_TEST_LLVM_BIN || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin';
const python = process.env.MPV_TEST_PYTHON || (process.platform === 'win32'
  ? path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe') : 'python3');
const cases = ['case_speed_segments', 'case_silent_tail', 'case_pause_and_epoch', 'case_unknown_pts', 'case_boundaries_and_capacity', 'case_monotonic_clock_conversion'];
let temporary, library;
function run(command, args, options = {}) {
  const result = spawnSync(command, args, {encoding: 'utf8', timeout: 30000, ...options});
  assert.equal(result.status, 0, `${command}: ${result.error?.message || ''}\n${result.stdout || ''}\n${result.stderr || ''}`);
  return result;
}
test.before(() => {
  temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'mpv-pcm-timeline-'));
  // Test the exact production module delivered by the reusable core patch.
  run('git', ['apply', '--include=audio/out/pcm_timeline.c', '--include=audio/out/pcm_timeline.h',
    path.join(root, 'tool/mpv/patches/0001-ohaudio-pcm-timeline.patch')], {cwd: temporary});
  const include = path.join(temporary, 'audio/out');
  const source = path.join(include, 'pcm_timeline.c');
  const fixture = path.join(__dirname, 'mpv-pcm-timeline-fixture.c');
  if (process.platform === 'win32') {
    const objects = [path.join(temporary, 'timeline.obj'), path.join(temporary, 'fixture.obj')];
    for (const [i, file] of [source, fixture].entries())
      run(path.join(sdkBin, 'clang.exe'), ['-target', 'x86_64-pc-windows-msvc', '-std=c11', '-O2',
        '-ffreestanding', '-fno-builtin', '-fno-stack-protector', '-mno-stack-arg-probe', '-I', include, '-c', file, '-o', objects[i]]);
    library = path.join(temporary, 'timeline.dll');
    run(path.join(sdkBin, 'lld-link.exe'), ['/dll', '/noentry', '/nodefaultlib', '/machine:x64', `/out:${library}`,
      ...cases.map(name => `/export:${name}`), ...objects]);
  } else {
    library = path.join(temporary, 'timeline.so');
    run(process.env.CC || 'cc', ['-std=c11', '-O2', '-fPIC', '-shared', '-I', include, source, fixture, '-o', library]);
  }
});
test.after(() => {if (temporary) fs.rmSync(temporary, {recursive: true, force: true});});
for (const name of cases) test(`mpv PCM timeline: ${name}`, () => {
  const result = run(python, ['-c', 'import ctypes,sys; f=getattr(ctypes.CDLL(sys.argv[1]),sys.argv[2]); f.restype=ctypes.c_int; code=f(); print(code); sys.exit(int(code!=0))', library, name]);
  assert.equal(result.stdout.trim(), '0');
});
