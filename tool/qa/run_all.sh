#!/usr/bin/env bash
# 跨平台一键 Python 全量测试（适用于有 python3 的 macOS/Linux；Windows 可用 run_all.ps1 或 py）
set -eo pipefail
cd "$(dirname "$0")/../.."
exec python3 tool/qa/run_all.py "$@"
