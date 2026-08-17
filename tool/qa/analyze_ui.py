#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""UI 对齐/间距像素审计（基于截图）：
  1. 内容列边界检测（瀑布流双列左右留白与列间隙一致性）
  2. 卡片行节奏检测（垂直方向上暗色块的周期性，检测行距是否一致）
  3. 截图四边留白检测（内容是否贴边/不对称）
输出 JSON。
"""
import argparse, json, sys
from PIL import Image

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shot', required=True)
    ap.add_argument('--mode', default='columns',
                    choices=['columns', 'edges', 'rhythm'])
    args = ap.parse_args()
    im = Image.open(args.shot).convert('L')
    w, h = im.size
    out = {'file': args.shot, 'size': [w, h]}

    if args.mode == 'columns':
        # 内容区域 y 只取中部(避开头栏和 dock)
        y0, y1 = int(h * 0.25), int(h * 0.75)
        col_dark = [0] * w
        for y in range(y0, y1, 3):
            for x in range(0, w, 2):
                if im.getpixel((x, y)) < 170:
                    col_dark[x] += 1
        # 平滑：40px 滑窗
        smooth = []
        for x in range(0, w, 20):
            s = sum(col_dark[max(0, x - 20):x + 21])
            smooth.append({'x': x, 'dark': s})
        # 找内容左右边界: 第一个/最后一个 dark>阈值 的区域
        thr = (y1 - y0) // 3 * 2
        left = None; right = None
        for c in smooth:
            if c['dark'] > thr:
                if left is None: left = c['x']
                right = c['x']
        out['content_left'] = left
        out['content_right'] = right
        out['content_width'] = None if left is None else right - left
        # 找列间隙: dark 局部极小值(两列间的 gutter)
        gutters = []
        for i in range(3, len(smooth) - 3):
            if smooth[i]['dark'] < thr and smooth[i]['dark'] < smooth[i - 1]['dark'] and smooth[i]['dark'] < smooth[i + 1]['dark']:
                if smooth[i]['x'] > (left or 0) + 40 and smooth[i]['x'] < (right or w) - 40:
                    if not gutters or smooth[i]['x'] - gutters[-1]['x'] > 60:
                        gutters.append({'x': smooth[i]['x'], 'dark': smooth[i]['dark']})
        out['gutters'] = gutters
        # 对称性: 左留白 vs 右留白
        if left is not None:
            out['margin_left'] = left
            out['margin_right'] = w - right
            out['margin_diff'] = abs(left - (w - right))

    elif args.mode == 'rhythm':
        # 检测直线边界（卡片行分隔线/图片边界）在 y 方向的周期
        x0, x1 = int(w * 0.1), int(w * 0.9)
        row_dark = []
        for y in range(int(h * 0.2), int(h * 0.85)):
            cnt = sum(1 for x in range(x0, x1, 3) if im.getpixel((x, y)) < 170)
            row_dark.append(cnt)
        # 相邻行的差分，找突变点（边界）
        edges = []
        for i in range(2, len(row_dark) - 2):
            d = abs(row_dark[i + 1] - row_dark[i])
            if d > 25:
                edges.append(int(h * 0.2) + i)
        # 合并 20px 内相邻边界
        merged = []
        for e in edges:
            if merged and e - merged[-1] < 25:
                continue
            merged.append(e)
        out['edges_y'] = merged
        if len(merged) >= 3:
            gaps = [merged[i + 1] - merged[i] for i in range(len(merged) - 1)]
            out['gap_min'] = min(gaps); out['gap_max'] = max(gaps)
            out['gap_same'] = (max(gaps) - min(gaps)) <= 8
        else:
            out['gap_note'] = 'edges < 3, skip gap check'

    sys.stdout.write(json.dumps(out, ensure_ascii=False) + '\n')

if __name__ == '__main__':
    main()