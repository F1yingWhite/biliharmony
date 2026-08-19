# BiliHaromny UI 与导航设计方案 v1

> 状态：**v1 已全部实施并超出原范围**（2026-08-15 更新为现状对照版）
> 参考对象：B 站官方手机 App（Android/iOS）、BewlyBewly / BewlyCat 浏览器插件、HarmonyOS 原生沉浸光感设计规范、PiliPlus（本仓库内的 Flutter 参考实现）

---

## 0. 文档目的

本文档确认第一版 UI 方案与导航逻辑，作为开发基准。核心结论：

1. **视觉语言**："沉浸光感"方向（玻璃拟态 + 封面取色），向鸿蒙原生 `backgroundBlurStyle` 系统材质收敛，对标 BewlyCat 的磨砂体系。
2. **导航骨架**：以 B 站官方 App 为基准做减法，"首页 / 动态 / 我的"3 主 Tab + 全局搜索；路由使用 `Navigation/NavDestination`。
3. **搜索补全**：结果页分类 Tab（视频/用户）、排序与筛选。

**当前实施状态**：上述三条已全部落地，且 v1.x / v2 的多数项目也已提前完成（直播频道与直播间、消息中心、收藏/历史、动态详情等），详见 §6。

---

## 1. 现状盘点（2026-08-15，以代码为准）

### 1.1 页面与路由

| 页面          | 文件                      | 说明                                                                                  |
| ------------- | ------------------------- | ------------------------------------------------------------------------------------- |
| Index         | `pages/Index.ets`         | 导航根 + 主框架：系统 `Tabs` 悬浮式 Dock（首页/动态/我的）+ 玻璃头栏 + 折叠悬浮搜索球 |
| VideoDetail   | `pages/VideoDetail.ets`   | 播放器 + 简介/评论/相关，封面取色动态主题，完整互动（赞/币/藏/关注/分享）             |
| Search        | `pages/Search.ets`        | 热搜/历史/联想/结果四态，结果页视频/用户 Tab + 排序 + 筛选面板                        |
| Login         | `pages/Login.ets`         | 扫码（TV）/ 密码（RSA）/ 短信验证码 三种登录                                          |
| LiveRoom      | `pages/LiveRoom.ets`      | 直播间：低延迟播放、WebSocket 弹幕、醒目留言、发弹幕                                  |
| Messages      | `pages/Messages.ets`      | 私信会话列表 + 聊天详情（页内二级导航）                                               |
| UserSpace     | `pages/UserSpace.ets`     | 用户空间：主页/动态/投稿三 Tab                                                        |
| DynamicDetail | `pages/DynamicDetail.ets` | 动态详情 + 评论                                                                       |
| ImageViewer   | `pages/ImageViewer.ets`   | 全屏看图（缩放/平移/共享元素转场/保存/分享）                                          |
| RelationList  | `pages/RelationList.ets`  | 关注/粉丝列表                                                                         |
| LibraryPages  | `pages/LibraryPages.ets`  | 观看历史 / 我的收藏                                                                   |

- 路由：`Navigation + NavDestination`，全局唯一 `NavPathStack`（`common/AppRouter.ets`），`PageMap` 按路由名分发，带参数守卫。
- 沉浸式：窗口级 `setWindowLayoutFullScreen` + 组件级 `expandSafeArea` 结合，系统栏图标深浅随栈顶页面切换（`common/Immersive.ets`）。
- 主题：`common/AppTheme.ets`，跟随系统/浅色/深色三档 + 8 个预设主题色 + 封面取色，全部持久化。

### 1.2 搜索（原主要短板，已补齐）

- 已切到 `Api.searchByType`（`/x/web-interface/wbi/search/type`），支持 `search_type` / `order` / 筛选参数。
- 已实现：视频、用户两个 Tab + 结果数徽标；视频排序 chips（综合/最多点击/最新发布/最多弹幕/最多收藏）；筛选面板（时长/发布时间/分区）。
- 未实现：番剧/影视/直播/专栏 Tab、"综合"聚合 Tab。

### 1.3 原缺口对照

| 原缺口           | 现状                                    |
| ---------------- | --------------------------------------- |
| 无用户空间页     | 已实现（§4.6 结构 + 动态 Tab）          |
| 无消息页         | 已实现（私信会话 + 聊天，首页头栏入口） |
| 动态页无分类筛选 | 仍未做                                  |
| 首页无直播频道   | 已实现（推荐/热门/直播三频道）          |

---

## 2. 参考对象结论

### 2.1 B 站官方 App（导航基准）

- **底部导航 5 位**：首页 | 动态 | ＋发布 | 会员购 | 我的。"消息"不在底部，在首页顶栏右上角（信封 + 未读角标）。
- **首页**：顶栏 = 头像 + 搜索框（含默认搜索词）+ 消息；频道 Tab = 直播/推荐/热门/追番/影视/分区（可自定义）；双列视频瀑布流。
- **搜索**：搜索页 = 热搜榜 + 历史 + 搜索发现；结果页 Tab = 综合、视频、番剧、影视、直播、专栏、用户（带结果数徽标）。
  - 视频排序（`order`）：`totalrank` 综合 / `click` 最多点击 / `pubdate` 最新发布 / `dm` 最多弹幕 / `stow` 最多收藏 / `scores` 最多评论。
  - 视频筛选：发布时间（`pubtime_begin_s`/`pubtime_end_s`）、时长（`duration` 0-4）、分区（`tids`）。
  - 用户排序：`order=fans|level` + `order_sort=0|1` 升降序；用户类型筛选：全部/UP主/普通用户/认证用户。
- **视频详情**：播放器 → 标题区（可折叠）→ 互动行 → UP 主条 → 分P → Tab（简介 | 评论）。
- **用户空间**：头部 banner + 头像/等级/认证 + 关注|粉丝|获赞；Tab = 主页/动态/投稿/收藏/追番……投稿支持 最新/最多播放/最多收藏 排序。
- **动态页**：顶部关注 UP 主横滑栏（直播中带 Live 角标）+ 分类（全部/视频/番剧/专栏）。

### 2.2 BewlyBewly / BewlyCat（视觉基准）

> 事实澄清：BewlyBewly（原作者 hakadao）已于 2025-02 归档停更，社区续作是 **BewlyCat**（keleus 维护），完整继承原设计语言。两者视觉体系一致，统称 BewlyCat。

设计语言自述 "inspired by YouTube, Vision OS, and iOS"：

- **毛玻璃（frosted glass）**为标志性特征：顶栏、Dock、弹层全部磨砂半透明；独立的毛玻璃开关 + 模糊强度档位 + 禁用阴影开关。
- **大圆角卡片** + 悬停动效；深色模式为一等公民（深/浅/跟随系统多档）。
- 多种主题色预设（含 B 站粉 `#fb7299`、B 站蓝 `#00a1d6`）+ 自定义取色。
- 悬浮 Dock 栏承载页面切换；首页为"搜索居中 + 滚动衔接推荐流"。

启示（已采纳）：**磨砂材质要有开关**（我的页"沉浸光感"开关，关闭即降级实底）；主题色/深色体系对齐"预设 + 派生"结构。

### 2.3 HarmonyOS 原生沉浸光感能力（技术底座）

- **沉浸式两方案**：
  - 窗口级：`setWindowLayoutFullScreen(true)`——全局延伸、手动避让。
  - 组件级（官方推荐）：`.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP/BOTTOM])`——只扩展该组件边界。滚动 List 扩 BOTTOM、顶栏扩 TOP 是标准用法。
- **模糊材质**：`backgroundBlurStyle(BlurStyle, { colorMode, adaptiveColor, scale })` 为系统材质，即 BewlyCat 磨砂玻璃的鸿蒙等价物；`backdropBlur(radius)` 按半径背景模糊作为降级方案。
- **底部页签规范**：3–5 个互斥模块；悬浮式（胶囊）形态落地 = `Tabs` + `barOverlap = true` + 透明 `barBackgroundColor` + `barBackgroundBlurStyle`（本工程用 `barFloatingStyle` + `systemMaterial`）。Tabs 内 `expandSafeArea` 失效的已知坑需加 `.clip(false)`。
- **宽屏适配**：`Navigation` 分栏 + 按断点（840vp）切换"底部页签 ↔ 侧边页签"——仍为后续平板/折叠屏预留。

---

## 3. 视觉方案

### 3.1 设计原则

1. **内容在前，材质在后**：视频封面是画面主角，玻璃材质只做承载，不抢视线。
2. **材质分层**：越靠近内容越透明，越靠近操作越实。
3. **性能可降级**：所有实时模糊可关（设置内"沉浸光感"开关）。

### 3.2 材质分层规范

| 层级    | 用途                      | 材质                                                                    |
| ------- | ------------------------- | ----------------------------------------------------------------------- |
| L0 背景 | 页面底色                  | 纯色，深色基准色对齐主题色色相倾向                                      |
| L1 氛围 | 页面顶部氛围色            | 封面取色 `ImageColor.extract` → 低透明度渐变                            |
| L2 浮层 | 顶栏、底部 Dock、搜索胶囊 | `backgroundBlurStyle` 系统材质（`AppTheme.floatBg/floatBlur` 全局设施） |
| L3 弹层 | 筛选面板、菜单、对话框    | 系统材质 + 大圆角（20vp）+ 阴影                                         |
| L4 模态 | 全屏播放、登录            | 实底，不模糊                                                            |

- 触控反馈：L2/L3 浮层按压时 scale + 提亮，近似"沉浸光感"光晕反馈；底部 Dock 的指尖光晕由系统 `barFloatingStyle` 直接提供。

### 3.3 圆角与间距

- 视频卡片圆角 12vp，封面内部圆角 10vp。
- 弹层/面板圆角 20vp；按钮/胶囊全圆角。
- 页面边距 16vp，卡片间距 10vp（瀑布流）。

### 3.4 主题体系（已实施）

- 主题色：预设 8 种（B 站粉默认）+ 封面取色联动；由种子色派生完整色调板（`ColorUtil`）。
- 深色模式：跟随系统 / 浅色 / 深色三档，启动时同步原生 ColorMode。
- 封面取色氛围：取色影响 L1 氛围层与全局强调色，功能色保持稳定。
- 全部主题设置经 `PersistentStorage` 持久化。

### 3.5 实施方式

- 语义色收敛进 `AppTheme`，组件读语义色（`surface` / `onSurface` / `accent` 等）。
- 浮层统一走 `AppTheme.floatBg/floatBlur` 全局设施（`backgroundBlurStyle` 系统材质），深浅色自适应交给系统。

---

## 4. 信息架构与导航方案

### 4.1 导航骨架（已实施）

```
┌─ 主框架（Navigation 根，NavPathStack 栈）──────────────────┐
│  Tab 1 首页    Tab 2 动态    Tab 3 我的                      │
│  （系统 Tabs + barFloatingStyle 悬浮式 Dock）                 │
├─ 顶层页面（push 到 NavDestination 栈）──────────────────────┤
│  搜索 / 视频详情 / 用户空间 / 登录 / 直播间                   │
│  私信 / 观看历史 / 我的收藏 / 关注粉丝列表                    │
│  动态详情 / 全屏看图                                         │
└──────────────────────────────────────────────────────────────┘
```

**关键决策与理由：**

1. **底部 Tab 维持 3 个（首页/动态/我的）**，不加"会员购/发布"。发布是创作入口、会员购是电商，第三方客户端两头都不做；PiliPlus 同样是 3 tab。消息入口放首页头栏（对齐官方信息架构）。——已实施
2. **底部导航用系统 `Tabs`**：`barFloatingStyle` 悬浮式 Dock + `systemMaterial`，直接获得 HDS 沉浸光感材质，替代自绘 TabBar。——已实施
3. **路由 `Navigation + NavDestination`**：支持分栏（宽屏/平板预留）、转场动画、参数守卫。——已实施
4. **主 Tab 保活**：Tabs 内视图保持状态，首页瀑布流位置不丢。——已实施

### 4.2 首页（Tab 1，已实施）

1. **顶栏（L2 玻璃浮层）**：头像（进"我的"）｜搜索胶囊（默认搜索词来自热搜）｜消息入口。
2. **频道 Tab**：推荐 / 热门 / **直播** 三频道（悬浮切换条随滚动淡出）；追番、影视、分区、排行榜待后续。
3. **内容流**：双列瀑布流（`List.lanes(2)`），下拉刷新 + 触底加载 + 按 key 去重 + 每频道独立游标/错误态。

### 4.3 动态页（Tab 2，已实施）

- 关注动态 feed：表情图文混排（按 dynId 缓存）、九宫格图片、转发展示、直播卡片直达直播间。
- 未做：分类切换（全部/视频/番剧/专栏）、关注 UP 主横滑栏、动态点赞/转发。

### 4.4 我的（Tab 3，已实施）

- 顶部用户区（头像/昵称/Lv/签名 + 关注/粉丝/获赞，可跳列表与空间页）。
- 功能列表：历史记录、我的收藏。
- 外观设置组：显示模式（跟随系统/浅色/深色）、沉浸光感开关、主题色（8 预设色板）。
- 关于、退出登录。

### 4.5 搜索（已实施 v1 必做项）

#### 4.5.1 搜索首页

热搜榜（首页头栏与搜索页共享一次请求，`HotSearchStore`）+ 输入联想（300ms 防抖 + 乱序丢弃）+ 历史记录（本地 Preferences 持久化，可删除）。

#### 4.5.2 搜索结果页

| Tab                                                                        | search_type | 排序（order）                            | 筛选                               | 状态   |
| -------------------------------------------------------------------------- | ----------- | ---------------------------------------- | ---------------------------------- | ------ |
| 视频                                                                       | `video`     | 综合/最多点击/最新发布/最多弹幕/最多收藏 | 时长/发布时间/分区（底部弹层面板） | 已实施 |
| 用户                                                                       | `bili_user` | 默认/粉丝数/等级                         | —                                  | 已实施 |
| 番剧 `media_bangumi` / 影视 `media_ft` / 直播 `live_room` / 专栏 `article` | —           | —                                        | —                                  | 待做   |
| 综合（`search/all/v2` 聚合页）                                             | —           | —                                        | —                                  | 待做   |

- 用户结果项：头像 + 昵称 + 认证 + 粉丝数 + 简介 → 点击进用户空间页。
- API：`BiliApi.search / searchByType / searchVideosByType / searchUsers / searchSuggest / getHotSearch`。

### 4.6 用户空间页（已实施）

1. 头部（L1 氛围层）：banner 氛围头部 + 头像 + 昵称 + 等级/认证 + 签名；关注 | 粉丝；关注/取关按钮。
2. Tab：主页 / 动态（内嵌 `DynamicView`）/ 投稿（最新/最多播放/最多收藏排序 + 双列流）。

### 4.7 视频详情页（已实施）

- 保留 简介/评论/相关 三 Tab 结构（决策点 4）。
- UP 主条点击 → 用户空间页。
- 互动行全部接入真实 API：点赞/点踩、投币（1/2 币 + 同时点赞）、收藏（收藏夹多选弹层）、关注、系统分享 + 上报。
- 评论：发表、楼中楼（页内二级导航）、表情包、点赞/点踩、分享成图片卡片、富文本（BV 号/时间轴跳转/@提及）。

---

## 5. 沉浸式方案统一

| 位置                        | 方案                                                                    |
| --------------------------- | ----------------------------------------------------------------------- |
| 窗口                        | `setWindowLayoutFullScreen(true)`；新页面用组件级 `expandSafeArea` 避让 |
| 首页/动态瀑布流             | `List.expandSafeArea([SYSTEM], [BOTTOM])`，内容滚入导航条区域           |
| 顶栏                        | 顶栏容器 `expandSafeArea([SYSTEM], [TOP])`，材质延伸到状态栏            |
| 视频详情                    | 播放器黑区延伸 TOP，状态栏图标浅色                                      |
| 全屏播放                    | `Immersive.setFullscreen`                                               |
| Tabs 内 expandSafeArea 失效 | 已知坑，加 `.clip(false)`                                               |
| 系统栏图标深浅              | 按 NavPathStack 栈顶页面自动重算（Index 统一调度）                      |

---

## 6. 实施路线图（现状对照）

### v1.0（原范围，已全部完成）

1. ~~路由迁移：`router` → `Navigation/NavDestination`~~ ✅（`common/AppRouter.ets`）
2. ~~底部 TabBar：自绘 → 系统 `Tabs` 悬浮 Dock~~ ✅
3. ~~搜索结果页：视频/用户 Tab + 排序 chips + 筛选面板~~ ✅
4. ~~用户空间页~~ ✅（超出：主页/动态/投稿三 Tab）
5. ~~材质收敛：L2 浮层系统材质 + 毛玻璃开关~~ ✅（`AppTheme.floatBg/floatBlur`）
6. ~~主题收敛：语义色进 `AppTheme`~~ ✅

### v1.x（部分提前完成）

- ✅ 首页直播频道（超出：完整直播间 + WebSocket 弹幕 + 醒目留言）
- ✅ 消息中心（提前：私信会话 + 聊天 + 发送文字）
- ✅ 收藏 / 历史（提前：游标分页 + 观看进度）
- ⬜ 搜索番剧/影视/直播/专栏 Tab、动态分类筛选

### v2（剩余）

- 综合搜索聚合 Tab、排行榜/分区页、稍后再看
- 动态点赞/转发、关注 UP 主横滑栏
- 宽屏 Navigation 分栏（840vp 断点）、定时深色切换

---

## 7. 决策点（定稿 2026-08-14，2026-08-15 更新状态）

1. 底部 Tab 数量：**3 个（首页/动态/我的）**，消息位放首页头栏。——已实施
2. 底部导航实现：**系统 `Tabs`**（`barFloatingStyle` 悬浮 Dock + `systemMaterial`），自绘 TabBar 已删除。——已实施
3. 搜索"综合"聚合 Tab：放 v2，v1 做视频/用户两个 `search/type` Tab。——已实施（综合 Tab 仍待做）
4. 视频详情"相关"Tab 合并进"简介"：**保留现状**（简介/评论/相关三 Tab 不动）。
5. 直播频道：原排期 v2，**已提前实施**（首页第三频道 + 直播间）。

## 附：主要参考来源

- bilibili-API-collect 搜索 API 文档（search_type / order / 筛选参数）
- PiliPlus 源码：`lib/models/common/search/*`、`lib/pages/search_result/*`
- BewlyCat 仓库：`github.com/keleus/BewlyCat`（Appearance 设置源码）
- HarmonyOS 设计指南《底部页签》、ArkUI 模糊效果与沉浸式开发文档
- 参考截图索引：`docs/ref/README.md`
