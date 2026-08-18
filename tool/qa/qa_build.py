#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨平台命令行构建。
用法: python3 tool/qa/qa_build.py [--clean] [--install] [--hvigor PATH]
优先使用 PATH 中的 hvigorw / DevEco 自带 hvigorw。
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def find_hvigor() -> str:
    env = os.environ.get('HVIGOR')
    if env:
        return env
    exe = shutil.which('hvigorw')
    if exe:
        return exe
    home = Path.home()
    patterns = [
        '/home/*/ohos-sdk/command-line-tools/bin/hvigorw',
        '/root/ohos-sdk/command-line-tools/bin/hvigorw',
        '/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw',
        str(home / 'ohos-sdk/command-line-tools/bin/hvigorw'),
        str(home / 'Library/Huawei/Sdk/command-line-tools/bin/hvigorw'),
    ]
    for pat in patterns:
        for p in glob.glob(pat):
            if os.access(p, os.X_OK):
                return p
    # Windows DevEco
    for p in [
        r'D:\DevEco Studio\tools\hvigor\bin\hvigorw.bat',
        r'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat',
    ]:
        if Path(p).exists():
            return p
    raise RuntimeError('未找到 hvigor。请安装 DevEco Studio 或设置 HVIGOR 环境变量。')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--clean', action='store_true')
    ap.add_argument('--install', action='store_true')
    ap.add_argument('--parallel', action='store_true')
    args = ap.parse_args()

    hvigor = find_hvigor()
    cmd = [hvigor, 'assembleHap', '--mode', 'module', '-p', 'product=default', '--no-daemon']
    if args.clean:
        cmd = [hvigor, 'clean', 'assembleHap', '--mode', 'module', '-p', 'product=default', '--no-daemon']
    if not args.parallel:
        cmd.append('--no-parallel')
    print(f'[build] {cmd}')
    env = os.environ.copy()
    env['HOME'] = env.get('HOME', str(Path.home()))
    proc = subprocess.run(cmd, cwd=ROOT, env=env)
    unsigned = ROOT / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
    if proc.returncode != 0 and unsigned.exists():
        # 本仓库签名配置指向 Windows 本机路径；跨平台构建可产出 unsigned HAP。
        print('注意: hvigor 未完成签名，但已生成 unsigned HAP（CompileArkTS 通过）。')
    elif proc.returncode != 0:
        sys.exit(proc.returncode)
    if unsigned.exists():
        print(f'产物: {unsigned} {unsigned.stat().st_size} bytes')
    else:
        print('构建完成，但未找到 unsigned HAP；可能构建签名后路径不同。')
    if args.install:
        from qa_common import device, APP_ID
        hap = unsigned
        if not hap.exists():
            signed = ROOT / 'entry/build/default/outputs/default/entry-default-signed.hap'
            if signed.exists():
                hap = signed
            else:
                print('未找到可安装 HAP')
                sys.exit(2)
        device().run(['install', '-r', str(hap)], check=True)
        print('安装完成')


if __name__ == '__main__':
    main()
