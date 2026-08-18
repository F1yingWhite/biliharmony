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

# 2. 一键执行：构建 -> 安装 -> 全量/深度回归 -> UI 审计
python3 tool/qa/run_all.py

# 3. 只跑已有 dump 的 UI 审计，不连模拟器
python3 tool/qa/run_all.py --only-audit
```

## 组件

- `qa_common.py`  跨平台 hdc/uitest 驱动、UI 树解析、截图/dump、断言
- `qa_build.py`   跨平台 hvigor 构建
- `suite_all.py`  全量 UI 回归（首页三频道/视频详情/搜索/番剧/动态/我的/深色）
- `suite_deep.py` 深度链路回归（评论/弹幕/用户空间/排行/番剧/直播/历史收藏）
- `audit_ui.py`   UI 重叠 / 越界 / 对齐 / 行距审计
- `smoke.py`      快速冒烟入口

## 产物

默认写到 `.emulator/qa/`：
- `*.jpeg` 页面截图像素证据
- `*.json` 布局 dump
- `qa_report.md` 最近套件明细
- `SUMMARY.md` 一键汇总
