# 播放内核复用与验证边界

视频播放使用一个 libmpv 会话读取选中的视频 URL 和音频 URL。分离 DASH 文件通过
`audio-files` 原生字符串数组接入同一会话，音视频解码、缓冲、时间戳同步、精确定位和倍速由 mpv 管理。
业务层保留 B 站播放地址选择、画质、弹幕、字幕、播放意图和页面生命周期。
请求头采用独立的 `user-agent` 属性和 `http-header-fields` 字符串数组。
`audio-files` 与请求头均使用 `MPV_FORMAT_NODE_ARRAY`，避免把签名 URL 中的逗号、冒号当成列表分隔符。
网络连接和读取由内核处理；ArkTS/NAPI 只传地址、控制命令和状态。

## 代码职责

| 层 | 入口 | 职责 |
| --- | --- | --- |
| 业务会话 | `PlayerPlaybackSession.ets` | 播放意图、画质/CDN 重试、后台策略，以及定位和倍速控制器 |
| 内核生命周期 | `PlayerEngineController.ets` | 持有一个 `engine`，隔离旧事件，等待旧内核释放 Surface 后再创建替代实例 |
| ArkTS 适配 | `PlayerEngine.ets`、`PlayerMpvEngine.ets` | 统一命令/事件接口，将原生观测值交给会话 |
| 平台资源 | `PlayerAudioFocus.ets`、`PlayerMpvResources.ets` | 系统音频焦点、中断和 TLS CA 文件 |
| NAPI 边界 | `bilimpv.cpp` | 参数校验、状态封送、异步创建/打开/释放的完成通知 |
| 原生会话 | `mpv_session.h`、`mpv_session.cpp` | libmpv 句柄、命令队列、事件线程、媒体状态观测和销毁屏障 |

渲染使用 `vo=gpu`、`gpu-context=ohos`、`gpu-api=opengl`、`opengl-es=yes`、`egl-output-format=auto`。
0003 先查询显示器对 HDR10 / HLG 的能力，再协商精确的 EGL `10/10/10/2` 与 NativeWindow
`RGBA_1010102`，并确认默认 framebuffer 的实际位深至少 10。能力缺失、查询失败或格式协商失败时，
回退到匹配的 EGL `8/8/8/8` 与 NativeWindow `RGBA8888`，由 GPU 完成 HDR 到 SDR 的色调映射。
EGL 配置、NativeWindow 像素格式和实际 framebuffer 都经过检查，避免仅改变位深请求造成 `EGL_BAD_MATCH` 黑屏。
原生层在 `FILE_LOADED` 时检查选中的视频轨和 `current-vo=gpu`；缺失时报告视频输出错误，
分离流还检查选中的外部音轨。输出初始化成功仅表示渲染路径已建立，首帧实际呈现仍需画面与设备日志确认。

音频变速滤镜 `af=scaletempo2` 在内核创建时一次配置，普通速度下也保留实例。
固定版本的 [自动变速实现](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/filters/f_auto_filters.c)
会在 1 倍速与其他倍速之间切换时排空并添加/移除滤镜；常驻滤镜让长按开始和松手只更新速度参数，保留音调校正并避免这次重建。
会话同时合并相同倍速命令和确认事件，已选 2 倍速时长按不会重复提交变速，也不会重复更新弹幕速度。
这些配置和命令边界由原生/会话回归检查；鸿蒙虚拟机的实际切换与持续倍速结果见
[倍速运行验证](player-hold-transition-validation.md)。

## 固定的鸿蒙二进制

播放器使用共享库 `libmpv.so` 和依赖载体 `libdep.so`。新内核来自固定源码
`6edeee00a07b9b76f197aa71eee3d029fb090de4`，依次应用本仓库 `tool/mpv/patches/0001`、`0002`、`0003` 与 `0004`。
依赖载体来自原始 OHOS 20260715 发布，只有 ELF SONAME 从 libmpv.so 改为 libdep.so。
原发布及全部组件、版权和许可证信息仍保留在 sources.json 与 licenses.txt。

| 产物 | 原始构建输入 SHA-256 | 实际 HAP 中剥离后的 SHA-256 |
| --- | --- | --- |
| 新 libmpv.so | `98f14b2cc6904448b3ca6f72c34a0c8899fa9d2d4545e31e7a48df1eb76f71c9` | `66355d20da77ecf087aa0d31790fc2321c6c2b96654fea3ef1feb0a3d7d960bb` |
| libdep.so | `098e628f73f1a709bdff16de7eb5fad7d104a0d5bce68c23435b6214d57a35e0` | `098e628f73f1a709bdff16de7eb5fad7d104a0d5bce68c23435b6214d57a35e0` |

新内核剥离后 2,261,552 字节；载体剥离后 35,491,168 字节。
HAP 的散列对应 SDK `llvm-strip --strip-all` 后的产物，构建输入散列不能冒充包内散列。
完整固定输入、补丁校验值、构建选项与 ELF 检查在 `tool/mpv/rebuild-report-arm64.json`。
可复现命令见 [内核重建说明](../tool/mpv/README.md)。两库必须一起分发和替换。

0001 在 PCM 变成裸字节前记录每段的真实 PTS 与 effective rate，按硬件时间映射音频播放点
与视频显示期限；OHAudio 的 CLOCK_MONOTONIC 时间通过成对取时转换到 mpv 的进程时基。
0002 保护 OHCodec interop 初始化失败后的清理，让解码器继续走原有回退流程。
0003 接通 `vo=gpu` 的目标颜色协商：绘制前设置平台颜色和元数据，把实际接受的目标写入
`ra_fbo.color_space`，并固定 GPU shader 的输出编码，避免 SDR 像素被标为 PQ / HLG。
标准 HDR10 传递 ST 2086、MaxCLL / MaxFALL，HLG 使用对应的平台类型；同一 PQ 的元数据变化也更新。
HDR 到 SDR 切换恢复 sRGB、`NONE`、零静态元数据与零 HDR 白点亮度。
输出颜色或元数据变化时重建 EGL window surface，让新申请的缓冲携带新标签，保留 EGL context 和 GL 资源；
普通帧及倍速切换不触发这次重建。协商或提交失败时回退 SDR，无法恢复则停止输出并报告错误。
0004 保留纯尺寸变化时已协商的颜色标签，避免缩放或旋转后把同一颜色再次提交并重建 EGL surface；
真正的 HDR/SDR、静态元数据变化及失败回退仍执行原有协商与缓冲更新。
当前 ARM64 虚拟机上的评论区缩放、定位、全屏返回与弹幕/控件交互记录见
[界面流畅性验证](player-ui-fluency-validation.md)。
虚拟机使用的 GLES 格式探测兼容保护不属于 ARM 补丁。

这次核心重建使用 OpenGL，关闭新核心的 Vulkan/shaderc；相关组件仍留在原始载体中。
新核心的 `gpl=false` 不会消除载体中静态 FFmpeg 的 LGPL-3.0-or-later 分发要求。
ARM 构建报告的 runtime_validated 保持其实际值；虚拟机运行结果另见
[倍速运行验证](player-hold-transition-validation.md) 与 [HDR 输出验证](player-hdr-validation.md)，
不能把 x86_64 验证当作 ARM 验收。
替换产物时同时更新来源清单、包检查器、离线 notice 和本表，并重新检查真实 HAP。

## HDR 选源与输出验证

画质菜单中的 HDR/HDR Vivid 表示请求和选择对应的 B 站片源，不代表当前视频已经按 HDR 输出到屏幕。
视频标题、菜单标签、截图亮度、BT.2020 色域或像素位深都不能单独证明 HDR 输出。
当前业务层按 `dash.video` 的画质 ID、编解码器和 URL 选流，没有用片源颜色字段判断实际渲染输出。

当前 0003 实现标准 HDR10（BT.2020 / PQ）和 HLG，保留 `vo=gpu`。
它按片源参数生成目标，再以显示能力、实际 10 位缓冲及平台接受的颜色共同决定最终编码；
不满足条件时选择 SDR。画质菜单中的 HDR Vivid 仍只是选源请求，这条路径没有实现其动态元数据透传，
也不宣称支持 Dolby Vision 动态元数据。
原生策略与完整 EGL 上下文 fixture 已执行 13 项测试，涵盖能力缺失、10 位协商失败、元数据变化、
缓冲标签时序及失败回退。虚拟机实际不具备 HDR 显示能力，验证了 PQ / HLG 输入与 SDR 输出回退；
实际测试素材、系统缓冲结果和物理屏幕未验证的项目见 [HDR 输出验证](player-hdr-validation.md)。

### 0003 前的历史观察

以下日志来自 2026-10-09 19:15、应用 0003 之前的真机验证。片源为 `BV1R1e4zKEh1`，
在用户选择 HDR 后连续观测到：

```text
mpv.color sourcePrimaries=bt.2020 sourceTransfer=pq sourceFormat=ohcodec targetPrimaries=bt.709 targetTransfer=gamma2.2 vo=gpu
```

片源参数确认输入为 BT.2020/PQ HDR；GPU 目标参数确认当时的应用把它映射为 BT.709/Gamma 2.2 SDR 输出。
原始观测保存在本次设备验收的 `.qa/hold-transition/baseline-rates-complete.txt`。
此结果只证实补丁前的输出路径没有输出 HDR，不能据此认定手机面板不支持 HDR，也不能用它判断当前补丁的输出。
`ohcodec` 是硬解图像格式名称，本条日志没有直接给出解码缓冲区的位深。

未应用 0003 的固定 mpv 源码说明了这次历史观测的原因：

- [OHOS OpenGL 上下文](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/video/out/opengl/context_ohos.c#L100) 注册 `preferred_csp` 和 `set_color`，但补丁前的 [vo=gpu 绘制路径](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/video/out/vo_gpu.c#L79) 没有调用它们。
  [OpenGL start_frame](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/video/out/opengl/context.c#L220) 也没有填入目标色彩空间；[GPU 色彩转换](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/video/out/gpu/video.c#L2693) 因而默认 BT.709，并把 HDR 源的目标传递函数设为 Gamma 2.2，再执行色彩映射。
- 原有 [OHOS 输出实现](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/video/out/ohos_common.c#L79) 已包含 NativeWindow 的 PQ/HLG 标签与元数据设置。
  0003 将目标协商接入现有 `vo=gpu`，补足显示能力、实际位深、失败检查、元数据更新和新缓冲申请时序。

### 当前诊断与验收边界

诊断属性由固定版本的 [图像参数属性实现](https://github.com/ErBWs/mpv/blob/6edeee00a07b9b76f197aa71eee3d029fb090de4/player/command.c#L2410) 提供：

| 属性 | 含义和读取边界 |
| --- | --- |
| `video-params` | 解码后、进入视频滤镜前的图像参数；首帧解码前可能只有宽高，颜色字段不可用 |
| `video-out-params` | 滤镜后交给 VO 的图像参数，不能当作屏幕目标输出 |
| `video-target-params` | VO 发布的 GPU 目标图像参数；目标建立且实际渲染后读取，用于判断本次色彩映射结果 |
| 上述三组的 `/primaries`、`/gamma`、`/colormatrix`、`/pixelformat`、`/sig-peak` | 均由同一属性实现提供；传递函数返回 `pq`/`hlg`/`gamma2.2` 等名称，硬解可另读 `/hw-pixelformat`。`sig-peak` 是参数中的 `max_luma / 203`，不是屏幕实测亮度 |
| `current-vo`、`current-gpu-context` | 实际采用的视频输出和 GPU 上下文；不能只记录请求配置 |

属性尚不可用时保留不可用状态，不把缺失值或未知颜色推断成 SDR。HDR 验收还需关联正在播放的视频 Surface 与系统输出：

- RenderService 树的 `colorSpace`、`uifirstColorGamut`、`NodeColorSpace` 使用 [GraphicColorGamut](https://github.com/openharmony/graphic_graphic_surface/blob/d04831dfb91e4c710daea9e241353c699b06bf7c/interfaces/inner_api/surface/surface_type.h#L412)，其中 `4` 为 sRGB、`6` 为 Display P3；节点色域不包含传递函数，背景色的 Display P3 声明也不是视频缓冲区的 HDR 证据。
- [BufferQueue dump](https://github.com/openharmony/graphic_graphic_surface/blob/d04831dfb91e4c710daea9e241353c699b06bf7c/surface/src/buffer_queue.cpp#L2404) 中，`config` 后的裸数为缓冲区 `CM_ColorSpaceType`，如 `2294273` 为 sRGB；`metadataType` 为 [HDI 元数据类型](https://github.com/openharmony/drivers_interface/blob/74caef74888bc73eecd3719e59f09b7e4b4e9d6f/display/graphic/common/v1_0/CMColorSpace.idl#L123)，`0/1/2/3` 分别为无元数据/HLG/HDR10/HDR Vivid。
  同行的 `HDR` 字段是旧元数据接口状态，不是实际 HDR 输出的布尔值。应同时检查视频缓冲区色彩空间、静态/动态元数据以及合成后的输出，不能把屏幕或圆角装饰层的缓冲区当作视频 Surface。
- 上述历史验证的 `screen` dump 仅提供刷新模式、分辨率和背光等信息，没有给出面板 HDR 能力；背光数值、Surface 的默认 `displayNit` 和白点比例不能当作实测峰值亮度。

[官方 NativeWindow 使用示例](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hdr-vivid-transcoding-sdr) 分别设置输出色彩空间、元数据类型和像素格式。
当前的 `auto` 由 0003 执行能力与格式协商；位深本身不能判定 HDR/SDR。
虚拟机上的 RGBA8 / sRGB / `NONE` 是能力不足时的实际回退结果。
物理设备的 HDR 输出仍需验证真实 10 位视频缓冲、PQ/HLG 标签、元数据、合成输出与面板表现；
不能只凭配置请求或虚拟机回退测试宣称已经完成物理 HDR 验收。

## 可以独立重复的真实媒体验证

macOS/Linux 安装 `mpv` 与 `ffmpeg` 后运行：

```bash
node --test --test-timeout=20000 tool/qa/player-mpv-integration.test.cjs
```

可用 `QA_MPV`、`QA_FFMPEG` 指定可执行文件。缺少工具或在 Windows 上运行时显示明确 SKIP。
测试生成 3 秒 AVC 视频和 AAC 音频，使用真实的 HTTP 服务器及 mpv JSON IPC，且关闭画面窗口和扬声器输出。
它验证：

- 一个 mpv 实例中存在且选中一条视频轨与一条外部音轨，实际解码器识别为 H.264/AAC。
- 两条文件均由内核直接发起带 User-Agent、Referer 和 Range 的 HTTP 请求。
- 带逗号、冒号的模拟签名 URL 保持完整。
- 暂停状态下两次精确 seek、暂停时钟不推进、恢复、1.5 倍速、内核 `avsync` 和 EOF。
- 外部音频 HTTP 404 时主视频仍能加载和推进，但没有选中的外部音轨；切换备用音频 URL 后恢复同一会话的音视频解码。

mpv 将外部音频加载失败视为可忽略的附加文件错误。仅凭 `FILE_LOADED` 不能认定分离流播放成功，
桥接层必须检查 `track-list` 中存在选中的外部音轨，否则向会话报告错误，触发备用音频 CDN 重试。

测试调用本机安装的 mpv，以软件解码验证分离流协议。本次宿主版本为 mpv 0.41.0 / FFmpeg 9.0.2；
HAP 固定的是上表中的 OHOS mpv 开发版 / FFmpeg 8.0，二者不是同一个二进制。
ArkTS 适配与业务会话由 Node 替身回归验证，NAPI 与原生会话另由 C++ 边界回归和 OHOS 构建验证；
XComponent、OHCodec 及实际音画同步需要鸿蒙运行环境验收。虚拟机的播放时序与
物理设备的硬解、HDR 输出分别记录，不能互相替代。

真机验收应使用同一条曾出现问题的视频，包含连续拖动、定位时暂停、恢复、长按启动/持续/松手、快速反复长按、
从 1.5 倍速长按后还原及已选 2 倍速时长按、切清晰度、
全屏与后台返回，并检查原生解码器、丢帧、缓存、内核 A/V 误差及实际声音/画面。
高码率网络不足、设备不支持所选硬解格式等问题需要相应的降画质或错误处理，换内核本身不构成验收。

## 随 HAP 分发的第三方信息

该发布的 mpv 构建参数为 `-Dgpl=false`，mpv 源码适用 LGPL-2.1-or-later；
库内静态合入的 FFmpeg 使用 `--enable-version3`，二进制明确报告
`LGPL version 3 or later`。第三方库包的分发信息必须同时保留 LGPL-3.0-or-later 条款，
不能只标注“libmpv LGPL 2.1”。应用业务代码与此共享库的许可证范围应分别说明。

`entry/src/main/resources/rawfile/mpv/` 已加入可以离线读取的 `notice.txt`、完整 LGPL/GPL/MPL
和依赖版权文本 `licenses.txt`、固定版本/哈希/来源清单 `sources.json`，随 rawfile 资源进入 HAP。
原生共享库保留动态链接，源码仓保留桥接源码、
构建与签名步骤，使替换库后重建安装的路径可操作。
发布渠道还需提供对应版本的完整源码、适配补丁与构建脚本，或采用条款允许的源码提供方式；
一个指向会移动的分支的链接不足以描述“准确对应源码”。

发布版本的依赖表涵盖 FFmpeg、mpv、libass、libplacebo、dav1d、Mbed TLS、
FreeType、FriBidi、HarfBuzz、Fontconfig、libxml2、Little CMS、Lua、Shaderc 及其静态依赖。
清单及原文取自固定发布脚本的依赖版本，包括 Shaderc 固定的 glslang/SPIRV 依赖；
FreeType 选择 FTL，Mbed TLS 选择 Apache-2.0，完整原始双授权文本也保留在 `licenses.txt`。
交付前运行以下命令检查实际 HAP 中的原生库、链接、CA 与许可证资源：

```bash
python3 tool/qa/player-mpv-package-check.py
# 也可以传入另一个 HAP 的路径：
python3 tool/qa/player-mpv-package-check.py /path/to/entry-default-signed.hap
```

检查原生 core 的固定 SHA-256、桥接库与 core 的 ARM64 ELF、桥接库动态链接到 libmpv、
OHOS NAPI/硬解依赖、完整 CA，以及和工作区逐字节一致的版权/来源资源。
它不打印或读取签名凭据，也不能证明运行时硬解已经选中。

20260715 发布压缩包本身只包含 `libmpv.so`。因此版权文件、源码清单与重建说明需要由本仓库一起提供；
不能依赖压缩包已经附带这些内容。替换内核时，将重新构建的兼容共享库放入
`entry/libs/arm64-v8a/libmpv.so`，按仓库构建流程重新编译 NAPI、打包和签名安装。
更新上述来源与哈希后再重复构建、包检查和设备验收。
