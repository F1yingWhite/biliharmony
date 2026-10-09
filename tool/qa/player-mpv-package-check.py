#!/usr/bin/env python3
"""Check the reviewed ARM core/carrier pair inside an actual HAP."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import zipfile

PINNED = {'core': {'input_sha256': 'f904d78b7c227c659f53131e65033218be8b77d5ce49d18acad5be6f5d4597b3', 'input_bytes': 2628832, 'packaged_sha256': '5a8279b527ff889ab273f93aded9ca96006f2d11e4abc391456c5c6bd725c9ce', 'packaged_bytes': 2261536}, 'carrier': {'input_sha256': '098e628f73f1a709bdff16de7eb5fad7d104a0d5bce68c23435b6214d57a35e0', 'input_bytes': 35491168, 'packaged_sha256': '098e628f73f1a709bdff16de7eb5fad7d104a0d5bce68c23435b6214d57a35e0', 'packaged_bytes': 35491168}, 'original_sha256': '672e98d497199a89e20893979ecec686dee1113bbe1b609c9a9266aa1679bd32', 'recipe_commit': '1bab837e662ffa47ce51efd0720d3ed7c4988944', 'local_patches': [{'path': 'tool/mpv/patches/0001-ohaudio-pcm-timeline.patch', 'sha256': '8638719f964243aa4f738226c97ad13170cba6c0f499d14b168ce6176f5fda76'}, {'path': 'tool/mpv/patches/0002-ohcodec-init-failure.patch', 'sha256': '5d8ce119bb9297c713b2e394520ec4bec8ed2f2cf0cecb0bee54187d42d658a9'}, {'path': 'tool/mpv/patches/0003-ohos-hdr-output.patch', 'sha256': '8735cfbf347e81173797e771c0155be806175f72c93e897aeddf13ec9899e091'}], 'rebuild_report_sha256': '3fe8d74f2930e0638ccfc5bf59acd879a8d9ac3441529785a4ace48990f25bb8', 'ca_sha256': 'a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505', 'licenses_sha256': '9ba94e22bf32cd52fdab838888d8e236ed2519e50262fb02af9c995699433348'}
ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def elf_metadata(data, label):
    require(data[:6] == b'\x7fELF\x02\x01', label + ': expected little-endian ELF64')
    header = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    require(header[2] == 183 and header[1] == 3, label + ': expected AArch64 ET_DYN')
    programs = [struct.unpack_from('<IIQQQQQQ', data, header[5] + n * header[9])
                for n in range(header[10])]
    dynamic = next((p for p in programs if p[0] == 2), None)
    require(dynamic is not None, label + ': missing PT_DYNAMIC')
    needed, strings, soname, flags = [], None, None, 0
    for offset in range(dynamic[2], dynamic[2] + dynamic[5], 16):
        tag, value = struct.unpack_from('<qQ', data, offset)
        if tag == 0:
            break
        if tag == 1:
            needed.append(value)
        elif tag == 5:
            strings = value
        elif tag == 14:
            soname = value
        elif tag == 30:
            flags = value
    require(strings is not None, label + ': missing DT_STRTAB')
    segment = next((p for p in programs if p[0] == 1 and
                    p[3] <= strings < p[3] + p[5]), None)
    require(segment is not None, label + ': string table is not file-backed')
    base = segment[2] + strings - segment[3]

    def string(relative):
        start = base + relative
        return data[start:data.index(b'\0', start)].decode('ascii')

    return {'needed': [string(n) for n in needed],
            'soname': string(soname) if soname is not None else None,
            'symbolic': bool(flags & 2)}


def inspect_hap(hap):
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()

        def read_suffix(suffix):
            matches = [n for n in names if n == suffix or n.endswith('/' + suffix)]
            require(len(matches) == 1, 'HAP must contain one ' + suffix)
            return archive.read(matches[0])

        app = json.loads(read_suffix('module.json'))['app']
        expected_app = json.loads((ROOT / 'AppScope/app.json5').read_text())['app']
        for key in ['bundleName', 'versionName', 'versionCode']:
            require(app.get(key) == expected_app[key], 'HAP app identity differs: ' + key)

        native_names = {n for n in names if n.endswith('.so')}
        require(native_names == {'libs/arm64-v8a/' + n for n in
                ('libmpv.so', 'libdep.so', 'libbilimpv.so', 'libc++_shared.so')},
                'HAP must package exactly the four reviewed ARM libraries')
        libraries, metadata = {}, {}
        for name in ('libmpv.so', 'libdep.so', 'libbilimpv.so', 'libc++_shared.so'):
            libraries[name] = read_suffix('libs/arm64-v8a/' + name)
            metadata[name] = elf_metadata(libraries[name], name)
        for name, role in [('libmpv.so', 'core'), ('libdep.so', 'carrier')]:
            expected = PINNED[role]
            data = libraries[name]
            require(len(data) == expected['packaged_bytes'] and
                    digest(data) == expected['packaged_sha256'],
                    name + ': packaged bytes do not match the reviewed stripped input')
            require(metadata[name]['soname'] == name, name + ': incorrect DT_SONAME')
            require(metadata[name]['symbolic'], name + ': missing SYMBOLIC binding')
        core_needed = metadata['libmpv.so']['needed']
        require(b'BiliPcmTiming' not in libraries['libmpv.so'] and
                b'BiliHdrOutput' not in libraries['libmpv.so'] and
                b'QA ONLY forcedCapabilities' not in libraries['libmpv.so'],
                'production core contains QA timing/HDR probes')
        require('libnative_display_manager.so' in core_needed,
                'HDR core must query the native display capabilities')
        carrier_needed = metadata['libdep.so']['needed']
        bridge_needed = metadata['libbilimpv.so']['needed']
        require('libmpv.so' in bridge_needed and 'libace_napi.z.so' in bridge_needed,
                'bridge must dynamically use the new mpv API and OHOS NAPI')
        require('libdep.so' in core_needed, 'new core does not load its dependency carrier')
        require('libmpv.so' not in core_needed + carrier_needed,
                'core/carrier dependency graph contains an mpv back edge')
        require('libnative_media_vdec.so' in carrier_needed,
                'carrier has no OHOS video-decoder dependency')
        require('libc++_shared.so' in carrier_needed, 'carrier has no C++ runtime dependency')
        require(not any('avcodec' in n or 'avformat' in n for n in core_needed + carrier_needed),
                'FFmpeg must stay inside the carrier instead of an unpackaged shared library')

        prefix = 'resources/rawfile/mpv/'
        resources = {name: read_suffix(prefix + name) for name in
                     ('cacert.pem', 'notice.txt', 'licenses.txt', 'sources.json')}
        for name, data in resources.items():
            require(data == (ROOT / 'entry/src/main/resources/rawfile/mpv' / name).read_bytes(),
                    'HAP contains stale resource: ' + name)
        require(digest(resources['cacert.pem']) == PINNED['ca_sha256'] and
                resources['cacert.pem'].count(b'-----BEGIN CERTIFICATE-----') > 100,
                'CA bundle is not the pinned complete certificate set')
        require(digest(resources['licenses.txt']) == PINNED['licenses_sha256'],
                'original complete license text changed')
        notice = resources['notice.txt'].decode('utf8')
        licenses = resources['licenses.txt'].decode('utf8')
        require('LGPL-3.0-or-later' in notice and 'MPL-2.0' in notice,
                'player/CA license notice is missing')
        require(len(licenses) > 100000 and 'Version 3, 29 June 2007' in licenses and
                'Mozilla Public License Version 2.0' in licenses and
                'The FreeType Project LICENSE' in licenses,
                'complete third-party license texts are missing')
        sources = json.loads(resources['sources.json'])
        require(sources['recipe_commit'] == PINNED['recipe_commit'], 'recipe commit is not pinned')
        for field, role in [('binary', 'core'), ('dependency_carrier', 'carrier')]:
            expected = PINNED[role]
            value = sources[field]
            require(value['sha256'] == expected['packaged_sha256'] and
                    value['bytes'] == expected['packaged_bytes'] and
                    value['input_sha256'] == expected['input_sha256'] and
                    value['input_bytes'] == expected['input_bytes'] and
                    value['architecture'] == 'aarch64', 'manifest does not identify ' + role)
        require(sources['original_binary']['sha256'] == PINNED['original_sha256'],
                'original dependency-carrier provenance is missing')
        require(sources['local_patches'] == PINNED['local_patches'],
                'manifest local patch order/hash differs')
        for patch in PINNED['local_patches']:
            require(digest((ROOT / patch['path']).read_bytes()) == patch['sha256'],
                    'delivered patch differs: ' + patch['path'])
        require(digest((ROOT / sources['rebuild_report']['path']).read_bytes()) ==
                PINNED['rebuild_report_sha256'], 'delivered rebuild report differs')
        components = {c['name']: c for c in sources['components']}
        require({'mpv', 'FFmpeg', 'Mbed TLS', 'libplacebo', 'Mozilla CA certificate data'} <= components.keys(),
                'bundled component manifest is incomplete')
        require(components['FFmpeg']['license'] == 'LGPL-3.0-or-later',
                'static FFmpeg licensing is mislabeled')
    return {'hap': str(hap.resolve()), 'status': 'passed', 'version': app['versionName'],
            'hap_sha256': digest(hap.read_bytes()), 'core': PINNED['core'],
            'carrier': PINNED['carrier'], 'linkage': metadata,
            'scope': 'Actual HAP bytes/linkage/resources; runtime playback is separate'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('hap', nargs='?', type=Path,
                        default=ROOT / 'entry/build/default/outputs/default/entry-default-signed.hap')
    args = parser.parse_args()
    try:
        print(json.dumps(inspect_hap(args.hap), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, struct.error, zipfile.BadZipFile) as error:
        print('Player package check failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
