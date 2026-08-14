# BiliHaromny UI 与导航设计方案 v1

> 状态：草案待评审
> 参考对象：B 站官方手机 App（Android/iOS）、BewlyBewly / BewlyCat 浏览器插件、HarmonyOS 原生沉浸光感设计规范、PiliPlus（本仓库内的 Flutter 参考实现）

---

## 0. 文档目的

当前项目处于雏形阶段：4 个页面（首页/搜索/视频详情/登录）、旧版 `router` 路由、搜索只支持"综合搜索取视频"单列表。本文档确认第一版完整 UI 方案与导航逻辑，作为后续开发的基准。核心结论：

1. **视觉语言**：沿用已有的"沉浸光感"方向（玻璃拟态 + 封面取色），向鸿蒙原生 `backgroundBlurStyle` 系统材质收敛，对标 BewlyCat 的磨砂体系。
2. **导航骨架**：以 B 站官方 App 为基准做减法，采用"首页 / 动态 / 我的"3 主 Tab + 全局搜索；路由从 `router` 迁移到 `Navigation/NavDestination`。
3. **搜索补全**：结果页补齐分类 Tab（视频/番剧/影视/直播/用户/专栏）、排序与筛选，API 常量已预留，直接接线即可。

---

## 1. 现状盘点

### 1.1 已有页面与路由

| 页面        | 文件                                       | 说明                                                                                  |
| ----------- | ------------------------------------------ | ------------------------------------------------------------------------------------- |
| Index       | `entry/src/main/ets/pages/Index.ets`       | 主框架，3 主 Tab（首页/动态/我的），`visibility` 切换保活，自制玻璃顶栏 + 底部 TabBar |
| Search      | `entry/src/main/ets/pages/Search.ets`      | 热搜/联想/结果三态切换                                                                |
| VideoDetail | `entry/src/main/ets/pages/VideoDetail.ets` | 播放器 + 简介/评论/相关三 Tab                                                         |
| Login       | `entry/src/main/ets/pages/Login.ets`       | 扫码登录                                                                              |

- 路由：旧版 `@kit.ArkUI router`，路由表 `entry/src/main/resources/base/profile/main_pages.json`。
- 沉浸式：`common/Immersive.ets` 窗口级全屏（`setWindowLayoutFullScreen`）+ 手动避让，各页 `onPageShow` 切换系统栏图标深浅。
- 主题：`common/AppTheme.ets`，`@StorageProp('accentColor')` / `isDarkMode`，跟随系统深浅色。

### 1.2 搜索现状（主要短板）

- API：`BiliApi.search(keyword, page)` → `GET /x/web-interface/wbi/search/all/v2`，**仅传 `keyword` + `page`**，客户端过滤 `result_type === 'video'`，其余类型（用户/番剧/直播/专栏）全部丢弃。
- **没有 `order` 排序参数、没有 `search_type` 分类、没有筛选**（时间/时长/分区）。
- `Constants.ets:95` 已预留 `Api.searchByType = /x/web-interface/wbi/search/type`，全项目无调用（dead code，可直接接线）。

### 1.3 其他缺口（对照官方 App）

- 无用户空间页（点 UP 主头像无去处）——这正是"搜索里看不到用户"的连带问题：即使搜到用户也没有落地页。
- 无消息页、无排行榜、无分区页；动态页无分类筛选（全部/视频/番剧/专栏）。
- 首页频道只有"推荐/热门"自制文字切换，无直播/追番。

---

## 2. 参考对象结论

### 2.1 B 站官方 App（导航基准）

- **底部导航 5 位**：首页 | 动态 | ＋发布 | 会员购 | 我的。"消息"不在底部，在首页顶栏右上角（信封 + 未读角标）。
- **首页**：顶栏 = 头像 + 搜索框（含默认搜索词）+ 游戏中心 + 消息；频道 Tab = 直播/推荐/热门/追番/影视/分区（可自定义）；双列视频瀑布流。
- **搜索**：搜索页 = 热搜榜 + 历史 + 搜索发现；结果页 Tab = **综合、视频、番剧、影视、直播、专栏、用户**（带结果数徽标）。
  - 视频排序（`order` 参数）：`totalrank` 综合 / `click` 最多点击 / `pubdate` 最新发布 / `dm` 最多弹幕 / `stow` 最多收藏 / `scores` 最多评论。
  - 视频筛选：发布时间（一天/一周/半年，`pubtime_begin_s`/`pubtime_end_s`）、时长（0-10/10-30/30-60/60+ 分钟，`duration` 0-4）、分区（`tids`）。
  - 用户排序：`order=fans|level` + `order_sort=0|1` 升降序；用户类型筛选：全部/UP主/普通用户/认证用户。
- **视频详情**：播放器 → 标题区（可折叠）→ 互动行（赞/踩/币/藏/转）→ UP 主条（关注按钮）→ 分P → Tab（简介 | 评论）。简介 tab 内含相关推荐单列流。
- **用户空间**：头部 banner + 头像/等级/认证 + 关注|粉丝|获赞；Tab = 主页/动态/投稿/收藏/追番……投稿视频支持 最新/最多播放/最多收藏 排序。
- **动态页**：顶部关注 UP 主横滑栏（直播中带 Live 角标）+ 分类（全部/视频/番剧/专栏）。

### 2.2 BewlyBewly / BewlyCat（视觉基准）

> 事实澄清：BewlyBewly（原作者 hakadao）已于 2025-02 归档停更，社区续作是 **BewlyCat**（keleus 维护），完整继承原设计语言。两者视觉体系一致，以下统称 BewlyCat。

设计语言自述 "inspired by YouTube, Vision OS, and iOS"：

- **毛玻璃（frosted glass）**为标志性特征：顶栏、Dock、弹层全部磨砂半透明；设置中有独立的毛玻璃开关 + **模糊强度滑杆**（带性能提示）、禁用阴影开关。
- **大圆角卡片** + 悬停动效；深色模式为一等公民（深/浅/跟随系统/定时四档，深色基准色 8 种预设）。
- 主题色 17 种预设（含 B 站粉 `#fb7299`、B 站蓝 `#00a1d6`）+ 自定义取色器 + 渐变主题色背景。
- 右侧悬浮 Dock 栏（类 macOS）承载页面切换与深色模式快捷开关；首页为"搜索居中 + 滚动衔接推荐流"。
- 背景壁纸支持（自动加遮罩保证可读性）。

对我们的启示：**磨砂材质要有开关和强度档位**（性能权衡是真实存在的，BewlyCat 和华为官方文档都明确提示实时模糊每帧渲染的开销）；主题色/深色体系我们已有雏形，可对齐其"预设 + 自定义"结构。

### 2.3 HarmonyOS 原生沉浸光感能力（技术底座）

- **沉浸式两方案**：
  - 窗口级：`setWindowLayoutFullScreen(true)`（我们当前方案）——全局延伸、手动避让。
  - 组件级（官方推荐）：`.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP/BOTTOM])`——只扩展该组件边界，子组件仍在安全区内。滚动 List 扩 BOTTOM、顶栏扩 TOP 是标准用法。
- **模糊材质**：
  - `backgroundBlurStyle(BlurStyle, { colorMode, adaptiveColor, scale })`：**系统材质**，即 BewlyCat 磨砂玻璃的鸿蒙等价物。`BlurStyle.BACKGROUND_THIN/REGULAR/THICK/ULTRA_THICK` 专为背景浮层设计；`colorMode` 跟随深浅色，`adaptiveColor` 支持取色模糊，`scale` 调强度。
  - `backdropBlur(radius)`：按半径背景模糊（我们当前方案，`backdropBlur(30)`）。静态场景更省性能的做法是 `blur` 或系统材质。
- **底部页签规范**（华为设计指南）：3–5 个互斥模块；HarmonyOS 6.1+ 有平铺式与**悬浮式（胶囊，"沉浸光感"材质：折射/模糊/透射背景，触控位置有光源光晕+材质形变）**两种形态；落地方式 = `Tabs` + `barOverlap = true` + 透明 `barBackgroundColor` + `barBackgroundBlurStyle`。Tabs 内 `expandSafeArea` 失效的已知坑需加 `.clip(false)`。
- **宽屏适配**：`Navigation` 分栏 + 按断点（840vp）切换"底部页签 ↔ 侧边页签（Tabs Vertical）"——为后续平板/折叠屏预留。

---

## 3. 视觉方案（v1 定稿方向）

### 3.1 设计原则

延续 README 的"沉浸光感"定位，三条原则：

1. **内容在前，材质在后**：视频封面是画面主角，玻璃材质只做承载，不抢视线。
2. **材质分层**：越靠近内容越透明，越靠近操作越实。
3. **性能可降级**：所有实时模糊可关、可调档（对齐 BewlyCat 的"毛玻璃开关 + 强度滑杆"）。

### 3.2 材质分层规范

| 层级    | 用途                        | 材质                                                                                            |
| ------- | --------------------------- | ----------------------------------------------------------------------------------------------- |
| L0 背景 | 页面底色                    | 纯色（浅色 `#F7F8FA` / 深色 `#0F1014` 系，深色基准色对齐主题色色相倾向）                        |
| L1 氛围 | 页面顶部氛围色              | 封面取色 `ImageColor.extract` → 大面积低透明度渐变（现有 `pageTint` 方案的规范化）              |
| L2 浮层 | 顶栏、底部 TabBar、搜索胶囊 | `backgroundBlurStyle(BACKGROUND_REGULAR, adaptiveColor: AVERAGE)`，降级为 `backdropBlur(18~30)` |
| L3 弹层 | 筛选面板、菜单、对话框      | `backgroundBlurStyle(BACKGROUND_THICK)` + 大圆角（20vp）+ 阴影                                  |
| L4 模态 | 全屏播放、登录              | 实底，不模糊                                                                                    |

- 模糊强度设置项：系统材质 Thin / Regular / Thick 三档，对应 BewlyCat 的强度滑杆；低端设备或设置关闭时回退为 95% 不透明度实底。
- 触控反馈：L2/L3 浮层按压时 scale 0.98 + 提亮 8%，模拟"沉浸光感"的光晕反馈（鸿蒙 6.1 悬浮式页签的指尖光晕可用 HDS 组件直接获得，自绘组件用手动动效近似）。

### 3.3 圆角与间距

- 视频卡片圆角 12vp（BewlyCat 的大圆角风格），封面内部圆角 10vp。
- 弹层/面板圆角 20vp；按钮/胶囊全圆角。
- 页面边距 16vp，卡片间距 10vp（瀑布流）。

### 3.4 主题体系

对齐 BewlyCat 的可定制结构，在现有 `AppTheme` 上扩展：

- 主题色：预设 8 种（B 站粉 `#FB7299` 默认、B 站蓝 `#00A1D6`、绿/青/紫/橙/玫瑰/黄）+ 自定义取色器；由种子色派生完整色调板（现有能力保留）。
- 深色模式：跟随系统 / 浅色 / 深色 三档（定时切换 v2 再做）；深色基准色提供 2-3 种预设。
- 首页/详情页封面取色氛围：保留现有能力，统一收敛为"取色只影响 L1 氛围层，不影响功能色"的规则，避免可读性问题。

### 3.5 暗色与模糊的实施改动

- 现状是组件内 `this.isDark ? ... : ...` 内联三目，维护成本高。v1 做一次收敛：常用色值收进 `AppTheme`（或颜色资源表），组件只读语义色（`surface`、`onSurface`、`accent`）。
- 现有 `backdropBlur(30) + saturate(1.6)` 自绘玻璃逐步替换为 `backgroundBlurStyle` 系统材质，深浅色自适应交给系统（`colorMode: ThemeColorMode.SYSTEM`）。

---

## 4. 信息架构与导航方案

### 4.1 导航骨架（v1）

```
┌─ 主框架（Navigation 根，NavDestination 栈）──────────────────┐
│  Tab 1 首页    Tab 2 动态    Tab 3 我的                        │
│  （Tabs 组件 + barOverlap + 模糊背板，替代自制 TabBar）         │
├─ 顶层页面（push 到 NavDestination 栈）───────────────────────┤
│  搜索（含结果页内部二级 Tab）                                  │
│  视频详情                                                      │
│  用户空间  ← 新增                                              │
│  登录                                                          │
│  排行榜 / 分区（v2）                                           │
│  消息中心（v2）                                                │
└──────────────────────────────────────────────────────────────┘
```

**关键决策与理由：**

1. **底部 Tab 维持 3 个（首页/动态/我的），不加"会员购/发布"。** 官方 5 tab 中，发布是创作入口、会员购是电商，第三方客户端两头都不做；PiliPlus 同样是 3 tab。消息中心 v2 放首页顶栏右上角（对齐官方信息架构）。
2. **实现上从自制 TabBar 迁移到系统 `Tabs` 组件**：`barOverlap = true` + 透明 `barBackgroundColor` + `barBackgroundBlurStyle`，直接获得 HDS 沉浸光感材质与触底渐隐等官方微动效，减少自绘维护成本；若坚持自绘，至少把材质换成系统模糊。
3. **路由从 `router` 迁移到 `Navigation + NavDestination`**：旧 router 已停止演进，Navigation 支持分栏（宽屏/平板）、转场动画、路由拦截，是未来维护的正路。Index 的三个主视图改为 TabContent，搜索/详情/空间等改为 NavDestination push。
4. **主 Tab 保活策略保留**：现状用 `visibility` 保活是对的，迁移到 Tabs 后用 `LazyForEach` + 缓存或继续 visibility 方案，保证首页瀑布流位置不丢。

### 4.2 首页（Tab 1）

对齐官方，自上而下：

1. **顶栏（L2 玻璃浮层）**：左侧头像（登录态，点击进"我的"）｜搜索胶囊（显示默认搜索词 placeholder，来自热搜 API）｜右侧消息入口（v2，带未读角标）。
2. **频道 Tab**：v1 做 推荐 / 热门 / 直播（直播 API 简单、价值高）；追番、影视、分区、排行榜放 v2。用系统 `Tabs`（barPosition 顶部）或保留自制切换条但统一组件。
3. **内容流**：双列瀑布流保留（`List .lanes(2)`），下拉刷新 + 触底加载保留；视频卡片按 §3.3 规范（12vp 圆角、时长角标、UP 主行）。

### 4.3 动态页（Tab 2）

- v1：保留现有动态流，顶部增加分类切换（全部 / 视频投稿 / 番剧 / 专栏，对齐 PiliPlus `dynamics_type`）。
- v2：顶部加关注 UP 主横滑栏（直播中带 Live 角标）。

### 4.4 我的（Tab 3）

保留现有结构，补充入口占位：历史记录、收藏、设置（设置内需含 §3.2 模糊强度、§3.4 主题设置）。具体页面 v2 逐个落地。

### 4.5 搜索（本次重点补全）

#### 4.5.1 搜索首页（现状保留，微调）

热搜榜 + 输入联想 + 历史记录（新增：本地存储，可单删/清空）。三态切换逻辑不变。

#### 4.5.2 搜索结果页（重构）

提交搜索后进入结果态，顶部二级 Tab（系统 `Tabs`，带结果数徽标）：

| Tab  | search_type     | 排序选项（order）                                                                          | 筛选                                   |
| ---- | --------------- | ------------------------------------------------------------------------------------------ | -------------------------------------- |
| 视频 | `video`         | 综合 `totalrank` / 最多点击 `click` / 最新发布 `pubdate` / 最多弹幕 `dm` / 最多收藏 `stow` | 发布时间 / 时长 / 分区（底部弹层面板） |
| 番剧 | `media_bangumi` | —                                                                                          | —                                      |
| 影视 | `media_ft`      | —                                                                                          | —                                      |
| 直播 | `live_room`     | 人气 `online` / 最新开播 `live_time`                                                       | —                                      |
| 用户 | `bili_user`     | 默认 / 粉丝数 `fans` / 等级 `level`（`order_sort` 升降序）                                 | 全部 / UP主 / 普通用户 / 认证用户      |
| 专栏 | `article`       | 综合 / 最多阅读 / 最新 / 最多喜欢                                                          | —                                      |

- v1 必做：**视频、用户** 两个 Tab + 视频排序 + 发布时间/时长筛选。
- v1 可做（API 同一接口，仅是 UI 工作）：番剧、专栏。
- "综合" Tab（`search/all/v2` 聚合页）：v2 再做（聚合页 UI 复杂：用户卡片 + 番剧卡片 + 视频流混排）。
- 排序 UI：Tab 栏下方一行横向排序 chips（对齐官方 App 的"综合排序 ∨"下拉，我们用 chips 更轻量）；筛选入口在排序行右侧"筛选"按钮，底部弹出 L3 玻璃面板。
- **用户结果项**：头像 + 昵称 + 认证标识 + 粉丝数 + 简介 + 关注按钮 → 点击进 §4.6 用户空间页。解决"搜索里看不到用户"。

#### 4.5.3 API 改造

- `BiliApi.search` 增加参数：`searchType`、`order`、`page`，切到已预留的 `Api.searchByType`（`/x/web-interface/wbi/search/type`）。
- 视频筛选参数：`duration`（0 不限~4）、`tids`、`pubtime_begin_s`/`pubtime_end_s`。
- 保留 `search/all/v2` 备用（v2 做综合 Tab 时用）。
- 参考实现：`PiliPlus/lib/models/common/search/`（`search_type.dart`、`video_search_type.dart`、`user_search_type.dart`）枚举可直接搬译。

### 4.6 用户空间页（新增，v1）

理由：搜索用户 Tab、视频详情 UP 主条、评论区头像都需要这个落地页，不做则多处断链。

结构（对齐官方，做减法）：

1. 头部（L1 氛围层）：封面取色/默认渐变 banner + 头像 + 昵称 + 等级/认证 + 签名；数据行：关注 | 粉丝；操作：关注/已关注按钮。
2. Tab：**投稿 | 动态**（v1）；收藏/追番等 v2。
3. 投稿 Tab：视频双列流 + 排序（最新发布 / 最多播放 / 最多收藏）。

### 4.7 视频详情页（微调）

- 现有 简介/评论/相关 三 Tab 对齐官方改为：**简介（内含相关推荐流，对齐官方结构）| 评论**，"相关"独立 Tab 取消，合并进简介底部。—— 此项可选，若改动成本高于收益则保留现状，v2 再议。
- UP 主条点击 → 用户空间页（§4.6）。
- 互动行（赞/币/藏/转）接入已登录态的真实 API（现状若未接需补齐）。

---

## 5. 沉浸式方案统一

| 位置                        | 方案                                                                                                                          |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| 窗口                        | 保留 `setWindowLayoutFullScreen(true)`（v1 不动，避免大改）；新页面一律用组件级 `expandSafeArea` 做避让，逐步替代手动 padding |
| 首页/动态瀑布流             | `List.expandSafeArea([SYSTEM], [BOTTOM])`，内容可滚入导航条区域                                                               |
| 顶栏                        | 顶栏容器 `expandSafeArea([SYSTEM], [TOP])`，材质延伸到状态栏                                                                  |
| 视频详情                    | 播放器黑区延伸 TOP，状态栏图标浅色（现有逻辑保留）                                                                            |
| 全屏播放                    | `Immersive.setFullscreen`（现有逻辑保留）                                                                                     |
| Tabs 内 expandSafeArea 失效 | 已知坑，加 `.clip(false)`                                                                                                     |

---

## 6. 实施路线图

### v1.0（本次范围）

1. 路由迁移：`router` → `Navigation/NavDestination`，4 页面全部迁移。
2. 底部 TabBar：自绘 → 系统 `Tabs` + 模糊背板。
3. 搜索结果页重构：视频/用户 Tab + 排序 chips + 筛选面板 + `searchByType` 接线。
4. 用户空间页：头部 + 投稿 Tab。
5. 材质收敛：L2 浮层换 `backgroundBlurStyle`，设置页加模糊开关与强度档。
6. 主题收敛：语义色收敛进 `AppTheme`。

### v1.x

- 搜索补番剧/影视/直播/专栏 Tab；动态分类；首页直播频道。

### v2

- 综合搜索 Tab（聚合页）、消息中心、排行榜/分区页、收藏/历史、宽屏 Navigation 分栏（840vp 断点）、定时深色切换、背景壁纸。

---

## 7. 决策点（已定稿，2026-08-14）

1. 底部 Tab 数量：**3 个（首页/动态/我的）**，消息位 v2 放首页顶栏右上角。——已实施
2. 底部导航实现：**迁系统 `Tabs`**（`barOverlap` + `barBackgroundBlurStyle(BACKGROUND_REGULAR)`），自绘玻璃 TabBar 已删除。——已实施
3. 搜索"综合"聚合 Tab：**放 v2**，v1 做视频/用户两个 `search/type` Tab。——已实施
4. 视频详情"相关"Tab 合并进"简介"：**保留现状**（简介/评论/相关三 Tab 不动），v2 再议。
5. 直播频道：**v2**。

v1.0 已完成的实施项：路由迁移 `Navigation/NavPathStack`（`common/AppRouter.ets` 全局导航栈）、搜索结果页（视频/用户 Tab + 排序 chips + 筛选面板 + 结果数徽标）、用户空间页（投稿 Tab + 三种排序）、材质收敛（L2/L3 浮层统一走 `backgroundBlurStyle` 系统材质，`AppTheme.floatBg/floatBlur` 全局设施，我的页新增毛玻璃开关与三档强度设置）。

## 附：主要参考来源

- bilibili-API-collect 搜索 API 文档（search_type / order / 筛选参数）
- PiliPlus 源码：`lib/models/common/search/*`、`lib/pages/search_result/*`
- BewlyCat 仓库：`github.com/keleus/BewlyCat`（Appearance 设置源码）
- HarmonyOS 设计指南《底部页签》、ArkUI 模糊效果与沉浸式开发文档（developer.harmonyos.cool 镜像）
