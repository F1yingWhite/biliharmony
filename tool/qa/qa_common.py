#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BiliHarmony 全量 UI QA 跨平台驱动核心。
- Windows / macOS / Linux 通用，只需要 Python3 + hdc。
- 通过 QA_HDC / QA_PORT / QA_APPID / QA_SHOT_DIR 覆盖默认值。
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence

APP_ID = os.environ.get('QA_APPID', 'com.piliplus.harmony')
ROOT = Path(__file__).resolve().parents[2]
QA_DIR = Path(os.environ.get('QA_SHOT_DIR', str(ROOT / '.emulator' / 'qa')))
SCREEN_W = 1320
SCREEN_H = 2848


def log(msg: str) -> None:
    print(f"[QA] {msg}", flush=True)


def find_hdc() -> Optional[str]:
    exe = os.environ.get('QA_HDC') or shutil.which('hdc') or shutil.which('hdc.exe')
    if exe:
        return exe
    home = Path.home()
    patterns = [
        '/home/*/ohos-sdk/command-line-tools/sdk/default/openharmony/toolchains/hdc',
        '/root/ohos-sdk/command-line-tools/sdk/default/openharmony/toolchains/hdc',
        '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc',
        str(home / 'ohos-sdk/command-line-tools/sdk/default/openharmony/toolchains/hdc'),
        str(home / 'Library/Huawei/Sdk/default/openharmony/toolchains/hdc'),
    ]
    candidates: List[Path] = []
    for pattern in patterns:
        candidates += [Path(p) for p in glob.glob(pattern)]
    for p in candidates:
        if p.exists() and os.access(p, os.X_OK):
            return str(p)
    win = os.environ.get('DEVECO_SDK_HOME', '')
    for p in [
        r'D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
        r'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe',
        str(Path(win) / 'default/openharmony/toolchains/hdc.exe') if win else '',
    ]:
        if p and Path(p).exists():
            return p
    return None


def hdc_path() -> str:
    p = find_hdc()
    if not p:
        raise RuntimeError('未找到 hdc。请设置 QA_HDC 环境变量或将 hdc 加入 PATH。')
    return p


def ensure_qa_dir() -> Path:
    QA_DIR.mkdir(parents=True, exist_ok=True)
    return QA_DIR


class Hdc:
    """hdc 调用封装：重试、超时、错误信号过滤。"""
    def __init__(self, executable: Optional[str] = None):
        self.path = executable or hdc_path()

    def run(self, args: Sequence[str], retries: int = 3, timeout: int = 20,
            check: bool = False, fire_and_forget: bool = False) -> str:
        # 多设备连接时（模拟器+真机）hdc 必须带 -t 指定 connect-key，否则会报
        # "need connect-key"。用 QA_TARGET 环境变量显式指定目标设备。
        target = os.environ.get('QA_TARGET', '')
        if target and (not args or args[0] != '-t'):
            args = ['-t', target] + list(args)
        last_err = ''
        for _ in range(retries):
            try:
                proc = subprocess.run([self.path] + list(args), capture_output=True,
                                      text=True, timeout=timeout)
            except Exception as e:
                last_err = str(e)
                time.sleep(0.4)
                continue
            out = (proc.stdout or '').strip()
            err = (proc.stderr or '').strip()
            combined = (out + ' ' + err).strip()
            if proc.returncode != 0:
                last_err = f'exit={proc.returncode} {combined}'
                time.sleep(0.4)
                continue
            low = combined.lower()
            # hdc 的 "No Error" 是成功态，必须放误判前面。
            if 'no error' in low or 'success' in low:
                return out
            if any(k in low for k in ('error', 'fail', 'denied', 'invalid', 'not found',
                                      'no such', 'usage:', 'exception', 'empty')):
                last_err = combined or '(empty output)'
                time.sleep(0.4)
                continue
            if fire_and_forget:
                return out
            if check and not out:
                last_err = combined or '(empty output)'
                time.sleep(0.4)
                continue
            return out
        raise RuntimeError(f'hdc failed: {self.path} {" ".join(args)} -> {last_err}')

    def fire(self, args: Sequence[str]) -> None:
        try:
            self.run(args, retries=1, timeout=8)
        except Exception:
            pass


class QaReport:
    def __init__(self, title: str):
        self.title = title
        self.lines: List[str] = []
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.current = ''

    def begin(self, name: str) -> None:
        self.current = name
        self.lines.append(f"==> {name}")

    def pass_(self, detail: str = '') -> None:
        self.passed += 1
        self.lines.append(f"PASS  {self.current} {detail}")

    def fail(self, detail: str = '') -> None:
        self.failed += 1
        self.lines.append(f"FAIL  {self.current} {detail}")

    def skip(self, detail: str = '') -> None:
        self.skipped += 1
        self.lines.append(f"SKIP  {self.current} {detail}")

    def note(self, msg: str) -> None:
        self.lines.append(f"NOTE  {msg}")

    def export(self) -> Path:
        ensure_qa_dir()
        md = QA_DIR / 'qa_report.md'
        content = [f"# {self.title}", '',
                   f"- 时间: {time.strftime('%Y-%m-%d %H:%M:%S')}",
                   f"- 通过: {self.passed} / 失败: {self.failed} / 跳过: {self.skipped}", '',
                   '## 明细', '']
        content += [f"- {l}" for l in self.lines]
        md.write_text('\n'.join(content), encoding='utf-8')
        return md


_hdc: Optional[Hdc] = None


def device() -> Hdc:
    global _hdc
    if _hdc is None:
        _hdc = Hdc()
    return _hdc


def connect(port: Optional[str] = None) -> None:
    port = port or os.environ.get('QA_PORT')
    if port:
        device().fire(['tconn', f'127.0.0.1:{port}'])
    try:
        out = device().run(['list', 'targets'], check=False)
    except Exception as e:
        log(f'warn: hdc list targets 调用失败: {e}')
        return
    low = out.lower()
    if not any(k in low for k in ('5555', 'localhost', '127.0.0.1', 'emulator', 'harmony')):
        log(f'warn: hdc list targets 未识别到设备: {out or "(empty)"}')


# ---------------- 应用生命周期 ----------------
def start_app() -> None:
    device().run(['shell', 'aa', 'start', '-a', 'EntryAbility', '-b', APP_ID], check=False)
    time.sleep(3)


def stop_app() -> None:
    device().run(['shell', 'aa', 'force-stop', APP_ID], check=False)
    time.sleep(0.6)


def keep_awake() -> None:
    device().fire(['shell', 'power-shell', 'timeout', '-o', '7200000'])


def wake_screen() -> None:
    device().fire(['shell', 'power-shell', 'wakeup'])
    time.sleep(0.4)


def cold_start() -> None:
    keep_awake()
    stop_app()
    start_app()
    time.sleep(2)


def snapshot_shot(name: str) -> Path:
    device().run(['shell', 'snapshot_display', '-f', f'/data/local/tmp/{name}.jpeg'], check=False)
    time.sleep(0.5)
    local = ensure_qa_dir() / f'{name}.jpeg'
    device().run(['file', 'recv', f'/data/local/tmp/{name}.jpeg', str(local)], check=False)
    return local


def dump_ui(name: str) -> Path:
    device().run(['shell', 'uitest', 'dumpLayout', '-p', f'/data/local/tmp/{name}.json'], check=False)
    time.sleep(0.25)
    local = ensure_qa_dir() / f'{name}.json'
    try:
        device().run(['file', 'recv', f'/data/local/tmp/{name}.json', str(local)], check=False)
    except Exception as e:
        log(f'dump recv warn: {e}')
    if not local.exists():
        raise RuntimeError(f'dump json missing: {local}')
    return local


def load_ui_tree(path: Path) -> Any:
    return json.loads(path.read_text(encoding='utf-8-sig'))


# ---------------- UI 树工具 ----------------
def node_text(n: Any) -> str:
    a = n.get('attributes') if isinstance(n, dict) else {}
    return str(a.get('text', '')) if isinstance(a, dict) else ''


def node_type(n: Any) -> str:
    a = n.get('attributes') if isinstance(n, dict) else {}
    return str(a.get('type', '')) if isinstance(a, dict) else ''


def node_bounds(n: Any) -> str:
    a = n.get('attributes') if isinstance(n, dict) else {}
    return str(a.get('bounds', '')) if isinstance(a, dict) else ''


def walk(root: Any) -> List[Any]:
    out: List[Any] = []
    stack = [root]
    while stack:
        n = stack.pop()
        if isinstance(n, dict):
            out.append(n)
            children = n.get('children')
            if isinstance(children, list):
                stack.extend(reversed(children))
    return out


def find_nodes(root: Any, pred: Callable[[Any], bool]) -> List[Any]:
    return [n for n in walk(root) if pred(n)]


def first_node(root: Any, pred: Callable[[Any], bool]) -> Optional[Any]:
    for n in walk(root):
        if pred(n):
            return n
    return None


def all_texts(root: Any) -> List[str]:
    return [node_text(n).strip() for n in walk(root) if node_text(n).strip()]


def parse_bounds(bounds: Optional[str]) -> Optional[Dict[str, int]]:
    if not bounds:
        return None
    m = re.search(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', bounds)
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2}


def has_text(root: Any, text: str, min_count: int = 1) -> bool:
    count = 0
    for n in walk(root):
        if re.search(text, node_text(n)):
            count += 1
            if count >= min_count:
                return True
    return count >= min_count


def tap_bounds(bounds: str, wait_ms: int = 500) -> None:
    b = parse_bounds(bounds)
    if not b:
        raise ValueError(f'bad bounds: {bounds}')
    x = (b['x1'] + b['x2']) // 2
    y = (b['y1'] + b['y2']) // 2
    device().run(['shell', 'uitest', 'uiInput', 'click', str(x), str(y)], check=False)
    time.sleep(wait_ms / 1000)


def tap_text(root: Any, text: str, wait_ms: int = 700) -> bool:
    n = first_node(root, lambda x: re.search(text, node_text(x)))
    if not n:
        return False
    tap_bounds(node_bounds(n), wait_ms)
    return True


def swipe_up(dist: int = 500) -> None:
    y1 = 2000
    y2 = max(100, y1 - dist)
    device().run(['shell', 'uitest', 'uiInput', 'swipe', '660', str(y1), '660', str(y2), '400'],
                 check=False)
    time.sleep(0.4)


def swipe_down(dist: int = 500) -> None:
    y1 = 2000 - dist
    y2 = 2200
    device().run(['shell', 'uitest', 'uiInput', 'swipe', '660', str(y1), '660', str(y2), '400'],
                 check=False)
    time.sleep(0.4)


def key_back() -> None:
    device().run(['shell', 'uitest', 'uiInput', 'keyEvent', 'Back'], check=False)
    time.sleep(0.4)


def dump_until_text(text: str, timeout: int = 20, name: str = 'dump') -> Path:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = dump_ui(name)
        try:
            tree = load_ui_tree(last)
        except Exception:
            time.sleep(0.7)
            continue
        if has_text(tree, text):
            return last
        time.sleep(0.7)
    raise RuntimeError(f"wait text 超时: '{text}' (last={last})")


def dump_until_rich(min_texts: int = 20, timeout: int = 15, name: str = 'rich') -> Path:
    deadline = time.time() + timeout
    last = None
    last_count = 0
    while time.time() < deadline:
        last = dump_ui(name)
        try:
            last_count = len(all_texts(load_ui_tree(last)))
        except Exception:
            last_count = 0
        if last_count >= min_texts:
            return last
        time.sleep(0.6)
    return last


def back_home(max_back: int = 6) -> bool:
    for _ in range(max_back):
        try:
            d = dump_ui('bk')
            t = load_ui_tree(d)
            dock = first_node(t, lambda n: node_text(n) in ('首页', '动态', '我的') and
                              (parse_bounds(node_bounds(n)) or {}).get('y1', 0) > 2400)
            if dock:
                return True
        except Exception:
            pass
        key_back()
    return False


def main():
    ap = argparse.ArgumentParser(description='QA common module')
    ap.add_argument('--path', action='store_true')
    args = ap.parse_args()
    if args.path:
        print(hdc_path())


if __name__ == '__main__':
    main()
