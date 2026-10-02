"""Offline regression tests for real ArkUI dump shapes; never invokes HDC."""
import unittest
from unittest.mock import patch

import player_layout as layout
import suite_player as suite
from qa_common import node_bounds, node_text


def node(kind, bounds, text='', children=None, **attrs):
    return {'attributes': {'type': kind, 'bounds': bounds, 'text': text,
                           'visible': 'true', 'opacity': '1.000000', **attrs},
            'children': children or []}


def player():
    # Bounds and ordering reproduced from supp_quality_changed.json. The slider
    # thumb is an Image too, and must not become a bottom action button.
    return node('root', '[0,0][2848,1320]', children=[
        node('XComponent', '[0,0][2848,1320]'),
        node('Image', '[0,0][2848,1320]'),
        node('Slider', '[147,1037][2702,1159]', '134.000000'),
        node('Image', '[1720,1074][1767,1121]'),
        node('Image', '[62,1194][146,1279]'),
        node('Image', '[217,1198][295,1276]'),
        node('Image', '[366,1201][437,1272]'),
        node('Text', '[2393,1190][2499,1283]', '4K', clickable='true'),
        node('Image', '[2710,1198][2788,1276]'),
    ])


def with_panel(kind='quality'):
    root = player()
    if kind == 'quality':
        content = [
            node('Column', '[1822,174][2794,562]', children=[
                node('Row', '[1876,214][2740,269]', children=[
                    node('Text', '[1876,214][2018,269]', '清晰度')]),
                node('Flex', '[1876,296][2740,522]', children=[
                    node('Text', '[1876,296][2007,389]', '4K', clickable='true'),
                    node('Text', '[2034,296][2277,389]', '1080P60', clickable='true'),
                    node('Text', '[2304,296][2501,389]', '1080P', clickable='true'),
                ]),
            ]),
            node('Column', '[1822,596][2794,1273]', children=[
                node('Text', '[1876,1095][2079,1154]', '下载画质'),
                node('Text', '[2490,1083][2683,1166]', '1080P'),
                node('Text', '[2507,1266][2683,1273]', '选择格式'),
            ]),
        ]
    else:
        content = [node('Column', '[1822,174][2794,1273]', children=[
            node('Text', '[1876,207][2740,270]', '弹幕设置'),
            node('Text', '[1923,364][2099,415]', '弹幕密度'),
            node('Text', '[2539,344][2693,435]', '重叠', clickable='true'),
            node('Text', '[1876,475][2740,540]', '尽量显示全部弹幕，允许相互重叠'),
        ])]
    root['children'].append(node('Column', '[1768,0][2848,1320]', children=[
        node('Column', '[1822,47][2794,1273]', children=[
            node('Row', '[1822,47][2794,174]', clickable='true', children=[
                node('Text', '[1957,71][2059,130]', '返回')]),
            node('Scroll', '[1822,174][2794,1273]', children=content),
        ])]))
    return root


def dialog():
    root = with_panel()
    root['children'].append(node('Dialog', '[0,0][2848,1320]', '选择下载内容'))
    return root


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.hdc = patch.object(suite, 'device', side_effect=AssertionError('offline test called HDC')).start()
        self.addCleanup(patch.stopall)

    def test_quality_chips_exclude_underlying_4k_and_download_1080p(self):
        options = layout.quality_options(with_panel())
        self.assertEqual([node_text(n) for n in options], ['4K', '1080P60', '1080P'])
        self.assertEqual(node_bounds(options[0]), '[1876,296][2007,389]')
        self.assertEqual(node_bounds(options[2]), '[2304,296][2501,389]')

    def test_bottom_label_alone_does_not_confirm_quality_panel(self):
        self.assertEqual(layout.mode(player()), 'player')
        with self.assertRaisesRegex(RuntimeError, '不是清晰度面板'):
            layout.quality_options(player())

    def test_occluding_drawer_blocks_underlying_controls(self):
        for kind in ['quality', 'danmaku']:
            root = with_panel(kind)
            self.assertEqual(layout.mode(root), kind)
            with self.assertRaisesRegex(RuntimeError, '遮挡'):
                suite.footer_icons(root)

    def test_native_dialog_wins_over_settings_mode(self):
        root = dialog()
        self.assertEqual(layout.mode(root), 'dialog')
        with self.assertRaisesRegex(RuntimeError, 'dialog'):
            layout.panel_back(root)
        with self.assertRaisesRegex(RuntimeError, 'dialog'):
            layout.quality_options(root)

    def test_footer_uses_icons_below_slider_not_its_thumb(self):
        icons = suite.footer_icons(player())
        self.assertEqual(len(icons), 4)
        self.assertEqual(node_bounds(icons[2]), '[366,1201][437,1272]')
        self.assertEqual(node_bounds(icons[-1]), '[2710,1198][2788,1276]')

    def test_portrait_footer_excludes_thumb_and_body_icons(self):
        root = node('root', '[0,0][1320,2848]', children=[
            node('XComponent', '[0,132][1320,874]'),
            node('Slider', '[269,725][1052,847]', '134'),
            node('Image', '[740,762][788,809]'),
            node('Image', '[47,748][122,823]'),
            node('Image', '[1198,748][1273,823]'),
            node('Image', '[1192,917][1267,991]'),
        ])
        self.assertEqual([node_bounds(n) for n in suite.footer_icons(root)],
                         ['[47,748][122,823]', '[1198,748][1273,823]'])

    def test_ended_screen_cannot_be_used_as_live_controls(self):
        root = player()
        root['children'].append(node('Text', '[1348,347][1429,394]', '重播'))
        self.assertEqual(layout.mode(root), 'ended')
        with self.assertRaisesRegex(RuntimeError, 'ended'):
            suite.footer_icons(root)

    def test_close_clicks_explicit_back_and_confirms_mode_and_orientation(self):
        with patch.object(suite, 'tap_bounds') as tap, patch.object(suite, 'wait_for_ui') as wait:
            wait.return_value = ('unused', player())
            self.assertEqual(suite.close_settings(with_panel(), 'closed'), player())
            tap.assert_called_once_with('[1822,47][2794,174]', 250)
            predicate = wait.call_args.args[0]
            self.assertFalse(predicate(with_panel()))
            self.assertFalse(predicate(dialog()))
            self.assertTrue(predicate(player()))
            portrait = node('root', '[0,0][1320,2848]', children=[node('XComponent', '[0,132][1320,874]')])
            self.assertFalse(predicate(portrait))

    def test_quality_auto_close_never_clicks_underlying_player(self):
        with patch.object(suite, 'tap_bounds') as tap, patch.object(suite, 'wait_for_ui') as wait:
            suite.close_settings(player(), 'closed')
            tap.assert_not_called()
            wait.assert_not_called()

    def test_failed_close_does_not_fall_back_to_mask_or_fullscreen(self):
        with patch.object(suite, 'tap_bounds') as tap, patch.object(suite, 'tap') as blind, \
                patch.object(suite, 'wait_for_ui', side_effect=RuntimeError('still open')):
            with self.assertRaisesRegex(RuntimeError, 'still open'):
                suite.close_settings(with_panel(), 'closed')
            tap.assert_called_once_with('[1822,47][2794,174]', 250)
            blind.assert_not_called()

    def test_dialog_close_is_rejected_before_any_click(self):
        with patch.object(suite, 'tap_bounds') as tap:
            with self.assertRaisesRegex(RuntimeError, 'dialog'):
                suite.close_settings(dialog(), 'closed')
            tap.assert_not_called()

    def test_open_retries_only_uncovered_player_not_other_overlay(self):
        with patch.object(suite, 'dump_ui', return_value='unused'), \
                patch.object(suite, 'load_ui_tree', side_effect=[player(), dialog()]), \
                patch.object(suite, 'show_controls', return_value=player()), \
                patch.object(suite, 'tap_bounds') as tap, \
                patch.object(suite, 'wait_for_ui', side_effect=RuntimeError('wrong mode')):
            with self.assertRaisesRegex(RuntimeError, 'wrong mode'):
                suite.open_panel('quality', lambda t: layout.quality_button(t, suite.largest_node(t, 'Slider')), 'panel')
            tap.assert_called_once_with('[2393,1190][2499,1283]', 250)

    def test_full_quality_flow_clicks_only_density_and_real_quality_chip(self):
        with patch.object(suite, 'set_playing', return_value=player()), \
                patch.object(suite, 'open_panel', side_effect=[with_panel('danmaku'), with_panel()]), \
                patch.object(suite, 'tap_bounds') as tap, \
                patch.object(suite, 'wait_for_ui', side_effect=[('unused', with_panel('danmaku')), ('unused', player())]), \
                patch.object(suite, 'close_settings', return_value=player()), \
                patch.object(suite, 'dump_ui', return_value='unused'), \
                patch.object(suite, 'load_ui_tree', return_value=player()), \
                patch.object(suite, 'show_controls', return_value=player()), \
                patch.object(suite, 'report'):
            suite.set_highest_quality_and_density(player())
            self.assertEqual([call.args[0] for call in tap.call_args_list],
                             ['[2539,344][2693,435]', '[1876,296][2007,389]'])


if __name__ == '__main__':
    unittest.main()
