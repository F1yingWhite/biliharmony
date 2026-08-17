#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""图片像素级检查工具（QA 用，纯 Pillow，输出 JSON）。

用法:
  python check_img.py --shot xxx.jpeg --mode bg      # 屏幕分区平均色/明暗判定
  python check_img.py --shot xxx.jpeg --mode region --region x1,y1,x2,y2 [--name top]
  python check_img.py --shot xxx.jpeg --mode pink    # 粉/红色占比扫描
  python check_img.py --shot xxx.jpeg --mode dock     # Dock 底栏亮度（检查深色模式 Dock 是否泛白）
输出一行 JSON。
"""
import argparse, json, sys
from PIL import Image

W, H = 1320, 2848  # 模拟器物理分辨率

def avg_rgb(im, box):
    region = im.crop(box).resize((8, 8))
    px = list(region.getdata())
    n = len(px)
    r = sum(p[0] for p in px) // n
    g = sum(p[1] for p in px) // n
    b = sum(p[2] for p in px) // n
    return (r, g, b)

def fmt(c):
    return '#%02X%02X%02X' % c

def lum(c):
    r, g, b = c
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def check_bg(im):
    res = {}
    res['top'] = fmt(avg_rgb(im, (0, 140, W, 420)))
    res['mid'] = fmt(avg_rgb(im, (0, 1400, W, 1650)))
    res['bottom'] = fmt(avg_rgb(im, (0, 2500, W, 2800)))
    res['is_dark'] = lum(avg_rgb(im, (0, 140, W, 420))) < 125
    return res

def check_dock(im):
    """Dock 区（底部 ~90px 内）平均亮度，判定是否在深色下泛白。"""
    for y1 in (2600, 2650, 2700, 2750):
        c = avg_rgb(im, (60, y1, W - 60, min(y1 + 40, H)))
        if lum(c) > 40:
            return {'dock_avg': fmt(c), 'dock_lum': round(lum(c), 1), 'y': y1, 'too_bright': lum(c) > 150}
    return {'dock_avg': 'none'}

def check_pink(im):
    """扫描全屏，返回接近品牌粉 #FB7299 的像素占比（粗略）与“整屏是否出现非
    品牌色高饱和杂色”的估计。"""
    px = im.load()
    pink = 0
    total = 0
    for y in range(100, H - 60, 12):
        for x in range(0, W, 12):
            r, g, b = px[x, y][:3]
            total += 1
            if r > 190 and 90 < g < 160 and 130 < b < 200:
                pink += 1
    return {'pink_ratio': round(pink / max(total, 1), 4)}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shot', required=True)
    ap.add_argument('--mode', default='bg')
    ap.add_argument('--region', help='x1,y1,x2,y2')
    ap.add_argument('--name', default='r')
    args = ap.parse_args()
    im = Image.open(args.shot).convert('RGB')
    out = {'file': args.shot}
    if args.mode == 'bg':
        out['checks'] = check_bg(im)
    elif args.mode == 'dock':
        out['checks'] = check_dock(im)
    elif args.mode == 'pink':
        out['checks'] = check_pink(im)
    elif args.mode == 'region':
        x1, y1, x2, y2 = [int(v) for v in args.region.split(',')]
        c = avg_rgb(im, (x1, y1, x2, y2))
        out['checks'] = {args.name: fmt(c), args.name + '_lum': round(lum(c), 1)}
    else:
        out['checks'] = check_bg(im)
        out['checks'].update(check_dock(im))
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + '\n')
    sys.stdout.flush()

if __name__ == '__main__':
    main()