#!/usr/bin/env python3
"""Prepare real, pinned dependency headers for the host HDR output fixture.

This does not build or replace any app/native library. The SDK is already
installed by the workflow; libplacebo is the same hash-verified source archive
used by the production core rebuild.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil


ROOT = Path(__file__).resolve().parents[2]
SDK_HEADERS = (
    'native_buffer/buffer_common.h', 'native_window/external_window.h',
    'window_manager/oh_display_info.h', 'EGL/egl.h', 'EGL/eglext.h',
    'EGL/eglplatform.h', 'KHR/khrplatform.h',
)


def find_sdk(root):
    root = root.resolve(strict=True)
    candidates = set()
    for header in root.rglob('buffer_common.h'):
        sdk = header.parents[4]
        include = sdk / 'sysroot/usr/include'
        if all((include / name).is_file() for name in SDK_HEADERS):
            candidates.add(sdk)
    if len(candidates) != 1:
        raise RuntimeError('Expected one complete native SDK under ' + str(root) +
                           ', found ' + str(len(candidates)))
    return candidates.pop()


def load_rebuild_helpers():
    spec = importlib.util.spec_from_file_location(
        'pinned_core_rebuild', ROOT / 'tool/mpv/rebuild-ohos-core.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare(sdk_root, work, archive=None):
    sdk = find_sdk(sdk_root)
    helpers = load_rebuild_helpers()
    lock = helpers.MANIFEST
    spec = lock['archives']['libplacebo']
    version = re.search(r'/tags/v(\d+)\.(\d+)\.(\d+)$', spec['url'])
    if not version or not re.fullmatch(r'[0-9a-f]{40}', lock['libplacebo_sha']):
        raise RuntimeError('The production libplacebo source lock is incomplete')
    work = work.resolve()
    destination = archive.resolve() if archive else work / 'downloads/libplacebo.tar.gz'
    archive = helpers.fetch(spec['url'], destination, spec['sha256'])
    source = helpers.extract(archive, work / 'source')
    include = work / 'include'
    public = include / 'libplacebo'
    public.mkdir(parents=True, exist_ok=True)
    upstream = source / 'src/include/libplacebo'
    for name in ('colorspace.h', 'common.h'):
        shutil.copyfile(upstream / name, public / name)
    # Match the public-header generation in the pinned core rebuild. No Meson,
    # compiler, unpinned package or invented SDK declaration is needed here.
    features = '\n'.join('#define PL_HAVE_' + name + ' 1' for name in
                         ('OPENGL', 'VULKAN', 'SHADERC', 'LCMS', 'DOVI', 'LIBDOVI'))
    config = (upstream / 'config.h.in').read_text(encoding='utf-8')
    for key, value in {'majorver': version[1], 'apiver': version[2],
                       'extra_defs': features}.items():
        config = config.replace('@' + key + '@', value)
    if re.search(r'@[A-Za-z_]+@', config):
        raise RuntimeError('Unsubstituted libplacebo public configuration')
    (public / 'config.h').write_text(config, encoding='utf-8', newline='\n')
    # This is libplacebo's private source version header. The fixture consumes
    # public config.h; retain the source version too without calling git describe
    # in a source archive nested under the application's repository.
    pretty = '.'.join(version.groups())
    template = (source / 'src/version.h.in').read_text(encoding='utf-8')
    version_header = template.replace('@buildver@', 'v' + pretty)
    if '@buildver@' in version_header:
        raise RuntimeError('Unsubstituted libplacebo source version')
    (work / 'version.h').write_text(version_header, encoding='utf-8', newline='\n')
    result = {
        'MPV_HDR_TEST_SDK': str(sdk),
        'MPV_HDR_TEST_PLACEBO_INCLUDE': str(include),
        'MPV_HDR_TEST_REQUIRED': '1',
    }
    report = {'environment': result, 'libplacebo_sha': lock['libplacebo_sha'],
              'archive_sha256': helpers.sha256(archive), 'version': pretty,
              'header_sha256': {name: helpers.sha256(public / name) for name in
                                ('colorspace.h', 'common.h', 'config.h')}}
    (work / 'preparation.json').write_text(json.dumps(report, indent=2) + '\n',
                                          encoding='utf-8', newline='\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk-root', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--archive', type=Path, help='Reuse a local pinned archive; its hash is checked')
    parser.add_argument('--github-env', type=Path)
    args = parser.parse_args()
    environment = prepare(args.sdk_root, args.work_dir, args.archive)
    # Publish environment only after every dependency was found and verified.
    if args.github_env:
        with args.github_env.open('a', encoding='utf-8', newline='\n') as output:
            for key, value in environment.items():
                if '\n' in value or '\r' in value:
                    raise RuntimeError('Dependency path contains a line break')
                output.write(key + '=' + value + '\n')
    print(json.dumps(environment, indent=2))


if __name__ == '__main__':
    main()
