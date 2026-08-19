# 动态图片 Hero 动画修复 与 性能/内存/保活测量报告

> 日期：2026-08-19
> 环境：DevEco 模拟器 `bili_dev`（HarmonyOS 6.1.0.125 / API 24），4 vCPU / 4GB RAM（QEMU guest，无 GPU 透传）。
> 测试手段：hdc + uitest（点击/返回键/layout dump）、宿主机 Python 帧分析（`snapshot_display` 暗度 + 48×104 灰度指纹差分）、设备端 `/proc/<pid>` RSS/jiffies 采样、`hidumper --mem` Pss 深采、设备端 `top`。

---

## 一、动态图片"从哪开就从哪放大/收回去"

### 1.1 目标

对齐参考视频（`e0da1ef2b2ed1dc870ba5841af5a8ff4.mp4`，cv2 帧差分分析确认）：开图 = 被点缩略图所在矩形 → 全屏展开（约 0.7s）；关图 = 全屏 → 缩回原矩形，再退场。

### 1.2 根因排查结论

| 尝试过的方案 | 结果 |
| --- | --- |
| `geometryTransition` 共享元素转场（根场景） | **不生效**：主页底部 Tabs 是 Navigation 根页面内容，根页面 push 不建立共享元素转场 |
| `bindContentCover($$state, ModalTransition.NONE)` 全屏 Cover | **API24 致命 bug**：Navigation 作用域内挂载的 ModalPage 会被框架在**挂载同帧移除**（hilog：AceNavigation `can't find inner navigation`），看图一闪即关且封面盖不回来。hilog 时间戳证据：Cover mount 07.993 → 同帧移除 08.051 |
| "根页面 push(false) 被系统强制叠加从右滑入"（旧结论） | **本机未复现**：首页视频卡 → 详情同为根场景 `pushPathByName(…, param, false)` + srcRect 手动矩形放大，转场干净无右滑 |

### 1.3 最终方案（两条路径）

- **根场景**（主页底部 Tabs 内动态流，`DynamicView.embedded=false` → `DynCard.sharedImageTransition=false`）：
  - 开：`getComponentUtils().getRectangleById(缩略图id)` 取窗口矩形 → `pushPathByName(NAV_IMAGE_VIEWER, {images, initialIndex, srcRect}, false)`；`ImageViewerPage.prepareRectEntrance()` 首帧把整页内容压到 srcRect（scale+translate，黑底 opacity=0），30ms 后 `animateTo(300ms)` 展开。与首页卡片→详情同一套已验证机制。
  - 关（点按 / 系统返回键）：`goBack()` 中 `entryFromRect && srcRect` 分支镜面回放——300ms 缩回 srcRect + 黑底淡出，310ms 后 `pop(false)`。返回键由 Index 的 `onBackPressed` 拦截（`imageViewerCloseRequest`++ → 页面 `@Watch` 走 goBack），不破坏"缩回去"动画。
- **内嵌场景**（用户空间等已入栈页面的动态流，`sharedImageTransition=true`）：保持 `geometryTransition` + `animateTo` 原路径，不变。

### 1.4 验证证据（hilog + 帧采样）

| 环节 | 数据 |
| --- | --- |
| 开：`ROOT_OPEN_VIEWER` → `VIEWER_APPEAR` | +9ms（push 首帧） |
| 开：`ENTRY_PREPARED` → `ENTRY_ANIM_DONE` | ≈366ms = 30ms 延迟 + 300ms 动画 ✓，画面确从缩略图矩形放大 |
| 开图后驻留 | 无自动消失（旧 cover bug 的"一闪即关"消除） |
| 点按关：`REVERSE_RECT` → 页面消失 | +326ms ✓，画面缩回原位置 |
| 返回键关：`NAV_BACK_CLOSE_VIEWER` → `CLOSE_REQUEST` → `REVERSE_RECT` → 关闭 | ✓ 全链路 |

> 注：上述 HeroTrace 打点为本次排查用临时 hilog，验证完成后已全部移除，`onRequestClose` 死代码一并清理。

### 1.5 遗留同类 bug（未修）

`PlayerView.ets:2240` 横屏设置抽屉仍用 `.bindContentCover($$this.showSideDrawer, …, { modalTransition: ModalTransition.NONE })`——API24 下会命中同一 ModalPage 同帧移除 bug（早测 15:01:07.993 挂载 → 08.051 移除），横屏点设置无反应。建议后续改用 in-tree 覆盖层（同页内 `@State` 控制显隐 + 动画，不经过 ModalPage）。

---

## 二、性能 / 内存 / 保活测量

### 2.1 根 Tabs 保活成本（A 组，两轮一致）

Tab 切换用 layout dump 的 `selected` 属性验证（dock 点击坐标 y=2660；**y≈2714 命中不了**，底边系手势区）。

| 状态 | RSS（轮1/轮2） | 线程 |
| --- | --- | --- |
| 首页空闲 | 270 / 267 MB | 37 / 36 |
| + 动态 tab | 359 / 354 MB（**+84~89MB**） | 40 / 42 |
| + 我的 tab | 364 / 361 MB（+5~7MB） | 40 / 42 |
| 回首页（三 tab 全保活） | 364 / 361 MB | 40 / 42 |

结论：保活开关状态正确（回首页后三个 tab 内容均未销毁、无增长）；动态流是主要保活成本（feed 数据+封面缓存）。

### 2.2 视频详情播放往返（B 组）

用"帧指纹差分 > 18"判定页面切换（不依赖画面明暗——视频内容可能是亮画面）。

| 时刻 | RSS | 线程 |
| --- | --- | --- |
| 首页空闲 | 267MB | 36 |
| 详情 6s（播放中） | **754MB** | 48 |
| 详情 20s / 36s | 754MB（**平稳，无增长**） | 41 / 37 |
| 返回首页（settle 后） | **424MB**（释放 330MB） | 39 |

- `hidumper --mem` Pss 拆解（播放 vs 首页）：

| 成分 | 首页 | 播放中 | Δ |
| --- | --- | --- | --- |
| ark ts heap（JS 堆） | 28.3MB | 26.4MB | **0（无膨胀、无泄漏迹象）** |
| native heap | 132MB | 150MB | +18MB（解码帧缓冲等） |
| dev（与渲染/解码服务共享的设备内存） | 112MB | 430MB | **+318MB ← 播放增量的主体**（视频表面，返回后回收） |
| .so / .ttf / .hap | — | — | ≈0 |

- CPU（播放中设备端 `top`）：解码**不在 app 进程**——`av_codec_service`（系统媒体进程）42.3% 做解码，`render_service` 76.9%（QEMU guest 全软件合成），app 主进程仅 15.3%；播放总消耗 ≈ 4 核 guest 的 35%。
- 返回后 RSS 424MB > 基线 267MB：+约157MB 为进程级缓存（封面/解码热路径），二次进入详情更快；HWM 停在 772MB 未再涨。

### 2.3 看图页（C 组）

- 当前测试账号"关注"feed 样本**无图片动态**（30 次滚动 + layout 确认，全部为投稿视频），单独增量无法测得。
- 参考：前一日多次 开→关→返回键 往返的 hero 验证期间 HWM 稳定无增长（同一 hap 族）。看图页为按需推入页，出栈即销毁。

### 2.4 保活结论与建议

现有配置：**3 个根 TabContent 全保活 + 各 feed 频道 `Tabs.cachedMaxCount(1, CACHE_BOTH_SIDE)` + 列表 `cachedCount 3~5`**。

- 无泄漏证据：tab 往返零增长、播放 36s 平稳、返回释放 330MB。
- 动态 tab +87MB 换取频道筛选/滚动位置/直播角标状态不重置，**建议保持**；guest 4GB 是模拟器配置（峰值占用 ~72%、swap 轻度使用），真机 6–12GB 无压力。
- 不建议再降 `cachedMaxCount`/`cachedCount`：收益 <10MB，长列表回滚/重取代价更大。
- 若未来要面向低端机，优先级应为：限制封面图解码缓存上限 > 关闭非当前频道 tab 的预取，而不是砍保活。

### 2.5 模拟器环境说明（解释"为什么慢/卡"）

- 实例实际在 **54 (wanggroup)**：`Emulator -start bili_dev -noWindow -hdcPort 15556`（headless；`-screenshot` 输出 0 字节，DevEco 模拟器无 VNC/推流参数，内核虽为 QEMU 但实例未开 vnc）。
- guest 4 vCPU/4GB：截图读回、UI 合成、软件解码全跑在模拟 CPU 上。
- 帧率上限：`snapshot_display` 单帧捕获 ≈230–400ms（不随分辨率变化）+ `file recv` ≈70–160ms → **hdc 截图链路 ≈3–4fps 封顶**（base64 走 stdout 更慢）。
- 网页控制台（已部署，当前停）：`54:/data2/xyh/emuweb/`（`emuweb.py` 端口 8099，token 在 `token.txt`；后台线程持续采集 + 32×72 灰度 sha1 变化检测，空闲不推流，支持鼠标点击/滑动/Back/Home）。重启：`cd /data2/xyh/emuweb && setsid nohup env EMUWEB_TOKEN=$(cat token.txt) python3 emuweb.py 8099 > emuweb.log 2>&1 &`

---

## 三、其他发现

1. **沉浸光感底栏**：`AppTheme.isImmersiveUiSupported() = deviceInfo.apiAvailable('26.0.0')`（`AppTheme.ets:362`）→ API24 模拟器上恒 false → 恒走 PlainTabs 实底栏。这台 VM 从来不会有玻璃浮层底栏；API26 真机会自动呈现。
2. **build-profile**：`compatibleSdkVersion` 暂为 `6.1.1(24)`（API24 模拟器运行必需；compatible 是"最低支持版本"，不影响 API26 真机），`compile/target` 仍为 `26.0.0`。
3. **设备端工具约束**（脚本调试经验）：设备无 `awk`、toybox `sed` 不支持 `\) `（用 `[)]`）、无 `/proc/cpuinfo`；`dumpLayout` 输出**整棵树**（被覆盖的根页面节点仍在），屏幕识别不能靠 id 计数，需结合 `selected` 属性/帧分析；hdc 管道命令注意引号层（Python 中用 argv 直传单参数给 `hdc shell`，避免宿主机 sh 二次解析）。
4. **官方文档**：曾以 git submodule 挂载于 `docs/openharmony-docs`（本地源仓 `ohdocs-md`，pin `8046e9d`）；因源仓 url 为开发机本地路径、其他机器无法 clone，2026-08-19 已从主仓库移除。md 摘录仍保留在开发机 `/app/rssd/xuyihan/ohdocs-md` 供本地参考。

---

## 附录：关键复现命令

```bash
# 构建（本机 SDK）
export DEVECO_SDK_HOME=... PATH=.../command-line-tools/bin:$PATH
hvigorw assembleHap --mode module -p product=default --no-daemon
# 产物 entry/build/default/outputs/default/entry-default-unsigned.hap

# 54 上安装/启停（HDC=/data2/xyh/ohos-sdk/command-line-tools/sdk/default/openharmony/toolchains/hdc）
$HDC install -r entry-default-unsigned.hap
$HDC shell aa start -a EntryAbility -b com.piliplus.harmony -m entry
$HDC shell aa force-stop com.piliplus.harmony
$HDC shell "ps -ef | grep piliplus | grep -v grep | cut -d' ' -f2"   # 取 PID（勿用 pidof，bundle 名不同）

# dock 点击（y=2660，勿用 2714 附近）
$HDC shell "uitest uiInput click 209 2660"   # 首页
$HDC shell "uitest uiInput click 628 2660"   # 动态
$HDC shell "uitest uiInput click 1046 2660"  # 我的
$HDC shell "uitest uiInput keyEvent 2"       # 返回键（根页面无推入页时=退出 app，慎用）

# 数据
$HDC shell "grep -E '^VmRSS|^VmHWM|^Threads' /proc/<PID>/status"
$HDC shell "hidumper --mem <PID>"            # 直接管道输出（重定向到设备文件会得 0 字节）
$HDC shell "uitest dumpLayout"               # 输出 /data/local/tmp/layout_*.json
```
