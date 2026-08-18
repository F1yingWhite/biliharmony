#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BiliHarmony 深度 UI 流失回归（跨平台 Python 版，覆盖原 suite_deep.ps1 主要链路）。"""
import sys
import time
from pathlib import Path

from qa_common import (
    QaReport, connect, cold_start, dump_ui, dump_until_text, load_ui_tree,
    find_nodes, first_node, all_texts, node_text, node_type, node_bounds,
    parse_bounds, has_text, tap_bounds, swipe_up, key_back,
    snapshot_shot, back_home, SCREEN_W, SCREEN_H,
)

report = QaReport('BiliHarmony 深度回归（Python 跨平台）')


def first_text_cards(root, y_min=500, y_max=2400, min_len=6):
    return [n for n in find_nodes(root, lambda x: (
        node_type(x) == 'Text' and len(node_text(x)) > min_len and
        (parse_bounds(node_bounds(x)) or {}).get('y1', -1) > y_min and
        (parse_bounds(node_bounds(x)) or {}).get('y2', 0) < y_max
    ))]


def tap_first_text(root, text, wait_ms=1200):
    n = first_node(root, lambda x: text in node_text(x))
    if not n:
        return False
    tap_bounds(node_bounds(n), wait_ms)
    return True


def go_hot_channel():
    cold_start()
    d = dump_until_text('热门', 20, 'hot_ch')
    t = load_ui_tree(d)
    n = first_node(t, lambda x: node_text(x) == '热门' and (parse_bounds(node_bounds(x)) or {}).get('y1', 9999) < 500)
    if not n:
        n = first_node(t, lambda x: node_text(x) == '热门')
    if n:
        tap_bounds(node_bounds(n), 1000)
    time.sleep(0.8)
    return load_ui_tree(dump_ui('hot_done'))


def test_d1():
    report.begin('D1 视频详情-评论-弹幕')
    try:
        cold_start()
        d = dump_until_text('推荐', 20, 'd1_home')
        t = load_ui_tree(d)
        cards = first_text_cards(t)
        if not cards:
            report.skip('无卡片')
            return
        tap_bounds(node_bounds(cards[0]), 2500)
        d2 = dump_until_text('评论', 25, 'd1_detail')
        t2 = load_ui_tree(d2)
        assert has_text(t2, '评论')
        snapshot_shot('d1_detail')
        n_dm = first_node(t2, lambda x: node_text(x) in ('弹幕', '弹幕列表') or node_text(x).startswith('弹幕'))
        if n_dm:
            tap_bounds(node_bounds(n_dm), 800)
            dump_ui('d1_danmaku')
            snapshot_shot('d1_danmaku')
            report.pass_('弹幕面板可打开')
            key_back()
        else:
            report.note('弹幕入口未找到')
        swipe_up(900)
        time.sleep(0.8)
        snapshot_shot('d1_comment_scroll')
    except Exception as e:
        report.fail(f'D1: {e}')
    finally:
        back_home()


def test_d2():
    report.begin('D2 用户空间')
    try:
        cold_start()
        d = dump_until_text('推荐', 20, 'd2_home')
        t = load_ui_tree(d)
        cards = first_text_cards(t)
        if not cards:
            report.skip('无卡片')
            return
        tap_bounds(node_bounds(cards[0]), 2500)
        d2 = load_ui_tree(dump_ui('d2_detail'))
        n_up = first_node(d2, lambda x: ' 粉丝' in node_text(x) or '粉丝' in node_text(x))
        if n_up:
            tap_bounds(node_bounds(n_up), 2500)
            t2 = load_ui_tree(dump_ui('d2_userspace'))
            if len(all_texts(t2)) > 10:
                report.pass_(f'用户空间 N={len(all_texts(t2))}')
            else:
                report.fail('用户空间内容少')
            snapshot_shot('d2_userspace')
            key_back()
            key_back()
        else:
            report.skip('UP 入口未找到')
    except Exception as e:
        report.fail(f'D2: {e}')
    finally:
        back_home()


def test_d3():
    report.begin('D3 排行榜')
    try:
        t = go_hot_channel()
        n = first_node(t, lambda x: '排行' in node_text(x))
        if not n:
            report.skip('排行入口未找到')
            return
        tap_bounds(node_bounds(n), 2500)
        t2 = load_ui_tree(dump_ui('d3_rank'))
        if has_text(t2, '全站') or has_text(t2, '排行'):
            report.pass_('排行榜打开')
        else:
            report.fail('排行榜缺少核心文本')
        snapshot_shot('d3_rank')
        n_week = first_node(t2, lambda x: '每周' in node_text(x))
        if n_week:
            tap_bounds(node_bounds(n_week), 2000)
            snapshot_shot('d3_weekly')
            report.pass_('每周必看可切换')
    except Exception as e:
        report.fail(f'D3: {e}')
    finally:
        back_home()


def test_d4():
    report.begin('D4 番剧索引/详情')
    try:
        t = go_hot_channel()
        n = first_node(t, lambda x: '番剧' in node_text(x))
        if not n:
            report.skip('番剧入口未找到')
            return
        tap_bounds(node_bounds(n), 2500)
        t2 = load_ui_tree(dump_ui('d4_bangumi_index'))
        if len(all_texts(t2)) > 5:
            report.pass_('番剧索引有内容')
        else:
            report.fail('番剧索引空')
        snapshot_shot('d4_bangumi_index')
        card = first_text_cards(t2)
        if card:
            tap_bounds(node_bounds(card[0]), 3000)
            t3 = load_ui_tree(dump_ui('d4_bangumi_detail'))
            if has_text(t3, '追番') or has_text(t3, '选集'):
                report.pass_('番剧详情打开')
            else:
                report.fail('番剧详情缺少追番/选集')
            snapshot_shot('d4_bangumi_detail')
    except Exception as e:
        report.fail(f'D4: {e}')
    finally:
        back_home()


def test_d5():
    report.begin('D5 直播房间')
    try:
        cold_start()
        d = dump_until_text('直播', 20, 'd5_home')
        t = load_ui_tree(d)
        n = first_node(t, lambda x: node_text(x) == '直播' and (parse_bounds(node_bounds(x)) or {}).get('y1', 9999) < 500)
        if n:
            tap_bounds(node_bounds(n), 1500)
        t2 = load_ui_tree(dump_ui('d5_livepage'))
        card = first_text_cards(t2, 700, 2000)
        if not card:
            report.skip('直播卡未找到')
            return
        tap_bounds(node_bounds(card[0]), 4000)
        t3 = load_ui_tree(dump_ui('d5_room'))
        if has_text(t3, '人气') or has_text(t3, '弹幕'):
            report.pass_('直播房间打开')
        else:
            report.fail('直播房间缺核心文本')
        snapshot_shot('d5_room')
    except Exception as e:
        report.fail(f'D5: {e}')
    finally:
        back_home()


def test_d6():
    report.begin('D6 我的-历史/稍后/收藏')
    try:
        cold_start()
        t = load_ui_tree(dump_ui('d6_home'))
        n = first_node(t, lambda x: node_text(x) == '我的' and (parse_bounds(node_bounds(x)) or {}).get('y1', -1) > 2400)
        if n:
            tap_bounds(node_bounds(n), 1200)
        t2 = load_ui_tree(dump_ui('d6_mine'))
        for label in ('历史', '稍后'):
            n = first_node(t2, lambda x: label in node_text(x))
            if not n:
                continue
            tap_bounds(node_bounds(n), 2000)
            t3 = load_ui_tree(dump_ui('d6_' + label))
            report.pass_(f'{label} 打开 N={len(all_texts(t3))}')
            snapshot_shot('d6_' + label)
            key_back()
            time.sleep(0.8)
            # 重新进入“我的”
            t4 = load_ui_tree(dump_ui('d6_back'))
            n_mine = first_node(t4, lambda x: node_text(x) == '我的' and (parse_bounds(node_bounds(x)) or {}).get('y1', -1) > 2400)
            if n_mine:
                tap_bounds(node_bounds(n_mine), 1000)
        n_fav = first_node(load_ui_tree(dump_ui('d6_mine')), lambda x: '我的收藏' in node_text(x) or node_text(x) == '收藏')
        if n_fav:
            tap_bounds(node_bounds(n_fav), 2000)
            t4 = load_ui_tree(dump_ui('d6_fav'))
            if len(all_texts(t4)) > 3:
                report.pass_('收藏页有内容')
            else:
                report.fail('收藏页空')
            snapshot_shot('d6_fav')
    except Exception as e:
        report.fail(f'D6: {e}')
    finally:
        back_home()


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--skip-install', action='store_true')
    ap.add_argument('--hap', default='')
    args = ap.parse_args()

    if not args.skip_install:
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

    connect()
    for fn in (test_d1, test_d2, test_d3, test_d4, test_d5, test_d6):
        fn()
    out = report.export()
    print(f'report: {out}')
    print(f'PASS={report.passed} FAIL={report.failed} SKIP={report.skipped}')
    sys.exit(1 if report.failed else 0)


if __name__ == '__main__':
    main()
