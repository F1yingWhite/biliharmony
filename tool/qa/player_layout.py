"""Pure selectors for player QA, including occluding settings and dialogs.

ArkUI dumps keep the player controls beneath a drawer. A text match alone is
therefore insufficient: actions must be scoped to the currently visible mode.
"""
import re
from typing import Any, Callable, List, Optional

from qa_common import find_nodes, first_node, node_bounds, node_text, node_type, parse_bounds


QUALITY_LABEL = re.compile(r'^(8K|杜比视界|HDR|4K|1080P60|1080P\+|1080P 高码率|1080P|720P60|720P|480P|360P|智能修复|自动)$')


def visible(node: Any) -> bool:
    attrs = node.get('attributes', {})
    bounds = parse_bounds(node_bounds(node))
    return bool(bounds and bounds['x2'] > bounds['x1'] and bounds['y2'] > bounds['y1'] and
                attrs.get('visible') != 'false' and attrs.get('opacity') not in ('0', '0.000000'))


def text_node(root: Any, text: str) -> Optional[Any]:
    return first_node(root, lambda n: visible(n) and node_text(n) == text)


def node_path(root: Any, predicate: Callable[[Any], bool]) -> List[Any]:
    if not isinstance(root, dict):
        return []
    if predicate(root):
        return [root]
    for child in root.get('children', []):
        found = node_path(child, predicate)
        if found:
            return [root] + found
    return []


def settings_panel(root: Any) -> Optional[Any]:
    path = node_path(root, lambda n: visible(n) and node_text(n) == '返回')
    # The shared settings content owns a Back row and the page below it. Stop
    # before a page/window ancestor can also include underlying player controls.
    for ancestor in reversed(path[:-1]):
        if node_type(ancestor) != 'Column':
            continue
        if any(text_node(ancestor, title) for title in ('清晰度', '弹幕密度', '倍速播放')):
            return ancestor
    return None


def mode(root: Any) -> str:
    if first_node(root, lambda n: visible(n) and node_type(n) == 'Dialog'):
        return 'dialog'
    panel = settings_panel(root)
    if panel is not None:
        if text_node(panel, '清晰度'):
            return 'quality'
        if text_node(panel, '弹幕密度'):
            return 'danmaku'
        return 'settings'
    if text_node(root, '小窗播放') and text_node(root, '倍速播放'):
        return 'menu'
    if text_node(root, '重播'):
        return 'ended'
    if first_node(root, lambda n: visible(n) and node_type(n) == 'XComponent'):
        return 'player'
    return 'outside-player'


def require_player(root: Any) -> None:
    current = mode(root)
    if current != 'player':
        raise RuntimeError(f'播放器控件被遮挡或当前不在播放界面: {current}')


def panel_back(root: Any) -> Any:
    if mode(root) not in ('quality', 'danmaku', 'settings'):
        raise RuntimeError(f'当前没有可关闭的设置子页: {mode(root)}')
    path = node_path(settings_panel(root), lambda n: visible(n) and node_text(n) == '返回')
    for ancestor in reversed(path[:-1]):
        if node_type(ancestor) == 'Row' and ancestor.get('attributes', {}).get('clickable') == 'true':
            return ancestor
    raise RuntimeError('设置页返回按钮没有可点击的父 Row')


def quality_options(root: Any) -> List[Any]:
    if mode(root) != 'quality':
        raise RuntimeError(f'当前不是清晰度面板: {mode(root)}')
    panel = settings_panel(root)
    path = node_path(panel, lambda n: visible(n) and node_text(n) == '清晰度')
    # PlayerSettingsPanel's heading and quality Flex are siblings. The download
    # preference chip below belongs to a different Column and must never match.
    for ancestor in reversed(path[:-1]):
        for child in ancestor.get('children', []):
            if node_type(child) == 'Flex':
                choices = [n for n in child.get('children', []) if visible(n) and
                           node_type(n) == 'Text' and QUALITY_LABEL.fullmatch(node_text(n))]
                if choices:
                    return choices
    raise RuntimeError('清晰度面板中找不到画质选项 Flex')


def footer_icons(root: Any, slider: Any, landscape: bool) -> List[Any]:
    require_player(root)
    track = parse_bounds(node_bounds(slider))
    if track is None:
        raise RuntimeError('进度 Slider 没有有效边界')
    icons = []
    for node in find_nodes(root, lambda n: visible(n) and node_type(n) == 'Image'):
        b = parse_bounds(node_bounds(node))
        if not b or b['x2']-b['x1'] > track['x2']-track['x1']:
            continue
        if landscape:
            belongs = b['y1'] >= track['y2']
        else:
            mid_y = (b['y1']+b['y2'])/2
            belongs = track['y1'] <= mid_y <= track['y2'] and (b['x2'] <= track['x1'] or b['x1'] >= track['x2'])
        if belongs:
            icons.append(node)
    return sorted(icons, key=lambda n: parse_bounds(node_bounds(n))['x1'])


def quality_button(root: Any, slider: Any) -> Any:
    require_player(root)
    track = parse_bounds(node_bounds(slider))
    found = first_node(root, lambda n: visible(n) and node_type(n) == 'Text' and
                       QUALITY_LABEL.fullmatch(node_text(n)) is not None and
                       parse_bounds(node_bounds(n))['y1'] >= track['y2'] and
                       n.get('attributes', {}).get('clickable') == 'true')
    if found is None:
        raise RuntimeError('横屏播放器底栏没有清晰度按钮')
    return found
