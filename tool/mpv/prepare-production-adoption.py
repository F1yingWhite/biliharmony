#!/usr/bin/env python3
"""Prepare a reviewed ARM core/carrier replacement; never modify production files."""
import argparse
import ast
import difflib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RESOURCE = 'entry/src/main/resources/rawfile/mpv/'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf8', newline='\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path, help='Successful current rebuild-report.json')
    parser.add_argument('--sdk', required=True, type=Path, help='OHOS native SDK directory')
    parser.add_argument('--core', type=Path, help='Default: report directory/artifacts/libmpv.so')
    parser.add_argument('--carrier', type=Path, help='Default: report directory/artifacts/libdep.so')
    parser.add_argument('--original-core', type=Path, help='Default: report directory/original/libmpv.so')
    parser.add_argument('--output', type=Path, default=ROOT / '.qa/mpv-speed-core/production-adoption',
                        help='Dedicated staging directory; production directories are refused')
    parser.add_argument('--prepare-app', action='store_true',
                        help='Copy tracked working app inputs and link installed modules for an isolated build')
    args = parser.parse_args()
    report_path, sdk, output = args.report.resolve(), args.sdk.resolve(), args.output.resolve()
    # This tool produces a mirror and diff only. It cannot target production
    # files, dependency directories, or their parents through a junction.
    if output == ROOT or output in ROOT.parents or ROOT in output.parents:
        require(output.is_relative_to(ROOT / '.qa'), 'Workspace staging must stay inside .qa')
    # Durable report bytes use LF, matching the repository checkout contract.
    report_bytes = report_path.read_bytes().replace(b'\r\n', b'\n')
    report = json.loads(report_bytes)
    inputs = json.loads((HERE / 'rebuild-inputs.json').read_text(encoding='utf8'))
    require(report['mpv_sha'] == inputs['mpv_sha'] and
            report['recipe_sha'] == inputs['recipe_sha'], 'Rebuild source/recipe differs from pinned inputs')
    require(report['inputs'] == inputs, 'Rebuild input manifest changed')
    core = (args.core or report_path.parent / 'artifacts/libmpv.so').resolve()
    carrier = (args.carrier or report_path.parent / 'artifacts/libdep.so').resolve()
    original = (args.original_core or report_path.parent / 'original/libmpv.so').resolve()
    require(digest(core.read_bytes()) == report['core_sha256'] and
            core.stat().st_size == report['core_bytes'], 'Core differs from successful rebuild report')
    require(digest(carrier.read_bytes()) == report['carrier_sha256'], 'Carrier differs from rebuild report')
    require(digest(original.read_bytes()) == inputs['original_core']['sha256'] and
            original.stat().st_size == inputs['original_core']['bytes'], 'Original release does not match pinned input')
    patches = [{**patch, 'path': patch['path'].replace('\\', '/')}
               for patch in report['local_patches_in_order']]
    require([p['path'] for p in patches] == ['tool/mpv/patches/0001-ohaudio-pcm-timeline.patch',
                                           'tool/mpv/patches/0002-ohcodec-init-failure.patch',
                                           'tool/mpv/patches/0003-ohos-hdr-output.patch'],
            'Unexpected local patch order')
    for patch in patches:
        require(digest((ROOT / patch['path']).read_bytes()) == patch['sha256'],
                'Rebuild report is stale for ' + patch['path'])

    spec = importlib.util.spec_from_file_location('core_rebuild', HERE / 'rebuild-ohos-core.py')
    rebuild = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rebuild)
    validation = rebuild.validate(core, original, carrier, sdk)
    require(validation == report['elf_validation'], 'Current ELF validation differs from rebuild report')
    with tempfile.TemporaryDirectory(prefix='mpv-adoption-carrier-') as temporary:
        expected_carrier = Path(temporary) / 'libdep.so'
        offset = rebuild.make_carrier(original, expected_carrier)
        require(offset == report['carrier_soname_offset'] and
                expected_carrier.read_bytes() == carrier.read_bytes(),
                'Carrier contains changes beyond the reviewed SONAME rename')

    output.mkdir(parents=True, exist_ok=True)
    if args.prepare_app:
        root_inputs = {'build-profile.json5', 'hvigorfile.ts', 'oh-package.json5',
                       'oh-package-lock.json5', 'code-linter.json5'}
        tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode('utf8').split('\0')
        for relative in tracked:
            if not (relative in root_inputs or relative.startswith(('AppScope/', 'entry/', 'hvigor/'))):
                continue
            if relative.startswith('entry/libs/') or not (ROOT / relative).is_file():
                continue
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        # Installed modules are read during builds; never install/update through
        # these links. Signing configuration is copied without printing it.
        for relative in ('oh_modules', 'entry/oh_modules'):
            target = output / relative
            if not target.exists():
                if os.name == 'nt':
                    env = dict(os.environ, MPV_ADOPTION_LINK=str(target),
                               MPV_ADOPTION_MODULES=str(ROOT / relative))
                    subprocess.run(['powershell', '-NoProfile', '-Command',
                                    'New-Item -ItemType Junction -Path $env:MPV_ADOPTION_LINK '
                                    '-Target $env:MPV_ADOPTION_MODULES | Out-Null'], check=True, env=env)
                else:
                    target.symlink_to(ROOT / relative, target_is_directory=True)
    stage_pins = {}
    for name, role, source in [('libmpv.so', 'core', core), ('libdep.so', 'carrier', carrier)]:
        target = output / 'entry/libs/arm64-v8a' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        packaged = output / 'expected-packaged' / name
        packaged.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(sdk / 'llvm/bin/llvm-strip.exe'), '--strip-all',
                        '-o', str(packaged), str(source)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stage_pins[role] = {'input_sha256': digest(source.read_bytes()),
                            'input_bytes': source.stat().st_size,
                            'packaged_sha256': digest(packaged.read_bytes()),
                            'packaged_bytes': packaged.stat().st_size}
    original_manifest = json.loads((ROOT / RESOURCE / 'sources.json').read_text(encoding='utf8'))
    original_binary = original_manifest.get('original_binary', original_manifest['binary'])
    require(original_binary['sha256'] == inputs['original_core']['sha256'] and
            original_binary['bytes'] == inputs['original_core']['bytes'],
            'Original-release provenance differs from the pinned input')
    # Repeated adoption retains immutable release provenance and replaces the
    # derived core/carrier/report pins, rather than nesting derivations.
    manifest = dict(original_manifest, original_binary=original_binary)
    for field, role, name in [('binary', 'core', 'libmpv.so'),
                              ('dependency_carrier', 'carrier', 'libdep.so')]:
        pins = stage_pins[role]
        manifest[field] = {'name': name, 'sha256': pins['packaged_sha256'],
                           'bytes': pins['packaged_bytes'], 'architecture': 'aarch64',
                           'input_sha256': pins['input_sha256'], 'input_bytes': pins['input_bytes'],
                           'packaging_transform': 'OHOS SDK llvm-strip --strip-all', 'soname': name}
    manifest['local_patches'] = patches
    manifest['rebuild_report'] = {'path': 'tool/mpv/rebuild-report-arm64.json',
                                  'sha256': digest(report_bytes)}
    manifest['derivation'] = {'kind': 'local core-only rebuild plus original dependency carrier',
                             'source_sha': report['mpv_sha'], 'meson_options': report['meson_options'],
                             'feature_changes': report['feature_changes'],
                             'carrier_modification': 'Only DT_SONAME libmpv.so -> libdep.so',
                             'arm_runtime_validated': report['runtime_validated']}
    for name in ('cacert.pem', 'licenses.txt'):
        target = output / RESOURCE / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / RESOURCE / name, target)
    write_json(output / RESOURCE / 'sources.json', manifest)
    notice = (ROOT / RESOURCE / 'notice.txt').read_text(encoding='utf8')
    original_marker = 'Original dependency-carrier release notice:\n\n'
    while original_marker in notice:
        notice = notice.split(original_marker, 1)[1]
    banner = ('BiliHarmony locally rebuilt OHOS player and dependency carrier.\n\n'
              f"New libmpv.so HAP SHA-256: {stage_pins['core']['packaged_sha256']}\n"
              f"New libmpv.so build input SHA-256: {stage_pins['core']['input_sha256']}\n"
              f"Dependency libdep.so HAP SHA-256: {stage_pins['carrier']['packaged_sha256']}\n"
              f"Dependency libdep.so input SHA-256: {stage_pins['carrier']['input_sha256']}\n\n"
              'The original release notice below describes the dependency carrier before its\n'
              'SONAME rename. Its original libmpv.so hash identifies that original input,\n'
              'not the new playback core. All original licenses and copyright texts remain.\n'
              'The new core applies local patches 0001/0002/0003 from tool/mpv/patches, using\n'
              'the fixed source SHA and inputs in sources.json and tool/mpv/rebuild-inputs.json.\n'
              'Rebuild script: tool/mpv/rebuild-ohos-core.py; exact ARM report:\n'
              'tool/mpv/rebuild-report-arm64.json. Ship the corresponding sources, original\n'
              'recipe patches, local patches and build instructions with the library pair.\n'
              'The core-only rebuild disables Vulkan and shaderc in the new core; these\n'
              'components remain in the carrier. FFmpeg LGPL-3.0-or-later terms still apply.\n\n'
              'Original dependency-carrier release notice:\n\n')
    (output / RESOURCE / 'notice.txt').write_text(banner + notice, encoding='utf8', newline='\n')
    pins = {**stage_pins, 'original_sha256': inputs['original_core']['sha256'],
            'recipe_commit': inputs['recipe_sha'], 'local_patches': patches,
            'rebuild_report_sha256': digest(report_bytes),
            'ca_sha256': digest((ROOT / RESOURCE / 'cacert.pem').read_bytes()),
            'licenses_sha256': digest((ROOT / RESOURCE / 'licenses.txt').read_bytes())}
    checker = (HERE / 'package-check-derived.py.in').read_text(encoding='utf8')
    require(checker.count('__ADOPTION_PINS__') == 1, 'Unexpected package checker template')
    checker = checker.replace('__ADOPTION_PINS__', repr(pins))
    ast.parse(checker) # Fail before handing off a broken generated checker.
    checker_path = output / 'tool/qa/player-mpv-package-check.py'
    checker_path.parent.mkdir(parents=True, exist_ok=True)
    checker_path.write_text(checker, encoding='utf8', newline='\n')
    for relative in [*(p['path'] for p in patches), 'tool/mpv/rebuild-inputs.json',
                     'tool/mpv/rebuild-ohos-core.py', 'tool/mpv/README.md', 'AppScope/app.json5']:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    (output / manifest['rebuild_report']['path']).write_bytes(report_bytes)

    cmake_relative = 'entry/src/main/cpp/CMakeLists.txt'
    cmake = (ROOT / cmake_relative).read_text(encoding='utf8')
    import_end = '  "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libmpv.so")'
    require(cmake.count(import_end) == 1, 'Unexpected imported mpv target')
    carrier_cmake = '''

add_library(mpv_dependencies SHARED IMPORTED)
set_target_properties(mpv_dependencies PROPERTIES IMPORTED_LOCATION
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libdep.so"
  IMPORTED_SONAME "libdep.so")
set_target_properties(mpv PROPERTIES IMPORTED_SONAME "libmpv.so"
  IMPORTED_LINK_DEPENDENT_LIBRARIES mpv_dependencies)
foreach(player_library IN ITEMS libmpv.so libdep.so)
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/${player_library}")
    message(FATAL_ERROR "Missing reviewed player dependency: ${player_library}")
  endif()
endforeach()'''
    if 'add_library(mpv_dependencies SHARED IMPORTED)' not in cmake:
        cmake = cmake.replace(import_end, import_end + carrier_cmake)
    else:
        require(cmake.count('add_library(mpv_dependencies SHARED IMPORTED)') == 1 and
                'IMPORTED_LINK_DEPENDENT_LIBRARIES mpv_dependencies' in cmake and
                'IMPORTED_SONAME "libdep.so"' in cmake,
                'Existing carrier CMake import differs from the reviewed configuration')
    rpath_link = 'target_link_options(bilimpv PRIVATE "-Wl,-rpath-link,${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}")'
    if rpath_link not in cmake:
        cmake += '\n# Resolve the carrier at link time; do not embed a development-machine RPATH.\n'
        cmake += rpath_link + '\n'
    require(cmake.count(rpath_link) == 1, 'Duplicate carrier linker options')
    target = output / cmake_relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(cmake, encoding='utf8', newline='\n')

    doc_relative = 'docs/player-core-reuse.md'
    doc = (ROOT / doc_relative).read_text(encoding='utf8')
    start, end = doc.index('## 固定的鸿蒙二进制'), doc.index('## HDR 选源与输出验证')
    core_pin, carrier_pin = stage_pins['core'], stage_pins['carrier']
    section = f'''## 固定的鸿蒙二进制

播放器使用共享库 `libmpv.so` 和依赖载体 `libdep.so`。新内核来自固定源码
`{report['mpv_sha']}`，依次应用本仓库 `tool/mpv/patches/0001`、`0002` 与 `0003`。
依赖载体来自原始 OHOS 20260715 发布，只有 ELF SONAME 从 libmpv.so 改为 libdep.so。
原发布及全部组件、版权和许可证信息仍保留在 sources.json 与 licenses.txt。

| 产物 | 原始构建输入 SHA-256 | 实际 HAP 中剥离后的 SHA-256 |
| --- | --- | --- |
| 新 libmpv.so | `{core_pin['input_sha256']}` | `{core_pin['packaged_sha256']}` |
| libdep.so | `{carrier_pin['input_sha256']}` | `{carrier_pin['packaged_sha256']}` |

新内核剥离后 {core_pin['packaged_bytes']:,} 字节；载体剥离后 {carrier_pin['packaged_bytes']:,} 字节。
HAP 的散列对应 SDK `llvm-strip --strip-all` 后的产物，构建输入散列不能冒充包内散列。
完整固定输入、补丁校验值、构建选项与 ELF 检查在 `tool/mpv/rebuild-report-arm64.json`。
可复现命令见 [内核重建说明](../tool/mpv/README.md)。两库必须一起分发和替换。

0001 在 PCM 变成裸字节前记录每段的真实 PTS 与 effective rate，按硬件时间映射音频播放点
与视频显示期限；OHAudio 的 CLOCK_MONOTONIC 时间通过成对取时转换到 mpv 的进程时基。
0002 保护 OHCodec interop 初始化失败后的清理，让解码器继续走原有回退流程。
0003 为 OHOS OpenGL 输出协商真实 10 位缓冲与 PQ/HLG 编码，能力未知或设置失败回退 SDR。
虚拟机使用的 GLES 格式探测兼容保护不属于 ARM 补丁。

这次核心重建使用 OpenGL，关闭新核心的 Vulkan/shaderc；相关组件仍留在原始载体中。
新核心的 `gpl=false` 不会消除载体中静态 FFmpeg 的 LGPL-3.0-or-later 分发要求。
ARM 构建报告的 runtime_validated 保持其实际值；虚拟机运行结果另见
[倍速运行验证](player-hold-transition-validation.md)，不能把 x86_64 验证当作 ARM 验收。
替换产物时同时更新来源清单、包检查器、离线 notice 和本表，并重新检查真实 HAP。

'''
    doc = doc[:start] + section + doc[end:]
    target = output / doc_relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(doc, encoding='utf8', newline='\n')
    changed_text = [RESOURCE + 'sources.json', RESOURCE + 'notice.txt',
                    'tool/qa/player-mpv-package-check.py', cmake_relative, doc_relative]
    changes = []
    for relative in changed_text:
        old, new = ROOT / relative, output / relative
        changes.append({'path': relative, 'before_sha256': digest(old.read_bytes()),
                        'after_sha256': digest(new.read_bytes())})
    diff = ''.join(''.join(difflib.unified_diff(
        (ROOT / rel).read_text(encoding='utf8').splitlines(keepends=True),
        (output / rel).read_text(encoding='utf8').splitlines(keepends=True),
        fromfile='a/' + rel, tofile='b/' + rel)) for rel in changed_text)
    (output / 'proposed-text.patch').write_text(diff, encoding='utf8', newline='\n')
    write_json(output / 'preparation.json', {'scope': 'Staged proposal only; no production mutation',
                                           'source_report': str(report_path), 'pins': pins,
                                           'elf_validation': validation, 'changes': changes,
                                           'production_adopted': False})
    print(json.dumps({'staging_directory': str(output), 'text_patch': str(output / 'proposed-text.patch'),
                      'pins': stage_pins, 'production_modified': False}, indent=2))


if __name__ == '__main__':
    main()
