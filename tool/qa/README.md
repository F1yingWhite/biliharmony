# BiliHarmony 全量 UI 测试流程（跨平台）

本目录同时提供两套入口：

| 入口 | 平台 | 说明 |
| --- | --- | --- |
| `run_all.py` | Windows / macOS / Linux（Python 3） | 推荐跨平台入口，纯 `subprocess`，仅依赖 Python 3 + hdc |
| `run_all_cross.ps1` | PowerShell Core（Windows/macOS/Linux） | 跨平台 PowerShell 入口，调用 run_all.py |
| `run_all.ps1` | Windows PowerShell / PowerShell Core | 原有 PowerShell 流程，保留兼容 |
| `run_all.sh` | macOS / Linux（Bash） | 包装 `run_all.py` |

## 快速开始

```bash
# 1. 检测 hdc/hvigor（也可通过环境变量指定）
export QA_HDC=/path/to/hdc
export QA_PORT=15555
export QA_APPID=com.piliplus.harmony

# 2. 一键执行：构建 -> 安装 -> 全量/深度/播放器回归 -> UI 审计
python3 tool/qa/run_all.py

# 3. 只跑已有 dump 的 UI 审计，不连模拟器
python3 tool/qa/run_all.py --only-audit
```

## 组件

- `qa_common.py`  跨平台 hdc/uitest 驱动、UI 树解析、截图/dump、断言
- `qa_build.py`   跨平台 hvigor 构建
- `suite_all.py`  全量 UI 回归（首页三频道/视频详情/搜索/番剧/动态/我的/深色）
- `suite_deep.py` 深度链路回归（评论/弹幕/用户空间/排行/番剧/直播/历史收藏）
- `suite_player.py` 播放器真机专项（高画质/高密度弹幕、拖动预览、全屏动画、播完返回、重播）
- `performance_probe.py` 调用设备 SmartPerf，保存 FPS/CPU/GPU/PSS 原始样本与统计
- `animation_probe.py` 分析全屏旋转连续截图的方向、重复帧和可选感知哈希
- `audit_ui.py`   UI 重叠 / 越界 / 对齐 / 行距审计
- `smoke.py`      快速冒烟入口

## 产物

默认写到 `.emulator/qa/`：
- `*.jpeg` 页面截图像素证据
- `*.json` 布局 dump
- `qa_report.md` 最近套件明细
- `suite_player_report.md` 播放器专项断言明细
- `p02_dense_4k_smartperf.{txt,json}` 高负载播放性能原始数据与汇总
- `p03_full_exit_*.jpeg`、`p03_full_exit_animation.json` 全屏退出动画逐帧证据
- `SUMMARY.md` 一键汇总

## 播放器专项

播放器测试会搜索 `BadApple`，打开标题包含 `4K 60FPS` 的固定视频，将弹幕密度切到
“重叠”，选择当前账号可见的最高画质，然后在真实播放器上执行手势和旋转。它依赖网络、
视频接口可用及设备中已配置的账号状态；不使用假播放器或静态 mock。

```bash
export QA_HDC=/path/to/hdc
export QA_TARGET=127.0.0.1:5555

# 已安装当前 HAP 时，只跑播放器专项
python3 tool/qa/suite_player.py --skip-install

# 快速检查交互/动画，不等待播完，也不采性能
python3 tool/qa/suite_player.py --skip-install --skip-ended --skip-performance

# 单独采集当前前台播放场景 20 秒性能
python3 tool/qa/performance_probe.py --seconds 20 --prefix manual_dense_4k
```

SmartPerf 在部分虚拟机图形栈上可能返回 `fps=0`。测试会将这种情况标为“无法取数”并保留
CPU/PSS 原始记录，不会把它伪报成播放器只有 0 FPS；真机或暴露 RenderService 帧统计的
虚拟机可直接得到 FPS 和 jitter。动画验收会同时检查 UI dump 中的 Surface 几何；若设备
导出 Canvas/弹幕视口节点，也会检查两者对齐。当前系统若省略 Canvas，会明确记为 SKIP，
不会根据截图臆测它的尺寸。
