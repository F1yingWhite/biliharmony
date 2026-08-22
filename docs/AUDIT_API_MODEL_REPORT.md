# BiliHarmony API 层 + 模型层 屎山审计报告

审计范围：`entry/src/main/ets/api/*.ets`（全部 10 个 API 文件）、`api/internal/ApiCommon.ets`、`model/Models.ets`、`model/LiveModels.ets`，并交叉比对了 `common/HttpClient.ets`、`common/Constants.ets`、`common/Utils.ets`。

严重程度：🔴 高优先级重构点（影响正确性 / 可维护性收益最大）｜🟡 中｜🟢 低。
所有行号以审计时的文件为准。

---

## 1. 重复代码

### 🔴 1.1 请求脚手架整段重复三套：`ActionResult` / `getData` / `actionWithCsrf` / `postVideoAction`
`ApiCommon.ets` 已经抽了 `internal/ApiCommon.ets`（第 9-58 行）作为统一脚手架，但 **`BiliApi.ets` 又原样复制了一份**：

- `ActionResult`：`ApiCommon.ets:9-19` **vs** `BiliApi.ets:34-44`（完全一致）
- `getData`：`ApiCommon.ets:22-32` **vs** `BiliApi.ets:102-112`（完全一致）
- `actionWithCsrf`：`ApiCommon.ets:35-51` **vs** `BiliApi.ets:274-290`（完全一致）
- `postVideoAction`：`ApiCommon.ets:53-58` **vs** `BiliApi.ets:292-298`（完全一致）

后果不只是一份重复代码，而是 **类型分裂**：UI 层从 `api/BiliApi` 导入 `ActionResult`（BiliApi 自己的那份，见 `VideoDetail.ets:15`、`Messages.ets:4`、`LibraryPages.ets:4` 等 20+ 处），而域模块（`CommentApi/LiveApi/DynamicApi` 等）返回的是 **`ApiCommon` 的 `ActionResult`**。二者靠“结构同型”才没编译报错，属典型的隐性类型窟窿。

建议：以 `internal/ApiCommon.ets` 为唯一事实源；删除 `BiliApi.ets:34-44、102-112、274-290、292-298` 这 88 行副本；让 `BiliApi` 统一 `export { ActionResult } from './internal/ApiCommon'` 转发，消除双类并存。

### 🔴 1.2 BiliApi 是 ~1500 行的“纯透传门面”
`BiliApi.ets` 1430 行里约 100 个方法只是**一行透传**（`return XxxApi.yyy(...)`），分布在：
- 直播透传 `BiliApi.ets:141-183`
- 评论/历史透传 `648-678、681-712`
- 动态透传 `715-745`
- 收藏夹透传 `760-814`
- 私信/通知透传 `817-863`
- 搜索/排行透传 `867-931`
- 用户透传 `934-1017`

每个域模块的方法签名在 `BiliApi` 全部重复一遍，任何签名变更都要同步两处。

建议修复建议：删掉门面类，让 UI 直接 import 各域模块；或保留一个**极薄**的 `BiliApi`，只 re-export（`export { FeedApi as Feed }`）不逐行重写签名。这是本报告“先做 10 项”里的头号项目。

### 🟡 1.3 同一请求结构被手写复制 68 处
`'?' + HttpClient.buildQuery(params)` 模式在 api 层出现 **68 次**（`HttpClient.get(` 共 74 处）。`Constants.webHeaders` 用 `HttpClient.merge(..., { 'Referer': 'https://live.bilibili.com/'... })` 反复打补丁：
- `'Referer': 'https://live.bilibili.com/'` 出现 11 次（`LiveApi.ets` 内）
- `'Referer': 'https://message.bilibili.com/'` 出现 13 次（`MessageApi.ets` 内）
- `'Referer': 'https://space.bilibili.com/'` 3 次（`UserApi/BiliApi`）
- `'build': '0', 'mobi_app': 'web'` 头拼接重复 11 次（`MessageApi`）

建议修复：在 `ApiCommon` 增加 `DomainHeaders`（live/message/space 域名各自的默认 Referer）与 `getJson(url, params, overrides)`/`createHeadersForDomain(domain)` 助手，把 “拼 query + merge referer” 收敛成一行。收益：删除约 60-80 行脚手架，且统一 Referer 拼写。

### 🟢 1.4 重复的列表映射循环
`for (i...){ result.push(Xxx.from(arr[i])) }` 在 api/model 层出现 **98 处**。`UserApi` 的 `parseDynamicPage`（`DynamicApi.ets:119-132`）逻辑几乎逐字重复 `getUserDynamicFeed` 与 `getDynamicFeed`。

建议修复建议：ArkTS（API 26）支持 `Array.prototype.map/filter/forEach`，可改 `const arr = asArray(data['list']).map(o => XxxItem.from(o)).filter(i => i.xid > 0)`。注意 ArkTS **不支持对象展开和数组解构**，但 `.map/.filter` 可用（见第 6 节）。

---

## 2. 超长方法 / 超长类

### 🔴 2.1 `BiliApi` 类 1145 行（1430 行文件）
见 1.2。既含自有逻辑（登录、弹幕、PGC、互动）又含 60+ 个透传。应拆成 `LoginApi` / `DanmakuApi` / `PgcApi` / `InteractionApi` 等，或直接删除门面层。

### 🟡 2.2 `LiveApi.getLivePlayInfo` 70 行（`LiveApi.ets:127-198`）
四层嵌套 `stream→format→codec→accept_qn` 循环 + 计分选流。可抽出 `selectBestStream(...)`、`collectAvailableQn(...)` 两个纯函数。

### 🟡 2.3 `UserApi.getUserSpaceDecoration` 76 行（`UserApi.ets:84-160`）
典藏卡裁剪坐标计算混在 JSON 解析里，含手写 `split('-')` + 4 段 `Number` 判断。建议拆成 `parseCollectionHeaderEntry(raw)`。

### 🟡 2.4 `Models.DynamicItem.from` 141 行（`Models.ets:1376-1517`）
动态卡片类型切换靠 **9 个连续 `if (Object.keys(card).length === 0)`**（`Models.ets:1426-1434`）逐个试探 `archive/ugc_season/pgc/courses/medialist/common/upower_common/music/live`。这是魔法字符串 + 手写链式 fallback 的典型屎山。建议抽象成 `CARD_FIELDS` 表 + 循环，或按 major.type 显式 switch。

### 🟡 2.5 `ReplyItem.from` 105 行（`Models.ets:1084-1188`）
单条评论解析塞了虚拟装扮（`pendant/sailing/cardbg/garb` 多份兼容字段）、@ 提及两套来源、表情/图片/跳转，责任过多。建议拆 `parseMemberDecoration` / `parseMentions` / `parseEmotes`。

---

## 3. 模型文件问题

### 🔴 3.1 大量重复的手写 `fromXxx` 字段赋值
`Models.ets` 里 `VideoItem.fromAppItem(33)` / `fromHotItem(57)` / `fromWebRecommendItem(88)` / `fromSearchItem(115)` / `fromSpaceItem(137)` 五个静态方法前 13 行几乎同名赋值（`aid/bvid/title/cover/duration/play/danmaku/upName/playText...`）。另 `HistoryVideoItem.from`（622）与 `WatchLaterItem.from`（652）都逐字段手搭 `VideoItem`，`FavoriteApi.getFavoriteVideos`（`FavoriteApi.ets:110-125`）与 `getCollectionVideos`（225-239）也是各自手搭 `VideoItem`。

建议修复：抽一个 `VideoItem.parseBasic(j, {coverField, durationField, ownerField,...})` 的字段映射描述表，或为常见来源写 2-3 个复用组合器，消灭 5 处近似重复。

### 🟡 3.2 未使用字段检查
- `VideoItem` 声明了 `like/reply/favorite/coin/share`（`Models.ets:19-23`）与 `videos`、`tname`、`upFace`——在 `fromAppItem/fromSearchItem/fromSpaceItem` 里**从不赋值**，只 `fromHotItem/webRecommendItem` 赋值，属半死字段。
- `LiveRoomInfo.from`（`LiveModels.ets:101-118`）里 `watched_show` 解析 `text_large/text_small` 后又完全没用到 `watchedShow` 变量？—— 实际上赋值了，但 `LiveRoomInfo` 类内 `watched` 与 `LiveRoomItem` 的 `watched` 生成规则重复。
- **整个 `SpaceDecorationInfo` 类在 `BiliApi.ets:94-99` 是死代码**：`BiliApi` 内无人使用，真正的实现在 `UserApi.ets:13-18`。→ 可直接删除，且该副本与 UserApi 副本不一致，正是“两份都要维护”的坑。

### 🟡 3.3 未使用端点常量（`Constants.Api` 中定义但无人调用）
- `Api.ab2c`（`Constants.ets:104`）
- `Api.favResourceDel`（`Constants.ets:179`）——注释里说 `/x/v3/fav/resource/del` 会 404 而改用 batch-deal，但常量仍留着
- `Api.followTagUpdate` / `Api.followTagDel`（`Constants.ets:207-208`）
- `HttpString.accountBaseUrl`（`Constants.ets:15`）
均可删除或标记 TODO。

### 🟡 3.4 `ForEach` 键依赖业务字段，缺稳定 id
`ReplyItem.rev`（`Models.ets:1046`）用“本地修订号”驱动 `LazyForEach`，原因为类没有稳定 id。同理念 `HistoryVideoItem` 复合 `video` 子对象。建议给这些模型加 `key()` 生成器，避免 UI 层踩 rev 的雷。

---

## 4. 硬编码 magic number / 字符串

### 🟡 4.1 风控 / 业务 magic code 散落
`-101`（未登录）/ `-111`（无 CSRF）在 api 层出现 **8 处**，`-352`（风控）、`-400`、`-412`、`-999` 作为响应默认值直接写死（`MessageApi.ets:30,130,214,265`）。建议在 `ApiCommon` 定义 `const ERR_NOT_LOGIN=-101; ERR_NO_CSRF=-111; RISK_CODE=352;` 等常量。

### 🟡 4.2 接口版本魔法号硬编码
- `build=2001100`、`appKey/appSec` 在 `Constants.ets:22-23` 与 `Constants.RecommendParams.build`（254-285）、`BiliApi.loginByPassword/sendCode`（`BiliApi.ets:1251,1284`）重复，且和 `UserApi.getUserSpaceDecoration` 的 `build/8.43.0`（`UserApi.ets:87-94`）不一致——同一 app 至少出现了两套 build 号。
- `web_location`（风控 token）散落 13 处不同值：`333.1330/333.1387/333.1245/1315875/1315873/333.1296/333.40164/333.934/444.8`，且同一语义（"网页评论"）在 `CommentApi:41` 与 `CommentApi:113` 各写一份。建议抽出 `WebLocationToken` 常量表。
- 弹幕颜色 `'16777215'`、字号 `'25'`、`fnval='4048'`、`pager` 等散落在 `BiliApi.ets:436-441`、`CommentApi` 等。

### 🟢 4.3 `qualityShortName`（`Models.ets:561-576`）用 15 个 `if (qn===x)` 手写映射
`'timeline', 129,127,126,125,120,116,112,80,74,64,32,16,6` 全部硬编码。建议 `const QN_NAMES = new Map<number,string>(...)`。

---

## 5. 错误处理不一致

### 🔴 5.1 同一种失败有的返回空、有的置 error、有的抛异常、有的返回默认对象
评分偏高的问题：
- `CommentApi.getReplies`（`CommentApi.ets:48-51`）失败仅 `return new ReplyData()`，错误被吞掉、UI 无提示；
- `FavoriteApi.getFavoriteVideos`（`FavoriteApi.ets:106`）同样吞错返回空；
- 但 `MessageApi.getMessageSessions`（`MessageApi.ets:26-33`）、`getPrivateMessages`（`MessageApi.ets:128-138`）、`getMsgFeedNotify`（210-215）失败会往 `result.error` 塞原因 + `hilog.warn`；
- 而 `SearchApi.getHotSearch`（17-20）检查 `resp.ok` 但 `getHotSearch` 与 `getSearchTrending`（32-44）对 `resp.ok` 判断后对**没 ok 也不看 code**，直接 `json['list']`。

建议：`getData` 之外再加一个 `getDataWithError(resp): {data, error}` 统一失败语义，域方法统一“业务失败→返回类型默认值 + error 字段”，替代“有的吞错有的吐 message”。

### 🟡 5.2 两个“手动解析 code/data”的非标准分支
- `BiliApi.getBangumiSeason`（`BiliApi.ets:461-486`）没有走 `getData`，而是自己 `if (asNumber(json['code'])!==0) return null` + 从 `result` 而非 `data` 取值——函数内部手写了一套 `getData`；
- `BiliApi.reportMember`（`BiliApi.ets:1008-1012`）返回码依赖 `json['status']` 布尔，而非 `code`，`ActionResult.code` 被赋 0 或 -1，与其他举报接口（走 `actionWithCsrf`）不一致。
- `BiliApi.getPgcTimeline`（`Bitmap`? 实际 `BiliApi.ets:563`）用 `resp.json()` 后手动 `code!==0`。

---

## 6. 冗余代码 / ArkTS 约束对照

### 🟡 6.1 现成 API 可用却手写循环/手工复制
**ArkTS 实际约束**（已在 `HttpClient.ets` 确认注释）：不支持对象展开、数组解构；但 `Array` 的 `.map/.filter/forEach/findIndex/sort/concat/indexOf` 全部可用（本项目 `HistoryApi.ets:59` 已用 `.map(...).join(',')`，`BiliApi` 用了 `.sort`、`Messages` 用了 `.concat/.findIndex`）。

可被替代的“手写 for”用例（共 98 处）：
- 把 `wbiParams` 逐 key 复制（`BiliApi.ets:220-229`）→ 直接 `HttpClient.merge(params, {...})`；
- `Object.keys(pageinfo).forEach(...)` 等 → 用 `Object.keys(...).map`。

### 🟢 6.2 明显冗余代码段
- `BiliApi.loginHeaders()`（`BiliApi.ets:1208-1210`）只在加密用一次，与 `FeedApi` 的 `merge(appHeaders,{buvid})` 重复——可并入但 `buvid` 翻种，收益很小。
- `RepostDynamic`（`DynamicApi.ets:65-92`）用**字符串拼接构造 JSON**（`'{"upload_id":"'+id+'"}'`），若 id 带引号会崩，应改用对象 + `JSON.stringify`。
- `WatchLaterSeasonItem.from`（`Models.ets:2084`）`str(seasonType, '', '')`——用 `''` 作为 key 取值永远是默认值，是死代码/拼写 bug（应读 `j['season_type_name']` 或 `j['type_name']`）。

---

## 7. 命名不一致

- 🟡 `action` 与 `ActionResult` 的 `ok/message/code` 与域返回模型（`ReplyPageData`、`${Xxx}PageData`）命名混用 `item.items` 各异：`ReplyData.replies` vs `ResponsePageData.items` vs `FavoriteFolderPageData.folders`。
- 🟡 中英混用：`dynId`（英文缩写）+ `upName/upMid/upFace`（up 英文 + 中文注释），`pubdate` / `pub_time_show` / `pubTimeShow` 三套时区命名，`tname`（无注释）。
- 🟢 `getData` 返回 `Record|null`，`getData` 语义其实包含“成功才返回”；又有 `HttpResponse.json()`（`HttpClient.ets:24-31`）另一个命名——语义重叠。
- 🟢 常量前缀不统一：`HttpString`、`Constants`、`Api`、`RecommendParams`，同类端点却分两个基类 `baseUrl` vs `BaseUrl`。

---

## 8. 其他坑

- 🔴 **两个 `ActionResult` 类同 identity**（见 1.1）：一旦一方加字段，UI 层强转就会 `undefined`。
- 🟡 `apiVersion` 字符串用 `+ '?' +` 拼接 URL（`Api.onlineTotal + '?' + buildQuery(params)`），Localhost/敏感字符未被 IDN-encode，`#`/`&` 会在 query 中错位——已有 `buildQuery` 却仍手拼。
- 🟡 `MessageApi.fillMsgFeedCursor`（`MessageApi.ets:242-250`）与 `getSysNotifications` 的 `cursors` 正则（271-276）都用正则抠 int64——是用字符串手擂的 workaround，应封成 `extractInt64Fields(body)` 一个 helper。
- 🟢 `BiliApi` 导入 `hilog`（`BiliApi.ets:6`）但从未使用；`LiveApi.ets:7` 导入 `asString` 但从未使用。均有死 import。
- 🟢 `ParseVideoDetail` 中 `d.cover = str(j,'pic','')` 未 `toHttps`（`Models.ets:327`），而各列表都用 `toHttps`，URL 处理不一致。

---

## 最值得先做的 10 项重构（按投入产出比排序）

1. **统一 `ActionResult`/getData/actionWithCsrf**：删除 `BiliApi.ets:34-44、102-112、274-290、292-298` 四段副本，只保留 `internal/ApiCommon.ets`，并由 `BiliApi` re-export。→ 根治“类型双类 + 88 行重复”。
2. **消除 BiliApi 透传门面**（约 60+ 个一行 `return XxxApi.y()`）：UI 层直接依赖域模块；`BiliApi` 只保留自有逻辑（登录/弹幕/PGC/互动）。→ 减 ~900 行。
3. **统一错误处理**：补 `getDataWithError`，每个域方法统一 “业务失败给 `error` 字段”而非散抛/吞错；对齐 `CommentApi/Messages/Favorite/History` 差异。
4. **抽取请求脚手架**：`ApiCommon` 加 `DomainWebFetch(domain,params,overrides)`，收敛 68 处 `'?'+buildQuery` + 各域 Referer merge。
5. **`DynamicItem.from` 去魔法链**：用 `CARD_TYPE→field` 映射表替代 9 连 `if(Object.keys(card).length===0)`。
6. **`VideoItem` 解析器去重**：`Models` 内 5 个 `from*` 前 13 块 + `History`/`Favorite` 手搭 `VideoItem` 合并到一个工厂。
7. **`View.SpaceDecorationInfo` 死类删除**（`BiliApi.ets:94-99`），并去重 `UserApi.ets:13-18` 与 `Constants` 未用端点。
8. **风控/业务 magic 号集中化**：`-101/-111/-352/-412`、`web_location`、`build=2001100` 等抽到 `ApiCommon` 常量。
9. **手写循环替为 `.map/.filter`**（ArkTS 26 已支持，见 `HistoryApi` 先例）。
10. **修命名 bug / 语义**：`WatchHistorySeasonItem` 的 `str(seasonType,'','')` 死代码（`Models.ets:2084`）、`Repost动态` 字符串拼 JSON、`Models/PgcVideo` cover 未 `toHttps`。

> 建议重构方向：按“域模块 + 薄门面”+ 单一 `ApiCommon` + 工厂模型，目标是把 `BiliApi.ets` 从 1430 行降到 ~500 行以内、把 `Models.ets` 2xxx 行的 `from*` 解析收敛掉约 40%。