#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BiliHarmony 快速冒烟测试（跨平台）。

用法: python3 tool/qa/smoke.py [--skip-install]
"""
import argparse
import sys
import time

from qa_common import (
    QaReport, connect, cold_start, dump_ui, dump_until_text, load_ui_tree,
    first_node, all_texts, node_text, node_bounds, parse_bounds, has_text, tap_bounds,
    swipe_up, snapshot_shot, back_home,
)

report = QaReport('冒烟测试报告（Python 跨平台）')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--skip-install', action='store_true')
    ap.add_argument('--hap', default='')
    args = ap.parse_args()
    connect()

    if not args.skip_install:
        from pathlib import Path
        from qa_common import ROOT, device
        hap = args.hap
        if not hap:
            for cand in ('entry/build/default/outputs/default/entry-default-signed.hap',
                         'entry/build/default/outputs/default/entry-default-unsigned.hap'):
                if (ROOT / cand).exists():
                    hap = str(ROOT / cand)
                    break
        if hap:
            device().run(['install', '-r', hap], check=True)
        else:
            print('未找到 HAP，跳过安装')

    report.begin('首页频道渲染')
    cold_start()
    d = dump_until_text('推荐', 25, 'smoke_home')
    t = load_ui_tree(d)
    if has_text(t, '推荐') or has_text(t, '热门'):
        report.pass_('首页渲染')
    else:
        report.fail('首页未渲染')
    snapshot_shot('smoke_home')

    report.begin('切换热门')
    n = first_node(t, lambda x: node_text(x) == '热门')
    if n:
        tap_bounds(node_bounds(n), 1000)
        t2 = load_ui_tree(dump_ui('smoke_hot'))
        if has_text(t2, '直播'):
            report.pass_('热门频道打开')
        else:
            report.fail('热门频道异常')
        snapshot_shot('smoke_hot')
    else:
        report.skip('无热门')

    report.begin('首页滚动')
    swipe_up(800)
    t3 = load_ui_tree(dump_ui('smoke_scroll'))
    if len(all_texts(t3)) > 20:
        report.pass_(f'滚动文本 {len(all_texts(t3))} 个')
    else:
        report.fail('滚动文本过少')

    report.begin('动态Tab')
    d4 = dump_ui('smoke_dyn_start')
    t4 = load_ui_tree(d4)
    n_dyn = first_node(t4, lambda x: node_text(x) == '动态')
    if n_dyn:
        tap_bounds(node_bounds(n_dyn), 1200)
    t4 = load_ui_tree(dump_ui('smoke_dyn'))
    if has_text(t4, '关注') or len(all_texts(t4)) > 5:
        report.pass_(f'动态页可渲染（texts={len(all_texts(t4))}）')
    else:
        report.fail('动态页无法渲染')
    snapshot_shot('smoke_dyn')

    report.begin('我的Tab')
    n_mine = first_node(t4, lambda x: node_text(x) == '我的')
    if n_mine:
        tap_bounds(node_bounds(n_mine), 1200)
    t5 = load_ui_tree(dump_ui('smoke_mine'))
    if has_text(t5, '我的追番') or has_text(t5, '稍后再看') or has_text(t5, '收藏'):
        report.pass_('我的页')
    else:
        report.fail('我的页缺少入口')
    snapshot_shot('smoke_mine')

    out = report.export()
    print(f'report: {out}')
    print(f'PASS={report.passed} FAIL={report.failed} SKIP={report.skipped}')
    sys.exit(1 if report.failed else 0)


if __name__ == '__main__':
    main()
