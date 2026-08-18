#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BiliHarmony 全量 UI 测试流程一键入口（跨平台）。

流程:
  1. build      构建 HAP（可选 --skip-build）
  2. install    安装到模拟器/真机（可选 --skip-install）
  3. suite_all  全量 UI 回归
  4. suite_deep 深度链路回归
  5. audit_ui   UI 对齐/重叠/越界审计
  6. 汇总 SUMMARY.md

用法:
  python3 tool/qa/run_all.py [--skip-build] [--skip-install] [--only-audit]
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from qa_common import QA_DIR, ROOT, ensure_qa_dir, log


def run_py(script: str, args=None):
    cmd = [sys.executable, str(Path(__file__).parent / script)]
    if args:
        cmd += args
    log(f'>>> {" ".join(cmd)}')
    return subprocess.run(cmd, cwd=ROOT).returncode


def find_hap():
    candidates = [
        ROOT / 'entry/build/default/outputs/default/entry-default-signed.hap',
        ROOT / 'entry/build/default/outputs/default/entry-default-unsigned.hap',
    ]
    for p in candidates:
        if p.exists():
            return p
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--skip-build', action='store_true')
    ap.add_argument('--skip-install', action='store_true')
    ap.add_argument('--only-audit', action='store_true')
    args = ap.parse_args()

    ensure_qa_dir()
    summary = QA_DIR / 'SUMMARY.md'

    if not args.only_audit:
        if not args.skip_build:
            rc = run_py('qa_build.py')
            if rc != 0:
                log('构建失败')
                sys.exit(rc)
        hap = find_hap()
        if args.skip_install:
            log('跳过安装')
        elif hap:
            from qa_common import device
            device().run(['install', '-r', str(hap)], check=True)
        else:
            log('未找到 HAP，跳过安装（请先构建或指定 HAP）')

    if args.only_audit:
        rc_all = 0
        rc_deep = 0
    else:
        suite_args = ['--skip-install'] if args.skip_install else []
        rc_all = run_py('suite_all.py', suite_args)
        rc_deep = run_py('suite_deep.py', suite_args)
    rc_audit = run_py('audit_ui.py', ['--all'] if not args.only_audit else [])

    report_all = QA_DIR / 'qa_report.md'
    lines = [
        '# BiliHarmony 全量测试汇总（Python 跨平台）',
        '',
        '- 时间: ' + __import__('time').strftime('%Y-%m-%d %H:%M:%S'),
        '- 组件: qa_common.py / qa_build.py / suite_all.py / suite_deep.py / audit_ui.py',
        '',
        '## 结果',
        f'- suite_all exit={rc_all}',
        f'- suite_deep exit={rc_deep}',
        f'- audit_ui exit={rc_audit}',
        '',
        '## 最近报告内容',
        '',
        (report_all.read_text(encoding='utf-8') if report_all.exists() else '（无）'),
    ]
    summary.write_text('\n'.join(lines), encoding='utf-8')
    log(f'汇总: {summary}')
    sys.exit(1 if (rc_all != 0 or rc_deep != 0 or rc_audit != 0) else 0)


if __name__ == '__main__':
    main()
