"""Pure library-page checks for QA; menu labels alone cannot prove navigation."""
from typing import Any, List, Optional

from qa_common import node_bounds, node_text, node_type, parse_bounds, root_size


LIBRARY_TITLES = {'历史': '历史记录', '稍后': '稍后再看'}


def visible_nodes(root: Any) -> List[Any]:
    """Respect hidden ancestors, including old destinations retained in dumps."""
    if isinstance(root, list):
        return [node for child in root for node in visible_nodes(child)]
    if not isinstance(root, dict):
        return []
    attrs = root.get('attributes', {})
    if attrs.get('visible') in (False, 'false'):
        return []
    try:
        if float(attrs.get('opacity', 1)) <= 0:
            return []
    except (TypeError, ValueError):
        pass
    return [root] + [node for child in root.get('children', []) for node in visible_nodes(child)]


def first_visible_text(root: Any, text: str) -> Optional[Any]:
    return next((node for node in visible_nodes(root) if node_text(node) == text), None)


def page_header_title(root: Any) -> str:
    _, height = root_size(root)
    if height <= 0:
        return ''
    # PageHeader is a top Row containing the shared BackButton text "‹" and
    # its title. Mine menu rows share the title text but contain no BackButton.
    titles = set()
    for row in visible_nodes(root):
        bounds = parse_bounds(node_bounds(row))
        if node_type(row) != 'Row' or not bounds or bounds['y2'] > height * 0.25:
            continue
        children = visible_nodes(row)
        if not any(node_text(node) == '‹' for node in children):
            continue
        title = next((node_text(node) for node in children
                      if node_type(node) == 'Text' and node_text(node) not in ('', '‹')), '')
        if title:
            titles.add(title)
    # A covered old destination may still have visible=true in a dump. Multiple
    # competing page headers cannot prove which destination is in front.
    return next(iter(titles)) if len(titles) == 1 else ''


def require_library_destination(root: Any, label: str) -> None:
    expected = LIBRARY_TITLES[label]
    if any(node_type(node) in ('Dialog', 'AlertDialog') for node in visible_nodes(root)):
        raise RuntimeError(f'目标页被弹窗遮挡，未确认{expected}')
    actual = page_header_title(root)
    if actual != expected:
        raise RuntimeError(f'预期{expected}，当前页头为{actual or "未找到"}')
