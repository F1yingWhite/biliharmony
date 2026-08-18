#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BiliHaromny 全量 UI 回归（跨平台 Python 版，覆盖原 suite_all.ps1 的 8 个测试）。"""
import sys
import time
from pathlib import Path

from qa_common import (
    QaReport, connect, cold_start, dump_ui, dump_until_text, load_ui_tree, ensure_qa_dir,
    find_nodes, first_node, all_texts, node_text, node_type, node_bounds,
    parse_bounds, has_text, tap_text, tap_bounds, swipe_up, key_back,
    snapshot_shot, back_home, SCREEN_W, SCREEN_H,
)

report = QaReport('BiliHarmony 全量回归（Python 跨平台）')


def text_cards(root, y_min=500, y_max=2400, min_len=6):
    return [n for n in find_nodes(root, lambda x: (
        node_type(x) == 'Text' and len(node_text(x)) > min_len and
        (parse_bounds(node_bounds(x)) or {}).get('y1', -1) > y_min and
        (parse_bounds(node_bounds(x)) or {}).get('y2', 0) < y_max
    ))]


def open_first_video(name='video'):
    d = dump_until_text('推荐', 25, name + '_home')
    t = load_ui_tree(d)
    cards = text_cards(t)
    if not cards:
        report.skip('没有卡片')
        return None
    target = cards[0]
    title = node_text(target)[:18]
    report.note(f'点开: {title}')
    tap_bounds(node_bounds(target), 2500)
    d2 = dump_until_text('评论', 25, name + '_detail')
    return load_ui_tree(d2)


def test_01():
    report.begin('01 首页三频道+瀑布流')
    try:
        cold_start()
        d = dump_until_text('推荐', 25, 'h01_home')
        t = load_ui_tree(d)
        if has_text(t, '推荐'):
            report.pass_('推荐 tab')
        else:
            report.fail('推荐 tab')
        if has_text(t, '热门'):
            report.pass_('热门 tab')
        else:
            report.fail('热门 tab')
        live = first_node(t, lambda x: node_text(x) == '直播' and (parse_bounds(node_bounds(x)) or {}).get('y1', 9999) < 500)
        if live:
            report.pass_('直播频道Tab')
        else:
            report.fail('直播频道Tab缺失')
        snapshot_shot('h01_home')
        swipe_up(900)
        time.sleep(0.8)
        swipe_up(900)
        t2 = load_ui_tree(dump_ui('h01_scroll'))
        n2 = len(all_texts(t2))
        if n2 > 50:
            report.pass_(f'瀑布流滚动文本N={n2}')
        else:
            report.fail(f'滚动文本少 N={n2}')
        snapshot_shot('h01_scroll')
    except Exception as e:
        report.fail(f'01 err: {e}')


def test_02():
    report.begin('02 首页频道切换')
    try:
        cold_start()
        d = dump_until_text('热门', 20, 'h02_tabs')
        t = load_ui_tree(d)
        n_hot = first_node(t, lambda x: node_text(x) == '热门' and (parse_bounds(node_bounds(x)) or {}).get('y1', 9999) < 500)
        if not n_hot:
            n_hot = first_node(t, lambda x: node_text(x) == '热门')
        if n_hot:
            tap_bounds(node_bounds(n_hot), 1000)
        else:
            report.fail('热门Tab缺失')
            return
        t2 = load_ui_tree(dump_ui('h02_hotpage'))
        cnt = len(all_texts(t2))
        if cnt > 8:
            report.pass_(f'热门feed N={cnt}')
        else:
            report.fail(f'热门feed N={cnt}')
        snapshot_shot('h02_hotpage')
        n_live = first_node(t2, lambda x: node_text(x) == '直播' and (parse_bounds(node_bounds(x)) or {}).get('y1', 9999) < 500)
        if n_live:
            tap_bounds(node_bounds(n_live), 1500)
            t3 = load_ui_tree(dump_ui('h02_livepage'))
            c3 = len(all_texts(t3))
            if c3 > 8:
                report.pass_(f'直播频道 N={c3}')
            else:
                report.fail(f'直播频道 N={c3}')
            snapshot_shot('h02_livepage')
        else:
            report.skip('无直播Tab')
    except Exception as e:
        report.fail(f'02: {e}')


def test_03():
    report.begin('03 打开视频详情')
    try:
        cold_start()
        d = dump_until_text('推荐', 20, 'h03_home')
        t = load_ui_tree(d)
        cards = text_cards(t)
        if not cards:
            report.skip('没有卡片')
        else:
            target = cards[0]
            tap_bounds(node_bounds(target), 2500)
            d2 = dump_until_text('评论', 25, 'h03_detail')
            t2 = load_ui_tree(d2)
            if has_text(t2, '评论'):
                report.pass_('详情评论可见')
            else:
                report.fail('详情评论缺失')
            snapshot_shot('h03_detail')
    except Exception as e:
        report.fail(f'03: {e}')
    finally:
        back_home()


def test_04():
    report.begin('04 搜索页')
    try:
        cold_start()
        d = dump_until_text('推荐', 20, 'h04_home')
        t = load_ui_tree(d)
        target = first_node(t, lambda x: (node_text(x) in ('搜索你感兴趣的内容', '搜索') or
                                          (node_text(x) and (parse_bounds(node_bounds(x)) or {}).get('y1', 9999) < 280)))
        if target:
            tap_bounds(node_bounds(target), 1500)
        else:
            # 兜底：首页头栏中上部大范围点击搜索胶囊
            tap_bounds('[80,160][1150,250]', 1500)
        t2 = load_ui_tree(dump_ui('h04_search'))
        if has_text(t2, '搜索') or has_text(t2, '热搜') or has_text(t2, '趋势榜'):
            report.pass_('搜索页渲染')
        else:
            report.fail('搜索页未渲染')
        snapshot_shot('h04_search')
    except Exception as e:
        report.fail(f'04: {e}')
    finally:
        back_home()


def test_05():
    report.begin('05 番剧入口')
    try:
        cold_start()
        dump_ui('h05_home')
        swipe_up(1800)
        time.sleep(0.6)
        t2 = load_ui_tree(dump_ui('h05_home2'))
        n = first_node(t2, lambda x: node_text(x).find('番剧') >= 0)
        if n:
            tap_bounds(node_bounds(n), 2500)
            t3 = load_ui_tree(dump_ui('h05_bangumi'))
            if len(all_texts(t3)) > 10:
                report.pass_('番剧有内容')
            else:
                report.fail('番剧空态')
            snapshot_shot('h05_bangumi')
        else:
            report.skip('无番剧入口')
    except Exception as e:
        report.fail(f'05: {e}')
    finally:
        back_home()


def test_06():
    report.begin('06 动态Tab')
    try:
        cold_start()
        t = load_ui_tree(dump_ui('h06_home'))
        n = first_node(t, lambda x: node_text(x) == '动态' and (parse_bounds(node_bounds(x)) or {}).get('y1', -1) > 2400)
        if n:
            tap_bounds(node_bounds(n), 1200)
        d2 = dump_ui('h06_dyn')
        t2 = load_ui_tree(d2)
        cnt = len(all_texts(t2))
        if cnt > 5:
            report.pass_(f'动态 N={cnt}')
        else:
            report.fail(f'动态 N={cnt}')
        snapshot_shot('h06_dyn')
        swipe_up(900)
        t3 = load_ui_tree(dump_ui('h06_dyn2'))
        if len(all_texts(t3)) > 5:
            report.pass_('动态滚动')
        else:
            report.fail('动态滚动异常')
    except Exception as e:
        report.fail(f'06: {e}')
    finally:
        back_home()


def test_07():
    report.begin('07 我的Tab及子项')
    try:
        cold_start()
        t = load_ui_tree(dump_ui('h07_home'))
        n = first_node(t, lambda x: node_text(x) == '我的' and (parse_bounds(node_bounds(x)) or {}).get('y1', -1) > 2400)
        if not n:
            n = first_node(t, lambda x: node_text(x) == '我的')
        if not n:
            report.fail('无我的Tab')
            return
        tap_bounds(node_bounds(n), 1200)
        t2 = load_ui_tree(dump_ui('h07_mine'))
        if has_text(t2, '我的追番'):
            report.pass_('我的追番入口')
        else:
            report.fail('我的追番入口缺失')
        if has_text(t2, '稍后再看'):
            report.pass_('稍后再看入口')
        else:
            report.fail('稍后再看入口缺失')
        if has_text(t2, '收藏'):
            report.pass_('收藏入口')
        else:
            report.fail('收藏入口缺失')
        snapshot_shot('h07_mine')
        # 收藏页
        n_fav = first_node(t2, lambda x: node_text(x) == '我的收藏' or node_text(x).startswith('我的收藏'))
        if not n_fav:
            n_fav = first_node(t2, lambda x: '收藏' in node_text(x))
        if n_fav:
            tap_bounds(node_bounds(n_fav), 1500)
            t3 = load_ui_tree(dump_ui('h07_fav'))
            if has_text(t3, '收藏'):
                report.pass_('收藏页打开')
            else:
                report.fail('收藏页未打开')
            snapshot_shot('h07_fav')
        else:
            report.skip('未找到收藏入口')
    except Exception as e:
        report.fail(f'07: {e}')
    finally:
        back_home()


def test_08():
    report.begin('08 深色模式(像素)')
    try:
        cold_start()
        d = dump_until_text('推荐', 20, 'h08_home')
        t = load_ui_tree(d)
        n = first_node(t, lambda x: node_text(x) == '我的' and (parse_bounds(node_bounds(x)) or {}).get('y1', -1) > 2400)
        if n:
            tap_bounds(node_bounds(n), 1200)
        t2 = load_ui_tree(dump_ui('h08_mine'))
        n_dark = first_node(t2, lambda x: node_text(x) == '深色')
        if not n_dark:
            swipe_up(900)
            t2 = load_ui_tree(dump_ui('h08_mine2'))
            n_dark = first_node(t2, lambda x: node_text(x) == '深色')
        if n_dark:
            tap_bounds(node_bounds(n_dark), 900)
            shot = snapshot_shot('h08_dark_on')
            # 像素判断交给 check_img.py（纯 Pillow，跨平台）
            import subprocess
            py = sys.executable
            p = subprocess.run([py, str(Path(__file__).parent / 'check_img.py'),
                                '--shot', str(shot), '--mode', 'bg'],
                               capture_output=True, text=True)
            import json
            try:
                data = json.loads(p.stdout)
                if data.get('checks', {}).get('is_dark'):
                    report.pass_(f"深色生效 {data['checks'].get('mid')}")
                else:
                    report.fail(f'深色未生效: {p.stdout}')
            except Exception as e:
                report.fail(f'像素检查失败: {e}')
            # 恢复浅色
            tap_bounds(node_bounds(n_dark), 900)
        else:
            report.skip('无显示模式入口')
    except Exception as e:
        report.fail(f'08: {e}')
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
    ensure_qa_dir()
    for fn in (test_01, test_02, test_03, test_04, test_05, test_06, test_07, test_08):
        fn()
    out = report.export()
    print(f'report: {out}')
    print(f'PASS={report.passed} FAIL={report.failed} SKIP={report.skipped}')
    sys.exit(1 if report.failed else 0)


if __name__ == '__main__':
    main()
