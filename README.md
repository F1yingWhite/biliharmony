# BiliHaromny（哔哩哔哩 · 鸿蒙原生版）

基于开源 Flutter 项目 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 移植并扩展的**鸿蒙原生（HarmonyOS NEXT）哔哩哔哩第三方客户端**。

- 语言/UI：ArkTS + ArkUI（声明式）
- 目标 SDK：**HarmonyOS API 26**（compileSdkVersion / compatibleSdkVersion / targetSdkVersion = 26.0.0）
- 构建：hvigor + ohpm（零第三方依赖，仅使用系统 Kit）
- 工程根目录即 DevEco Studio 工程，可直接 Open 打开

> 仅供学习交流使用。所有接口均来自 B 站官方公开 API，不提供任何破解内容。

---

## 功能

### 浏览

| 模块 | 说明 |
| --- | --- |
| 首页 | 推荐（app 端 `/x/v2/feed/index`）/ 热门（`/x/web-interface/popular`）/ **直播** 三频道，双列瀑布流、下拉刷新、触底加载、按键去重 |
| 搜索 | 热搜榜、搜索历史（本地持久化）、输入联想（防抖 + 乱序丢弃）；结果页视频/用户二级 Tab、排序 chips、视频筛选面板（时长/发布时间/分区） |
| 动态 | 关注动态 feed：表情图文混排、九宫格图片、转发展示、直播卡片直达直播间 |
| 视频详情 | 简介/评论/相关推荐，分 P、视频章节、"N 人正在看" |
| 用户空间 | Banner 氛围头部 + 资料卡，主页/动态/投稿三 Tab（投稿支持最新/最多播放/最多收藏排序），关注/取关、关注/粉丝列表 |
| 动态详情 | 正文/表情/评论完整呈现，首屏复用 feed 对象直出 |
| 历史/收藏 | 观看历史（游标分页 + 观看进度）、我的收藏（收藏夹/收藏集双分类） |
| 全屏看图 | 捏合缩放、拖动平移、共享元素转场、保存相册、系统分享 |

### 播放器

| 能力 | 说明 |
| --- | --- |
| 播放 | 系统 AVPlayer + XComponent 渲染；**DASH（fnval=4048）音视频分流双播放器同步**，多 URL 容错；登录走 WBI playurl，游客试看 |
| 弹幕 | Canvas 自绘弹幕引擎：滚动/顶部/底部、车道分配防碰撞、透明度/速度/字号/密度调节、分类屏蔽、**播放器内发弹幕** |
| 手势 | 双击播放暂停、长按 2x 倍速、横滑进度预览、上下滑音量/亮度 |
| 控制 | 清晰度实时换源、倍速面板、横屏全屏、mini 收缩模式 |
| 特色 | **SponsorBlock 空降**（自动跳过赞助片段，可开关）、章节/分段刻度进度条 |

### 直播

- 低延迟 AVPlayer 直播流播放、画质切换、全屏
- **WebSocket 弹幕客户端**（进房握手、心跳、断线重连）：实时弹幕/表情/醒目留言（SC），合帧缓冲渲染
- 直播弹幕浮层复用视频同款 Canvas 分轨引擎；发弹幕走 HTTP 接口
- 入口：首页直播频道、动态直播卡片、用户空间开播状态

### 互动（登录后）

- 视频：点赞/点踩、投币（1/2 币、可同时点赞）、收藏（收藏夹多选弹层）、关注 UP 主、系统分享 + 上报
- 评论：发表、点赞/点踩、**楼中楼**（树形缩进/折叠 + 页内二级导航）、表情包面板、富文本解析（BV 号/时间轴跳转/@提及）、**评论分享成图片卡片**（截图 + 二维码）
- 私信：会话列表、聊天详情（游标分页）、自动已读、发送文字私信；入口在首页头栏

### 账号

- 三种登录方式：**TV 扫码**（轮询 + Cookie 保存）、**密码**（RSA 公钥加密）、**短信验证码**
- 登录态 Preferences 持久化，Cookie 罐导入/导出

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
- `docs/ref/README.md` — 设计参考截图索引（BewlyCat / B 站官方 App）
- `docs/ref/` — 参考截图素材

## 待完善（Roadmap）

- [ ] 稍后再看、番剧/影视/专栏搜索 Tab、综合搜索聚合 Tab
- [ ] 动态点赞/转发（目前只读）、动态分类筛选
- [ ] 弹幕 protobuf 分段接口（dm/web/view + seg.so）替代整段 XML
- [ ] 排行榜 / 分区页、宽屏 Navigation 分栏（840vp 断点）
- [ ] 直播礼物/送礼、定时深色切换
