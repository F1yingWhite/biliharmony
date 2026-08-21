#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""截图序列动画探针。

无第三方依赖时仍可检查 JPEG 尺寸、方向和重复帧；存在 Pillow 或 ffmpeg 时额外计算
64 位感知哈希及相邻帧距离，用来发现动画冻结/瞬间跳变。
"""
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


def jpeg_size(path: Path) -> Tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 4 or data[:2] != b'\xff\xd8':
        raise ValueError(f'不是 JPEG: {path}')
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        i += 2
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            continue
        if i + 2 > len(data):
            break
        length = struct.unpack('>H', data[i:i + 2])[0]
        if length < 2 or i + length > len(data):
            break
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                      0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            height, width = struct.unpack('>HH', data[i + 3:i + 7])
            return width, height
        i += length
    raise ValueError(f'JPEG 缺少尺寸段: {path}')


def _dhash(path: Path) -> Optional[int]:
    try:
        from PIL import Image  # type: ignore
    except ImportError:
        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            return None
        proc = subprocess.run([
            ffmpeg, '-v', 'error', '-i', str(path), '-vf', 'scale=9:8,format=gray',
            '-frames:v', '1', '-f', 'rawvideo', '-',
        ], capture_output=True, timeout=8)
        if proc.returncode != 0 or len(proc.stdout) < 72:
            return None
        pixels = list(proc.stdout[:72])
    else:
        with Image.open(path) as image:
            pixels = list(image.convert('L').resize((9, 8)).getdata())
    value = 0
    for y in range(8):
        for x in range(8):
            value <<= 1
            value |= int(pixels[y * 9 + x] > pixels[y * 9 + x + 1])
    return value


def _orientation(width: int, height: int) -> str:
    if width > height:
        return 'landscape'
    if height > width:
        return 'portrait'
    return 'square'


def analyze(paths: Sequence[Path]) -> Dict[str, Any]:
    frames: List[Dict[str, Any]] = []
    hashes: List[str] = []
    perceptual: List[Optional[int]] = []
    for path in paths:
        raw = path.read_bytes()
        width, height = jpeg_size(path)
        digest = hashlib.sha256(raw).hexdigest()
        phash = _dhash(path)
        hashes.append(digest)
        perceptual.append(phash)
        frames.append({
            'path': str(path),
            'width': width,
            'height': height,
            'orientation': _orientation(width, height),
            'bytes': len(raw),
            'sha256': digest,
            'dhash': f'{phash:016x}' if phash is not None else None,
        })
    distances: List[Optional[int]] = []
    for left, right in zip(perceptual, perceptual[1:]):
        distances.append((left ^ right).bit_count() if left is not None and right is not None else None)
    orientations = [f['orientation'] for f in frames]
    meaningful = sum(1 for d in distances if d is not None and d >= 2)
    return {
        'frame_count': len(frames),
        'unique_exact_frames': len(set(hashes)),
        'orientations': orientations,
        'orientation_changed': len(set(orientations)) > 1,
        'final_orientation': orientations[-1] if orientations else None,
        'perceptual_available': all(v is not None for v in perceptual),
        'perceptual_distances': distances,
        'meaningful_transitions': meaningful if all(v is not None for v in perceptual) else None,
        'frames': frames,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description='分析 UI 动画截图序列')
    parser.add_argument('frames', nargs='+', type=Path)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    result = analyze(args.frames)
    payload = json.dumps(result, ensure_ascii=False, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(payload, encoding='utf-8')
    print(payload)


if __name__ == '__main__':
    main()
