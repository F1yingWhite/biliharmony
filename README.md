# BiliHaromny（哔哩哔哩 · 鸿蒙原生版）

基于开源 Flutter 项目 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 移植并扩展的**鸿蒙原生（HarmonyOS NEXT）哔哩哔哩第三方客户端**。

- 语言/UI：ArkTS + ArkUI（声明式）
- 目标 SDK：**HarmonyOS API 26**（compileSdkVersion / compatibleSdkVersion / targetSdkVersion = 26.0.0）
- 构建：hvigor + ohpm（零第三方依赖，仅使用系统 Kit）
- 工程根目录即 DevEco Studio 工程，可直接 Open 打开

> 仅供学习交流使用。所有接口均来自 B 站官方公开 API，不提供任何破解内容。
>
> 完整能力清单与更新历史见 [CHANGELOG.md](CHANGELOG.md)。

---

## 功能

### 浏览

| 模块 | 说明 |
| --- | --- |
| 首页 | 推荐（app 端 `/x/v2/feed/index`）/ 热门（`/x/web-interface/popular`）/ **直播** 三频道，双列瀑布流、下拉刷新、触底加载、按键去重；**长按卡片「不感兴趣」**（本地隐藏，Web 无服务端不感兴趣接口）；热门频道顶部提供 **排行榜**（全站/每周必看/入站必刷）与 **分区频道** 入口（`pages/ZoneChannelPage.ets`） |
| 搜索 | 热搜榜 + **趋势榜**（`x/v2/search/trending/ranking`，双榜点击直达搜索）、**搜索默认词**、搜索历史（本地持久化）、输入联想（防抖 + 乱序丢弃）；结果页 **综合/视频/番剧/影视/直播/专栏/用户** 七 Tab，综合聚合混排，视频排序 chips 与筛选面板，**用户类型筛选（全部/UP主/普通/认证）+ 粉丝数/等级排序**，番剧/影视进番剧详情页，直播进直播间，专栏进 App 内阅读页（Web 容器，`pages/ArticlePage.ets`） |
| 动态 | 关注动态 feed：顶部**关注 UP 主横滑栏**（头像直达用户空间 + 直播中红角标）、表情图文混排、九宫格图片、转发展示、直播卡片直达直播间；**点赞/转发**、**全部分类筛选（全部/视频/番剧/专栏）**、**发布纯文字动态**、**动态举报**（卡片「⋯」原因选择） |
| 视频详情 | 简介/评论/相关推荐，分 P、**UGC 合集选集 + 播完自动下一集**、视频章节、"N 人正在看"；**自动连播**（合集下一集，无合集时自动播「相关推荐」第一条，可开关） |
| 用户空间 | Banner 氛围头部 + 资料卡，主页/动态/投稿三 Tab（投稿支持最新/最多播放/最多收藏排序），关注/取关、关注/粉丝列表 |
| 动态详情 | 正文/表情/评论完整呈现，首屏复用 feed 对象直出，评论可点赞/点踩/楼中楼 |
| 历史/收藏 | 观看历史（游标分页 + 观看进度 + **长按删除单条** + **一键清空**）、我的收藏（收藏夹/收藏集双分类）、**稍后再看**、**收藏夹管理（新建/重命名/删除/批量移动）**、**收藏夹排序**（根列表「排序」页）+ **夹内视频排序**（编辑模式 ↑↓ 调整，退出自动保存） |
| 追番 | **我的追番/追剧列表**（「我的」入口，番剧/影视标签切换，点击进番剧详情，`pages/BangumiListPage.ets`；数据源 `x/space/bangumi/follow/list` 带 vmid；**踩过坑：pgc/web/follow/list 不返回数据、new_ep 是对象不能当字符串**）；**番剧索引**（按 番剧/国创/影视/剧集/纪录片 × 全部/连载中/已完结 筛选的三列聚合，`pages/BangumiIndexPage.ets`）；**新番时间表**（索引页右上「时间表」，`pgc/web/timeline` 前后排播组天、点集进详情，`pages/BangumiTimelinePage.ets`） |
| 全屏看图 | 捏合缩放、拖动平移、共享元素转场、保存相册、系统分享；**3MB 以下图片打开直接加载原图**（大图仍先低清后手动切换，省内存 + 防白屏） |

### 播放器

| 能力 | 说明 |
| --- | --- |
| 播放 | 系统 AVPlayer + XComponent 渲染；**DASH（fnval=4048）音视频分流双播放器同步**，多 URL 容错；登录走 WBI playurl，游客试看 |
| 弹幕 | Canvas 自绘弹幕引擎：滚动/顶部/底部、车道分配防碰撞、透明度/速度/字号/密度调节、分类屏蔽、**播放器内发弹幕**、**protobuf 分段加载**、**弹幕列表面板**、**屏上点击弹幕即可举报**（原因选择）、**屏蔽词/正则/屏蔽用户管理** |
| 手势 | 双击播放暂停、长按 2x 倍速、横滑进度预览、上下滑音量/亮度 |
| 控制 | 清晰度实时换源、倍速面板、横屏全屏、紧凑模式（详情页滚动使播放器变矮时自动精简控制条）、**CC 字幕轨道选择与开关** |
| 特色 | **SponsorBlock 空降**（自动跳过赞助片段，可开关）、章节/分段刻度进度条 |

### 直播

- 低延迟 AVPlayer 直播流播放、画质切换、全屏
- **WebSocket 弹幕客户端**（进房握手、心跳、断线重连）：实时弹幕/表情/醒目留言（SC），合帧缓冲渲染
- 直播弹幕浮层复用视频同款 Canvas 分轨引擎；发弹幕走 HTTP 接口
- **直播分区页**（`pages/LiveZonePage.ets`：一级分区网格 + 按人气排序的直播间列表，入口在首页直播频道顶部）
- 入口：首页直播频道、动态直播卡片、用户空间开播状态

### 互动（登录后）

- 视频：赞/点踩、**长按点赞一键三连**（赞+币+藏，`x/web-interface/archive/like/triple`）、投币（1/2 币、可同时点赞）、收藏（单击快捷收藏到默认夹，**长按弹「选择收藏夹」多选面板**）、关注 UP 主、**关注分组**（用户空间「分组」面板）、系统分享 + 上报、**用户空间举报/拉黑入口**
- 评论：发表、点赞/点踩、**楼中楼**（树形缩进/折叠 + 页内二级导航）、表情包面板、富文本解析（BV 号/时间轴跳转/@提及）、**评论分享成图片卡片**（截图 + 二维码）、**评论举报**（更多菜单 + 原因选择）、**删除自己的评论**（更多菜单红字 + 二次确认，主列表/楼中楼同步移除）
- 私信：会话列表、聊天详情（游标分页）、自动已读、发送文字私信、**会话删除**（行右缘「⋯」）、**举报对方**（聊天页右上「举报」，`x/bplus/im/report/add`）；入口在首页头栏
- 通知：回复/?@我/赞/系统四 Tab，未读角标，**长按删除单条通知**（`x/msgfeed/del`、`x/sys-msg/del_notify_list`）、**全部已读**（本地清角标，B 站无批量已读接口）

### 账号

- 三种登录方式：**TV 扫码**（轮询 + Cookie 保存）、**密码**（RSA 公钥加密）、**短信验证码**
- 登录态 Preferences 持久化，Cookie 罐导入/导出
- **黑名单管理**（「我的」入口：已拉黑用户列表 + 一键解除，`pages/BlackListPage.ets`）

## 沉浸光感效果（重点）

1. **封面取色动态主题**：进入视频详情时下载封面 → PixelMap 采样 → 量化分桶提取主色/鲜艳色 → 生成 Material You 风格色调板，全局强调色随封面联动（顶部渐变、按钮、标签、Tab 图标实时变色）。
2. **玻璃拟态（HarmonyOS 光感）**：浮层统一走 `backgroundBlurStyle` 系统材质（`AppTheme.floatBg/floatBlur` 全局设施）：顶部玻璃头栏、首页频道切换悬浮条、搜索胶囊、筛选/菜单弹层；底部导航用系统 `Tabs` 悬浮式 Dock（`barFloatingStyle` + `systemMaterial`）。毛玻璃可在设置中一键关闭降级为实底。
3. **光效辉光**：主题色径向光晕（Logo 光晕、导航激活项辉光、Tab 发光指示条、播放区氛围光），柔化卡片投影，按压反馈动画。
4. **沉浸式布局**：窗口级全屏 + 组件级 `expandSafeArea` 结合，状态栏/导航栏与页面同色一体化，图标深浅随栈顶页面自动切换；播放页横屏自动隐藏系统栏。
5. **主题体系**：跟随系统/浅色/深色三档显示模式（同步原生 ColorMode），8 个预设主题色板 + 封面取色，背景/卡片/文字/分割线全部从种子色派生；所有主题设置持久化。卡片质感参考 BewlyCat 插件风格。

## 目录结构

    entry/src/main/ets/
    ├── entryability/EntryAbility.ets   # 入口：主题初始化 + 沉浸式系统栏配色
    ├── pages/                          # 路由页（Navigation/NavDestination）
    │   ├── Index.ets                   # 主框架：Tabs 悬浮 Dock + 玻璃头栏
    │   ├── VideoDetail.ets             # 视频详情（取色/播放器/互动/评论）
    │   ├── Search.ets                  # 搜索（热搜/历史/联想/结果）
    │   ├── Login.ets                   # 扫码/密码/短信登录
    │   ├── LiveRoom.ets                # 直播间
    │   ├── Messages.ets                # 私信会话 + 聊天
    │   ├── UserSpace.ets               # 用户空间
    │   ├── DynamicDetail.ets           # 动态详情
    │   ├── ImageViewer.ets             # 全屏看图
    │   ├── RelationList.ets            # 关注/粉丝列表
    │   └── LibraryPages.ets            # 观看历史 / 我的收藏
    ├── views/                          # 主 Tab 视图
    │   ├── HomeView.ets                # 推荐 / 热门 / 直播
    │   ├── DynamicView.ets             # 动态（可内嵌用户空间页）
    │   └── MineView.ets                # 我的（用户区/历史/收藏/外观设置）
    ├── components/
    │   ├── PlayerView.ets              # 播放器主体（AVPlayer + 弹幕引擎）
    │   ├── Player*.ets                 # 播放器子件：底栏/进度条/手势/设置/全屏头栏/弹幕支撑
    │   ├── LivePlayerView.ets          # 直播播放器
    │   ├── Reply*.ets                  # 评论：卡片/发送栏/表情面板/楼中楼/分享卡片
    │   ├── VideoCard.ets / LiveRoomCard.ets / FeedCardParts.ets  # 信息流卡片（@Reusable）
    │   └── GlassHeaderBar / PageHeader / LoadingView 等通用 UI 件
    ├── api/BiliApi.ets                 # B 站接口层（按功能分组，见下）
    ├── model/Models.ets / LiveModels.ets
    └── common/
        ├── AppRouter.ets               # 全局 NavPathStack + 路由表 + 参数守卫
        ├── WbiSign.ets / AppSign.ets / Md5.ets   # WBI / App 签名（纯 ArkTS MD5）
        ├── RsaUtil.ets                 # 密码登录 RSA 加密（cryptoFramework）
        ├── HttpClient.ets              # @ohos.net.http 封装 + Cookie 罐
        ├── LiveDanmakuClient.ets       # 直播弹幕 WebSocket 客户端
        ├── UserStore.ets / SearchHistoryStore.ets / HotSearchStore.ets  # 登录态/搜索历史/热搜
        ├── ImageColor.ets / ColorUtil.ets / AppTheme.ets  # 取色 / 色调板 / 动态主题
        ├── Immersive.ets               # 沉浸式窗口工具
        ├── ReplyContentParser.ets / ReplyTree.ets  # 评论富文本解析 / 楼中楼构树
        ├── PlayerCommandBus.ets        # 评论时间轴 → 播放器 seek 等跨组件命令
        ├── ImageUrl.ets / Constants.ets / LayoutTokens.ets / BasicDataSource.ets / Utils.ets
    └── resources/                      # 字符串 / 颜色 / 图标

## 构建

### DevEco Studio

1. 打开工程根目录（本目录），SDK 需含 **HarmonyOS API 26**（工具 → SDK Manager）。
2. File → Sync 后直接 Run（自动签名），或 Build → Build Hap(s)。

### 命令行（macOS，已配置 DevEco Studio）

    bash tool/build.sh          # 或 bash tool/build.sh clean

脚本内置全部环境变量（hvigor/npm 缓存收进工程 `.home/`），产物：

    entry/build/default/outputs/default/entry-default-unsigned.hap

> 首次构建需要网络（hvigor 会安装 pnpm）。签名请用 DevEco Studio 的自动签名；命令行产物为未签名 HAP。

## 移植对照（PiliPlus → BiliHaromny）

| PiliPlus (Flutter) | BiliHaromny (ArkTS) |
| --- | --- |
| lib/utils/wbi_sign.dart | common/WbiSign.ets |
| lib/utils/app_sign.dart | common/AppSign.ets |
| lib/http/init.dart + dio | common/HttpClient.ets（@ohos.net.http） |
| lib/http/video.dart | BiliApi.getRecommendApp / getHot / getPlayUrl |
| lib/http/reply.dart | BiliApi.getReplies / addReply + ReplyTree.ets |
| lib/http/search.dart | BiliApi.search / searchByType / searchSuggest / getHotSearch |
| lib/http/login.dart（扫码/密码/短信） | BiliApi.getTVCode / loginByPassword / loginBySms + RsaUtil.ets |
| lib/http/live.dart + 弹幕 socket | BiliApi.getLive* + common/LiveDanmakuClient.ets |
| lib/http/msg.dart | BiliApi.getMessageSessions / sendPrivateMessage |
| lib/http/fav.dart / history | BiliApi.getFavorite* / getHistory |
| lib/utils/theme_utils.dart（Material You） | common/ColorUtil.ets + AppTheme.ets |
| mpv/media_kit 播放 | 系统 AVPlayer + 自研 Canvas 弹幕引擎 |
| lib/models/* | model/Models.ets / LiveModels.ets |

原始 PiliPlus 工程保留在 PiliPlus/ 目录作为对照参考。

## 文档

- `docs/UI与导航设计方案-v1.md` — UI 与导航设计方案（含实施状态与决策记录）
- `docs/Roadmap-对照网页端.md` — 对照 B 站网页端的功能差距与实施优先级
- `docs/ArkUI易错清单.md` — 本工程踩过的 ArkUI 坑与提交前自检清单（开发前必读）
- `docs/ref/README.md` — 设计参考截图索引（BewlyCat / B 站官方 App）
- `docs/ref/` — 参考截图素材

## 待完善（Roadmap）

- [x] 专栏文章阅读页（`pages/ArticlePage.ets`，App 内 Web 容器）
- [x] 自动连播开关（播放器「更多功能」设置，UGC 合集播完自动下一集）
- [x] 分区频道页（`pages/ZoneChannelPage.ets`，首页热门频道入口，点击分区进对应排行）
- [x] 番剧索引页（`pages/BangumiIndexPage.ets`，番剧/国创/影视/剧集/纪录片 × 连载状态筛选聚合）+ **新番时间表**（右上入口，近一周番剧/国创排播，`pgc/web/timeline`）
- [x] 用户类型筛选（搜索用户 Tab：全部/UP主/普通/认证，与粉丝数/等级排序并列）
- [x] 动态顶部关注 UP 主横滑栏 + 直播中角标（`DynamicView`，批量状态查询，开播头像带红角标，**点击角标直达直播间**）
- [x] 发布纯文字动态（`DynamicView` FAB + 输入面板）
- [x] 主播开播提醒（轻量版：关注栏「直播中」角标；系统级推送/真机提醒待做）
- [ ] 宽屏 Navigation 分栏（840vp 断点，待真机大屏）
- [x] 自动连播/播完暂停设置（播放器「自动连播」开关；无合集时自动连播相关推荐第一条）；画中画/后台播放待真机（模拟器无 PiP 能力）
- [ ] 历史弹幕（官方 API 已下线）、高级弹幕
- [x] 弹幕举报（播放画面内点击弹幕即弹原因菜单）
- [x] 评论举报、黑名单管理
- [x] 直播分区页（`LiveZonePage`）；直播回放（官方无公开接口，不做）
- [x] 定时深色切换（「我的」页开关 + 开始/结束时间选择，跨天时段，跟随系统模式下生效）
- [ ] 直播礼物/送礼、离线缓存（视频下载，真机从容做）
