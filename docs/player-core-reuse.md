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

渲染固定为 `vo=gpu`、`gpu-context=ohos`、`gpu-api=opengl`、`opengl-es=yes`、`egl-output-format=rgba8`，
使 EGL 输出格式与 XComponent 的 RGBA Surface 匹配，避免自动选择格式造成 `EGL_BAD_MATCH` 黑屏。
原生层在 `FILE_LOADED` 时检查选中的视频轨和 `current-vo=gpu`；缺失时报告视频输出错误，
分离流还检查选中的外部音轨。输出初始化成功仅表示渲染路径已建立，首帧实际呈现仍需画面与设备日志确认。

## 固定的鸿蒙二进制

| 项目 | 固定值 |
| --- | --- |
| 上游发布 | [mpv-ohos/libmpv-ohos-build 20260715](https://github.com/mpv-ohos/libmpv-ohos-build/releases/tag/20260715) |
| 构建脚本提交 | `1bab837e662ffa47ce51efd0720d3ed7c4988944` |
| 原生库 | `libmpv.so`，arm64，35,491,168 字节，OHOS API 15+ |
| SHA-256 | `672e98d497199a89e20893979ecec686dee1113bbe1b609c9a9266aa1679bd32` |
| 内嵌 mpv 版本 | `mpv v0.41.0-dev-g6edeee00a` |
| mpv 对应源码 | [ErBWs/mpv 6edeee00a07b9b76f197aa71eee3d029fb090de4](https://github.com/ErBWs/mpv/tree/6edeee00a07b9b76f197aa71eee3d029fb090de4) |
| 内嵌 FFmpeg 版本 | `n8.0`，带 OHCodec 适配 |
| FFmpeg 对应源码 | [FFmpeg/FFmpeg 140fd653aed8cad774f991ba083e2d01e86420c7](https://github.com/FFmpeg/FFmpeg/tree/140fd653aed8cad774f991ba083e2d01e86420c7)，`n8.0` 标签对应提交 |

以发布标签中的下载脚本、补丁和版本表为重建依据。
[发布版本表](https://github.com/mpv-ohos/libmpv-ohos-build/blob/1bab837e662ffa47ce51efd0720d3ed7c4988944/download/deps-version.sh)
中的 FFmpeg 引用为 `n8.0`，下载自 FFmpeg 上游；mpv 引用为 `feat-ohos-0.41.0`。
当前 `main` 已在发布后改动，不能把最新脚本当成此二进制的准确构建来源。
更换二进制时同步更新版本、哈希、源码引用、依赖许可证和验证结果。

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
XComponent、OHCodec 及实际音画同步需要真机验收。各层验证结果分别记录。

真机验收应使用同一条曾出现问题的视频，包含连续拖动、定位时暂停、恢复、倍速、切清晰度、
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
