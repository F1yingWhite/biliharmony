<div align="center">

# BiliHaromny

**HarmonyOS NEXT 原生第三方哔哩哔哩客户端**

从开源项目 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 移植并扩展，ArkTS / ArkUI 全原生实现 ——
不是跨端套壳：系统 AVPlayer 播放、Canvas 自绘弹幕引擎、系统提醒 / 画中画等鸿蒙能力原生接入。

`HarmonyOS API 26` · `ArkTS + ArkUI` · `零第三方依赖（仅系统 Kit）` · [QA 回归说明](tool/qa/README.md)

<img src="docs/screenshots/home.jpg" width="260" alt="首页信息流"/>
<img src="docs/screenshots/detail.jpg" width="260" alt="视频详情与弹幕播放器"/>
<img src="docs/screenshots/live-room.jpg" width="260" alt="直播间实时弹幕"/>

<img src="docs/screenshots/live.jpg" width="260" alt="直播频道"/>
<img src="docs/screenshots/search.jpg" width="260" alt="搜索与热搜双榜"/>

**[下载最新构建](https://github.com/F1yingWhite/biliharmony/releases/tag/latest)** · [更新日志](CHANGELOG.md) · [开发文档](docs/)

</div>

> ⚠️ 仅供学习交流使用。所有接口均来自 B 站官方公开 API，不提供任何破解内容；哔哩哔哩及相关商标归其权利人所有。

---

## 这是什么

BiliHaromny 是为 HarmonyOS NEXT 打造的第三方 B 站客户端。项目以 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)（Flutter）的功能与协议实现为蓝本，用 **ArkTS + ArkUI 从零重写为鸿蒙原生应用**：WBI / App 签名、DASH 播放、直播 WebSocket 弹幕等核心链路均为纯 ArkTS 实现，同时接入 reminderAgent 系统提醒、画中画、沉浸式窗口等 HarmonyOS 原生能力。

模块对应关系见 [docs/移植对照-PiliPlus.md](docs/移植对照-PiliPlus.md)。

## 功能速览

### 🏠 浏览与发现
- 首页 **推荐 / 热门 / 直播** 三频道，双列瀑布流、下拉刷新、触底分页；长按卡片「不感兴趣」（本地持久化黑名单，设置中可清空）
- **排行榜**（全站 / 每周必看 / 入站必刷）、**分区频道**、**番剧索引**（番剧/国创/影视/剧集/纪录片 × 连载状态）、**新番时间表**（近一周排播，条目可设开播前 5 分钟系统提醒）
- 搜索：热搜榜 + 趋势榜双榜、默认词、输入联想、本地历史；结果页 **综合 / 视频 / 番剧 / 影视 / 直播 / 专栏 / 用户** 七分类，视频排序筛选、用户类型筛选与排序
- 动态：关注 UP 横滑栏（直播中角标直达直播间）、全部分类筛选、**发布文字 / 图文动态**、话题跳转搜索、举报
- 个人数据：观看历史（进度 / 删除 / 清空）、稍后再看（多选批量删除）、收藏夹（新建 / 重命名 / 排序 / 批量移动）、我的追番

### ▶️ 播放器
- 系统 AVPlayer + XComponent，**DASH（fnval=4048）音视频分流双播放器同步**，多 URL 容错，清晰度实时换源；登录 WBI playurl，游客试看
- **Canvas 自绘弹幕引擎**：滚动 / 顶部 / 底部、车道分配防碰撞、透明度 / 速度 / 字号 / 密度调节、分类与关键词（正则）屏蔽、protobuf 分段加载、弹幕列表、**重复弹幕合并计数**、屏上点击弹幕即可举报
- **小电视空降助手**（类 SponsorBlock）：11 类片段独立策略（跳过 / 静音 / 标记 / 手动），彩色分段进度条、**高能热度条**、章节刻度、赞踩与匿名投稿
- **CC 字幕**轨道选择与字号缩放、倍速面板、横屏全屏、紧凑模式、手势操作（双击暂停 / 长按 2x / 横滑进度预览 / 上下滑音量亮度）
- **画中画**（PiPWindow）、后台播放（AVSession 长时任务）、**截图存相册**、自动连播、UGC 合集选集、番剧自动跳过片头

### 📺 直播
- 低延迟直播流播放、画质切换、全屏
- **WebSocket 弹幕客户端**：进房握手、心跳、断线重连；实时弹幕、表情、**醒目留言（SC）**，合帧缓冲渲染
- 直播分区页（一级分区网格 + 人气排序房间列表）

### 💬 互动（登录后）
- 视频：点赞 / **长按一键三连** / 投币 / 收藏（快捷入默认夹，长按收藏夹多选）/ 关注 / 分享；官方版式视频详情页（折叠标题、TAG 胶囊、BV 复制、合集、相关推荐点赞角标）
- 评论：发表、**楼中楼**、表情包面板、富文本解析（BV / 时间轴 / @提及）、**分享成图片卡片**、举报、删除自己的评论、UP 主置顶
- 私信与通知：会话列表 / 聊天 / **会话置顶** / 举报；回复 / @我 / 赞 / 系统四类通知，未读角标、全部已读
- 用户：关注分组（创建 / 重命名 / 删除）、黑名单管理、**追番状态标记**（想看 / 在看 / 看过）

### 👤 账号
- 四种登录方式：**TV 扫码 / Web 扫码 / 密码（RSA 加密）/ 短信验证码（内置极验滑块）**
- **Web Cookie 自动续期**（correspondPath 加密流程，鉴权失败自愈），refresh_token 持久化
- 登录态本地持久化，Cookie 罐导入 / 导出

### ⬇️ 下载中心
- 视频 / 音频缓存队列：任务持久化、失败重试、进度管理
- 一键导出：**MP4 / M4A / 弹幕 XML（12 段合并）/ CC 字幕 SRT / 封面**

### 🧩 鸿蒙原生能力
- **开播系统提醒**（reminderAgent 日历提醒，免推送服务）
- **宽屏 Navigation 分栏**（840vp+，外观设置实验开关）
- **封面取色动态主题**（Material You 风格色调板）、玻璃拟态材质（可关闭降级）、沉浸式系统栏、深色模式 / 定时深色
- 网络代理设置与本地隐私管理

### 🌐 其他平台（实验性）
- YouTube 浏览：搜索（联想 / 筛选）、频道行、相关推荐、本地稍后看与历史；详情页经 ArkWeb IFrame 播放，游客态

## 安装

1. 从 [Releases（tag=latest 滚动更新）](https://github.com/F1yingWhite/biliharmony/releases/tag/latest) 下载 HAP；
2. 通过 DevEco Studio 或 `hdc install <path>.hap` 安装到 HarmonyOS NEXT（API 26+）真机 / 模拟器。

## 从源码构建

### DevEco Studio

打开工程根目录（需含 **HarmonyOS API 26** SDK，不兼容 API 24），File → Sync 后直接 Run（自动签名）。

### 命令行（macOS，需已配置 DevEco Studio）

```bash
bash tool/build.sh                    # debug（含签名配置时产物已签名）
bash tool/build.sh clean release      # release
```

产物：`entry/build/default/outputs/default/entry-default-*.hap`。脚本内置全部环境变量（hvigor/npm 缓存收进工程 `.home/`）；首次构建需要网络。

### GitHub Actions

`.github/workflows/release-hap.yml` 在 push 到 main（或手动触发）后：跑全量 QA → `ubuntu-latest` + [ErBWs/setup-ohos](https://github.com/ErBWs/setup-ohos) 构建 release HAP → 发布到滚动 Release（附更新日志）。签名配置可通过仓库 Secret（`HARMONY_BUILD_PROFILE_B64`，base64 的 build-profile.json5）注入，构建后即清除、不入 Git。

## 测试

```bash
node --test --test-timeout=10000 tool/qa/*.test.cjs
```

核心逻辑（签名 / 解析 / 状态机 / 组件构建）以 TS 转译 + 平台 mock 在 Node 端回归，无需真机。环境配置、覆盖范围和验证边界见 [QA 回归说明](tool/qa/README.md)，用例数量以实际运行结果为准。CI 每次推送全量执行。

## 项目结构

```text
entry/src/main/ets/
├── entryability/EntryAbility.ets    # 入口：主题初始化、沉浸式系统栏、深链、启动代理
├── entryformability/                # 已取消注册的桌面卡片历史实现（保留源码）
├── pages/                           # 路由页（视频详情 / 搜索 / 登录 / 直播间 / 私信 / 番剧 / 下载中心 …）
├── views/                           # 主 Tab 视图（首页三频道 / 动态 / 我的 / YouTube 外壳）
├── components/
│   ├── player/                      # 播放器、弹幕引擎、手势、设置面板
│   ├── live/                        # 直播播放器与房间卡片
│   ├── reply/                       # 评论卡片、编辑器、楼中楼、分享卡片
│   ├── video/                       # 视频卡片与投币 / 收藏面板
│   └── …                            # 玻璃头栏、看图、加载态等通用件
├── api/                             # 按领域拆分的接口层（WBI / App 签名在此封装）
├── model/                           # 领域模型（Models.ets 稳定导出入口）
├── services/                        # 网络 / 认证 / 媒体 / 缓存 / 消息 / 书架型数据
└── common/                          # 路由、签名、取色主题、直播弹幕 WS、工具
```

## 文档

- [CHANGELOG.md](CHANGELOG.md) — 版本历史与完整能力清单
- [docs/移植对照-PiliPlus.md](docs/移植对照-PiliPlus.md) — 上游 Flutter 模块 ↔ ArkTS 实现对照
- [docs/UI与导航设计方案-v1.md](docs/UI与导航设计方案-v1.md) — UI 与导航设计（含决策记录）
- [docs/Roadmap-对照网页端.md](docs/Roadmap-对照网页端.md) — 对照 B 站网页端的功能差距
- [docs/ArkUI易错清单.md](docs/ArkUI易错清单.md) — 本工程踩过的 ArkUI 坑与自检清单（开发前必读）
- [docs/api/](docs/api/) — B 站 Web API 调研清单与复现脚本

## 致谢

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) — 功能蓝本与协议实现参考
- [BewlyBewly](https://github.com/BewlyBewly/BewlyBewly)（MIT）— 首页卡片设计、频道胶囊与分区图标集
- [MingCute Icon](https://github.com/Richard9394/MingCute)（Apache-2.0，经 [Iconify](https://iconify.design) 分发）— 全局界面图标
- [BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)（GPL-3.0）— 空降助手协议与交互设计

## 已知边界

不做消费类功能（大会员 / 充电 / 送礼）、创作中心、直播回放；历史弹幕暂缺。视频举报已接入可用原因和服务端结果确认，画中画与宽屏分栏已实现，真机持续验收中。

桌面「继续观看」服务卡片已按用户要求取消入口，不作为当前交付功能；范围变更记录见 [模拟器测试记录](docs/emulator-test-2026-09-27.md#用户范围纠正取消桌面卡片集中浮窗播放)。
