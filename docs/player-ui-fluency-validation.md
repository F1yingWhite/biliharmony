# 播放器画面缩放、弹幕与控件验证

本轮针对评论区拖动时画面比例波动、弹幕运动不连贯，以及长按加速时控件卡顿。
验证日期：2026-10-10。工作基线为 `b8a221d`，应用版本仍为 `1.4.3`。

## 改动与边界

- 视频 XComponent 使用固定布局尺寸，评论区收缩只对整幅画面做等比变换；有效尺寸按像素取整后去重，拒绝零尺寸。弹幕 Canvas 保持后备缓冲尺寸，外层只裁剪。
- 纯窗口尺寸变化保留已协商的输出颜色，避免重复重建 EGL Surface。真正的 HDR/SDR、元数据变化与失败回退继续走原有协商。
- 高级弹幕在真实媒体样本之间使用同一墙钟平滑绘制，预测最多 300ms；暂停、缓冲和定位时停止，过期判断仍使用真实播放时间。普通弹幕跳过屏幕外的文字绘制，保留移动、碰撞与命中规则。
- 每个原生进度样本通过小型控制通道直接更新 Slider，使用 150ms 线性过渡到真实样本；不预测媒体进度，不添加逐帧 JavaScript 定时器。原生相同目标可能沿用已有过渡，最终停在真实样本。
- 拖动预览只更新小型控件，松手先对齐目标再清除预览，只提交一次定位；没有 End 的保底清理回到真实播放点。拖动期间取消自动隐藏计时，结束后重新安排。
- 控件显隐复用节点；隐藏时 Slider 只缓存样本，显示时一次对齐。高能分段的最大值在数据变化时计算，避免每个分段重复遍历全部数据。

本轮没有调整解码参数、弹幕容量或目标帧率，也没有改变既有音频同步实现。虚拟机界面验证不能代替物理手机的音画同步、HDR 实际显示及整机帧率验收。

## 运行环境与交互

使用已有 **Mate 80 Pro Max** 虚拟机，HarmonyOS 7.0.0 / API 26，guest `7.0.0.107(SP8)`、`arm64-v8a`。
保留虚拟机数据，目标为 `127.0.0.1:10000`；本轮没有向物理手机安装。
视频为 `BV1R1e4zKEh1`（20:06），使用实际在线片源与弹幕。

| 场景 | 检查结果 |
| --- | --- |
| 长按加速 | 隐藏控件后长按仍显示“倍速播放中”，松手后提示消失；隐藏控件不阻挡播放手势 |
| 控件显隐 | 自动隐藏后再次显示，Slider accessibilityId 与 hashcode 保持不变，时间对齐最新样本 |
| 暂停恢复 | 暂停后真实进度保持不变，恢复后继续推进 |
| 进度拖动 | 松手后落在目标，等待后不回跳；迟到 TouchUp 不覆盖提交目标 |
| 持续拖动 | 6.5 秒拖动的第四秒仍可见；松手后保持可见，再等 3.5 秒正常隐藏 |
| 评论区收缩 | 暂停时上下滑动评论：展开 1320×742、收缩 576×323，宽高按相同比例变化；恢复播放后展开 |
| 横屏切换 | 进入全屏与返回竖屏后画面正常 |

当前横向视频在播放期间滚动评论保持展开，这是页面原有策略；暂停后才收缩。不能把它记为“播放中横向视频随评论拖动缩小”的验收。

## 检查与证据

| 检查 | 结果 |
| --- | --- |
| 全量 Node 回归（持续拖动计时修复前） | 1546 通过；需要 SDK 的 15 项另行指定真实依赖后全部通过 |
| 最终播放器、弹幕、parity 回归 | 451/451 通过，0 跳过；包含新增 3 项拖动计时回归 |
| 真实 SDK HDR 原生 fixture | 15/15 通过，0 跳过；覆盖 SDR/PQ/HLG 纯尺寸变化保留 Surface 以及后续颜色/元数据切换 |
| 最终 release 构建 | 成功；签名 HAP 安装到指定 ARM64 模拟器成功 |
| 实际 HAP 检查 | passed；检查四个 SO、ELF 链接依赖、实际包内哈希及来源清单 |

最终 HAP SHA-256：`610ff436283756196faf43eb4564762d5d8276c18d432d28e9451a972f98dd2d`。
包内 `libmpv.so` SHA-256：`66355d20da77ecf087aa0d31790fc2321c6c2b96654fea3ef1feb0a3d7d960bb`。
该包是基于 `1.4.3` 的本地测试构建，以散列标识本次安装的确切产物。

临时运行证据位于 `.qa/player-fluency-20261010/`，不随源码提交。
自动检查见 `regression-retained.log`、`hdr-regression-retained.log`、`player-regression-final.log`、`build-final.log` 与 `package-check-final.json`。
交互记录见 `controls-reuse-result.json`、`hold-retained-result.json`、`long-drag-result.json`、`seek-result.json` 及 `final-*-layout.json`。

性能采样统计 `UIVsyncTask`、弹幕 Canvas 任务和绘制提交间隔。源 VSync 周期约 15.659ms，而弹幕目标为 60Hz，部分双周期提交间隔是正常节拍差异。
任务事件率、Canvas 提交率和 Surface buffer 时间均不能单独证明屏幕实际呈现帧率。
最早基线在采样期间播放结束，媒体位置及弹幕密度也不同，故本轮不提供旧版与新版的帧率提升百分比。
保底清理测试不代表原生 TouchCancel 一定不定位：平台 Slider 可能先发出 End，再发出用户 TouchCancel；本轮沿用平台的提交顺序。

最终 16.427 秒记录 `fixed-short.trace` 完整保存 498021/498021 条事件，无环形覆盖、应用同步 B/E 配对缺失。
以下耗时为线程上配对任务的墙钟时间，不是 GPU 耗时或屏幕实际呈现间隔。

| 阶段 | 界面任务最大耗时 | Canvas 任务 p95 / 最大耗时 | 相邻 Canvas 最大提交间隔 |
| --- | --- | --- | --- |
| 普通播放、再次显示控件 | 2.869ms | 0.555 / 1.244ms | 32.715ms |
| 长按 8 秒 | 8.240ms | 0.506 / 6.869ms | 34.333ms |
| 松手后 | 3.162ms | 0.460 / 0.869ms | 32.665ms |

三阶段的界面与 Canvas 任务均未超过该记录约 15.659ms 的源周期。
再次显示控件所在的界面任务为 2.869ms，Slider 全段只有更新、没有重复 Build/Destroy；与 accessibilityId 复用记录一致。
松手阶段尾部约 775ms 没有 Canvas 提交：记录明确出现 `RemoveDisplaySync`，视频 NativeWindow 仍持续提交。
这段缺少活动弹幕数量，原因尚未直接确认；不能根据阶段内相邻间隔统计，声称整个阶段都连续绘制或没有断档。
完整聚合与复现脚本为 `fixed-short-metrics.json`、`aggregate_ui_trace.py`，输入元数据为 `fixed-short-capture.json`。

另用 64MB 缓冲补采 `fixed-extended.trace`：20.441 秒、560232/560232 条事件完整，无同步 B/E 配对缺失。
长按阶段观察到 `RemoveDisplaySync(38)` → `AddDisplaySync(38)` → 同一个 Canvas(406) 恢复绘制。
两次 Canvas 之间约 4.870 秒，期间视频 NativeWindow 提交 282 次（最大相邻间隔 67.404ms）、UI 处理 22 个任务（最慢 1.779ms）。
这证明绘制可重新注册并恢复，未发生整条界面与原生提交流程卡死；缺少活动弹幕计数，仍不能确认停绘期间是否存在应该显示的弹幕。
松手后的 8.105 秒记录有 486 次 Canvas 提交，最大相邻间隔 35.238ms、尾部距离 9.233ms；所有阶段的 UI 与 Canvas 任务均未超过源周期。
补采控件再次显示任务为 2.262ms。源回调停止区间不参与“连续绘制”或“FPS 改善”结论。
证据与命令见 `fixed-extended-metrics.json`、`fixed-extended-capture.json`；聚合命令：

```sh
python3 .qa/player-fluency-20261010/aggregate_ui_trace.py \
  .qa/player-fluency-20261010/fixed-extended.trace \
  --capture .qa/player-fluency-20261010/fixed-extended-capture.json \
  --output .qa/player-fluency-20261010/fixed-extended-metrics.json
```

## 复现方式

1. 用 DevEco Studio 自带 Node、JBR、SDK 构建 release HAP；运行 `tool/qa/player-mpv-package-check.py` 检查实际 HAP。
2. 向指定模拟器安装，打开上述视频；等待片源、弹幕加载和倍速恢复。
3. 检查控件显隐、长按/松手、暂停/恢复、进度拖动、评论区收缩与全屏返回。
4. 独立采集约 16 秒 `hitrace`：4 秒普通播放、8 秒长按、4 秒松手后播放，启用 `ace graphic animation` 标签；采样时不并行构建或运行大型测试。
5. 按应用 PID 与线程独立配对 B/E 事件，检查记录完整性、任务耗时和 Canvas 间隔；不要累加嵌套任务耗时，也不要将事件率标作实际 FPS。
