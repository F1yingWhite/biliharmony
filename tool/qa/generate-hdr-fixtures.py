#!/usr/bin/env python3
"""Generate and probe local SDR, HDR10/PQ and HLG playback fixtures.

Requires host ffmpeg/ffprobe with libx264 and 10-bit libx265. The clips contain
synthetic grayscale transfer-function stimuli, moving frame markers and AAC
audio. They test playback/color signaling, not physical display brightness.
"""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MASTER = 'G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50)'


def pq(nits):
    # ITU-R BT.2100 / SMPTE ST 2084: normalized absolute luminance.
    m1, m2 = 2610 / 16384, 2523 / 32
    c1, c2, c3 = 3424 / 4096, 2413 / 128, 2392 / 128
    x = (nits / 10000) ** m1
    return ((c1 + c2 * x) / (1 + c3 * x)) ** m2


def hlg(scene_linear):
    # ITU-R BT.2100 HLG OETF. Stimuli are scene-relative, not absolute nits.
    a = 0.17883277
    b = 1 - 4 * a
    c = 0.5 - a * math.log(4 * a)
    return math.sqrt(3 * scene_linear) if scene_linear <= 1 / 12 else a * math.log(12 * scene_linear - b) + c


def bt709(scene_linear):
    return 4.5 * scene_linear if scene_linear < 0.018 else 1.099 * scene_linear ** 0.45 - 0.099


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Command failed: ' + repr(command) + '\n' + result.stderr)
    return result.stdout


def raw_frames(path, levels, bits, width, height, frames):
    low, high, neutral = (64, 940, 512) if bits == 10 else (16, 235, 128)
    values = [round(low + (high - low) * level) for level in levels]
    row = [values[min(7, x * 8 // width)] for x in range(width)]

    def pack(samples):
        if bits == 8:
            return bytes(samples)
        result = array('H', samples)
        if sys.byteorder != 'little':
            result.byteswap()
        return result.tobytes()

    bars = pack(row) * (height - 12)
    chroma = pack([neutral] * (width * height // 2))
    with path.open('wb') as output:
        for frame in range(frames):
            marker = (frame * 4) % width
            moving_row = pack([high if marker <= x < min(width, marker + 8) else low for x in range(width)])
            output.write(bars + moving_row * 12 + chroma)
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    parser.add_argument('--ffprobe', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / '.qa/hdr/media')
    parser.add_argument('--duration', type=int, default=12)
    parser.add_argument('--fps', type=int, default=30)
    args = parser.parse_args()
    if args.duration < 2 or not 1 <= args.fps <= 60:
        parser.error('Use duration >= 2 seconds and fps between 1 and 60')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    width, height, frames = 320, 180, args.duration * args.fps
    pq_values = [0.005, 0.1, 1, 10, 100, 203, 400, 1000]
    relative = [0.0001, 0.001, 0.01, 0.05, 0.1, 0.25, 0.5, 1]
    cases = [('hdr10-pq', 10, [pq(x) for x in pq_values], 'bt2020', 'smpte2084', 'bt2020nc'),
             ('hlg', 10, [hlg(x) for x in relative], 'bt2020', 'arib-std-b67', 'bt2020nc'),
             ('sdr-bt709', 8, [bt709(x) for x in relative], 'bt709', 'bt709', 'bt709')]
    report = {'scope': 'Synthetic playback fixtures; not display HDR-output proof',
              'ffmpeg': {'path': str(args.ffmpeg.resolve()),
                         'sha256': hashlib.sha256(args.ffmpeg.read_bytes()).hexdigest(),
                         'version': run([str(args.ffmpeg), '-version']).splitlines()[0]},
              'ffprobe': {'path': str(args.ffprobe.resolve()),
                          'sha256': hashlib.sha256(args.ffprobe.read_bytes()).hexdigest()},
              'clips': []}
    with tempfile.TemporaryDirectory(prefix='raw-', dir=output) as temporary:
        for name, bits, levels, primaries, transfer, matrix in cases:
            raw = Path(temporary) / (name + '.yuv')
            values = raw_frames(raw, levels, bits, width, height, frames)
            clip = output / (name + '.mp4')
            command = [str(args.ffmpeg), '-hide_banner', '-loglevel', 'error', '-y',
                       '-f', 'rawvideo', '-pixel_format', 'yuv420p10le' if bits == 10 else 'yuv420p',
                       '-video_size', f'{width}x{height}', '-framerate', str(args.fps), '-i', str(raw),
                       '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', str(args.duration),
                       '-color_primaries', primaries, '-color_trc', transfer, '-colorspace', matrix,
                       '-color_range', 'tv', '-vf',
                       f'setparams=range=limited:color_primaries={primaries}:color_trc={transfer}:colorspace={matrix}']
            if bits == 10:
                settings = 'pools=1:frame-threads=1:wpp=0:repeat-headers=1:keyint=' + str(args.fps)
                settings += ':colorprim=9:colormatrix=9:transfer=' + ('16' if name == 'hdr10-pq' else '18')
                if name == 'hdr10-pq':
                    settings += ':hdr10=1:master-display=' + MASTER + ':max-cll=1000,400'
                command += ['-c:v', 'libx265', '-preset', 'fast', '-crf', '15', '-profile:v', 'main10',
                            '-x265-params', settings, '-tag:v', 'hvc1']
            else:
                command += ['-c:v', 'libx264', '-preset', 'fast', '-crf', '15', '-g', str(args.fps),
                            '-x264-params', 'colorprim=bt709:transfer=bt709:colormatrix=bt709']
            command += ['-c:a', 'aac', '-b:a', '64k', '-shortest', '-movflags', '+faststart', str(clip)]
            run(command)
            probe = json.loads(run([str(args.ffprobe), '-v', 'error', '-show_streams', '-show_format',
                                    '-of', 'json', str(clip)]))
            first = json.loads(run([str(args.ffprobe), '-v', 'error', '-select_streams', 'v:0',
                                    '-read_intervals', '%+#1', '-show_frames', '-of', 'json', str(clip)]))
            video = next(stream for stream in probe['streams'] if stream['codec_type'] == 'video')
            expected = {'color_primaries': primaries, 'color_transfer': transfer, 'color_space': matrix,
                        'pix_fmt': 'yuv420p10le' if bits == 10 else 'yuv420p'}
            for key, value in expected.items():
                if video.get(key) != value:
                    raise ValueError(f'{name}: actual {key}={video.get(key)!r}, expected {value!r}')
            side_data = first['frames'][0].get('side_data_list', [])
            if name == 'hdr10-pq':
                types = {item['side_data_type'] for item in side_data}
                if not {'Mastering display metadata', 'Content light level metadata'} <= types:
                    raise ValueError('HDR10 fixture is missing mastering/CLL metadata')
            report['clips'].append({'path': str(clip), 'bytes': clip.stat().st_size,
                                    'sha256': hashlib.sha256(clip.read_bytes()).hexdigest(),
                                    'stimulus': 'absolute nits' if name == 'hdr10-pq' else 'scene-linear relative',
                                    'stimulus_values': pq_values if name == 'hdr10-pq' else relative,
                                    'y_limited_codes': values, 'ffprobe': probe,
                                    'first_video_frame': first['frames'][0],
                                    'command': [str(raw).replace(str(temporary), '<temporary>') if arg == str(raw)
                                                else arg for arg in command]})
    report_path = output / 'fixtures-report.json'
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf8', newline='\n')
    print(json.dumps({'report': str(report_path),
                      'clips': [{key: clip[key] for key in ('path', 'sha256', 'bytes')} for clip in report['clips']]}, indent=2))


if __name__ == '__main__':
    main()
