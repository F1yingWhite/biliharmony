# BiliHarmony 全量 UI 测试流程（跨平台）

本目录同时提供两套入口：

| 入口 | 平台 | 说明 |
| --- | --- | --- |
| `run_all.py` | Windows / macOS / Linux（Python 3） | 推荐跨平台入口，纯 `subprocess`，仅依赖 Python 3 + hdc |
| `run_all_cross.ps1` | PowerShell Core（Windows/macOS/Linux） | 跨平台 PowerShell 入口，调用 run_all.py |
| `run_all.ps1` | Windows PowerShell / PowerShell Core | 原有 PowerShell 流程，保留兼容 |
| `run_all.sh` | macOS / Linux（Bash） | 包装 `run_all.py` |

## 快速开始

无需设备的服务回归：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node --test --test-timeout=20000 tool/qa/*.test.cjs
```

Windows（DevEco 装在 `D:\DevEco Studio`）等价命令，`ARKTS_TEST_TYPESCRIPT` 指向 DevEco 自带 TypeScript：

```powershell
$env:ARKTS_TEST_TYPESCRIPT = 'D:\DevEco Studio\tools\hvigor\hvigor\node_modules\typescript'
& 'D:\DevEco Studio\tools\node\node.exe' --test --test-timeout=20000 tool/qa/*.test.cjs
```

使用 DevEco 自带 Node 24 或支持测试文件通配符的新版 Node，预期全部通过。
通配符同时纳入分享、持久化竞争、分类、收藏排序及减少动效专项，避免显式旧清单漏跑新增回归。
部分 Windows 受限环境可能出现 `spawn EPERM`（Node `--test` 需要创建子进程和管道）；
此时应在允许相关进程权限的终端里运行，不能将装载失败视为业务缺陷证据。

> **锚点维护**：部分 UI 适配和未迁移用例仍使用 `methodHarness` 按源码文本切片抽取生产方法。
> 改动被切片的方法签名或紧邻注释后，必须同步对应调用处的锚点并重跑该文件，
> 否则用例会以"看起来像功能回归"的方式失败；新增领域用例优先加载完整生产模块。
> 详见 `docs/ArkUI易错清单.md` 第 17 条。

测试直接转译并执行 ArkTS 服务源码，平台网络/文件接口使用可控替身；覆盖凭证隔离、账号切换、
播放与搜索乱序响应、历史分页失败、缓存流式写入与并发限制。新增领域测试通过 `arkts-module.cjs`
加载完整生产模块，每个夹具具有独立模块缓存，只替换网络、存储、系统资源与时间边界。
播放器使用 `player-session-fixture.cjs` 驱动真实会话和可控内核事件；部分 UI 适配测试仍提取页面方法。
UI DSL 的合法性仍由完整 `CompileArkTS` 构建验证。这些测试不能替代真机播放与 UI 验收。

视频播放由一个原生 libmpv 会话管理音视频时间线。合流视频直接打开；分离 DASH 的视频 URL 和音频 URL
通过原生 `audio-files` 数组接入同一个内核，请求头同样直接传给内核。下载、缓冲、解码、定位和同步由
mpv 处理。完整的固定版本、构建来源和设备验收边界见 [播放内核复用说明](../../docs/player-core-reuse.md)。

| 播放器回归 | 验证范围 |
| --- | --- |
| `player-session.test.cjs`、`player-seek.test.cjs` | 单内核会话、定位请求合并与旧回调隔离、资源退出屏障、画质/CDN 替换和播放意图 |
| `player-clock.test.cjs`、`player-live-clock.test.cjs` | 一个内核时钟、缓冲/定位状态协调、事件时间线和实际落点回退 |
| `player-native.test.cjs` | ArkTS libmpv 适配器的命令/事件转换、播放意图与异步生命周期 |
| `player-audio-focus.test.cjs` | 平台音频焦点申请、系统中断与资源释放边界 |
| `player-mpv-native.test.cjs` | 编译完整生产 C++ 桥接文件，仅模拟 NAPI/mpv 边界，检查 seek/暂停顺序、真实销毁屏障、外部音轨缺失，以及 GLES/RGBA 配置和视频轨/输出初始化失败 |
| `player-mpv-resources.test.cjs` | CA 资源写入、局部缓冲区与部分写入、失败重试和文件释放 |
| `player-mpv-integration.test.cjs` | 宿主 mpv 实际解码分离的 HTTP AVC/AAC 文件，验证单会话轨道、原生头/Range、URL 完整性、精确定位、暂停、倍速、A/V 误差、EOF，以及外部音频 404 的无声状态检测与备用地址恢复 |

宿主 mpv 集成可独立运行：

```bash
node --test --test-timeout=20000 tool/qa/player-mpv-integration.test.cjs
```

宿主集成需要 macOS/Linux 的 `mpv`、`ffmpeg`；可用 `QA_MPV`、`QA_FFMPEG` 指定程序路径。
缺少工具或在 Windows 上运行时明确 SKIP。它关闭画面窗口和扬声器输出，验证本机 mpv 的软件解码；
本次宿主 mpv 0.41.0 与 HAP 中固定的 OHOS 开发版应分别记录。
原生桥接回归编译 `bilimpv.cpp` 与 `mpv_session.cpp`，需要 `clang++` 或 `c++`；
可用 `CXX` 指定编译器，缺少编译器时明确 SKIP。
HarmonyOS 库加载、XComponent、硬解及真机音画同步按下文播放器专项验收。
视频轨和 `current-vo=gpu` 检查只验证输出初始化；首帧实际呈现须在设备上确认。

打包完成后运行 `python3 tool/qa/player-mpv-package-check.py`。它读取实际签名 HAP，检查包名、版本名与版本码和 AppScope 一致、固定 core SHA、
ARM64 原生桥接的动态依赖，以及完整 CA、版权与准确版本来源原文确实随包携带；可传入其他 HAP 路径。
包检查不读取签名凭据，不能代替运行时内核加载、硬解选择或设备验收。

`release-publishing.test.cjs` 在临时 Git 仓库中执行真实发布脚本，仅替换 GitHub 远端边界。
它验证版本化 HAP 与校验和、每版日志范围、重复运行与同版本新提交不覆盖历史、标签冲突、
接口失败和版本降级拒绝。测试不会创建真实 GitHub 标签或 Release。

`player-interaction-ui.test.cjs` 和 `reply-vote-ui.test.cjs` 还会保留首次 Builder 的入参/闭包，
在状态变化后重放同一个生产 Builder，验证投票详情、比例和后续互动没有停在旧快照。
这是针对原生局部更新中参数捕获问题的回归；普通的整次 `build()` 重跑会漏掉这个问题，
该重放也没有模拟完整 ArkUI 渲染器，仍须配合下面的真实设备验收。
生命周期用例还覆盖二维码刷新、评论切根、动态分类、稍后再看读写竞争、直播换源、AVSession 和 PixelMap 释放、下载取消。
这些用例由审查复现转为正确行为断言；通过表示这些边界没有回归。
`architecture.test.cjs` 检查相对导入、静态循环依赖及服务/模型/组件的依赖方向。
新增测试优先执行生产领域模块，避免因页面注释和方法顺序变化而失效的文本锚点。
`video-controllers.test.cjs` 与 `video-favorite-picker.test.cjs` 直接加载拆分后的完整生产控制器，覆盖分 P 乱序、推荐重置、
回退后的观看心跳及收藏提交竞态，平台输入用可控替身提供，无需维护页面文本切片锚点。
弹幕用例覆盖同屏数量、固定轨道、混合模式、时间与屏蔽规则，以及 protobuf 未知字段的解析。
对齐用例覆盖综合搜索排序/筛选和图文混排、失败与空结果的区别、后台播放开关、SC 合并和选中状态。

评论投票专项执行完整的 `ReplyVoteApi`、`ReplyVoteController` 与实际 ArkUI 卡片构建，覆盖
`content.vote` 附件、`vote_card` 顶部卡、单选/多选、真实选项 ID、投后比例、重复点击、
账号切换和卡片复用。协议夹具 `fixtures/reply-vote-protocol.json` 来自官方前端及匿名公开 GET，
记录出处，不含账号凭证；提交测试只走受控网络边界，不会向 B 站实际投票。
登录时旧分页接口缺少顶部投票，专项还检查补取 `/main` 元数据不能阻塞或破坏评论分页。
可用 `BV16b421H7WG`（七选一，已结束）、`BV1zrMizzERZ`（多选，已结束）和
`BV1r6QcBvEqt`（顶部二选一）核对真实展示；实际投票状态以服务端为准。

另可运行 `node tool/qa/reply-vote-header.mutations.cjs` 与 `node tool/qa/reply-vote-api.mutations.cjs`：先通过基线，再在临时副本中分别
破坏元数据读取、分页隔离、账号/来源守卫、投票附件保留及页面传参，要求回归产生行为断言失败。
接口专项另破坏选项 ID、提交地址、旧接口补取标记及账号守卫。
该验证不会改动工作区源码，不能用语法错误或装载失败代替“测试确实能抓到缺陷”的证据。

其他环境可用 `node --test`，并将 `ARKTS_TEST_TYPESCRIPT` 指向已安装的 TypeScript 模块。

播放器 UI 定位器另有无需设备的 Python 回归：`python tool/qa/player_layout_test.py`。它检查真实布局形状中的抽屉遮挡、同名画质标签和返回按钮归属，GitHub 发布工作流也会执行；真实播放仍需下述设备专项。

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
- `suite_comment_vote.py` 评论投票真机专项（顶部第二答案、详情加载、查看/刷新比例、七选一及多选附件）
- `performance_probe.py` 调用设备 SmartPerf，保存 FPS/CPU/GPU/PSS 原始样本与统计
- `animation_probe.py` 分析全屏旋转连续截图的方向、重复帧和可选感知哈希
- `audit_ui.py`   UI 重叠 / 越界 / 对齐 / 行距审计
- `smoke.py`      快速冒烟入口
- `build_install.ps1` Windows 构建+安装（DevEco 装在 `D:\DevEco Studio` 时用；hvigor 输出重定向到
  临时文件再读取，因为 PowerShell 管道在大输出时会挂起；带产物新鲜度校验，拒绝安装旧 HAP）
- `ui_probe.ps1`  Windows UI 探针：`dump` / `nodes` / `tap` / `tapxy` / `back` / `start` / `stop`，
  自动 dump 到 `.qa/ui/`。`-Action tap -Text "我的"` 按文本定位并点击

## 模拟器验收 YouTube（可选）

YouTube 需要出网。应用侧 HTTP 支持可选代理，默认关闭（不配置时代码路径与历史版本一致）：

```powershell
hdc rport tcp:7897 tcp:7897
hdc shell aa start -a EntryAbility -b com.piliplus.harmony --ps netProxy http://127.0.0.1:7897
```

注意三点：

- 该参数**同时覆盖两条网络栈**：应用侧 HTTP 走 `HttpClient` 的 `usingProxy`，
  ArkWeb 播放器走 `WebProxy` 的 `ProxyController.applyProxyOverride`（API 15+）。
  **默认空值两条路径都不下发任何配置**，与历史版本一致。
  `applyProxyOverride` 是 `webview.ProxyController` 的静态方法，**不在 `ProxyConfig` 上**
  ——`docs/ArkUI易错清单.md` 第 18a 条记录了写错类名导致的误判。
- 播放器空白不要先归因于网络：初始 `about:blank` 导航会 abort 掉 `loadData` 文档，
  只看网络日志会得到相反结论（第 18c 条）。
- 公开搜索页必须声明桌面版 UA。不带 UA 时 YouTube 返回验证页/移动版页面，
  `ytInitialData` 里没有 `videoRenderer`，搜索会整体失败。该行为已由回归测试锁定。

**播放层被风控挡住时如何验收全屏/返回联动**：YouTube 的「请登录，以便我们确认你不是
聊天机器人」面板会顶掉官方控件，全屏按钮点不到。此时用 QA 探针页（默认关）验证应用侧管线：

```bash
hdc shell aa start -a EntryAbility -b com.piliplus.harmony --ps netProxy http://127.0.0.1:7890 --ps ytPlayerProbe 1
```

进任意视频详情会加载一个只有「全屏探针」按钮的本地页面（不请求任何远端内容）：点它应进入
横屏沉浸全屏并隐藏头栏，按返回键应恢复竖屏与头栏。**不传 `ytPlayerProbe` 时永远走真实播放器。**

播放器画面渲染出来后，点播放仍可能被 YouTube 的「请登录，以便我们确认你不是聊天机器人」
拦截（出口 IP 风控，第 18d 条）——它没有 `onError` 事件，既不能记成应用缺陷，
也不能当作播放验收通过。

## 产物

默认写到 `.emulator/qa/`：
- `*.jpeg` 页面截图像素证据
- `*.json` 布局 dump
- `qa_report.md` 最近套件明细
- `suite_player_report.md` 播放器专项断言明细
- `p02_dense_4k_smartperf.{txt,json}` 高负载播放性能原始数据与汇总
- `p03_full_exit_*.jpeg`、`p03_full_exit_animation.json` 全屏退出动画逐帧证据
- `SUMMARY.md` 一键汇总

## 评论投票专项

先安装本次构建的 HAP，再执行以下命令；脚本不会自动安装，也不会点击“提交投票”。
它使用公开视频的真实接口和原生 UI，只选择本地草稿及读取结果，并保留截图和 UI 树。

```powershell
$env:QA_HDC = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$env:QA_TARGET = '127.0.0.1:5555'
python tool/qa/suite_comment_vote.py

# 仅复现顶部投票首次详情加载和第二答案更新
python tool/qa/suite_comment_vote.py --header-only
```

完整运行检查 `BV1r6QcBvEqt` 的两个答案可选择，查看/刷新后真实比例条和本地选择保留；
`BV16b421H7WG` 的七个答案及 `BV1zrMizzERZ` 的多选限制、结束状态和结果正确显示。
顶部用例需要当前账号尚未投过该投票，公开样本也依赖网络及远端内容可用。
仅显示元数据答案或比例条不算加载成功：仍在加载、显示重新加载按钮、答案不可选都会失败。
报告写入 `comment_vote_vm_report.md`；可用 `QA_SHOT_DIR` 指定产物目录。

`suite_all.py` 的结果属于导航冒烟；跳过入口不能计作通过。投票提交、图片上传及弹幕发送
的离线接口回归通过，也不能据此声称已在设备上完成这些账号写入操作。

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
