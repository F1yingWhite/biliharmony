# 全面重构计划与验收（2026-10-02）

目标：保留现有产品能力，重新划清领域、请求状态和资源所有权，移除重复实现与已失效代码。完成标准不是单文件行数，也不是某一批回归通过。当前基线为 `25e0fb5`（1.3.1），工作分支为 `codex/deep-refactor`。

## 审计基线

232 个 ArkTS 模块的静态相对导入图没有循环，services/model 没有反向依赖页面。已拆出的播放选择、推荐、收藏选择与 HTTP 响应解析承担真实职责，保留这些边界。主要问题仍是页面和播放器同时持有业务事务、异步请求代际、系统资源和视图。

## 必须完成的工作包

勾选表示实现已接入生产入口，并有自动回归或静态依赖证据；原生能力和界面验收仍按下方矩阵单独完成。

- [x] 播放器：AVPlayer 双轨播放会话拥有创建、回调、同步、换源、恢复与释放；画中画、辅助内容请求、下载导出独立拥有生命周期。PlayerView 保留 ArkUI 布局与状态适配，不能将整个页面作为可写宿主传给另一个巨型类。
- [x] 视频/番剧详情：详情初始化、UP 关系、评论提交具有目标和账号代际；评论结果绑定提交时的 oid/type/root/parent/草稿，不能在切楼层后写入新楼层。保留 Hero、导航与视图状态发布。
- [x] 动态：分类信息流、独立卡片、互动事务、发布草稿和图片资源分离；各分类保持独立稳定数据源，刷新和分页有明确归属。
- [x] 搜索：已提交查询/分类/分页、输入联想/热榜/历史、筛选草稿与卡片分离；新搜索可替代旧分页，旧响应不能覆盖标签或结束新加载。
- [x] 用户空间：投稿排序/分页独立，关注分组提交拥有选择快照与锁；排序请求不会被在途旧请求丢弃，失败不会伪报保存成功。
- [x] 消息：会话列表与聊天会话各自拥有分页、发送、已读和账号生命周期；保留精确字符串游标及已确认未读状态。
- [x] 直播间：连接/历史补拉会话与有界弹幕合批/去重/SC 分离；保留播放器换源旧帧和离场立即静音语义。
- [x] 收藏库：三个分页域与编辑事务分离；账号/离场/失败/旧移动响应不污染当前编辑。
- [x] 首页与 YouTube：各自的列表/搜索/筛选/分页与缓存请求归领域控制器；不引入覆盖所有业务的万能列表抽象。
- [x] 评论共享模块：审查主评论分页、楼中楼会话、分享导出边界，减少共享控制器对页面散落字段的依赖。
- [x] HTTP：文本 GET/POST/二进制 POST 使用一条凭证、请求、Cookie 和预热解析执行链；保留每个异步边界的账号检查。
- [x] 清理：核实并删除零引用服务 re-export、未接入的 PreferencesHandle、孤立播放指示组件、已取消注册的桌面卡片与对应过时测试；保留实际用于续播的 ContinueWatchingStore 和在用的 Models 聚合入口。
- [x] 测试基础：新领域直接加载完整生产模块，建立小型共用 ArkTS 模块夹具；迁移受重构影响的方法切片测试，保留行为断言。
- [x] 文档与本地交付验收：同步真实架构说明，完成下述本地验收并审查所有工作包；云端发布状态按当前提交的工作流结果另行核对。

## 验收矩阵

| 要求 | 必须取得的证据 |
| --- | --- |
| 职责落地 | 生产调用实际使用新模块，无新旧重复实现；页面不再管理已抽领域的事务/分页代际；系统资源只有一个所有者 |
| 依赖方向 | 全仓导入图无循环，model/网络底层无 UI 反向依赖，组件不导入页面 struct |
| 最新请求拥有结果 | deferred 回归覆盖刷新替代分页、A→B、离场/重新进入、账号变化、旧请求不能结束新 loading |
| 发送/保存归属 | 提交快照、连续点击、切目标、修改草稿、失败重试；成功只更新原目标且不清空新输入 |
| 分页语义 | 空数据与错误分开；失败不推进游标；去重；当前标签与显示的数据一致 |
| 播放资源 | 完整模块回归及模拟器实际双轨播放、暂停/恢复、清晰度、连续 seek/章节、分 P、全屏、后台/AVSession、退出释放 |
| 直播资源 | 实际播放、换源、退出；旧帧至新帧就绪；连接/轮询结束；去重有界，不回放进房快照 |
| 账号和持久化 | Cookie、列表、互动旧响应不污染新账号；保留 Preference key/格式；冷启动与写盘失败测试 |
| UI | 首页三频道、搜索类别/筛选、动态分类/发布、视频/番剧及评论、用户空间排序/分组、消息、收藏编辑、设置；无需发送真实评论 |
| 工程 | 全部 Node 回归、完整 CompileArkTS/HAP，审查新增告警和真实设备证据；测试数量不能替代覆盖判断 |
| 文档与遗留 | 文档与当前路径一致，删除项无调用且无有效功能入口丢失；仅在界面改变时更新截图 |

每个工作包记录实际文件、验证命令、结果和未覆盖项。以上勾选表示本地证据齐备；最终交付还必须核对当前提交的 [GitHub Actions](https://github.com/F1yingWhite/biliharmony/actions/workflows/release-hap.yml) 成功、`latest` 标签指向该提交、[发布页](https://github.com/F1yingWhite/biliharmony/releases/tag/latest) 的 HAP 与校验和更新，不能仅凭本地构建判断发布完成。手机最终包按用户要求稍后安装，见末尾设备记录。

## 实施与自动回归记录

下表生产路径均相对 `entry/src/main/ets/`，模块名省略 `.ets`；对应测试位于 `tool/qa/`。新增领域直接执行完整生产模块，页面保留布局、导航与状态适配。

| 领域 | 实际模块 | 已覆盖的核心行为 |
| --- | --- | --- |
| 播放核心 | `components/player/PlayerPlaybackSession`、`PlayerTrackPair`、`PlayerAudioSync`、`PlayerPlaybackState` | 创建/释放屏障、旧源回调失效、双轨同步与首帧静音、后台策略、质量恢复、Surface 重建、系统暂停后换画质不复播；见 `player-session`、`player-background`、`player-recovery`、`player-view-adapter` 回归 |
| 播放辅助与导出 | `components/player/PlayerPictureInPicture`、`PlayerAuxiliaryController`、`PlayerSeekPreviewController`、`PlayerMediaExportController`；`services/media/DocumentExportService`、`MediaExportFormat` | 换源/离场取消、字幕与辅助结果归属、预览节流、ImageSource/PixelMap/文件句柄释放、导出快照、选择器取消与失败不伪报保存成功；见 `player-auxiliary`、`seek-preview`、`media-export`、`photo-library-saver` 回归 |
| 视频与番剧详情 | `components/video/VideoDetailController`、`VideoAccountController`、`VideoActionController`；`components/bangumi/BangumiDetailController`、`BangumiFollowController` | 初始化与账号/目标代际、分 P 乱序、互动提交锁和快照、失败回滚归属；见 `detail-initialization`、`detail-actions`、`video-controllers` 回归 |
| 动态 | `components/dynamic/DynamicFeedController`、`DynamicFollowController`、`DynamicDetailController`、`DynamicComposerController`、`DynCard`、`DynamicCardActions`、`DynamicCardNavigation` | 分类独立稳定数据源、刷新替代分页、隐藏标签回调隔离、互动归属、草稿/图片生命周期、Hero 与减少动效导航；见 `dynamic-category`、`dynamic-composer`、`dynamic-actions`、`dynamic-navigation` 等回归 |
| 搜索 | `components/search/SearchResultsController`、`SearchResultsStore`、`SearchDiscoveryController`、`SearchQuery`、`SearchFilterPanel` 与卡片组件 | 提交查询替代旧分页、分类/排序/筛选快照、联想防抖、历史/热榜、错误与空结果、数据源稳定性；见 `search-controllers`、`search-library-fixes` 回归 |
| 用户空间 | `components/user/UserSpaceFeedController`、`FollowGroupController`、`FollowGroupSheet` | 排序替代在途请求、分页失败不推进、账号/离场隔离、分组提交快照与失败重试；见 `user-space` 回归 |
| 消息 | `components/message/SessionListController`、`PrivateChatSession`、`MessageSessionScope`、`MessageState` | 精确字符串游标、已确认未读不回滚、历史消息 prepend、发送期间新草稿保留、原生菜单目标快照、账号/离场锁隔离；见 `message-read`、`message-api-read` 回归 |
| 直播 | `components/live/LiveRoomSession`、`LiveChatBuffer`，接入 `pages/LiveRoom` | 连接/历史补拉生命周期、有界合批与去重、SC 与普通消息分流、旧帧保留至新帧就绪、退出静音和发送/滚动边界；见 `live-room-session`、`live-weak-network`、`live-chat-scroll`、`live-send` 回归 |
| 收藏库 | `components/favorites/FavoriteLibraryController`、`FavoriteLibrarySession`、`FavoriteFolderCatalog`、`FavoriteVideoList`、`FavoriteVideoEditor`、`FavoriteFolderEditor` | 收藏夹/视频/收藏集独立分页、稳定数据源、选择与排序保存、移动/删除事务、旧编辑或旧账号回调隔离、失败保持待保存状态；见 `favorites-order` 回归 |
| 首页与 YouTube | `components/home/HomeFeedController`、`HomeFeedItems`；`components/youtube/YouTubeSearchController`、`YouTubeDiscoveryController`、`YouTubeDetailController`、`YouTubeThumbnailCache`、`YouTubeWebPlayback` | 首页频道独立分页/曝光、账号变化后当前频道重载；YouTube 搜索/筛选代际、评论分页、缩略图请求和 Web 文档生命周期；见 `home-feed`、`youtube-controllers` 回归。过滤后空列表与隐藏最后一卡均进入可重试空态，继续加载保留下一页游标 |
| 评论共享模块 | `components/reply/RepliesController`、`MainRepliesController`、`ReplyThreadSession`、`ReplySubmissionController`、`ReplyShareController`、`ReplyState` | 主评论与楼中楼分页、切根/排序/账号隔离、服务端 rev、发送绑定目标与草稿、预览与已发评论合并、分享资源生命周期；见 `reply-state`、`reply-submission`、`reply-share-session`、`reply-share-lifecycle` 回归 |
| HTTP | `services/network/HttpClient` 的 `requestText`/`execute`，沿用 `CredentialPolicy`、`HttpResponse` | 文本 GET/POST 与二进制 POST 共用请求链；凭证隔离、Cookie 更新、预热解析和各 await 边界的账号检查；见 `http-request-pipeline`、`http-parse-session` 回归 |

### 接线、清理与夹具

静态审查确认 63 个新增生产模块都有生产引用，并能从 Ability 或路由依赖图到达。架构回归检查相对导入解析、循环依赖及服务/模型/组件的依赖方向；当前没有发现缺失导入或反向依赖。路由注册未变更。

删除前已确认零生产引用：五个 `common` 服务转发入口、`PreferencesHandle`、`PlayerPlaybackIndicator`；删除未注册的 `EntryFormAbility`、`ContinueWatchCard`、`form_config.json` 及三项旧卡片测试。`ContinueWatchingStore`、其续播回归及在用的 `Models` 聚合入口保留。README、API 使用说明和测试夹具说明已同步；历史审计文档保留当时路径。

`tool/qa/arkts-module.cjs` 提供独立模块缓存和完整 ArkTS 模块加载，`player-session-fixture.cjs` 驱动真实会话与可控 AVPlayer 事件。评论、动态、搜索、收藏、消息和播放器的受影响断言已迁移，保留游标、状态、请求代际、资源释放与导航行为检查。部分 UI 适配及未迁移页面仍使用方法切片；这部分锚点与 ArkUI DSL 编译仍需分别维护。

### 本地集成结果

- 最终全量命令 `node --test --test-timeout=20000 tool/qa/*.test.cjs` 已通过 **914 项**，使用 DevEco 自带 Node/TypeScript；各专项计数不再重复相加。完整记录为 `.qa/refactor-20261002/final-tests.log`。
- 本轮 debug HAP 构建约 12 秒成功；包含举报修正的最终 `clean assembleHap` release 构建约 25 秒成功，CompileArkTS、打包与本地签名通过。生成配置为 `BUILD_MODE_NAME = 'release'`、`DEBUG = false`。debug ArkTS 警告 147 条，release 为 150 条（另三条是已有条件分支内的组件 ID 重复告警），此前基线为 159 条；构建成功不代表警告清零。最终构建日志为 `final-release-build.log`，产物与 SHA-256 清单保存在 `release-final/`。
- 首页过滤空态和举报分类修正均已纳入最终回归及构建。举报按视频请求新版分组分类，普通类型在应用内填写详细描述，权益申诉和需专用材料的类型进入官方表单。API 层拒绝特殊类型和跨视频选项误提交；弹窗使用请求代次隔离关闭后迟到结果，提交时固定视频、类型与描述。
- Mate 80 Pro Max 模拟器已覆盖安装 `1.3.2 / 1000302` release，保留原有数据。播放器取得 25 条直接原生通过记录（含设置恢复）：实际进度推进/暂停冻结、连续 seek、暂停切画质、Surface 返回、横竖屏、后台策略、桌面 PiP 与恢复、自然播完和重播。release 另核对播放、暂停、seek、恢复与退出。广域页面与五张新截图验收已完成。

### 广域界面与章节进度

本地完整记录为 `.qa/refactor-20261002/ui/acceptance-report.md`。实际覆盖首页三频道、直播播放与刷新恢复、评论和楼中楼、搜索七类别及视频时长/用户筛选、用户投稿三种排序、动态四分类和发布表单取消、消息入口、收藏编辑无修改退出、历史/稍后再看、番剧索引与详情、三个设置页面。基础只读脚本 14 项通过；旧深度脚本执行至 D3 后模拟器退出，保留其中 3 条通过记录，其余范围通过真实入口手动补验，不将整份旧深度套件标为通过。未提交评论、私信、举报、动态或收藏修改。

章节条取得当前段部分填充的真实证据：播放宇宙视频时，“形状角度”段宽 283px，白色已播放部分仅 32px；之前章节全白、之后章节未填充。新 `home.jpg`、`search.jpg`、`live.jpg`、`live-room.jpg`、`detail.jpg` 均来自本次 1.3.2 模拟器，截图已核对，无键盘、菜单或骨架遮挡，并替换 README 中原有五张图。

举报先完成原有表单的原因加载和取消验收；随后对照官方 Web/H5 脚本确认普通类型详细描述必填，同时发现旧分类中的侵权条目需要官方专门申诉。该问题已修正并纳入 9 项完整生产 API 回归；不以未发送的举报推断服务端成功。

最终 release 上补验普通类别的必填提示及空描述禁用状态，以及侵权类别无需本地描述即可进入官方申诉的按钮。跳转已打开官方站点，浏览器要求单独登录时即停止，没有代填登录或提交申诉；返回应用后关闭表单。原始截图和布局位于 `ui/report-v2/`。

### 播放器原生证据与自动化限制

本地证据位于 `.qa/refactor-20261002/player/PLAYER_UI_HANDOFF.md`、`supplemental-results.json` 和 `release-basic/`。播放 112.035→119.005 秒；暂停保持 121.031 秒；连续暂停 seek 64→134 秒后保持不动。4K→720P 保留暂停位置，手动播放后继续推进。后台听关闭时暂停、开启时音轨推进并在返回时对齐画面；PiP 在桌面播放且返回后移除浮窗。自然结束、退出全屏、重播及最终 release 退出后无播放器 Surface 均有截图/布局及时间对比证据。

`suite_player.py` 的原始失败报告全部保留：历史结束态未先重播、三秒控件自动隐藏与布局采集竞态、旧抽屉遮罩定位导致流程失败。现已修复场景准备和面板范围定位；新增 `player_layout.py` 及 13 项无需设备的 Python 选择器回归，并接入 GitHub Actions。关闭面板失败会明确报错，不跳过该断言。修复后的正式命令 `python tool/qa/suite_player.py --skip-install --query BadApple --performance-seconds 10` 取得 **14 项通过、0 项失败、1 项跳过**；唯一跳过为模拟器不提供 FPS，保留 10 个 CPU/PSS 采样，但不以此作真机性能结论。报告为 `player/final-suite/suite_player_report.md`。

一次“关闭后台听后前台应自动播放”的测试预期经对照旧实现纠正为保持暂停，原始记录仍保留。最终专项后已在 UI 将弹幕密度调回正常，并重选原有自动画质基础策略（0），清除本轮测试的手动画质覆盖。冷启动后同一视频实际选择 1080P，没有继续沿用测试中的 4K/720P；未知的测试前手动画质值不能声称完整恢复。证据保存在 `player/final-suite/restore/`。

模拟器没有提供有效 SmartPerf FPS，不作帧率或实机性能结论。未做音视频同步的人工听感验证、真实弱网穷举、所有账号/设备组合或真实媒体文件导出；这些限制不由 Node 平台替身结果代替。手机已覆盖安装举报分类修正前的本地签名 `1.3.2 / 1000302`，EntryAbility 启动成功且应用进程存在，记录为 `release/phone-version.txt`、`release/phone-start.txt`。用户明确要求稍后再安装包含举报修正的最终包，该签名包已保存在 `release-final/`。手机没有执行全量 UI/播放专项，README 截图全部使用模拟器。
