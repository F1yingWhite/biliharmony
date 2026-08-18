#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨平台 UI 对齐/间距/重叠审计（Python 版）。

读取 .emulator/qa 中最新的 dump JSON，执行：
  - 零尺寸 / 越界节点
  - 文本重叠（排除 Dock 区）
  - 行内列左缘对齐
  - 行距档位
用法: python3 tool/qa/audit_ui.py [--dump path.json ...] [--all]
"""
import argparse
import json
import sys
from pathlib import Path

from qa_common import QA_DIR, walk, node_text, node_type, node_bounds, parse_bounds, SCREEN_W, SCREEN_H

DOCK_Y = 2500


def audit_dump(path: Path):
    t = json.loads(path.read_text(encoding='utf-8-sig'))
    nodes = walk(t)
    texts = [n for n in nodes if node_type(n) == 'Text' and node_text(n).strip()]
    zero = 0
    overflow = 0
    overflow_samples = []
    for n in nodes:
        b = parse_bounds(node_bounds(n))
        if not b:
            continue
        if b['x2'] <= b['x1'] or b['y2'] <= b['y1']:
            zero += 1
        if b['x1'] < 0 or b['x2'] > SCREEN_W or b['y1'] < 0 or b['y2'] > SCREEN_H:
            overflow += 1
            if len(overflow_samples) < 5:
                overflow_samples.append(f"[{node_type(n)}] {node_text(n)} @{node_bounds(n)}")

    overlaps = 0
    overlap_samples = []
    for i in range(len(texts)):
        bi = parse_bounds(node_bounds(texts[i]))
        if not bi or bi['y1'] > DOCK_Y:
            continue
        for j in range(i + 1, len(texts)):
            bj = parse_bounds(node_bounds(texts[j]))
            if not bj or bj['y1'] > DOCK_Y:
                continue
            if node_text(texts[i]) == node_text(texts[j]):
                continue
            w = max(0, min(bi['x2'], bj['x2']) - max(bi['x1'], bj['x1']))
            h = max(0, min(bi['y2'], bj['y2']) - max(bi['y1'], bj['y1']))
            ai = (bi['x2'] - bi['x1']) * (bi['y2'] - bi['y1'])
            aj = (bj['x2'] - bj['x1']) * (bj['y2'] - bj['y1'])
            if ai <= 0 or aj <= 0:
                continue
            if w * h > 0.45 * min(ai, aj):
                overlaps += 1
                if len(overlap_samples) < 6:
                    overlap_samples.append(f"  '{node_text(texts[i])}' <> '{node_text(texts[j])}'")

    # 简单列对齐：同一 90px 行带、同一 60px 中心列，检查 >=3 项左缘方差
    groups = {}
    for n in texts:
        b = parse_bounds(node_bounds(n))
        if not b or b['y1'] < 380 or b['y1'] > 2600:
            continue
        txt = node_text(n)
        if len(txt) < 4:
            continue
        row = (b['y1'] // 90) * 90
        col = ((b['x1'] + b['x2']) // 2 // 60) * 60
        groups.setdefault((row, col), []).append((b, txt))
    align_issue = 0
    align_samples = []
    for (row, col), items in groups.items():
        if len(items) < 3:
            continue
        xs = sorted(x['x1'] for x, _ in items)
        ys = sorted(x['y1'] for x, _ in items)
        if xs[-1] - xs[0] > 6 and ys[-1] - ys[0] > 8:
            align_issue += 1
            sample = max(items, key=lambda iv: len(iv[1]))[1]
            if len(sample) > 24:
                sample = sample[:24]
            align_samples.append(f"行y={row} 列x~{col}: {len(items)} 项左缘散 {xs[-1]-xs[0]}px ('{sample}' 等)")

    # 行距档位
    ys = []
    for n in texts:
        b = parse_bounds(node_bounds(n))
        if b and 380 < b['y1'] < 2600:
            ys.append(b['y1'])
    ys_sorted = sorted(ys)
    diffs = []
    for i in range(1, len(ys_sorted)):
        d = ys_sorted[i] - ys_sorted[i-1]
        if 8 < d < 400:
            diffs.append(d)
    gap_counts = {}
    for d in diffs:
        key = (d // 6) * 6
        gap_counts[key] = gap_counts.get(key, 0) + 1
    top = sorted(gap_counts.items(), key=lambda kv: kv[1], reverse=True)[:3]
    top_str = ' '.join(f'{k}-{v}' for k, v in top)
    spread_note = f'⚠ 行距分散({len(gap_counts)}档)' if len(gap_counts) >= 4 else ''

    lines = [
        f"== 审计 {path.name} ==",
        f"  节点 {len(nodes)} 文本 {len(texts)} 零尺寸 {zero} 越界 {overflow} 重叠 {overlaps}",
    ]
    for s in overlap_samples:
        lines.append(f"    重叠: {s}")
    for s in overflow_samples:
        lines.append(f"    越界: {s}")
    lines.append(f"  列对齐问题: {align_issue}")
    for s in align_samples:
        lines.append(f"    {s}")
    lines.append(f"  行距档位: {top_str} {spread_note}")
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--all', action='store_true', help='审计全部 dump，默认最近 10 个')
    ap.add_argument('--dump', action='append', help='指定 dump JSON 文件')
    args = ap.parse_args()
    if args.dump:
        paths = [Path(p) for p in args.dump]
    else:
        files = sorted(QA_DIR.glob('*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
        paths = files if args.all else files[:10]
    if not paths:
        print('没有可审计 dump，请先运行 smoke/suite_all/suite_deep 生成 dump')
        return
    for p in paths:
        try:
            print('\n'.join(audit_dump(p)))
        except Exception as e:
            print(f'audit fail {p.name}: {e}')


if __name__ == '__main__':
    main()
