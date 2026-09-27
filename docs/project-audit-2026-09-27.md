# 项目审查与测试有效性检查（2026-09-27）

本轮检查生产源码、执行现有回归、用受控异步响应复现缺陷，并检查界面和导出图片。以下保留首次审查的触发条件与证据；用户随后授权修复，六处已确认功能缺陷均已修改，并补充评论分享、收藏排序、动态横滑与减少动效。下文“建议/仍需验收”为首次审查时的状态，最终修复范围和验证结果以[修复记录](fixes-2026-09-27.md)为准。

## 优先修复的功能问题

| 优先级 | 问题、触发及影响 | 代码位置 | 修复方向 |
| --- | --- | --- | --- |
| P1 | **冷启动写入可能丢失旧本地记录。** YouTube 历史恢复尚未完成时记录新视频，内存最终含新旧记录，但等待恢复的写入仍保存合并前的 JSON；重新创建模块后旧记录消失。 | [PreferencesCollection.ets](../entry/src/main/ets/common/preferences/PreferencesCollection.ets#L80)，`restore` 第 144 行、`persist` 第 160 行 | 恢复与写入统一排序，落盘使用合并后的权威快照，同时区分删除/清空意图；补非空磁盘、冷启动写入及真实新实例恢复测试。已实证 YouTube 观看历史，不泛称所有账户历史都丢失。 |
| P1 | **关闭后台播放仍可能迟到起播。** 视频尚在准备时切到后台，`playing=false` 导致后台处理不暂停、不撤销自动起播意图；随后 prepared 路径仍调用 `play()`。 | [PlayerView.ets](../entry/src/main/ets/components/player/PlayerView.ets#L753)，`tryStartPreparedPlayers` 第 2028 行 | 起播/seek 恢复前统一检查前后台和画中画策略；补“准备中→后台→prepared”的完整事件序列。已证实错误播放调用，未声称真机声音及系统后台策略已验收。 |
| P1 | **动态分类串台并污染分页。** 「全部」有缓存时，切「视频」发请求，再马上返回「全部」；缓存分支未使旧请求失效，视频响应覆盖全部的内容、offset、hasMore。 | [DynamicView.ets](../entry/src/main/ets/views/DynamicView.ets#L1359)，`loadFeed` 第 1185 行附近 | 每次分类切换都失效旧操作，加载状态按分类管理；缓存命中也需要隔离在途响应。 |
| P2 | **稍后再看批量删除成功后列表不更新。** 成功分支在 `actionBusy=true` 时调用 `load`，被其守卫直接拒绝。已删除行和数量仍保留。 | [WatchLaterPage.ets](../entry/src/main/ets/pages/library/WatchLaterPage.ets#L189)，`load` 第 74 行 | 用请求时的选中项快照更新列表并失效旧读请求，或解锁后刷新；保留现有单条删除的竞争保护。 |
| P2 | **搜索切分类后无法继续翻页。** 视频还有后续页，切到只有一页的用户分类再切回视频，沿用共享的 `hasMoreResults=false`。 | [Search.ets](../entry/src/main/ets/pages/Search.ets#L535)，加载守卫第 189 行 | 各分类保存自己的分页、错误和请求状态，恢复缓存时同步恢复。 |
| P2 | **未提交的新关键词混入旧搜索列表。** 搜索 alpha 后仅编辑为 beta，继续滚动触底，实际请求 beta 的第二页并追加至 alpha 第一页。 | [Search.ets](../entry/src/main/ets/pages/Search.ets#L198)，`onInput` 第 150 行 | 分离输入草稿和已提交查询；分页、排序、分类使用已提交查询；新提交统一重置上下文。 |

补充：下载页确认框说“清理已完成/失败的任务记录”，但实际调用会删除完成任务的媒体文件，未导出文件也在内。见 [DownloadCenterPage.ets:255](../entry/src/main/ets/pages/DownloadCenterPage.ets#L255) 与 [DownloadCenter.ets:356](../entry/src/main/ets/services/media/DownloadCenter.ets#L356)。这是源码可确认的提示与行为不一致；未执行真实删除。建议明确提示“删除任务及本地下载文件”，或拆分清记录与删文件。

## UI 与动效优化顺序

1. **先稳定加载前后布局。** [LoadingSkeleton.ets:36](../entry/src/main/ets/components/LoadingSkeleton.ets#L36) 的网格封面为 4:3，真实 [VideoCard.ets:173](../entry/src/main/ets/components/video/VideoCard.ets#L173) 为 16:9。统一比例、文字行数、底部信息区和间距，减少加载完成时换高；之后再做轻微淡入。
2. **提高浅色玻璃底栏可读性。** [Index.ets:782](../entry/src/main/ets/pages/Index.ets#L782) 只给深色玻璃增加稳定底衬。浅色彩色封面透底时，文字和选中粉色的对比会变化。增加浅色底衬、调整选中文字色，并按明暗封面检查实际对比。
3. **扩大动态操作热区并补语义。** [DynamicView.ets:939](../entry/src/main/ets/views/DynamicView.ets#L939) 起的赞、转发和更多较小，图标与数字缺少完整动作名称。视觉尺寸可保持紧凑，扩大可点击区域，补“点赞/取消点赞/转发/更多”读屏名称及选中状态；成功与失败反馈保持一致。
4. **统一动效节奏并提供减少动效选项。** 通用 [MotionTokens.ets](../entry/src/main/ets/common/MotionTokens.ets)、Dock 弹簧和 Hero 使用分散时长。按按压、面板、页面三类收敛参数；减少动效时以短淡入替代大幅位移缩放。属于增强建议，不是已测出的性能故障。
5. **补动态横滑的实际录屏验收。** 四个分类页共用 `dynSource`，`onChange` 后再换数据，存在滑动中先看到相同列表的风险。见 [DynamicView.ets:1603](../entry/src/main/ets/views/DynamicView.ets#L1603)、第 1865 行附近。该项仍需真机或可靠模拟器录屏确认。

已实际查看旧有首页、深色 Dock、动态和我的页面截图。没有用静态图断言 Hero 流畅或测得 FPS。当前模拟器快照出现应用和系统图层显示不完整，无法归因；本轮不将其列为确定的项目 bug。

## 回归测试是否有用

结论：**部分测试有明确保护价值，但原来的全绿不能证明完整业务链路或持久化正确。** 没有用测试数量代替质量评价。

### 已证明有用的测试

在独立源码副本中故意破坏行为，原代码对照通过，破坏后现有测试在业务断言失败：

| 注入的错误 | 测试检出的结果 |
| --- | --- |
| `RequestEpoch.isCurrent` 恒为 true | 旧动态响应错误改变 loading，行为断言失败。 |
| 直播 15 秒超时回退置空 | 播放器释放/切备用线路的次数不符。 |
| App 推荐取消广告过滤 | 实际 4 条、预期 3 条。 |

以上不是语法错误、锚点失配或缺少 mock 导致的假失败。播放 seek 的完整控制器测试以及下载取消测试也真实执行生产代码，用可控 Promise 和时钟模拟竞争，具有保留价值。抽查不等于全套 mutation 覆盖率。

### 本轮发现并整改的测试问题

- 原搜索乱序用例缺少 `allVideoSource`，最新响应在 `.reset` 处抛错，被生产 `catch` 吞掉；仅断言 `allSections/loading`，仍显示通过。已补完整结果数据源与 section 结构，并检查可见结果、错误状态、分页推进及旧响应隔离。
- 原搜索历史、YouTube 稍后看/历史用例只检验内存排序、去重和上限；所谓“重启恢复”没有创建新模块。确实删除持久化调用后，原三个用例仍通过。已补 flush 后新模块读取已落盘数据的断言，并用同样变异复验。
- 原动态分类测试只覆盖无缓存分支；原后台测试只覆盖已播放/已暂停状态；原稍后看测试只覆盖单条删除/清空。这些已有断言有局部价值，但漏掉了本报告的完整操作序列。

后续新增回归应连接用户入口与结果：点击/状态变化 → 实际生产调用链 → 最终可见数据、错误、游标、持久化或播放器调用。网络、文件系统和原生播放器可以替换；被测的业务编排不应整体 mock。源码字符串检查只证明结构约束，不能作为交互或渲染验收。

## 新 Logo

新标记将小写 **b** 与播放三角融合，采用白色圆角带状轮廓和玫瑰粉背景。已接入应用图标与启动窗口资源，保留旧资源便于对比。

- [正式 PNG](../entry/src/main/resources/base/media/app_icon_20260927.png)，1254 × 1254、全不透明。
- [分层图标资源](../entry/src/main/resources/base/media/app_layered_icon_20260927.json)。
- [生成方式与完整提示词](brand/logo-20260927.md)：内置 image_gen，一次生成、一次定向编辑。

资源已通过 assembleHap 编译、打包和签名。后续设备验收结果见修复记录。

## 首次审查的验证与证据

- 初始与整改后的完整正式回归均为 **263/263 通过**。整改增强了原有四条测试的断言，没有靠增加测试数量美化结果；审查中故意失败的缺陷证明不计入正式通过项。
- 测试整改负对照：恢复缺少结果数据源时，搜索测试准确失败；省略列表持久化的副本实际执行后，三个增强列表测试全部因未落盘失败。生产文件未被变异修改。
- 原源码增量构建成功；接入 Logo 后 assembleHap 成功，CompileArkTS、PackageHap、SignHap 均执行完成。
- 六个缺陷复现均使用当前生产实现及受控边界，不对真实账号执行删除、发布、投币、私信等操作。
- 本轮未测量真实 FPS、内存、音画同步、弱网 CDN 或全部页面，不宣称完整端到端验收。

本地证据目录：[`.qa/audit-20260927`](../.qa/audit-20260927/)，此目录不提交仓库。关键文件：

| 文件 | 用途 |
| --- | --- |
| `feature-repros.cjs` / `feature-repros-output.json` | 三个业务缺陷的实际输出；断言确认当前错误存在，是审查证据，不是正确行为回归测试。 |
| `dynamic-cache-race.test.cjs` / `.log` | 无缓存控制用例通过，缓存返回的正确行为断言失败。需要支持 stripTypeScriptTypes 的本地 Node。 |
| `media-persistence.repro.cjs` | 后台迟到起播与冷恢复写入后重启丢记录，两个正确行为断言失败。 |
| `search-test-quality-repro.cjs` / `search-test-quality-output.json` | 修正前搜索测试假通过的夹具与证据。 |
| `mutation-validation.cjs` / `mutation-summary.json` | 三组 baseline/变异对照及行为断言。 |
| `redirect-list-mutation.cjs` | 持久化变异加载器，记录读取与实际执行次数，防止变异未注入造成假结论。 |
| `regression.log` / `final-regression.log` / `logo-build.log` | 初始、整改后的完整正式测试与新图标构建日志。 |
| `final-persistence-mutation.log` / `search-strengthened-negative-control.log` | 增强测试能抓住缺失落盘和失败加载的负对照。 |

可重跑示例（本机 DevEco 路径，其他环境需调整）：

```powershell
$env:ARKTS_TEST_TYPESCRIPT = 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript'
& 'C:/Program Files/Huawei/DevEco Studio/tools/node/node.exe' --test --test-timeout=20000 tool/qa/*.test.cjs
node .qa/audit-20260927/feature-repros.cjs
node --test .qa/audit-20260927/dynamic-cache-race.test.cjs
node --test .qa/audit-20260927/media-persistence.repro.cjs
```

最后两个命令在业务缺陷修复前应以行为断言失败退出；不要为了全绿而反转正确行为断言。
