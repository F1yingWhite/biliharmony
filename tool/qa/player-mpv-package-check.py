#!/usr/bin/env python3
"""Check the actual HAP's pinned player core, native linkage and offline notices."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import zipfile


CORE_SHA256 = '672e98d497199a89e20893979ecec686dee1113bbe1b609c9a9266aa1679bd32'
CA_SHA256 = 'a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505'
CORE_BYTES = 35491168
RECIPE_COMMIT = '1bab837e662ffa47ce51efd0720d3ed7c4988944'
ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def elf_dependencies(data, label):
    require(data[:6] == b'\x7fELF\x02\x01', label + ': expected little-endian ELF64')
    header = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    require(header[2] == 183, label + ': expected AArch64 machine')
    require(header[1] == 3, label + ': expected a shared object (ET_DYN)')
    program_offset, program_size, program_count = header[5], header[9], header[10]
    programs = [struct.unpack_from('<IIQQQQQQ', data, program_offset + i * program_size)
                for i in range(program_count)]
    dynamic = next((program for program in programs if program[0] == 2), None)
    require(dynamic is not None, label + ': missing PT_DYNAMIC')
    needed_offsets, string_address = [], None
    for offset in range(dynamic[2], dynamic[2] + dynamic[5], 16):
        tag, value = struct.unpack_from('<qQ', data, offset)
        if tag == 0:
            break
        if tag == 1:
            needed_offsets.append(value)
        elif tag == 5:
            string_address = value
    require(string_address is not None, label + ': missing dynamic string table')
    segment = next((program for program in programs if program[0] == 1 and
                    program[3] <= string_address < program[3] + program[5]), None)
    require(segment is not None, label + ': string table has no file-backed segment')
    string_offset = segment[2] + string_address - segment[3]
    result = []
    for relative in needed_offsets:
        start = string_offset + relative
        result.append(data[start:data.index(b'\0', start)].decode('ascii'))
    require(result, label + ': expected native shared-library dependencies')
    return result


def inspect_hap(hap):
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()

        def read_suffix(suffix):
            matches = [name for name in names if name == suffix or name.endswith('/' + suffix)]
            require(len(matches) == 1, 'HAP must contain one ' + suffix)
            return archive.read(matches[0])

        expected_app = json.loads((ROOT / 'AppScope/app.json5').read_text())['app']
        packaged_app = json.loads(read_suffix('module.json'))['app']
        for key in ['bundleName', 'versionName', 'versionCode']:
            require(packaged_app.get(key) == expected_app[key],
                    'HAP ' + key + ' differs from AppScope/app.json5')

        core = read_suffix('libs/arm64-v8a/libmpv.so')
        bridge = read_suffix('libs/arm64-v8a/libbilimpv.so')
        runtime = read_suffix('libs/arm64-v8a/libc++_shared.so')
        require(len(core) == CORE_BYTES, 'HAP libmpv.so size differs from the pinned core')
        require(hashlib.sha256(core).hexdigest() == CORE_SHA256, 'HAP libmpv.so SHA-256 mismatch')
        core_needed = elf_dependencies(core, 'libmpv.so')
        bridge_needed = elf_dependencies(bridge, 'libbilimpv.so')
        runtime_needed = elf_dependencies(runtime, 'libc++_shared.so')
        require('libmpv.so' in bridge_needed, 'bridge does not dynamically link libmpv.so')
        require('libace_napi.z.so' in bridge_needed, 'bridge has no OHOS NAPI dependency')
        require('libnative_media_vdec.so' in core_needed, 'core has no OHOS video-decoder dependency')
        require(not any('avcodec' in item or 'avformat' in item for item in core_needed),
                'pinned core should include FFmpeg rather than require unpackaged shared FFmpeg')

        prefix = 'resources/rawfile/mpv/'
        ca = read_suffix(prefix + 'cacert.pem')
        require(hashlib.sha256(ca).hexdigest() == CA_SHA256, 'HAP TLS CA bundle SHA-256 mismatch')
        require(ca.count(b'-----BEGIN CERTIFICATE-----') > 100, 'TLS CA bundle is not complete')
        notice = read_suffix(prefix + 'notice.txt').decode('utf8')
        licenses = read_suffix(prefix + 'licenses.txt').decode('utf8')
        sources = json.loads(read_suffix(prefix + 'sources.json'))
        require('LGPL-3.0-or-later' in notice and 'MPL-2.0' in notice,
                'player or CA license notice is missing')
        require('Version 3, 29 June 2007' in licenses and
                'Mozilla Public License Version 2.0' in licenses and
                'The FreeType Project LICENSE' in licenses,
                'complete LGPL3/MPL2/dependency license texts are missing')
        require(len(licenses) > 100000, 'aggregate third-party license file is unexpectedly small')
        require(sources['binary']['sha256'] == CORE_SHA256, 'source manifest identifies a different core')
        require(sources['recipe_commit'] == RECIPE_COMMIT, 'source manifest recipe is not pinned')
        components = {component['name']: component for component in sources['components']}
        require({'mpv', 'FFmpeg', 'Mbed TLS', 'libplacebo', 'Mozilla CA certificate data'} <= components.keys(),
                'source manifest is missing bundled components')
        require(components['FFmpeg']['license'] == 'LGPL-3.0-or-later',
                'manifest incorrectly labels static FFmpeg licensing')
        # Resources must be byte-identical to the reviewed workspace files.
        for name in ['cacert.pem', 'notice.txt', 'licenses.txt', 'sources.json']:
            packaged = read_suffix(prefix + name)
            local = ROOT / 'entry/src/main/resources/rawfile/mpv' / name
            require(packaged == local.read_bytes(), 'HAP contains stale rawfile/mpv/' + name)
    return {'hap': str(hap.resolve()), 'version_name': packaged_app['versionName'],
            'version_code': packaged_app['versionCode'], 'core_sha256': CORE_SHA256,
            'bridge_needed': bridge_needed, 'core_needed': core_needed,
            'cpp_runtime_needed': runtime_needed,
            'certificate_count': ca.count(b'-----BEGIN CERTIFICATE-----'),
            'license_components': len(components), 'status': 'passed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('hap', nargs='?', type=Path,
                        default=ROOT / 'entry/build/default/outputs/default/entry-default-signed.hap')
    args = parser.parse_args()
    try:
        print(json.dumps(inspect_hap(args.hap), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        print('Player package check failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
