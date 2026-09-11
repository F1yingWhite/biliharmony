# YouTube 同级页 — Mac 工作交接（2026-09-11）

Windows 侧已完成并提交（4 个本地提交，**未 push**）：

| 提交 | 内容 |
| --- | --- |
| `948eee9` | 修测试夹具 CRLF 静默失配 → 123/123 |
| `bc98554` | YouTube 提升为同级平台 + 桌面 UA + 可选代理 |
| `0889f1b` | Windows 构建/UI 探针工具 |
| `066f7cf` | 文档与验证记录 |

先 `git log --oneline -5` 核对，再按下面继续。

> **Mac 侧回执（2026-09-11 同日晚）**：第一节的播放器问题已定位并修复，而且原诊断有误——
> `applyProxyOverride` 不在 `ProxyConfig` 上；`about:blank` 的直接原因是导航竞态，不是网络。
> 详见文末「Mac 侧工作回执」。下面正文保留 Windows 侧当时的判断，便于对照。

---

## 一、最高优先级：播放器画面尚未验收

**这是唯一没通过验收的功能点，请优先在 Mac 上跑通。**

`YouTubeDetail` 的 ArkWeb 播放器在 Windows 模拟器上停在 `about:blank`。已定性原因：
- 模拟器**无法到达 YouTube**（`ping www.youtube.com` 100% 丢包，`ping www.baidu.com` 正常）；
- `HttpClient` 的 `usingProxy` **只作用于 `@ohos.net.http`**，ArkWeb 内 Chromium 是独立网络栈；
- SDK 里 `webview.ProxyConfig.applyProxyOverride(proxyConfig, cb)`（静态、API 15+）本该能给
  ArkWeb 单独下发代理，但本机 API 26 SDK **编译报** `Property 'applyProxyOverride' does not
  exist on type 'typeof ProxyConfig'`（尽管它确实在 `.d.ts` 的 `class ProxyConfig` 内），故未合入。

**Mac 上要做的**：
1. 确认 Mac 能直达 YouTube（多半可以，不需要代理）。
2. 安装后进 YouTube → 点任意视频 → 看 `Web` 区域是否播放。
3. 若仍空白，**先 ping 目标域名**，再怀疑代码；并尝试 `applyProxyOverride` 在 Mac 的 SDK 上
   是否可编译——如果可编译，就把代理支持补上（模式见下）。

`HttpClient` 已支持可选代理，默认空（不配置时代码路径与历史版本一致）：

```bash
hdc rport tcp:7897 tcp:7897
hdc shell aa start -a EntryAbility -b com.piliplus.harmony --ps netProxy http://127.0.0.1:7897
```

注意 `HttpClient.proxyConfig()` 会把 `http://host:port` 解析成 `HttpProxy{host,port}`
（`HttpProxy.host` 只接受主机名，不能塞整个 URL）。

---

## 二、你指出并已修好的关键问题（勿回退）

我原先**手绘了一个 Dock**，你指出与 B 站不一致——**你说对了**。已改为与主框架
`FloatingTabs` 同构的 `Tabs` + `barFloatingStyle`。

**当时手绘的起因是个错误判断**：第一次用 `Tabs` 时 Dock 没渲染，我归因于 `Tabs` 本身，
于是改成手绘。真实根因是 **`Tabs` 上的 `controller: this.tabsController` 参数**——
主框架的 `FloatingTabs` 根本没传 controller。移除后原生 `TabBar` 正常渲染，且几何与
B 站 Dock **逐像素一致**：

```
B 站 Dock : TabBar [241,2605][1079,2794]  图标 [367,2636][448,2717]
YouTube   : TabBar [241,2605][1079,2795]  图标 [367,2636][448,2717]
```

**教训：Dock 必须走原生 `Tabs` + `barFloatingStyle`，不要手绘**——手绘无法获得
`systemMaterial` 系统玻璃光效，几何也必然漂移。

已对齐的参数（改样式时两边必须同步改）：

| 项 | 值 |
| --- | --- |
| `barHeight` / `barOverlap` | 52 / true |
| `barFloatingStyle` | `barSideMargin 16`、`barBottomMargin 16`、`systemMaterial: AppTheme.floatMaterial(glassOn)` |
| `barBackgroundColor` | `glassOn ? (isDark ? '#EA15161A' : '#00000000') : AppTheme.floatBg(isDark,false)` |
| 动画 | `animationDuration(MotionTokens.navigation)` + `animationMode(CONTENT_FIRST)` |
| `onChange` | `AppTheme.resetHeaderFade()` |
| Dock 条目 | 图标 24vp、`space: 2`、激活态**换实心图标**、激活色取 `accent`、轻触 `scale 0.78 → springMotion(0.35,0.7)` |
| 列表避让 | `contentEndOffset(Immersive.bottomInset() + 76)`，不是手算 padding |

新增资源：`ic_youtube_tab_fill.svg`、`ic_search_fill.svg`（激活态实心，`fill="currentColor"`）。

---

## 三、已实测通过（Mac 上做回归即可）

| 验收项 | 结果 |
| --- | --- |
| 平台切换 / 返回路径 | ✅ 我的 → YouTube；YouTube 我的 → 哔哩哔哩 |
| YouTube 外壳 + 三 Tab Dock | ✅ 几何与 B 站逐像素一致 |
| Dock 切换（探索/搜索/我的） | ✅ |
| 真实搜索 | ✅ 6 张卡片：标题/频道/`814,326次观看`/`1:02:24`/`1个月前` |
| 卡片几何 | ✅ 封面 615px(4:3)、标题 535=615−2×12、双列网格 |
| 详情页元数据 | ✅ `814192 次观看 · 首播开始于 2026年7月12日 · 1:02:24` |
| 网络失败态 | ✅ 诚实报错 + 重试，非空白 |
| 播放器画面 | ❌ **见第一节** |

测试：**126/126 通过**。构建：0 error，94 条 WARN 全为既有基线（改动文件未新增）。

Mac 命令：

```bash
node --test --test-timeout=20000 \
  tool/qa/regression.test.cjs tool/qa/lifecycle.test.cjs \
  tool/qa/danmaku.test.cjs tool/qa/parity.test.cjs
```

（Mac 上 `ARKTS_TEST_TYPESCRIPT` 可省，默认走 `/Applications/DevEco-Studio.app/...`）

---

## 四、不要动的东西

- **不要复用 B 站的 `PlayerView`、弹幕引擎、`components/reply/*`、`VideoActionItem`/投币收藏面板、
  `FeedCardImage`/`biliImageThumbnail`**——这些与 B 站数据模型强耦合，复用会把 B 站回归风险抬高。
- **不要为 YouTube 引入新的设计常量**。样式只从这些来源取值：
  `GlassHeaderBar`、`components/video/VideoCard.ets`（`homeStyle` 分支）、`components/FeedCardParts.ets`、
  `views/MineView.ets`（`groupBg()`）、`common/LayoutTokens.ets`、`common/MotionTokens.ets`。
- **两个平台唯一刻意的设计差异是强调色**：B 站侧 `accentColor`，YouTube 侧 `AppTheme.DANGER`。
- **不要加无法闭环的登录按钮**。账号能力未接入，YouTube「我的」页只做诚实说明 +「了解如何连接」弹层，
  账号行显示「未解锁」。理由见 `docs/YOUTUBE_2026-09-11.md`「账号范围与尚未完成项」。
- **不要去掉 `YouTubeApi.DESKTOP_UA`**。它看起来像无用 header，实际是必需的：不带 UA 时
  YouTube 返回验证页/移动版页面，`ytInitialData` 里没有 `videoRenderer`，搜索整体失败。
  回归测试 `YouTube: public pages are requested as a desktop client...` 锁定该行为。

---

## 五、未完成项（按建议顺序）

1. **播放器画面验收**（见第一节）——唯一的功能缺口。
2. ~~**搜索分页**~~：已接入（见文末回执）。网页端翻页是 InnerTube `youtubei/v1/search` 的
   continuation POST，不是给结果页加 page 参数；token 与 key 都来自上一页 HTML。
3. **`lifecycle.test.cjs` 约 20 处内联锚点**未迁入 `ANCHOR` 常量（33 处 `methodHarness` 调用中）。
   单行锚点抗漂移稍好，但同样是静默失效点。你之前问过是否该删——**结论是不该删**
   （`lifecycle` 是唯一覆盖 `DynamicView`/`BangumiDetail` 的文件）。建议迁锚点，不要删用例。
   更彻底的方向：把并发决策逻辑抽成纯模块（工程已有先例 `common/ReplyMutation.ets`），
   测试直接调模块 API，不再切片页面源码。
4. **两条消息为 "1" 的提交**（`c4b1f6a`、`61607ae`，各带 50+ 文件改动）无法从历史判断意图。
   建议在 CHANGELOG 补记，不要重写历史。

---

## 六、本次新提交的验证缺口（诚实声明）

- Dock 改为原生 `Tabs` 后，我重新验证了**渲染、几何、Dock 切换**，也重跑了 126/126 测试；
  但**改版后的「探索 → 分类 → 搜索结果」链路没有重跑完**（用户中断）。
  请在 Mac 上补一次：探索页点「音乐」→ 确认渲染 6 张卡片。
- `View` 规格、`Tabs` 参数、卡片几何都是**静态对齐**（读源码逐参数对照）+
  部分节点几何实测，不是全量视觉回归。

---

## 七、Mac 侧工作回执（2026-09-11 同日晚）

### 7.1 纠正第一节的两处结论

1. **`applyProxyOverride` 的位置写错了。** 它是 `webview.ProxyController` 的静态方法
   （API 15+），`ProxyConfig` 只是承载规则的参数对象，自己没有这个方法。Windows 侧看到的
   `Property 'applyProxyOverride' does not exist on type 'typeof ProxyConfig'` 正是**类名写错**
   的报错，不是「本机 SDK 类型索引取不到」。改用 `ProxyController` 后，同一份 API 26 SDK 上
   **编译通过、运行成功**。
2. **`about:blank` 不是网络不可达的表现。** ArkWeb 日志显示：初始 `about:blank` 导航把
   `onControllerAttached` 里刚发出的 `loadData` 文档 abort 掉了
   （`OnLoadError ERR_ABORTED(-3) ... url:data:text/***`，`loadData` 内部就是一次 `data:` 导航）。
   而 `onPageEnd` 的恢复分支被 `playerLoaded` 去重标记挡住，成了空操作。两个问题同时存在：
   **只修网络仍然是空白**。

### 7.2 本轮改动（本地提交，未 push）

| 文件 | 改动 |
| --- | --- |
| `entry/src/main/ets/services/network/WebProxy.ets` | 新增：把 `netProxy` 归一为 `scheme://host:port` 后下发给 ArkWeb；默认空值零调用 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | `netProxy` 同时下发给 `HttpClient` 与 `WebProxy` |
| `entry/src/main/ets/pages/YouTubeDetail.ets` | `onPageEnd(about:blank)` 分支复位 `playerLoaded` 后重发 `loadData` |
| `tool/qa/regression.test.cjs` | 新增 2 项：ArkWeb 代理规则归一/默认零调用；播放器文档不被初始导航顶掉 |

### 7.3 Mac 验证结果

环境：Mac 模拟器 `127.0.0.1:5555` + 本机 Clash `127.0.0.1:7890` +
`hdc rport tcp:7890 tcp:7890` + `--ps netProxy http://127.0.0.1:7890`。
（模拟器 DNS 被污染，两条 ping 都 100% 丢包——**按第一节的排查法会误判成网络不通**。）

| 验收项 | 结果 |
| --- | --- |
| 离线回归 | **128/128 通过** |
| API 26 构建 | 成功，新增代码 0 error |
| 第六节待补的「探索 → 音乐」 | ✅ 6 张真实卡片 |
| 播放器画面 | ✅ 已渲染（海报帧 + 标题浮层 + YouTube 原生控件 + `在 YouTube 上观看`） |
| 代理下发 | ✅ 启动日志 `ArkWeb proxy override applied`；不传参数冷启动零调用 |
| 实际播放 | ❌ 两个视频点播放均被 YouTube「请登录，以便我们确认你不是聊天机器人」拦截（出口 IP 风控，无 `onError`，非应用缺陷） |

### 7.4 仍在清单上的未完成项

1. **真实音视频解码/音画同步未验收**：被上述风控挡住。若要继续，需要换一个未被标记的代理
   出口（本机 Clash 选其他节点）再试，这属于改动本机代理配置，需先确认。
2. ~~搜索分页（`continuationCommand`）未接入~~ —— 已接入（InnerTube continuation + 触底加载）。
3. `lifecycle.test.cjs` 约 20 处内联锚点未迁入 `ANCHOR` 常量（不建议删用例）。
4. 两条消息为 "1" 的提交（`c4b1f6a`、`61607ae`）未补 CHANGELOG。

### 7.5 给下一轮的提醒

- `docs/ArkUI易错清单.md` 第 18 条已改写：18a 代理（含正确类名）、18c 导航竞态、18d 播放层风控。
- `tool/qa/README.md` 的「模拟器验收 YouTube」小节已同步：`netProxy` 现在同时覆盖两条网络栈。
- Mac 上构建曾因缺 `DEVECO_SDK_HOME` 失败（hvigor 报 `Invalid value of 'DEVECO_SDK_HOME'`，
  而输出目录里上一轮的 HAP 会让人误以为成功）。`tool/qa/qa_build.py` 现在会在 macOS 上
  自动指向 DevEco 自带 SDK 根目录；已显式设置的环境变量优先。
  直接 `python3 tool/qa/qa_build.py [--install]` 即可。
