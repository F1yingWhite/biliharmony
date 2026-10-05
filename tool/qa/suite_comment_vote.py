#!/usr/bin/env python3
"""Real-device comment poll regression; public reads and local choices only, never POST a vote."""
import math
import re
import sys
import time
import traceback

import qa_common as q


def visible(node):
    return node.get('attributes', {}).get('visible') == 'true'


def text_node(tree, value):
    return q.first_node(tree, lambda node: visible(node) and q.node_text(node) == value)


def option_button(tree, label):
    return q.first_node(tree, lambda node: visible(node) and q.node_type(node) == 'Button' and
                        node.get('attributes', {}).get('description') == label)


def wait_tree(name, predicate, timeout=15):
    deadline = time.monotonic() + timeout
    tree = None
    while time.monotonic() < deadline:
        tree = q.load_ui_tree(q.dump_ui(name))
        if predicate(tree):
            return tree
        time.sleep(0.5)
    raise AssertionError(name + ': expected live UI state was absent; last texts=' + repr(q.all_texts(tree)))


def open_comments(bvid, name):
    q.stop_app()
    q.device().run(['shell', 'aa', 'start', '-a', 'EntryAbility', '-b', q.APP_ID, '--ps', 'bvid', bvid])
    tree = wait_tree(name + '_video', lambda tree: any(re.fullmatch(r'评论 [0-9万.]+', q.node_text(n))
                                                    for n in q.walk(tree)))
    tabs = [node for node in q.walk(tree) if visible(node) and re.fullmatch(r'评论 [0-9万.]+', q.node_text(node))]
    tab = min(tabs, key=lambda node: (q.parse_bounds(q.node_bounds(node)) or {}).get('y1', 99999))
    q.tap_bounds(q.node_bounds(tab), 600)


def require_real_detail(tree):
    # Merely showing metadata options and drawing ratios is not proof of a loaded detail.
    # This check reproduces the native @Builder snapshot bug that whole-build mocks missed.
    return text_node(tree, '重新加载投票') is None and text_node(tree, '投票信息加载失败，请重试') is None and \
        text_node(tree, '加载投票…') is None


def snapshot(name):
    q.dump_ui(name)
    return q.snapshot_shot(name)


def tap_current_text(name, value):
    # Playback can finish while taking a screenshot and move the comment pane.
    # Resolve bounds immediately before clicking rather than reusing an old dump.
    tree = q.load_ui_tree(q.dump_ui(name + '_before_click'))
    button = text_node(tree, value)
    assert button is not None, 'Missing visible action: ' + value
    q.tap_bounds(q.node_bounds(button), 400)


def test_header(report):
    report.begin('顶部投票：完成真实详情加载、第二答案选择、查看及刷新比例')
    open_comments('BV1r6QcBvEqt', 'vote_header')
    tree = wait_tree('vote_header_loaded', lambda tree: text_node(tree, '需不需要再额外补充设定呢') is not None and
                     option_button(tree, '目前够吃啦～') is not None and require_real_detail(tree))
    first, second = option_button(tree, '更多更多！'), option_button(tree, '目前够吃啦～')
    assert first is not None and first['attributes']['enabled'] == 'true'
    assert second['attributes']['enabled'] == 'true'
    q.tap_bounds(q.node_bounds(second), 400)
    tree = wait_tree('vote_header_second_selected', lambda tree: '●' in q.all_texts(option_button(tree, '目前够吃啦～') or {}))
    assert '●' not in q.all_texts(option_button(tree, '更多更多！'))
    snapshot('vote_header_second_selected')
    tap_current_text('vote_header_results', '查看结果')
    tree = wait_tree('vote_header_results', lambda tree: text_node(tree, '刷新结果') is not None and
                     len(q.find_nodes(tree, lambda node: q.node_type(node) == 'Progress')) == 2)
    for node in q.find_nodes(tree, lambda node: q.node_type(node) == 'Progress'):
        percent = float(q.node_text(node))
        assert math.isfinite(percent) and 0 <= percent <= 100
    tap_current_text('vote_header_refresh', '刷新结果')
    tree = wait_tree('vote_header_refreshed', lambda tree: require_real_detail(tree) and text_node(tree, '刷新结果') is not None)
    assert '●' in q.all_texts(option_button(tree, '目前够吃啦～'))
    report.pass_(str(snapshot('vote_header_refreshed')) + '；未点击提交投票')


def test_attachment(report, bvid, title, labels, choice_hint, name):
    report.begin(name + '：已结束附件投票，真实选项、限制与结果随详情更新')
    open_comments(bvid, name)
    tree = wait_tree(name + '_loaded', lambda tree: text_node(tree, title) is not None and
                     text_node(tree, '投票已结束') is not None and require_real_detail(tree))
    seen = set()
    progress_seen = False
    for attempt in range(10):
        progress_seen = progress_seen or bool(q.find_nodes(tree, lambda node: q.node_type(node) == 'Progress'))
        for label in labels:
            button = option_button(tree, label)
            if button is not None:
                seen.add(label)
                assert button['attributes']['enabled'] == 'false'
        if seen == set(labels):
            break
        # Derive gestures from the actual emulator bounds, not a fixed screenshot resolution.
        size = q.root_size(tree)
        width, height = size
        q.swipe(width // 2, int(height * 0.80), width // 2, int(height * 0.45), 700, 400)
        tree = q.load_ui_tree(q.dump_ui(name + '_scroll_' + str(attempt)))
    assert seen == set(labels), 'Missing actual answer(s): ' + repr(set(labels) - seen)
    # The title/hint may have scrolled away; its initial detail capture must retain them.
    loaded = q.load_ui_tree(q.QA_DIR / (name + '_loaded.json'))
    assert any(choice_hint in value for value in q.all_texts(loaded)), q.all_texts(loaded)
    assert text_node(loaded, '提交投票') is None
    assert progress_seen, 'Ended poll never rendered actual result bars while scrolling through its answers'
    report.pass_(str(snapshot(name + '_verified')) + '；未执行任何提交')


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--header-only', action='store_true')
    args = parser.parse_args()
    q.connect()
    q.keep_awake()
    report = q.QaReport('评论投票虚拟机回归（真实应用、无实际投票）')
    tests = [lambda: test_header(report)]
    if not args.header_only:
        tests.extend([
            lambda: test_attachment(report, 'BV16b421H7WG', '大家觉得最像雀豪的玩家是？',
                                    [str(index) + '号' for index in range(1, 8)], '单选', 'vote_seven'),
            lambda: test_attachment(report, 'BV1zrMizzERZ', '王麻子VS韩老魔，不知各位道友更喜欢谁？',
                                    ['王麻子', '韩老魔'], '最多选 2 项', 'vote_multi'),
        ])
    for run in tests:
        try:
            run()
        except Exception as error:
            last = traceback.extract_tb(error.__traceback__)[-1]
            report.fail(type(error).__name__ + ': ' + str(error) + ' (' + last.name + ':' + str(last.lineno) + ')')
    path = report.export('comment_vote_vm_report.md')
    print('report:', path)
    print('PASS=' + str(report.passed) + ' FAIL=' + str(report.failed))
    return 1 if report.failed else 0


if __name__ == '__main__':
    sys.exit(main())
