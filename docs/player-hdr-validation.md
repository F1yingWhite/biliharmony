# HDR 输出实现与验证

本次实现标准 HDR10（BT.2020 / PQ）和 HLG 输出。片源画质名不能证明屏幕输出：只有显示能力、真实缓冲位深、渲染目标及平台色彩设置都满足条件，才启用 HDR。其余情况由同一渲染器完成 HDR → SDR 色调映射。

## 输出链路

- 保留 `vo=gpu`，在绘制当前帧前把平台接受的色彩空间写入 `ra_fbo.color_space`。GPU shader 实际按此目标编码 PQ/HLG 或 SDR；不是渲染后只添加标签。
- 独立检查主屏是否支持 HDR10、HLG；能力查询失败或缺失时保守回退 SDR。
- 自动协商精确的 EGL `10/10/10/2`、NativeWindow `RGBA_1010102`，并确认默认 framebuffer 的实际位深至少 10。协商不成功时，在创建渲染资源前选择匹配的 `RGBA8888`。
- 传递 HDR10 的 SMPTE ST 2086、MaxCLL / MaxFALL 静态元数据。同一 PQ 类型的元数据变化也更新。
- SDR 恢复 sRGB、`NONE` 元数据类型、零静态元数据及零 HDR 白点亮度。此路径不生成 Dolby Vision / HDR Vivid 动态元数据；`NONE` 使继承的动态信息失效，不宣称通过不支持的空值 API 删除了它。
- OHOS 在请求缓冲时复制色彩标签。输出色彩或静态元数据变化后，重建 EGL window surface 以丢弃可能预取的旧标签缓冲，保留 EGL context、配置及 GL 资源；同时清理已编码画面缓存。
- 普通帧、长按加速及松手不重建输出 surface。渲染配置或元数据失败时降级 SDR；无法恢复时停止并向播放层报告错误，避免继续提交错误编码的画面。

## 测试素材及范围

`tool/qa/generate-hdr-fixtures.py` 从明确的数学亮度刺激生成本地视频，并用 ffprobe 核验实际编码。PQ 片包含 0.005–1000 nits 灰阶、BT.2020、10 位 HEVC Main 10、ST 2086、CLL=1000 / FALL=400；HLG 片采用 BT.2100 OETF、BT.2020、10 位 HEVC；SDR 片使用 8 位 AVC / BT.709。三片含移动帧标记和 AAC 音轨。

虚拟机是 HarmonyOS 7 / API 26、x86_64、Mate 80 Pro Max 配置。它实际报告 `hdrFormats=[]`。生产逻辑因此应选择 SDR。另用仅存在于 QA 构建的能力注入检查 HDR 分支；注入不改变生产二进制，不代表虚拟机或手机屏幕已支持 HDR。

隔离测试页模板为 `tool/qa/player-hdr-probe.ets.in`，使用实际 `PlayerView` 和原生播放器读取打包的本地片源。生产应用不包含测试页、测试视频或能力注入。素材播放和能力注入测试只操作虚拟机；后续用户明确要求的手机只读观测另见下节。

## 2026-10-09 验证结果

| 项目 | 结果与边界 |
| --- | --- |
| 原生 HDR / EGL 故障回归 | 13 项通过、0 跳过。将交付的 `0003` 补丁应用到固定上游源码，实际执行 `ohos_common.c` 与完整 `context_ohos.c`。覆盖 PQ/HLG 独立能力、静态元数据变化、HDR→SDR、10 位配置失败、实际 FBO 仅 8 位、驱动改写标签、surface/swap 失败、阻止错误帧提交和终止只通知一次。平台/EGL 调用由边界替身提供；这不是实际 10 位 GPU 或面板验收。 |
| 播放适配、会话、资源回归 | 63 项通过；20 项依赖 POSIX 的 C++ 会话测试在 Windows 明确跳过。原生桥接仍经过 OHOS 编译与链接。 |
| ARM 正式构建 | 编译、签名及实际 HAP 检查通过。检查包内 ELF、链接、来源散列、CA 和许可证；报告生成时 ARM 运行时未验收，后续手机当前 HDR 状态的只读观测另见下节。 |
| VM 实际 PQ / HLG 片源 | 确认输入为 `bt.2020/pq` 或 `bt.2020/hlg`、`yuv420p10`；能力缺失时实际 GPU 目标为 `bt.709/srgb`，完成 SDR 回退。 |
| VM 强制能力 QA 构建 | 显式标注能力注入；精确 10 位 EGL 配置创建失败，随后匹配 RGBA8888 / FBO 8 位回退成功。这只验证协商失败分支。 |
| VM 输出配置 / 切换 | PQ→HLG→SDR 保持 SDR 输出；NativeWindow 接受 sRGB、NONE、零静态元数据、零 HDR 白点。视频 Surface 的实际缓冲为 RGBA8888、元数据类型 NONE。此 VM 的缓冲 dump 未提供可用的 HDR 色彩空间证明。 |
| 正常应用 | 已安装无原生诊断日志、无能力注入、无测试页或测试素材的 x86_64 HAP。普通视频播放、定位、长按/松手、横屏全屏与返回可用；横竖屏往返及最后暂停后，累计输出丢帧由 1 增至 6，不能宣称此过程零丢帧。最终暂停时钟保持 820620 ms。 |

普通 B 站视频使用 `BV1R1e4zKEh1`，虚拟机未登录，实际取得的流是 BT.709 / BT.1886 SDR；标题包含 HDR 不改变这一事实。严格对照同一开头片段、定位后预热 14 秒，再执行两次 1.8 秒长按（间隔 1.4 秒，最后松手 1.8 秒）：旧版 289 条缓冲提交记录，最大间隔 49.821 ms；新版 296 条，最大间隔 58.502 ms。两者均无超过 80 ms 的间隔，长按过程没有新增解码或输出丢帧。新版再定位到约 500 秒后，普通速度约 0.96 媒体秒/墙钟秒；再次两次长按最大提交间隔 71.913 ms、无超过 80 ms 的间隔、无新增丢帧；倍速切换短时采样最大 A/V 误差 49.7 ms，最长重复时钟 32 ms。

早先一次恢复历史进度的新版运行约 0.65 媒体秒/墙钟秒、出现 10 个输出丢帧，后续同片段对照和重新定位未复现，保留为异常观测，不能据此证明或否定所有环境下的性能回退。额外的 SDR shader 优化候选没有纳入交付。

本地 HLG→SDR 的软件渲染在虚拟机中仍有不均匀提交：相同测试旧版最大 234.031 ms、新版最大 230.309 ms，双方各 15 个间隔超过 80 ms。该结果不能归因于新 HDR 输出，也不能作为 HDR 播放完全无停顿的证明。这里的所有间隔来自 RenderService 缓冲提交时间，不是屏幕最终呈现时间。

原始素材报告在 `.qa/hdr/media/fixtures-report.json`；原生回归在 `.qa/hdr/native-fixture-context.log`；ARM 检查在 `.qa/hdr/final-arm-package-validation.json`；虚拟机正常、能力注入和旧版对照日志在 `.qa/hdr/`。这些运行产物不随应用分发。

## 23:08 手机当前 HDR 状态

用户明确要求检查已连接手机当前是否 HDR 后，只读取正在运行的应用、RenderService 和视频 Surface 状态；没有重新安装、启动、停止应用或操作播放控件。以下是同一当前会话的观测，而非仅根据片源名称判定：

```text
sourcePrimaries=bt.2020 sourceTransfer=pq sourceFormat=ohcodec
targetPrimaries=bt.2020 targetTransfer=pq vo=gpu
```

当前可见的 `playerSurfaceSurface` 已有视频缓冲；正在消费的 `state=3` 缓冲和其余缓存均为像素格式 `34`（RGBA 10/10/10/2）、颜色空间 `2360324 / 0x240404`（BT.2020 / PQ / full range），`metadataType=2`（HDI HDR10），并携带 48 字节 HDR 静态元数据，动态元数据为空。HDR 白点比例为 1。源参数、实际 GPU 目标编码、10 位视频缓冲、平台 PQ 标签及 HDR10 元数据共同确认：当前应用视频输出链路确实在输出标准 HDR10，已经改变此前 HDR 输入映射为 SDR 的行为。

NativeWindow 的公开枚举与 HDI dump 枚举不是同一套数字；这里 `metadataType=2` 按 HDI 定义解释。dump 同行的 `HDR=0` 是旧元数据接口字段，不能覆盖当前缓冲的色彩空间与 HDR10 元数据证据。设备 `screen` dump 未提供最终显示 EOTF 或实测亮度，因此此结论不等同于测量面板峰值或系统合成后的光学效果，也没有验证手机 HLG、HDR→SDR 往返或所有播放控制。

本次日志在播放时显示 `hwdec=ohcodec`、解码器累计丢帧 0、输出累计丢帧 36；这次只读状态检查没有执行长按流程，不能作为手机零丢帧或完全无停顿的证明。原始只读记录保存在未入库的 `.qa/hdr/phone-current-*`。固定 ARM 构建报告保留其生成时的 `runtime_validated=false`，避免为追加运行记录改变报告散列。

## 交付产物

| 产物 | SHA-256 |
| --- | --- |
| `0003-ohos-hdr-output.patch` | `8735cfbf347e81173797e771c0155be806175f72c93e897aeddf13ec9899e091` |
| ARM 原始 `libmpv.so` | `f904d78b7c227c659f53131e65033218be8b77d5ce49d18acad5be6f5d4597b3` |
| ARM HAP 包内 `libmpv.so` | `5a8279b527ff889ab273f93aded9ca96006f2d11e4abc391456c5c6bd725c9ce` |
| `entry-default-signed.hap` | `f48885626e0bf8911b69e9c9a3eb3d515f3d6f8349f6dc162c7a5637ecbdc748` |
| VM 正常构建原始 `libmpv.so` | `2e579dd3b85056020ce350241fa28b253a3a2e5242d39ee85cb83cf427a70014` |
| VM `vm-hdr-release-signed.hap` | `cf913d7578ed9a821476629458fa477f30f3a9bc06f3de46a2d2a950136b1aa2` |

ARM HAP 与 x86_64 虚拟机 HAP 分开构建；虚拟机的运行结果不能替代 ARM 运行证明。包检查器会拒绝生产库中的能力注入与原生诊断标记。原有长按音频时间线和解码初始化失败清理的 9 个源码文件保持此前修复内容，详见 [倍速运行验证](player-hold-transition-validation.md)。

## 平台依据

- [Huawei NativeDisplayManager 显示能力](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/capi-oh-display-info-h)：主屏 HDR 格式能力。
- [Huawei 视频色彩空间与元数据接口示例](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hdr-vivid-transcoding-sdr)：像素格式、颜色空间、元数据分别设置并检查结果。
- [OpenHarmony NativeWindow 实现](https://github.com/openharmony/graphic_graphic_surface/blob/master/surface/src/native_window.cpp) 和 [ProducerSurface 缓冲请求](https://github.com/openharmony/graphic_graphic_surface/blob/master/surface/src/producer_surface.cpp)：元数据缓冲时序。
- 固定 mpv 源码、依赖、完整本地补丁及 ARM 构建报告见 `tool/mpv/` 与 `entry/src/main/resources/rawfile/mpv/sources.json`。

屏幕峰值亮度、面板色域、系统最终色调映射以及实际手机上的 HDR 发光效果，不能用虚拟机、截图、格式枚举或画质名称证明。本次不会把这些项目列为已验证。
