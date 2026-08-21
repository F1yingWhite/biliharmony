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
from typing import Any, Dict, List, Optional, Tuple

from animation_probe import analyze as analyze_animation
from performance_probe import collect as collect_performance
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
    snapshot_shot('p00_player_ready')
    return detail


def show_controls(root: Any, wait_ms: int = 350) -> Any:
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
        if largest_slider(latest) is not None:
            return latest
    raise RuntimeError('连续三次点击后播放器控制条仍未显示')


def largest_slider(root: Any) -> Optional[Dict[str, int]]:
    node = largest_node(root, 'Slider')
    return parse_bounds(node_bounds(node)) if node else None


def preview_texts(root: Any) -> List[str]:
    return [text for text in all_texts(root) if PREVIEW_RE.search(text)]


def enter_fullscreen(root: Any) -> Any:
    controlled = show_controls(root)
    surface, _ = player_geometry(controlled)
    if not surface:
        raise RuntimeError('进入全屏前 Surface 丢失')
    tap(surface['x2'] - 75, surface['y2'] - 75, 150)
    _, landscape = wait_for_ui(lambda t: is_orientation(t, True), timeout=10, name='p_fullscreen')
    time.sleep(0.8)
    return landscape


def set_highest_quality_and_density(root: Any) -> Any:
    controlled = show_controls(root)
    width, height = root_size(controlled)
    # 横屏底栏顺序固定：播放、弹幕开关、弹幕设置。第三个图标位于左下约 4.5% 屏宽。
    bottom_icons = find_nodes(controlled, lambda n: (
        node_type(n) == 'Image' and
        (parse_bounds(node_bounds(n)) or {}).get('y1', 0) > height * 0.75 and
        (parse_bounds(node_bounds(n)) or {}).get('x2', width) < width * 0.35
    ))
    bottom_icons.sort(key=lambda n: (parse_bounds(node_bounds(n)) or {}).get('x1', 0))
    if len(bottom_icons) >= 3:
        tap_bounds(node_bounds(bottom_icons[2]), 500)
    else:
        tap(max(390, int(width * 0.14)), height - 90, 500)
    try:
        _, settings = wait_for_ui(lambda t: has_text(t, '弹幕设置') and has_text(t, '重叠'),
                                  timeout=5, name='p_dense_settings')
        dense = first_node(settings, lambda n: node_text(n) == '重叠')
        if dense:
            tap_bounds(node_bounds(dense), 350)
            report.pass_('弹幕密度已切到“重叠”(30)')
        # 点抽屉左侧遮罩关闭，不触发系统返回/退出全屏。
        tap(max(80, width // 4), height // 2, 450)
    except Exception as exc:
        report.skip(f'无法自动切换高密度，保留当前设置: {exc}')

    controlled = show_controls(load_ui_tree(dump_ui('p_after_dense')))
    quality = first_node(controlled, lambda n: (
        re.search(r'(4K|1080P|720P|自动)', node_text(n), re.I) is not None and
        (parse_bounds(node_bounds(n)) or {}).get('y1', 0) > height * 0.65
    ))
    if quality:
        previous = node_text(quality)
        tap_bounds(node_bounds(quality), 450)
        try:
            _, panel = wait_for_ui(
                lambda t: any(re.search(r'(4K|1080P60|1080P)', s, re.I) for s in all_texts(t)),
                timeout=6, name='p_quality_panel')
            choices = ['4K', 'HDR', '杜比', '1080P60', '1080P 高码率', '1080P']
            chosen = None
            for label in choices:
                chosen = first_node(panel, lambda n, label=label: (
                    label.lower() in node_text(n).lower() and len(node_text(n)) <= 14 and
                    (parse_bounds(node_bounds(n)) or {}).get('x1', 0) > width * 0.6
                ))
                if chosen:
                    break
            if chosen:
                label = node_text(chosen)
                tap_bounds(node_bounds(chosen), 2800)
                report.pass_(f'已选择最高可见画质: {label}')
            else:
                report.skip(f'画质面板无高画质选项，当前 {previous}')
            # 若画质页仍在，点左侧遮罩关闭。
            current = load_ui_tree(dump_ui('p_quality_after'))
            if has_text(current, '返回') and has_text(current, '清晰度'):
                tap(max(80, width // 4), height // 2, 400)
                wait_for_ui(lambda t: not has_text(t, '清晰度'), timeout=5, name='p_quality_closed')
        except Exception as exc:
            report.skip(f'画质切换未完成，当前 {previous}: {exc}')
    else:
        report.skip('没有识别到横屏画质按钮')
    return load_ui_tree(dump_ui('p_dense_quality_ready'))


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
    controlled = show_controls(tree)
    width, height = root_size(controlled)
    if width <= height:
        report.fail(f'退出动画前不是横屏: {width}x{height}')
        return controlled
    frames = capture_transition(
        'p03_full_exit', ('click', str(width - 70), str(height - 95)),
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
    controlled = show_controls(landscape)
    slider = largest_slider(controlled)
    if not slider:
        report.fail('横屏找不到进度 Slider，无法制造播完态')
        return
    y = (slider['y1'] + slider['y2']) // 2
    span = slider['x2'] - slider['x1']
    swipe(slider['x1'] + int(span * 0.7), y, slider['x1'] + int(span * 0.995), y, 1000, 1000)
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
        report.begin('P0 场景准备')
        report.fail(str(exc))
    finally:
        output = report.export('suite_player_report.md')
        print(f'report: {output}')
        print(f'PASS={report.passed} FAIL={report.failed} SKIP={report.skipped}')
    sys.exit(1 if report.failed else 0)


if __name__ == '__main__':
    main()
