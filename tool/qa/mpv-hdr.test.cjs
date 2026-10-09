const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const sdk = process.env.MPV_HDR_TEST_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const sdkBin = process.env.MPV_TEST_LLVM_BIN || path.join(sdk, 'llvm/bin');
const placeboInclude = process.env.MPV_HDR_TEST_PLACEBO_INCLUDE || path.join(root, '.qa/mpv-speed-core/vm-deps/install/include');
const python = process.env.MPV_TEST_PYTHON || (process.platform === 'win32'
  ? path.join(os.homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe') : 'python3');
const patch = process.env.MPV_HDR_TEST_PATCH || path.join(root, 'tool/mpv/patches/0003-ohos-hdr-output.patch');
const sdkHeaders = ['native_buffer/buffer_common.h', 'window_manager/oh_display_info.h',
  'EGL/egl.h', 'EGL/eglext.h', 'EGL/eglplatform.h', 'KHR/khrplatform.h'];
const placeboHeaders = ['libplacebo/colorspace.h', 'libplacebo/common.h', 'libplacebo/config.h'];
const missing = [];
function checkHeaders(label, include, files, override) {
  const absent = files.filter(file => !fs.existsSync(path.join(include, file)));
  if (absent.length) missing.push({reason: `${label} headers missing under ${include}: ${absent.join(', ')}`,
    explicit: Boolean(process.env[override])});
}
function checkCommand(label, command, explicit = false) {
  const result = spawnSync(command, ['--version'], {encoding: 'utf8', timeout: 3000});
  if (result.error || result.status !== 0)
    missing.push({reason: `${label} unavailable (${command}): ${result.error?.code || `exit ${result.status}`}`, explicit});
}
checkHeaders('OHOS SDK', path.join(sdk, 'sysroot/usr/include'),
  [...sdkHeaders, 'native_window/external_window.h'], 'MPV_HDR_TEST_SDK');
checkHeaders('libplacebo', placeboInclude, placeboHeaders, 'MPV_HDR_TEST_PLACEBO_INCLUDE');
checkCommand('Git', 'git');
checkCommand('Python', python, Boolean(process.env.MPV_TEST_PYTHON));
if (process.platform === 'win32') {
  const explicit = Boolean(process.env.MPV_TEST_LLVM_BIN || process.env.MPV_HDR_TEST_SDK);
  checkCommand('Clang', path.join(sdkBin, 'clang.exe'), explicit);
  checkCommand('LLD', path.join(sdkBin, 'lld-link.exe'), explicit);
} else {
  checkCommand('C compiler', process.env.CC || 'cc', Boolean(process.env.CC));
}
if (!fs.existsSync(patch)) missing.push({reason: `HDR patch missing: ${patch}`, explicit: true});
const prerequisiteMessage = `HDR native fixture prerequisites unavailable: ${missing.map(item => item.reason).join('; ')}`;
const skipReason = missing.length && process.env.MPV_HDR_TEST_REQUIRED !== '1' && !missing.some(item => item.explicit)
  ? `${prerequisiteMessage}. Configure the dependency paths; MPV_HDR_TEST_REQUIRED=1 requires execution.` : false;
const cases = ['case_hdr_capability_and_depth', 'case_hdr_pq_hlg_selection',
  'case_hdr_static_metadata_and_generation', 'case_hdr_to_sdr_and_uninit',
  'case_hdr_failure_rollback', 'case_hdr_unrecoverable_output', 'case_hdr_verify_driver_override',
  'case_hdr_context_eight_bit_fallback', 'case_hdr_context_tags_before_buffer',
  'case_hdr_context_transition_recovers_sdr', 'case_hdr_context_terminal_failure_stop_once',
  'case_hdr_context_driver_override_recovers_sdr', 'case_hdr_context_swap_failure'];
const baseHashes = {
  'ohos_common.c': 'cfda05798da709524f947bb77d6437945bcaa1721556c649e94c6abd3267afd8',
  'ohos_common.h': '1fa7b1efb7aa70fe250dc511f311a02f044dd51457839e800f2ba5a5bb1eddb8',
  'opengl/context_ohos.c': '2757ffdaec1a8ee4126717f0f714ee584b0320d6fc757dba92f3ef2aef87b335',
};
let temporary, library;
function run(command, args, options = {}) {
  const result = spawnSync(command, args, {encoding: 'utf8', timeout: 30000, ...options});
  assert.equal(result.status, 0, `${command}: ${result.error?.message || ''}\n${result.stdout || ''}\n${result.stderr || ''}`);
  return result;
}
function copyHeader(source, target) {
  assert.ok(fs.existsSync(source), `Required real dependency header is missing: ${source}`);
  fs.mkdirSync(path.dirname(target), {recursive: true});
  fs.copyFileSync(source, target);
}
// A skipped environment never creates a build directory or starts compilation.
if (!missing.length) test.before(() => {
  temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'mpv-hdr-'));
  const sourceDir = path.join(temporary, 'video/out');
  const stubs = path.join(temporary, 'stubs');
  fs.mkdirSync(sourceDir, {recursive: true});
  for (const [file, hash] of Object.entries(baseHashes)) {
    // Canonicalize checkout EOL only; the pinned upstream source stays unchanged.
    const data = fs.readFileSync(path.join(__dirname, 'mpv-hdr-upstream/video/out', file), 'utf8').replace(/\r\n/g, '\n');
    assert.equal(crypto.createHash('sha256').update(data).digest('hex'), hash, `Unexpected upstream fixture base: ${file}`);
    fs.mkdirSync(path.dirname(path.join(sourceDir, file)), {recursive: true});
    fs.writeFileSync(path.join(sourceDir, file), data);
  }
  run('git', ['apply', '--include=video/out/ohos_common.c', '--include=video/out/ohos_common.h',
    '--include=video/out/opengl/context_ohos.c', patch], {cwd: temporary});
  fs.cpSync(path.join(__dirname, 'mpv-hdr-stubs'), stubs, {recursive: true});
  // Real SDK declarations prevent a permissive mock from inventing enum or ABI values.
  for (const relative of sdkHeaders)
    copyHeader(path.join(sdk, 'sysroot/usr/include', relative), path.join(stubs, relative));
  for (const relative of placeboHeaders)
    copyHeader(path.join(placeboInclude, relative), path.join(stubs, relative));
  const windowHeader = fs.readFileSync(path.join(sdk, 'sysroot/usr/include/native_window/external_window.h'), 'utf8');
  const operation = windowHeader.match(/typedef enum NativeWindowOperation\s*\{[\s\S]*?\}\s*NativeWindowOperation\s*;/);
  assert.ok(operation, 'SDK NativeWindow operation declaration was not found');
  fs.writeFileSync(path.join(stubs, 'native_window/fixture-native-window-operation.h'), operation[0]);
  const source = path.join(sourceDir, 'ohos_common.c');
  const context = path.join(sourceDir, 'opengl/context_ohos.c');
  const fixture = path.join(__dirname, 'mpv-hdr-fixture.c');
  const shared = ['-std=c11', '-O2', '-DPL_STATIC', '-DEGLAPI=', '-DEGL_NO_PLATFORM_SPECIFIC_TYPES',
    '-ffreestanding', '-fno-builtin', '-fno-stack-protector', '-I', stubs, '-I', sourceDir, '-I', temporary];
  if (process.platform === 'win32') {
    const objects = [path.join(temporary, 'color.obj'), path.join(temporary, 'fixture.obj'), path.join(temporary, 'context.obj')];
    for (const [i, file] of [source, fixture, context].entries())
      run(path.join(sdkBin, 'clang.exe'), ['-target', 'x86_64-pc-windows-msvc', '-mno-stack-arg-probe', ...shared,
        '-c', file, '-o', objects[i]]);
    library = path.join(temporary, 'hdr.dll');
    run(path.join(sdkBin, 'lld-link.exe'), ['/dll', '/noentry', '/nodefaultlib', '/machine:x64', `/out:${library}`,
      ...cases.map(name => `/export:${name}`), ...objects]);
  } else {
    library = path.join(temporary, 'hdr.so');
    run(process.env.CC || 'cc', [...shared, '-fPIC', '-shared', source, fixture, context, '-o', library]);
  }
});
test.after(() => {if (temporary) fs.rmSync(temporary, {recursive: true, force: true});});
for (const name of cases) test(`mpv HDR output: ${name}`, {skip: skipReason}, () => {
  assert.equal(missing.length, 0, prerequisiteMessage);
  const result = run(python, ['-c', 'import ctypes,sys; f=getattr(ctypes.CDLL(sys.argv[1]),sys.argv[2]); f.restype=ctypes.c_int; code=f(); print(code); sys.exit(int(code!=0))', library, name]);
  assert.equal(result.stdout.trim(), '0');
});
