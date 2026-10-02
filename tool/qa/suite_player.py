#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""播放器专项真机回归。

覆盖用户最容易感知且历史上出现过回归的链路：高画质/高密度弹幕、拖动预览收起、
横竖屏动画、旋转后 Surface/Canvas 几何、播完返回、重播及播放期性能。
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from animation_probe import analyze as analyze_animation
from performance_probe import collect as collect_performance
import player_layout as layout
from qa_common import (
    QA_DIR, ROOT, QaReport, all_texts, capture_transition, cold_start, connect,
    device, dump_ui, dump_until_text, ensure_qa_dir, find_nodes, first_node,
    has_text, input_text, load_ui_tree, node_bounds, node_text, node_type,
    node_id, parse_bounds, root_size, snapshot_shot, swipe, tap, tap_bounds, wait_for_ui,
)


TITLE_RE = r'4K\s*60FPS|Bad\s*apple'
PREVIEW_RE = re.compile(r'\d{1,3}:\d{2}\s*/\s*\d{1,3}:\d{2}')
report = QaReport('BiliHarmony 播放器动画/交互/性能专项')


def largest_node(root: Any, kind: str) -> Optional[Any]:
    nodes = find_nodes(root, lambda n: node_type(n) == kind and parse_bounds(node_bounds(n)) is not None)
    if not nodes:
        return None
    return max(nodes, key=lambda n: area(parse_bounds(node_bounds(n))))


def area(bounds: Optional[Dict[str, int]]) -> int:
    if not bounds:
        return 0
    return max(0, bounds['x2'] - bounds['x1']) * max(0, bounds['y2'] - bounds['y1'])


def center(bounds: Dict[str, int]) -> Tuple[int, int]:
    return (bounds['x1'] + bounds['x2']) // 2, (bounds['y1'] + bounds['y2']) // 2


def player_geometry(root: Any) -> Tuple[Optional[Dict[str, int]], Optional[Dict[str, int]]]:
    surface = largest_node(root, 'XComponent')
    canvas = largest_node(root, 'Canvas')
    if canvas is None:
        # Canvas 本体在部分系统无障碍树中会被裁掉；其唯一直接父层与 Canvas 同尺寸且承担 clip，
        # 用稳定 id 读取该真实弹幕视口几何。
        canvas = first_node(root, lambda n: node_id(n) == 'qa_player_danmaku_viewport')
    return (
        parse_bounds(node_bounds(surface)) if surface else None,
        parse_bounds(node_bounds(canvas)) if canvas else None,
    )


def bounds_close(left: Optional[Dict[str, int]], right: Optional[Dict[str, int]], tolerance: int = 4) -> bool:
    if not left or not right:
        return False
    return all(abs(left[key] - right[key]) <= tolerance for key in ('x1', 'y1', 'x2', 'y2'))


def is_orientation(root: Any, landscape: bool) -> bool:
    width, height = root_size(root)
    return width > height if landscape else height > width


def video_surface_ready(root: Any) -> bool:
    surface, _ = player_geometry(root)
    # 部分系统版本即使 Canvas 有测试 id，uitest 仍会省略无障碍树中的 Canvas；
    # 场景准备只以真实 XComponent 为准，Canvas 几何在支持导出的设备上单独断言。
    return bool(surface and area(surface) > 100000)


def open_search() -> Any:
    path = dump_until_text('推荐', 25, 'p00_home')
    tree = load_ui_tree(path)
    candidate = first_node(tree, lambda n: (
        node_type(n) == 'TextInput' or
        node_text(n) in ('搜索你感兴趣的内容', '搜索')
    ) and (parse_bounds(node_bounds(n)) or {}).get('y1', 9999) < 420)
    if candidate:
        tap_bounds(node_bounds(candidate), 1200)
    else:
        tap(660, 200, 1200)
    _, search_tree = wait_for_ui(
        lambda t: largest_node(t, 'TextInput') is not None or has_text(t, '搜索历史') or has_text(t, '热搜'),
        timeout=12, name='p00_search')
    return search_tree


def submit_search(tree: Any, query: str) -> Any:
    history = first_node(tree, lambda n: query.lower() in node_text(n).replace(' ', '').lower())
    if history:
        tap_bounds(node_bounds(history), 900)
    else:
        field = largest_node(tree, 'TextInput')
        if not field:
            raise RuntimeError('搜索页找不到 TextInput')
        x, y = center(parse_bounds(node_bounds(field)) or {'x1': 100, 'y1': 100, 'x2': 900, 'y2': 220})
        input_text(x, y, query, 350)
        latest = load_ui_tree(dump_ui('p00_search_typed'))
        search_button = first_node(latest, lambda n: (
            node_text(n) == '搜索' and (parse_bounds(node_bounds(n)) or {}).get('y1', 9999) < 420
        ))
        if search_button:
            tap_bounds(node_bounds(search_button), 900)
        else:
            # 输入框右侧搜索按钮兜底。
            width, _ = root_size(latest)
            tap(max(100, width - 100), y, 900)
    _, result = wait_for_ui(lambda t: has_text(t, TITLE_RE), timeout=30, name='p00_results')
    return result


def open_dense_4k_video(query: str) -> Any:
    cold_start()
    tree = submit_search(open_search(), query)
    target = first_node(tree, lambda n: re.search(r'4K\s*60FPS', node_text(n), re.I) is not None)
    if not target:
        target = first_node(tree, lambda n: re.search(TITLE_RE, node_text(n), re.I) is not None)
    if not target:
        raise RuntimeError('搜索结果中没有目标高画质视频')
    tap_bounds(node_bounds(target), 1800)
    _, detail = wait_for_ui(
        lambda t: video_surface_ready(t) and (has_text(t, '评论') or has_text(t, '简介')),
        timeout=35, name='p00_detail')
    # 给 DASH 音视频轨和弹幕 XML/API 留出加载时间。
    time.sleep(6)
    detail = load_ui_tree(dump_ui('p00_player_ready'))
    # QA 设备保留观看历史；上次已播完时必须显式重播，避免把暂停态的
    # seek/画质切换误当成播放中，并在结尾用例中等待永远不会发生的 completed。
    replay = first_node(detail, lambda n: node_text(n) == '重播')
    if replay:
        tap_bounds(node_bounds(replay), 1800)
        _, detail = wait_for_ui(
            lambda t: video_surface_ready(t) and not has_text(t, '^重播$'),
            timeout=15, name='p00_replay_started')
    snapshot_shot('p00_player_ready')
    return detail


def show_controls(root: Any, wait_ms: int = 350) -> Any:
    # 播放时控件会自动隐藏；调用方的树可能来自截图/性能采样之前，
    # 不能把旧 Slider 当成此刻仍可点击的控件。
    root = load_ui_tree(dump_ui('p_controls_current'))
    layout.require_player(root)
    if largest_slider(root) is not None:
        return root
    surface, _ = player_geometry(root)
    if not surface:
        raise RuntimeError('找不到播放器 Surface')
    # 高密度弹幕下点画面中心可能命中弹幕并弹出操作气泡，控制条不会显示。
    # 优先点字幕/进度条安全区，逐次验证 Slider，不能再把一次盲点当成成功。
    points = [
        ((surface['x1'] + surface['x2']) // 2, surface['y2'] - 28),
        (surface['x1'] + 32, surface['y2'] - 28),
        center(surface),
    ]
    latest = root
    for index, (x, y) in enumerate(points):
        tap(x, y, wait_ms)
        latest = load_ui_tree(dump_ui(f'p_controls_{index}'))
        layout.require_player(latest)
        if largest_slider(latest) is not None:
            return latest
    raise RuntimeError('连续三次点击后播放器控制条仍未显示')


def largest_slider(root: Any) -> Optional[Dict[str, int]]:
    node = largest_node(root, 'Slider')
    return parse_bounds(node_bounds(node)) if node else None


def preview_texts(root: Any) -> List[str]:
    return [text for text in all_texts(root) if PREVIEW_RE.search(text)]


def footer_icons(root: Any) -> List[Any]:
    slider = largest_node(root, 'Slider')
    if slider is None:
        raise RuntimeError('播放器控制条没有进度 Slider')
    icons = layout.footer_icons(root, slider, is_orientation(root, True))
    if len(icons) < 2:
        raise RuntimeError('播放器底栏缺少播放/全屏图标')
    return icons


def playback_sample(name: str) -> Tuple[float, float, Any]:
    first = show_controls(load_ui_tree(dump_ui(name + '_before')))
    before = float(node_text(largest_node(first, 'Slider')))
    time.sleep(1.2)
    last = show_controls(load_ui_tree(dump_ui(name + '_after')))
    after = float(node_text(largest_node(last, 'Slider')))
    return before, after, last


def set_playing(playing: bool, name: str) -> Any:
    # 在设置/动画阶段暂停，防止 3 秒控件隐藏或视频自然播完改变操作目标。
    # 用实际进度验证状态，不依赖无障碍树未暴露的图片资源名称。
    for attempt in range(3):
        before, after, current = playback_sample(f'{name}_{attempt}')
        if (after - before > 0.3) == playing:
            return current
        tap_bounds(node_bounds(footer_icons(current)[0]), 300)
    before, after, current = playback_sample(name + '_confirmed')
    if (after - before > 0.3) != playing:
        raise RuntimeError(f'无法确认播放器{"播放" if playing else "暂停"}状态: {before} -> {after}')
    return current


def close_settings(root: Any, name: str) -> Any:
    if layout.mode(root) == 'player':
        return root  # 选择可用画质时生产回调会主动关闭面板。
    orientation = is_orientation(root, True)
    back = layout.panel_back(root)
    tap_bounds(node_bounds(back), 250)
    _, closed = wait_for_ui(
        lambda t: layout.mode(t) == 'player' and is_orientation(t, orientation),
        timeout=6, name=name)
    return closed


def open_panel(kind: str, locate: Callable[[Any], Any], name: str) -> Any:
    for attempt in range(3):
        current = show_controls(load_ui_tree(dump_ui(name + '_before')))
        if not is_orientation(current, True):
            raise RuntimeError(f'打开 {kind} 设置前不是横屏')
        tap_bounds(node_bounds(locate(current)), 250)
        try:
            _, panel = wait_for_ui(lambda t: layout.mode(t) == kind, timeout=4, name=name)
            return panel
        except RuntimeError:
            current = load_ui_tree(dump_ui(name + '_missed'))
            # 仅控件自动隐藏导致点击未命中时重试；不穿过其它抽屉或对话框继续点。
            if layout.mode(current) != 'player' or attempt == 2:
                raise
    raise RuntimeError(f'无法打开 {kind} 设置')


def enter_fullscreen(root: Any) -> Any:
    # dumpLayout/file recv 与原生点击之间，3 秒自动隐藏计时仍会继续；
    # 有限次重新获取控件后点击，并始终用实际窗口方向确认操作生效。
    for attempt in range(3):
        controlled = show_controls(root)
        if is_orientation(controlled, True):
            return controlled
        tap_bounds(node_bounds(footer_icons(controlled)[-1]), 150)
        try:
            _, landscape = wait_for_ui(lambda t: is_orientation(t, True), timeout=3, name='p_fullscreen')
            time.sleep(0.8)
            return landscape
        except RuntimeError:
            if attempt == 2:
                raise
    raise RuntimeError('点击全屏控件后窗口始终未横屏')


def set_highest_quality_and_density(root: Any) -> Any:
    set_playing(False, 'p_settings_paused')

    def danmaku_button(current: Any) -> Any:
        icons = footer_icons(current)
        if len(icons) < 4:
            raise RuntimeError('横屏底栏缺少播放、弹幕、设置、全屏图标')
        return icons[2]

    settings = open_panel('danmaku', danmaku_button, 'p_dense_settings')
    dense = layout.text_node(layout.settings_panel(settings), '重叠')
    if dense is None:
        raise RuntimeError('弹幕设置没有“重叠”密度选项')
    tap_bounds(node_bounds(dense), 300)
    _, settings = wait_for_ui(
        lambda t: layout.mode(t) == 'danmaku' and has_text(layout.settings_panel(t), '尽量显示全部弹幕'),
        timeout=5, name='p_density_confirmed')
    report.pass_('弹幕密度已确认切到“重叠”(30)')
    close_settings(settings, 'p_density_closed')

    panel = open_panel('quality', lambda t: layout.quality_button(t, largest_node(t, 'Slider')), 'p_quality_panel')
    options = layout.quality_options(panel)
    choices = ['8K', '杜比视界', 'HDR', '4K', '1080P60', '1080P+', '1080P 高码率', '1080P']
    chosen = next((option for label in choices for option in options if node_text(option) == label), None)
    if chosen is None:
        close_settings(panel, 'p_quality_closed')
        report.skip('片源画质选项未提供 1080P 或以上；设置抽屉已关闭')
    else:
        label = node_text(chosen)
        tap_bounds(node_bounds(chosen), 250)
        # changeQuality 成功后会关闭子页；不能用固定延时把仍在请求中的
        # 面板当成播放器，更不能在它覆盖着底栏时点击底层同名标签。
        _, settled = wait_for_ui(
            lambda t: layout.mode(t) == 'player' and not has_text(t, '^切换中$'),
            timeout=15, name='p_quality_after')
        close_settings(settled, 'p_quality_closed')
        controlled = show_controls(load_ui_tree(dump_ui('p_quality_selected')))
        actual = node_text(layout.quality_button(controlled, largest_node(controlled, 'Slider')))
        if actual != label:
            raise RuntimeError(f'选择画质后未生效: 请求 {label}，实际 {actual}')
        report.pass_(f'已确认最高可见画质: {actual}')
    report.note('本专项选择的密度和手动画质会持久化；完成后按验收前记录恢复偏好。')
    return set_playing(True, 'p_dense_playing')


def test_initial_geometry_and_seek(tree: Any) -> None:
    report.begin('P1 竖屏播放区与拖动预览生命周期')
    surface, canvas = player_geometry(tree)
    if canvas is None:
        report.skip(f'当前系统 UI dump 不导出 Canvas；Surface={surface}')
    elif bounds_close(surface, canvas):
        report.pass_(f'Surface/Canvas 对齐 {surface}')
    else:
        report.fail(f'Surface={surface} Canvas={canvas}')
    controlled = show_controls(tree)
    slider = largest_slider(controlled)
    if not slider:
        report.fail('找不到播放进度 Slider')
        return
    y = (slider['y1'] + slider['y2']) // 2
    width = slider['x2'] - slider['x1']
    swipe(slider['x1'] + int(width * 0.25), y, slider['x1'] + int(width * 0.45), y, 700, 1200)
    after = load_ui_tree(dump_ui('p01_slider_release'))
    stale = preview_texts(after)
    if stale:
        report.fail(f'Slider 松手后预览未消失: {stale}')
    else:
        report.pass_('Slider 松手后中间预览已消失')
    # 再覆盖播放器画面横向拖动路径；之前两条路径的清理逻辑不同，必须分别回归。
    surface, _ = player_geometry(after)
    if surface:
        cy = (surface['y1'] + surface['y2']) // 2
        swipe(surface['x1'] + int((surface['x2'] - surface['x1']) * 0.35), cy,
              surface['x1'] + int((surface['x2'] - surface['x1']) * 0.55), cy, 700, 1200)
        gesture_after = load_ui_tree(dump_ui('p01_gesture_release'))
        stale = preview_texts(gesture_after)
        if stale:
            report.fail(f'画面拖动松手后预览未消失: {stale}')
        else:
            report.pass_('画面拖动松手后中间预览已消失')
    snapshot_shot('p01_seek_done')


def test_dense_playback_performance(tree: Any, seconds: int, skip_performance: bool) -> Any:
    report.begin('P2 高画质+高弹幕密度播放性能')
    prepared = set_highest_quality_and_density(tree)
    surface, canvas = player_geometry(prepared)
    if canvas is None:
        report.skip(f'当前系统 UI dump 不导出横屏 Canvas；Surface={surface}')
    elif bounds_close(surface, canvas, 6):
        report.pass_(f'横屏 Surface/Canvas 对齐 {surface}')
    else:
        report.fail(f'横屏 Surface={surface} Canvas={canvas}')
    if skip_performance:
        report.skip('命令行要求跳过 SmartPerf')
        return prepared
    try:
        perf = collect_performance(seconds, prefix='p02_dense_4k')
        count = perf.get('sample_count', 0)
        if count >= max(2, seconds - 2):
            report.pass_(f'SmartPerf 样本 {count}')
        else:
            report.fail(f'SmartPerf 样本不足 {count}')
        fps = perf.get('fps')
        pss = perf.get('pss_kb')
        cpu = perf.get('cpu_usage')
        if fps:
            report.pass_(f"FPS mean={fps['mean']:.1f} min={fps['min']:.1f} p95={fps['p95']:.1f}")
        else:
            report.skip('当前虚拟机 RenderService 未向 SmartPerf 暴露应用 FPS；CPU/PSS 原始样本已保留')
        if pss:
            report.note(f"PSS mean={pss['mean'] / 1024:.1f}MB max={pss['max'] / 1024:.1f}MB")
        if cpu:
            report.note(f"CPU mean={cpu['mean']:.3f} max={cpu['max']:.3f}")
    except Exception as exc:
        report.fail(f'SmartPerf 采集失败: {exc}')
    snapshot_shot('p02_dense_4k')
    return load_ui_tree(dump_ui('p02_after_perf'))


def test_fullscreen_exit_animation(tree: Any) -> Any:
    report.begin('P3 全屏退出旋转/缩小动画与最终几何')
    controlled = set_playing(False, 'p03_pause_for_capture')
    width, height = root_size(controlled)
    if width <= height:
        report.fail(f'退出动画前不是横屏: {width}x{height}')
        return controlled
    button = footer_icons(controlled)[-1]
    x, y = center(parse_bounds(node_bounds(button)))
    frames = capture_transition(
        'p03_full_exit', ('click', str(x), str(y)),
        offsets_ms=(40, 100, 180, 280, 420, 650, 900),
    )
    _, portrait = wait_for_ui(lambda t: is_orientation(t, False), timeout=10, name='p03_portrait')
    time.sleep(0.5)
    portrait = load_ui_tree(dump_ui('p03_final'))
    frames.append(snapshot_shot('p03_full_exit_1200_final'))
    animation = analyze_animation(frames)
    animation_path = QA_DIR / 'p03_full_exit_animation.json'
    animation_path.write_text(json.dumps(animation, ensure_ascii=False, indent=2), encoding='utf-8')
    if animation['orientation_changed'] and animation['final_orientation'] == 'portrait':
        report.pass_(f"连续帧捕获到横转竖: {animation['orientations']}")
    else:
        report.fail(f"动画方向序列异常: {animation['orientations']}")
    perceptual_count = animation.get('meaningful_transitions')
    motion_ok = perceptual_count >= 3 if perceptual_count is not None else animation['unique_exact_frames'] >= 3
    if motion_ok:
        detail = (f'感知变化 {perceptual_count}/{animation["frame_count"] - 1}'
                  if perceptual_count is not None else
                  f'唯一帧 {animation["unique_exact_frames"]}/{animation["frame_count"]}')
        report.pass_(f'动画中间态非冻结，{detail}')
    else:
        report.fail(f"动画疑似跳变/冻结，唯一帧 {animation['unique_exact_frames']}")
    surface, canvas = player_geometry(portrait)
    if canvas is None:
        report.skip(f'当前系统 UI dump 不导出旋转后 Canvas；Surface={surface}')
    elif bounds_close(surface, canvas, 6):
        report.pass_(f'旋转后 Surface/Canvas 对齐 {surface}')
    else:
        report.fail(f'旋转后 Surface={surface} Canvas={canvas}')
    if has_text(portrait, '评论') or has_text(portrait, '简介'):
        report.pass_('退出全屏后仍在视频详情页')
    else:
        report.fail('退出全屏后视频详情主体丢失')
    return portrait


def has_home_dock(root: Any) -> bool:
    _, height = root_size(root)
    return first_node(root, lambda n: (
        node_text(n) == '首页' and (parse_bounds(node_bounds(n)) or {}).get('y1', 0) > height * 0.75
    )) is not None


def test_end_back_and_replay(tree: Any) -> None:
    report.begin('P4 播放结束返回与重播')
    landscape = enter_fullscreen(tree)
    controlled = set_playing(False, 'p04_pause_for_seek')
    slider = largest_slider(controlled)
    if not slider:
        report.fail('横屏找不到进度 Slider，无法制造播完态')
        return
    y = (slider['y1'] + slider['y2']) // 2
    span = slider['x2'] - slider['x1']
    # 留出最后几秒自然播放，避免滑块把 seek 量化到精确 duration 后仍停在暂停态。
    swipe(slider['x1'] + int(span * 0.7), y, slider['x1'] + int(span * 0.96), y, 1000, 1000)
    controlled = show_controls(load_ui_tree(dump_ui('p04_seek_ready')))
    tap_bounds(node_bounds(footer_icons(controlled)[0]), 200)
    try:
        _, ended = wait_for_ui(lambda t: has_text(t, '重播') and is_orientation(t, True),
                               timeout=18, name='p04_ended_full')
    except Exception as exc:
        report.fail(f'未进入横屏播完态: {exc}')
        return
    snapshot_shot('p04_ended_full')
    width, height = root_size(ended)
    # 横屏结束页左上返回键。该坐标按窗口比例计算，避免绑死 2848x1320。
    tap(max(80, int(width * 0.072)), max(70, int(height * 0.24)), 150)
    try:
        _, portrait = wait_for_ui(lambda t: is_orientation(t, False), timeout=10, name='p04_back_portrait')
    except Exception as exc:
        report.fail(f'结束页返回键没有退出全屏: {exc}')
        return
    if has_home_dock(portrait):
        report.fail('结束页返回键错误地回到了首页')
    elif has_text(portrait, '评论') or has_text(portrait, '简介') or has_text(portrait, '重播'):
        report.pass_('结束页返回键只退出全屏，仍停留视频详情')
    else:
        report.fail('返回后的页面状态无法确认')
    replay = first_node(portrait, lambda n: node_text(n) == '重播')
    if not replay:
        portrait = load_ui_tree(dump_ui('p04_back_detail'))
        replay = first_node(portrait, lambda n: node_text(n) == '重播')
    if replay:
        tap_bounds(node_bounds(replay), 1600)
        replayed = load_ui_tree(dump_ui('p04_replayed'))
        stale = preview_texts(replayed)
        if stale:
            report.fail(f'重播后残留拖动预览: {stale}')
        else:
            report.pass_('重播后无拖动预览残留')
        if video_surface_ready(replayed):
            report.pass_('重播后播放器 Surface 恢复')
        else:
            report.fail('重播后播放器画面未恢复')
    else:
        report.fail('退出全屏后找不到重播按钮')
    snapshot_shot('p04_replay_done')


def install_if_needed(skip_install: bool, hap: str) -> None:
    if skip_install:
        return
    chosen = Path(hap) if hap else None
    if chosen is None:
        for candidate in (
            ROOT / 'entry/build/default/outputs/default/entry-default-signed.hap',
            ROOT / 'entry/build/default/outputs/default/entry-default-unsigned.hap',
        ):
            if candidate.exists():
                chosen = candidate
                break
    if chosen is None or not chosen.exists():
        raise RuntimeError('未找到 HAP；请先构建或传 --hap')
    device().run(['install', '-r', str(chosen)], check=True, timeout=60)


def main() -> None:
    parser = argparse.ArgumentParser(description='播放器动画/点击/高负载专项真机回归')
    parser.add_argument('--skip-install', action='store_true')
    parser.add_argument('--hap', default='')
    parser.add_argument('--query', default='BadApple')
    parser.add_argument('--performance-seconds', type=int, default=10)
    parser.add_argument('--skip-performance', action='store_true')
    parser.add_argument('--skip-ended', action='store_true', help='跳过拖到结尾/重播用例')
    args = parser.parse_args()

    ensure_qa_dir()
    try:
        install_if_needed(args.skip_install, args.hap)
        connect()
        tree = open_dense_4k_video(args.query)
        test_initial_geometry_and_seek(tree)
        tree = load_ui_tree(dump_ui('p_after_seek'))
        landscape = enter_fullscreen(tree)
        landscape = test_dense_playback_performance(
            landscape, max(3, args.performance_seconds), args.skip_performance)
        portrait = test_fullscreen_exit_animation(landscape)
        if args.skip_ended:
            report.begin('P4 播放结束返回与重播')
            report.skip('命令行要求跳过')
        else:
            test_end_back_and_replay(portrait)
    except Exception as exc:
        if not report.current:
            report.begin('P0 场景准备')
        report.fail(str(exc))
    finally:
        output = report.export('suite_player_report.md')
        print(f'report: {output}')
        print(f'PASS={report.passed} FAIL={report.failed} SKIP={report.skipped}')
    sys.exit(1 if report.failed else 0)


if __name__ == '__main__':
    main()
