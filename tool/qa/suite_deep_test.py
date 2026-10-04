"""Offline checks for D6 destination verification; never starts HDC."""
import unittest
from unittest.mock import patch

import qa_common
import suite_deep as suite


def node(kind, text='', bounds='[0,0][1320,2848]', children=None, **attrs):
    return {'attributes': {'type': kind, 'text': text, 'bounds': bounds,
                           'visible': 'true', 'opacity': '1.000000', **attrs},
            'children': children or []}


def mine(labels=('历史记录', '稍后再看')):
    return node('root', children=[
        node('Text', '我的', '[500,2500][700,2640]'),
        *[node('Row', bounds=f'[20,{650 + i * 180}][1300,{800 + i * 180}]', children=[
            node('Text', label, f'[180,{680 + i * 180}][800,{760 + i * 180}]')])
          for i, label in enumerate(labels)],
    ])


def page(title, content='视频标题'):
    return node('root', children=[
        node('Row', bounds='[0,130][1320,280]', children=[
            node('Row', bounds='[24,130][120,280]', children=[node('Text', '‹', '[35,160][85,245]')]),
            node('Text', title, '[160,170][980,240]'),
        ]),
        node('Text', content, '[40,500][1280,620]'),
    ])


class LibraryNavigationTests(unittest.TestCase):
    def run_d6(self, history=None, later=None, menu=None, back=None, home=None):
        report = qa_common.QaReport('offline D6')
        menu = menu if menu is not None else mine()
        back = back if back is not None else menu
        dumps = {'d6_home': home if home is not None else mine(), 'd6_mine': menu,
                 'd6_历史': history if history is not None else page('历史记录'),
                 'd6_稍后': later if later is not None else page('稍后再看'),
                 'd6_back': back}
        reads = {'d6_mine': 0}

        def dump(name):
            if name == 'd6_mine':
                reads[name] += 1
                return menu if reads[name] == 1 else back
            return dumps[name]

        with patch.object(suite, 'report', report), patch.object(suite, 'cold_start'), \
                patch.object(suite, 'back_home'), patch.object(suite, 'dump_ui', side_effect=dump), \
                patch.object(suite, 'load_ui_tree', side_effect=lambda tree: tree), \
                patch.object(suite, 'tap_bounds'), patch.object(suite, 'snapshot_shot'), \
                patch.object(suite, 'key_back'), patch.object(suite.time, 'sleep'), \
                patch.object(qa_common, 'device', side_effect=AssertionError('offline test called HDC')):
            suite.test_d6()
        return report

    def assert_history_not_passed(self, destination):
        report = self.run_d6(history=destination)
        self.assertFalse(any('PASS ' in line and '历史 打开' in line for line in report.lines), report.lines)
        self.assertTrue(any('FAIL ' in line and '历史' in line for line in report.lines), report.lines)

    def test_staying_on_home_does_not_count_as_history_success(self):
        self.assert_history_not_passed(node('root', children=[node('Text', '推荐'), node('Text', '热门')]))

    def test_mine_menu_text_does_not_count_as_target_page(self):
        self.assert_history_not_passed(mine())

    def test_login_page_does_not_count_as_history_success(self):
        self.assert_history_not_passed(page('登录', '扫码登录'))

    def test_wrong_library_destination_does_not_count_as_history_success(self):
        self.assert_history_not_passed(page('稍后再看'))

    def test_history_page_does_not_count_as_watch_later_success(self):
        report = self.run_d6(later=page('历史记录'))
        self.assertFalse(any('PASS ' in line and '稍后 打开' in line for line in report.lines), report.lines)
        self.assertTrue(any('FAIL ' in line and '稍后' in line for line in report.lines), report.lines)

    def test_expected_header_accepts_populated_and_empty_pages(self):
        report = self.run_d6(history=page('历史记录', '暂无观看历史'),
                             later=page('稍后再看', '暂无稍后再看内容'))
        self.assertTrue(any('PASS ' in line and '历史 打开' in line for line in report.lines), report.lines)
        self.assertTrue(any('PASS ' in line and '稍后 打开' in line for line in report.lines), report.lines)

    def test_hidden_target_header_cannot_validate_login_page(self):
        root = page('登录')
        root['children'].append(node('Column', children=page('历史记录')['children'], visible='false'))
        self.assert_history_not_passed(root)

    def test_retained_target_header_cannot_validate_a_covering_login_page(self):
        root = node('root', children=[page('历史记录'), page('登录')])
        self.assert_history_not_passed(root)

    def test_dialog_over_target_page_does_not_count_as_navigation_success(self):
        root = page('历史记录')
        root['children'].append(node('Dialog', '请先登录'))
        self.assert_history_not_passed(root)

    def test_missing_entries_are_explicitly_skipped(self):
        report = self.run_d6(menu=mine(labels=()))
        for label in ('历史', '稍后'):
            self.assertTrue(any('SKIP ' in line and label in line and '入口' in line for line in report.lines), report.lines)

    def test_missing_mine_tab_is_a_failure(self):
        report = self.run_d6(home=node('root', children=[node('Text', '推荐')]))
        self.assertEqual(report.passed, 0)
        self.assertTrue(any('FAIL ' in line and '我的入口' in line for line in report.lines), report.lines)

    def test_each_entry_is_selected_from_the_refreshed_mine_tree(self):
        report = self.run_d6(back=mine(labels=('历史记录',)))
        self.assertFalse(any('PASS ' in line and '稍后 打开' in line for line in report.lines), report.lines)
        self.assertTrue(any('SKIP ' in line and '稍后' in line for line in report.lines), report.lines)


if __name__ == '__main__':
    unittest.main()
