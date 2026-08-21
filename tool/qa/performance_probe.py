#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""通过设备自带 SmartPerf 采集播放器运行期 FPS/CPU/GPU/内存。"""
import argparse
import json
import re
import statistics
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from qa_common import APP_ID, QA_DIR, device, ensure_qa_dir, log


PAIR_RE = re.compile(r'^order:\d+\s+([^=]+)=(.*)$')


def scalar(value: str) -> Any:
    value = value.strip()
    if value in ('', 'NA'):
        return None
    try:
        return float(value) if '.' in value else int(value)
    except ValueError:
        return value


def parse_smartperf(raw: str) -> List[Dict[str, Any]]:
    samples: List[Dict[str, Any]] = []
    current: Dict[str, Any] = {}
    for line in raw.splitlines():
        match = PAIR_RE.match(line.strip())
        if not match:
            continue
        key, value = match.groups()
        if key == 'ChildProcCpuLoad' and current:
            samples.append(current)
            current = {}
        current[key] = scalar(value)
    if current:
        samples.append(current)
    return samples


def numeric(samples: List[Dict[str, Any]], key: str, positive_only: bool = False) -> List[float]:
    values: List[float] = []
    for sample in samples:
        value = sample.get(key)
        if isinstance(value, (int, float)) and (not positive_only or value > 0):
            values.append(float(value))
    return values


def stats(values: List[float]) -> Optional[Dict[str, float]]:
    if not values:
        return None
    ordered = sorted(values)
    p95_index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * 0.95))))
    return {
        'min': min(values),
        'mean': statistics.fmean(values),
        'p95': ordered[p95_index],
        'max': max(values),
    }


def collect(seconds: int, package: str = APP_ID, prefix: str = 'player_perf') -> Dict[str, Any]:
    count = max(2, seconds)
    started = time.time()
    raw = device().run([
        'shell', 'SP_daemon', '-N', str(count), '-PKG', package,
        '-c', '-g', '-f', '-r', '-print',
    ], retries=1, timeout=count + 20)
    ensure_qa_dir()
    raw_path = QA_DIR / f'{prefix}_smartperf.txt'
    raw_path.write_text(raw, encoding='utf-8')
    samples = parse_smartperf(raw)
    fps_all = numeric(samples, 'fps')
    fps_rendering = numeric(samples, 'fps', positive_only=True)
    cpu = numeric(samples, 'ProcCpuUsage')
    gpu = numeric(samples, 'gpuLoad')
    pss = numeric(samples, 'pss')
    result: Dict[str, Any] = {
        'package': package,
        'requested_seconds': seconds,
        'elapsed_seconds': round(time.time() - started, 3),
        'sample_count': len(samples),
        'raw': str(raw_path),
        # FPS=0 代表该秒没有拿到应用刷新帧，不将其伪装成真实 0 FPS。
        'fps': stats(fps_rendering),
        'fps_raw_zero_samples': sum(1 for v in fps_all if v == 0),
        'cpu_usage': stats(cpu),
        'gpu_load': stats(gpu),
        'pss_kb': stats(pss),
        'samples': samples,
    }
    json_path = QA_DIR / f'{prefix}_smartperf.json'
    json_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    result['json'] = str(json_path)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description='BiliHarmony SmartPerf 性能采样')
    parser.add_argument('--seconds', type=int, default=10)
    parser.add_argument('--package', default=APP_ID)
    parser.add_argument('--prefix', default='player_perf')
    parser.add_argument('--min-fps', type=float, default=0,
                        help='大于 0 时启用 FPS 门槛；设备拿不到 FPS 也会失败')
    parser.add_argument('--max-pss-mb', type=float, default=0,
                        help='大于 0 时启用 PSS 上限')
    args = parser.parse_args()
    try:
        result = collect(args.seconds, args.package, args.prefix)
    except Exception as exc:
        log(f'性能采样失败: {exc}')
        sys.exit(2)
    print(json.dumps({k: v for k, v in result.items() if k != 'samples'}, ensure_ascii=False, indent=2))
    failed: List[str] = []
    fps = result.get('fps')
    pss = result.get('pss_kb')
    if args.min_fps > 0 and (not fps or fps['mean'] < args.min_fps):
        failed.append(f'FPS mean < {args.min_fps}')
    if args.max_pss_mb > 0 and pss and pss['max'] / 1024 > args.max_pss_mb:
        failed.append(f'PSS max > {args.max_pss_mb} MB')
    if failed:
        print('FAIL: ' + '; '.join(failed))
        sys.exit(1)


if __name__ == '__main__':
    main()
