"""Rebuild the pinned ARM64 mpv core using its original OHOS dependency carrier.

Uses existing Python, Git, Meson, and the DevEco OHOS SDK. No SDK/tools are
installed and no production application files are replaced by this command.
"""
from pathlib import Path
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MANIFEST = json.loads((HERE / 'rebuild-inputs.json').read_text(encoding='utf-8'))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(url, destination, expected=None, normalize_lf=False):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.is_file():
        request = urllib.request.Request(url, headers={'User-Agent': 'biliharmony-pinned-core-rebuild'})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        if normalize_lf:
            data = data.replace(b'\r\n', b'\n')
        destination.write_bytes(data)
    if expected and sha256(destination) != expected:
        raise RuntimeError(f'SHA256 mismatch: {destination}')
    return destination


def extract(archive, destination):
    """Only extract ordinary files/directories under the requested source root."""
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as package:
        top_levels = {p.name.split('/')[0] for p in package.getmembers() if p.name}
        if len(top_levels) != 1:
            raise RuntimeError(f'Unexpected archive roots: {archive}')
        package.extractall(destination, filter='data')
    return destination / top_levels.pop()


def apply_patch(component, patch, git, workspace):
    # These component trees are generated copies. Remove only files that this
    # patch adds so preparation can be repeated from the pristine source archive.
    text = patch.read_text(encoding='utf-8')
    for block in text.split('diff --git '):
        if 'new file mode ' not in block:
            continue
        match = re.search(r'^\+\+\+ b/(.+)$', block, re.MULTILINE)
        if match:
            added = (component / match.group(1)).resolve()
            added.relative_to(component.resolve())
            if added.is_file():
                added.unlink()
    component = component.resolve()
    env = dict(os.environ)
    try:
        prefix = component.relative_to(REPO).as_posix()
        cwd = REPO
    except ValueError:
        prefix = component.relative_to(workspace.resolve()).as_posix()
        cwd = workspace
        # Prevent discovery of a surrounding, unrelated repository.
        env['GIT_CEILING_DIRECTORIES'] = str(workspace.resolve().parent)
    # Source archives use LF. Keep generated inputs independent of the user's
    # Windows checkout settings without changing their Git configuration.
    args = [git, '-c', 'core.autocrlf=false', '-c', 'core.eol=lf',
            'apply', '--verbose', '--unsafe-paths', '--directory=' + prefix]
    for extra in (['--check'], []):
        result = subprocess.run([*args, *extra, str(patch)], cwd=cwd, env=env,
                                capture_output=True, text=True)
        output = result.stdout + result.stderr
        if result.returncode or 'Skipped patch' in output or 'Checking patch ' not in output:
            raise RuntimeError('Git did not apply the pinned patch: ' + output)


def make_carrier(original, carrier):
    raw = bytearray(original.read_bytes())
    if raw[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', raw, 18)[0] != 183:
        raise RuntimeError('Expected an AArch64 ELF64 little-endian original core')
    phoff = struct.unpack_from('<Q', raw, 32)[0]
    phsize, phcount = struct.unpack_from('<HH', raw, 54)
    headers = [struct.unpack_from('<IIQQQQQQ', raw, phoff + phsize * i) for i in range(phcount)]
    dynamic = next(p for p in headers if p[0] == 2)
    tags = {}
    for offset in range(dynamic[2], dynamic[2] + dynamic[5], 16):
        tag, value = struct.unpack_from('<QQ', raw, offset)
        if tag == 0:
            break
        tags[tag] = value
    segment = next(p for p in headers if p[0] == 1 and p[3] <= tags[5] < p[3] + p[5])
    soname_offset = segment[2] + tags[5] - segment[3] + tags[14]
    if bytes(raw[soname_offset:soname_offset + 10]) != b'libmpv.so\0':
        raise RuntimeError('Unexpected original DT_SONAME string')
    raw[soname_offset:soname_offset + 9] = b'libdep.so'
    carrier.parent.mkdir(parents=True, exist_ok=True)
    carrier.write_bytes(raw)
    return soname_offset


def generate_headers(deps, stage):
    ass = stage / 'ass'
    ass.mkdir(parents=True, exist_ok=True)
    for name in ('ass.h', 'ass_types.h'):
        shutil.copy2(deps['libass'] / 'libass' / name, ass / name)
    avutil = deps['ffmpeg'] / 'libavutil'
    (avutil / 'avconfig.h').write_text(
        '/* Pinned original AArch64 OHOS carrier public configure features. */\n'
        '#ifndef AVUTIL_AVCONFIG_H\n#define AVUTIL_AVCONFIG_H\n'
        '#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n'
        '#endif\n', encoding='utf-8')
    (avutil / 'ffversion.h').write_text(
        '#ifndef AVUTIL_FFVERSION_H\n#define AVUTIL_FFVERSION_H\n'
        '#define FFMPEG_VERSION "n8.0"\n#endif\n', encoding='utf-8')
    pl = deps['libplacebo'] / 'src/include/libplacebo'
    features = '\n'.join('#define PL_HAVE_' + name + ' 1'
                         for name in ('OPENGL', 'VULKAN', 'SHADERC', 'LCMS', 'DOVI', 'LIBDOVI'))
    template = (pl / 'config.h.in').read_text(encoding='utf-8')
    config = template.replace('@majorver@', '7').replace('@apiver@', '360').replace('@extra_defs@', features)
    if '@' in config:
        raise RuntimeError('Unsubstituted libplacebo public configuration value')
    (pl / 'config.h').write_text(config, encoding='utf-8')


def prepare_meson(source, deps, headers, carrier):
    fmt = lambda path: str(path).replace('\\', '/')
    path = source / 'meson.build'
    content = path.read_text(encoding='utf-8')
    # Meson's auto-regeneration stores an absolute Windows cross-file path.
    # Normalize backslashes before placing that value inside a C literal.
    content = content.replace("conf_data.set_quoted('CONFIGURATION', meson.build_options())",
                              "conf_data.set_quoted('CONFIGURATION', meson.build_options().replace('\\\\', '/'))")
    lines = ["carrier_dep = declare_dependency(link_args: ['" + fmt(carrier) + "'])"]
    versions = {'libavcodec': '62.11.100', 'libavfilter': '11.4.100',
                'libavformat': '62.3.100', 'libavutil': '60.8.100',
                'libswresample': '6.1.100', 'libswscale': '9.1.100'}
    for name, version in versions.items():
        lines.append(f"meson.override_dependency('{name}', declare_dependency(version: '{version}', include_directories: include_directories('{fmt(deps['ffmpeg'])}'), dependencies: carrier_dep))")
    specs = [('libass', '0.17.4', headers),
             ('libplacebo', '7.360.1', deps['libplacebo'] / 'src/include'),
             ('lcms2', '2.17', deps['lcms'] / 'include'),
             ('lua52', '5.2.4', deps['lua'] / 'src')]
    for name, version, include in specs:
        lines.append(f"meson.override_dependency('{name}', declare_dependency(version: '{version}', include_directories: include_directories('{fmt(include)}'), dependencies: carrier_dep))")
    lines += ["qa_cc = meson.get_compiler('c')",
              "meson.override_dependency('zlib', declare_dependency(version: '1.3.1', dependencies: qa_cc.find_library('z')))"]
    marker = "python = find_program('python3')"
    if content.count(marker) != 1:
        raise RuntimeError('Pinned Meson dependency injection location changed')
    path.write_text(content.replace(marker, marker + '\n\n' + '\n'.join(lines)), encoding='utf-8')


def write_crossfile(path, sdk, python):
    fmt = lambda value: str(value).replace('\\', '/')
    sysroot = fmt(sdk / 'sysroot')
    path.write_text(f'''[binaries]
c = ['{fmt(sdk / 'llvm/bin/clang.exe')}', '--target=aarch64-linux-ohos', '--sysroot={sysroot}']
cpp = ['{fmt(sdk / 'llvm/bin/clang++.exe')}', '--target=aarch64-linux-ohos', '--sysroot={sysroot}']
ar = '{fmt(sdk / 'llvm/bin/llvm-ar.exe')}'
strip = '{fmt(sdk / 'llvm/bin/llvm-strip.exe')}'
python3 = '{fmt(python)}'

[host_machine]
system = 'ohos'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-D__MUSL__', '-fPIC']
cpp_args = ['-D__MUSL__', '-fPIC']
c_link_args = ['-Wl,-z,defs', '-Wl,--no-undefined', '-Wl,-rpath,$ORIGIN']
cpp_link_args = ['-Wl,-z,defs', '-Wl,--no-undefined', '-Wl,-rpath,$ORIGIN']
''', encoding='utf-8')


def symbol_table(nm, path, undefined=False):
    output = subprocess.check_output([str(nm), '-D', '--undefined-only' if undefined else '--defined-only', str(path)], text=True)
    return {parts[-1]: parts[-2] for line in output.splitlines() if len(parts := line.split()) >= 2}


def validate(core, original, carrier, sdk):
    nm, readelf = sdk / 'llvm/bin/llvm-nm.exe', sdk / 'llvm/bin/llvm-readelf.exe'
    defs = symbol_table(nm, core)
    orig_defs = symbol_table(nm, original)
    carrier_defs = symbol_table(nm, carrier)
    if orig_defs != carrier_defs:
        raise RuntimeError('Carrier dynamic exports changed')
    public = sorted(s for s in defs if s.startswith('mpv_'))
    if public != sorted(s for s in orig_defs if s.startswith('mpv_')):
        raise RuntimeError('libmpv public client API exports differ')
    dynamic = lambda path: subprocess.check_output([str(readelf), '-d', str(path)], text=True)
    core_dynamic, dep_dynamic = dynamic(core), dynamic(carrier)
    for path in (core, carrier):
        header = subprocess.check_output([str(readelf), '-h', str(path)], text=True)
        if 'AArch64' not in header:
            raise RuntimeError(f'Unexpected target machine: {path}')
    needed = re.findall(r'\(NEEDED\).*?\[(.*?)\]', core_dynamic)
    dep_needed = re.findall(r'\(NEEDED\).*?\[(.*?)\]', dep_dynamic)
    if re.findall(r'\(SONAME\).*?\[(.*?)\]', core_dynamic) != ['libmpv.so']:
        raise RuntimeError('Unexpected core SONAME')
    if re.findall(r'\(SONAME\).*?\[(.*?)\]', dep_dynamic) != ['libdep.so']:
        raise RuntimeError('Unexpected carrier SONAME')
    if 'libdep.so' not in needed or 'libmpv.so' in needed + dep_needed:
        raise RuntimeError('Invalid carrier dependency graph')
    if not all(re.search(r'\(FLAGS\).*?SYMBOLIC', text) for text in (core_dynamic, dep_dynamic)):
        raise RuntimeError('Missing symbolic binding')
    sdk_providers = set()
    for name in set(needed + dep_needed) - {'libdep.so'}:
        paths = [sdk / 'sysroot/usr/lib/aarch64-linux-ohos' / name,
                 sdk / 'llvm/lib/aarch64-linux-ohos' / name]
        library = next((p for p in paths if p.is_file()), None)
        if library is None:
            raise RuntimeError(f'Missing SDK dependency provider: {name}')
        sdk_providers.update(symbol_table(nm, library))
    providers = set(carrier_defs) | sdk_providers
    imports = symbol_table(nm, core, undefined=True)
    unresolved = sorted(s for s, kind in imports.items() if s not in providers and kind not in ('w', 'v'))
    if unresolved:
        raise RuntimeError(f'Strong unresolved imports: {unresolved}')
    carrier_imports = symbol_table(nm, carrier, undefined=True)
    carrier_unresolved = sorted(s for s, kind in carrier_imports.items()
                                if s not in sdk_providers and kind not in ('w', 'v'))
    if carrier_unresolved:
        raise RuntimeError(f'Strong unresolved carrier imports: {carrier_unresolved}')
    return {'api_exports': public, 'imports': len(imports), 'strong_unresolved': unresolved,
            'weak_unresolved': sorted(s for s, kind in imports.items() if s not in providers),
            'needed': needed, 'carrier_needed': dep_needed,
            'carrier_exports': len(carrier_defs), 'machine': 'AArch64',
            'carrier_imports': len(carrier_imports), 'carrier_strong_unresolved': carrier_unresolved,
            'carrier_weak_unresolved': sorted(s for s, kind in carrier_imports.items()
                                               if s not in sdk_providers)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True, help='OHOS SDK native directory')
    parser.add_argument('--work-dir', type=Path, required=True, help='Dedicated generated build directory')
    parser.add_argument('--python', type=Path, default=Path(sys.executable))
    parser.add_argument('--meson-path', type=Path, help='Directory containing the existing mesonbuild package')
    parser.add_argument('--original-core', type=Path, help='Pinned original ARM64 libmpv.so; otherwise fetch the release ZIP')
    parser.add_argument('--git', default=shutil.which('git'))
    parser.add_argument('--jobs', type=int, default=8)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    if not args.git:
        parser.error('An existing Git executable is required')
    work, sdk = args.work_dir.resolve(), args.sdk.resolve()
    work.mkdir(parents=True, exist_ok=True)
    downloads = work / 'downloads'
    downloads.mkdir(exist_ok=True)

    def download_archive(item):
        name, spec = item
        return name, fetch(spec['url'], downloads / (name + '.tar.gz'), spec['sha256'])

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        archives = dict(pool.map(download_archive, MANIFEST['archives'].items()))
    deps = {}
    for name, archive in archives.items():
        deps[name] = extract(archive, work / 'extracted' / name)
    # Component directories are regenerated from immutable archives before each
    # application. The new-file cleanup is limited to files added by that patch.
    for spec in MANIFEST['patches']:
        patch = fetch(spec['url'], downloads / spec['name'], spec['sha256_lf'], normalize_lf=True)
        apply_patch(deps[spec['component']], patch, args.git, work)
    local_patches = [HERE / 'patches/0001-ohaudio-pcm-timeline.patch',
                     HERE / 'patches/0002-ohcodec-init-failure.patch',
                     HERE / 'patches/0003-ohos-hdr-output.patch']
    for patch in local_patches:
        apply_patch(deps['mpv'], patch, args.git, work)
    patch_paths = [relative for patch in local_patches for relative in
                   re.findall(r'^\+\+\+ b/(.+)$', patch.read_text(encoding='utf-8'), re.MULTILINE)]
    patch_hashes = {}
    for relative in patch_paths:
        patched_file = deps['mpv'] / relative
        if not patched_file.is_file():
            raise RuntimeError(f'Missing patched source: {relative}')
        patch_hashes[relative] = sha256(patched_file)
    if not {'audio/out/pcm_timeline.c', 'audio/out/pcm_timeline.h'} <= patch_hashes.keys():
        raise RuntimeError('The PCM timeline patch is missing its helper source/header')
    original = work / 'original/libmpv.so'
    original.parent.mkdir(exist_ok=True)
    if args.original_core:
        if args.original_core.resolve() != original:
            shutil.copy2(args.original_core, original)
    elif not original.is_file():
        spec = MANIFEST['original_core']
        archive = fetch(spec['url'], downloads / 'libmpv_aarch64.zip', spec.get('archive_sha256'))
        with zipfile.ZipFile(archive) as package:
            candidates = [name for name in package.namelist() if Path(name).name == 'libmpv.so']
            if len(candidates) != 1:
                raise RuntimeError('Expected one libmpv.so in original release ZIP')
            original.write_bytes(package.read(candidates[0]))
    if sha256(original) != MANIFEST['original_core']['sha256'] or original.stat().st_size != MANIFEST['original_core']['bytes']:
        raise RuntimeError('Original core does not match the pinned release')
    carrier = work / 'artifacts/libdep.so'
    offset = make_carrier(original, carrier)
    headers = work / 'headers'
    generate_headers(deps, headers)
    prepare_meson(deps['mpv'], deps, headers, carrier)
    crossfile = work / 'aarch64-ohos-cross.ini'
    write_crossfile(crossfile, sdk, args.python.resolve())
    options = ['--auto-features=disabled', '-Dlibmpv=true', '-Dcplayer=false',
               '-Dgpl=false', '-Dbuild-date=false', '-Dohos=enabled', '-Degl-ohos=enabled',
               '-Dgl=enabled', '-Dvulkan=disabled', '-Dshaderc=disabled', '-Dlua=lua52',
               '-Dlcms2=enabled', '-Diconv=enabled', '-Dvector=enabled', '-Dcplugins=enabled',
               '-Dzlib=enabled', '-Dbuildtype=release', '-Db_lundef=true']
    report = {'mpv_sha': MANIFEST['mpv_sha'], 'recipe_sha': MANIFEST['recipe_sha'],
              'pcm_patch_sha256': sha256(local_patches[0]), 'inputs': MANIFEST,
              'local_patches_in_order': [{'path': str(patch.relative_to(REPO)), 'sha256': sha256(patch)}
                                         for patch in local_patches],
              'patched_source_sha256_before_build_overrides': patch_hashes,
              'sdk': str(sdk), 'python': str(args.python.resolve()), 'meson_options': options,
              'carrier_soname_offset': offset, 'original_sha256': sha256(original),
              'carrier_sha256': sha256(carrier), 'core_version': 'v0.41.0 (source archive; pinned SHA above)',
              'feature_changes': ['shaderc disabled', 'vulkan disabled'],
              'runtime_validated': False}
    if not args.prepare_only:
        env = dict(os.environ)
        if args.meson_path:
            env['PYTHONPATH'] = str(args.meson_path.resolve()) + os.pathsep + env.get('PYTHONPATH', '')
        ninja = sdk / 'build-tools/cmake/bin/ninja.exe'
        env['PATH'] = str(ninja.parent) + os.pathsep + str(sdk / 'llvm/bin') + os.pathsep + env['PATH']
        build = work / 'build'
        command = [str(args.python), '-m', 'mesonbuild.mesonmain', 'setup', str(build),
                   str(deps['mpv']), '--cross-file', str(crossfile), *options]
        if (build / 'meson-private/coredata.dat').is_file():
            command.insert(4, '--reconfigure')
        with (work / 'configure.log').open('w', encoding='utf-8') as output:
            subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
        with (work / 'compile.log').open('w', encoding='utf-8') as output:
            subprocess.run([str(ninja), '-C', str(build), '-j', str(args.jobs)], env=env,
                           stdout=output, stderr=subprocess.STDOUT, check=True)
        core = carrier.parent / 'libmpv.so'
        shutil.copy2(build / 'libmpv.so', core)
        report['elf_validation'] = validate(core, original, carrier, sdk)
        report['core_sha256'], report['core_bytes'] = sha256(core), core.stat().st_size
        for name in ('notice.txt', 'licenses.txt'):
            shutil.copy2(REPO / 'entry/src/main/resources/rawfile/mpv' / name, carrier.parent / name)
    (work / 'rebuild-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'work_dir': str(work), 'artifacts': str(carrier.parent),
                      'core_sha256': report.get('core_sha256'),
                      'report': str(work / 'rebuild-report.json')}, indent=2))


if __name__ == '__main__':
    main()
