#!/usr/bin/env bash
# ============================================================
# biliharmony 模拟器命令行工具 (纯 SDK, 不需要 DevEco)
#   用法:
#     ./emu.sh status            状态总览
#     ./emu.sh img-install       下载系统镜像 (如需)
#     ./emu.sh create            创建 phone 实例(6.1.1)
#     ./emu.sh boot              无窗口启动 (hdc 端口 15555)
#     ./emu.sh stop              停止模拟器
#     ./emu.sh list              列出 hdc 设备
#     ./emu.sh shell "<cmd>"     模拟器内执行命令
#     ./emu.sh install <xxx.hap> 安装 HAP
#     ./emu.sh launch            启动 BiliHarmony App
#     ./emu.sh shot [out.png]    截屏拉回本机
#     ./emu.sh logs              查看启动日志
# ============================================================
set -uo pipefail
E=/home/ohos-builder/ohos-sdk/command-line-tools/emulator/Emulator
HDC=/home/ohos-builder/ohos-sdk/command-line-tools/sdk/default/openharmony/toolchains/hdc
INSTANCE=bili_dev
PORT=15556
OSV="HarmonyOS 6.1.1(24)"
APPID="com.piliplus.harmony"

cmd_connect() {
  "$HDC" tconn 127.0.0.1:$PORT >/dev/null 2>&1 || true
}

case "${1:-}" in
  img|install)
    "$E" -install -deviceType phone -osVersion "$OSV" 2>&1 | tail -3 ;;
  create)
    "$E" -create "$INSTANCE" -deviceType phone -osVersion "$OSV" -memory 4 -storage 16 2>&1 | tail -4
    "$E" -list 2>&1 | tail -4 ;;
  boot|start)
    nohup "$E" -start "$INSTANCE" -noWindow -hdcPort $PORT >/tmp/emu-boot.log 2>&1 &
    echo "启动中 pid=$! (日志: tail -f /tmp/emu-boot.log)" ;;
  stop) "$E" -stop "$INSTANCE" 2>&1 | tail -2 ;;
  status|info)
    echo "--- 实例 ---"; "$E" -list -details 2>&1 | head -25
    echo "--- hdc 设备 ---"; cmd_connect; "$HDC" list targets 2>&1 | head -5
    echo "--- 远程 UI 服务 ---"
    pgrep -a "Xorg :99" 2>/dev/null || echo "Xorg :99 NOT RUNNING"
    pgrep -a x11vnc 2>/dev/null || echo "x11vnc NOT RUNNING"
    pgrep -a websockify 2>/dev/null | head -1 || echo "websockify NOT RUNNING"
    ss -ltnp 2>/dev/null | grep -E ":5900|:6080" || echo "VNC/Web no listener" ;;
  shell)
    shift; cmd_connect; "$HDC" shell "$@" 2>&1 ;;
  install)
    shift; [ -f "$1" ] || { echo "文件不存在: $1"; exit 1; }
    cmd_connect; "$HDC" install "$1" 2>&1 | tail -3 ;;
  uninstall)
    cmd_connect; "$HDC" uninstall "$APPID" 2>&1 | tail -2 ;;
  launch)
    cmd_connect; "$HDC" shell aa start -a EntryAbility -b "$APPID" 2>&1 | tail -3 ;;
  ui-restart)
    echo "505066278" | sudo -S pkill -f "Xorg :99" 2>/dev/null || true
    pkill -f "x11vnc -display :99" 2>/dev/null || true
    sleep 1
    rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
    echo "505066278" | sudo -S sh -c "nohup Xorg :99 -config /tmp/xorg-nvidia.conf -ac -noreset -nolisten tcp >/tmp/xorg_nvidia.log 2>&1 & sleep 2" || true
    nohup x11vnc -display :99 -nopw -forever -shared -repeat -rfbport 5900 -xkb >/tmp/x11vnc_nvidia.log 2>&1 &
    sleep 1
    echo "Xorg/x11vnc restarted" ;;
  shot)
    cmd_connect
    "$HDC" shell snapshot_display -f /data/local/tmp/s.png >/dev/null 2>&1
    sleep 1
    "$HDC" file recv /data/local/tmp/s.png "${2:-emu.png}" 2>&1 | tail -1 ;;
  smoke)
    cmd_connect
    "$HDC" shell power-shell wakeup >/dev/null 2>&1 || true
    "$HDC" shell uitest uiInput keyEvent Power >/dev/null 2>&1 || true
    "$HDC" shell uitest uiInput keyEvent 82 >/dev/null 2>&1 || true
    "$HDC" shell aa start -a EntryAbility -b "$APPID" >/dev/null 2>&1 || true
    sleep 4
    echo "--- 进程 ---"
    "$HDC" shell "ps -ef | grep $APPID | grep -v grep | head -1" 2>&1
    echo "--- 前台页面 ---"
    "$HDC" shell "aa dump -l" 2>&1 | head -8 ;;
  logs) tail -50 /tmp/emu-boot.log 2>/dev/null || echo "无日志";;
  *) sed -n '1,22p' "$0"; exit 1 ;;
esac