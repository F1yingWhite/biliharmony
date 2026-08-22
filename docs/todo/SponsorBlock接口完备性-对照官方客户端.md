# SponsorBlock（小电视空降助手）接口完备性盘点 —— 对照官方客户端

> **2026-08-22 完成状态：** P0 读侧、P1 贡献闭环与 P2 社区身份/计数均已原生实现，入口位于播放器「更多 → 空降助手」。实现包含哈希查询与旧协议回退、cid 隔离、10 分钟缓存/强制刷新、11 类四档策略、`skip/mute/full/poi`、进度条标记、提示/撤销、投稿/赞踩/观看统计、匿名 ID、昵称/贡献统计/版主提醒。P3 的 B 站→YouTube port 映射系列按本文原定边界不纳入 B 站数据闭环。

> 2026-08-19 盘点。对照对象：https://github.com/hanydd/BilibiliSponsorBlock （已 clone 至 `/tmp/bilibili-sponsorblock`，commit `07ddf7c`）。
> 服务地址：`https://bsbsb.top`（官方 `config.json` 默认 `https://www.bsbsb.top`，已实测两者均可达，本地代码用的是不带 `www` 的）。
> 本文所有接口行为均已对真实服务器请求验证。

## 1. 本地现状（已实现）

| 功能 | 位置 | 说明 |
| --- | --- | --- |
| `GET /api/skipSegments?videoID=&cid=` | `BiliApi.ets:661`（`getSponsorSegments`），地址在 `Constants.ets:216` | 请求格式已实测可用；官方用的是 `GET /api/skipSegments/{SHA256(bvid) 前 4 位}` 批量模式（返回 `[{videoID, segments:[...]}]`，一次带回同 hash 前缀的多个视频），服务器两种格式都支持，无功能差异 |
| 自动跳过 + 开关 | `PlayerView.ets:751`（`loadSponsorSegments`）、`PlayerView.ets:777`（`maybeSkipSponsor`）、`AppTheme.ets:124`（持久化 `sponsorSkipEnabled`） | 只在进入片段起点时 seek 一次，toast 提示；仅处理 `actionType === 'skip'` |
| 数据模型 | `BiliApi.ets:81`（`SponsorSegment`） | 仅 `start / end / category / uuid` 四个字段 |

## 2. 读侧不完备（P0）

1. **分类白名单过窄且写死**：`BiliApi.ets:675` 只保留 `sponsor` / `selfpromo`。官方（其 `config.json` categoryList）支持 11 类：
   `sponsor, selfpromo, exclusive_access, interaction, poi_highlight, intro, outro, preview, padding, filler, music_offtopic`。
   本地缺 9 类，其中 `intro`（片头）/ `outro`（片尾）是 B 站场景最高频的需求。
   实测：BV11Kc2zZEDK 返回的 `intro` 片段（0~20.934s，actionType=skip）会被本地直接丢弃，不跳过。
   官方侧分类是用户可配置的 `categorySelections`（每类独立 skip / mute / full / 关闭），本地无任何设置项。
2. **actionType 只支持 skip**，缺：
   - `mute`：进入片段后静音到片段结束；
   - `full`：整片标记（段为 `[0,0]`，配 `videoDuration`），官方在视频区用 categoryPill 展示"此视频为恰饭/合作视频"；
   - `poi`（`poi_highlight` 类）：高亮锚点，点击跳转到该时间点（不是跳过）。
3. **`SponsorSegment` 模型字段缺失**：服务器每条 segment 还带 `cid`、`videoDuration`、`locked`、`votes`、`description`（实测响应里有），本地模型没接，导致后续投票 UI、锁定判断、多 P 校验都做不了。
4. **多 P 视频未校验 cid**：本地不按 segment 的 `cid` 与当前播放 P 比对（官方按 bvId 匹配后把该视频全部 P 的段都交给播放器），建议客户端补校验，避免跳错 P。
5. **无缓存 / 无刷新**：官方有 segmentsCache、videoLabelCache（backgroundCache）+ `X-SKIP-CACHE: 1` 头 + 手动刷新按钮。本地每次进播放器裸请求。

## 3. 写侧 / 交互接口完全缺失（P1~P2，本地目前是纯只读消费者）

| 优先级 | 接口 | 方法 | 参数 | 用途（官方用法位置） |
| --- | --- | --- | --- | --- |
| P1 | `/api/skipSegments` | POST | `{videoID, cid, userID, segments, videoDuration, userAgent}` | 提交片段；响应返回带 `UUID` 的已建段（`segmentSubmission.ts:977`） |
| P1 | `/api/voteOnSponsorTime` | POST | query `?UUID=&userID=&type=`（type 缺省则带 `&category=`） | 片段上/下票，405=重复投票（`voteRequest.ts:17`） |
| P2 | `/api/viewedVideoSponsorTime` | POST | query `?UUID=` | 整跳（full skip）观看计数（`skipScheduler.ts:892`，受 trackViewCount 开关控制） |
| P2 | `/api/userInfo` | GET | body `{publicUserID, values:[... ]}`，values 可取 `userName, viewCount, minutesSaved, vip, permissions, segmentCount, warningReason` | 用户统计 / 警告原因（`user.ts:21`、`warnings.ts:14`） |
| P2 | `/api/getUsername` | GET | query `?userID=` | 警告弹窗里展示用户名（`warnings.ts:21`） |
| P2 | `/api/setUsername` | POST | query `?userID=&username=` | 设置用户名（`user.ts:9`） |
| P2 | `/api/warnUser` | POST | body `{userID, enabled:false}` | 确认并清除版主警告（`warnings.ts:50`） |

前置依赖：以上写接口都需要本地生成并持久化 `userID`（官方 `generateUserID()` + `Config.config.userID`），本地目前没有任何 userID 概念。

## 4. 高级功能接口缺失（P3，视功能范围取舍）

| 接口 | 方法 | 参数 | 用途 |
| --- | --- | --- | --- |
| `/api/videoLabels/{hashPrefix}` | GET | hashPrefix = SHA256(bvid) 前 4 位 | 整片标签块 `[{videoID, segments:[{category}]}]` → `Record<bvid, category>`，做"恰饭"整片标记 pill（`videoLabelRequest.ts`） |
| `/api/lockCategories/{hashPrefix}` | GET | 同上 | 管理员锁定的分类 `[{videoID, categories:[...]}]`，锁定后不可改/删（`segmentSubmission.ts:569`） |
| `/api/chapterNames` | GET | body/query `{description, channelID}` | 提交片段时的章节名建议（来自 YouTube 章节数据，`SponsorTimeEditComponent.tsx:776`） |
| `/api/portVideo/{hashPrefix}` | GET | SHA256 前 4 位（注意官方用 `getHash(bvid, 1)`） | 拉取 B↔YouTube 已映射数据，按 `bvID+cid` 匹配（`portVideo.ts:12`） |
| `/api/portVideo` | POST | `{bvID, cid, ytbID, biliDuration, userID, userAgent}` | 建立映射（`portVideo.ts:32`） |
| `/api/votePort` | POST | `{UUID, bvID, userID, type}` | 映射投票（`portVideo.ts:49`） |
| `/api/updatePortedSegments` | POST | `{videoID, UUID, cid}` | 用映射重新导入片段（`portVideo.ts:61`） |

> port 四个接口属于 B 站→YouTube SponsorBlock 数据同步特性，依赖 yt 侧数据，若本产品定位只做 B 站数据闭环可整体砍掉。

## 5. 落地建议（按优先级）

- **P0 读侧补齐**（改动集中在 `BiliApi.ets` + `PlayerView.ets`）：
  1. `SponsorSegment` 模型补齐 `cid / videoDuration / locked / votes / description`；
  2. 分类白名单从代码硬编码改为用户可配置（复用 `AppTheme` 持久化，参考官方 categorySelections 三态：skip/mute/full/off），默认至少打开 `sponsor, selfpromo, intro, outro`；
  3. `maybeSkipSponsor` 支持 mute（片段内静音）与 cid 校验；
  4. `full` + `videoLabels`：进播放器时顺带请求整片标签，恰饭视频顶部/进度条区域给标记（可选并入 P0 后续轮次）。
- **P1 贡献能力**：生成并持久化 `userID` → 提交片段（`POST /api/skipSegments`）+ 上/下票（`voteOnSponsorTime`）。最小闭环是"看到没跳过的广告 → 框选时间段 → 提交"。
- **P2 账号与计数**：`userInfo`（我的贡献统计，可做"我的"页卡片）、`setUsername/getUsername`、`warnUser` 警告弹窗、`viewedVideoSponsorTime`。
- **P3 port 系列**：默认不做，作为可选项记录在案。

## 6. 附：实测记录（2026-08-19，代理出口）

```
# 本地当前格式（可用，且按 video 精确返回）
GET https://bsbsb.top/api/skipSegments?videoID=BV11Kc2zZEDK&cid=36656057057
→ [{"cid":"36656057057","category":"intro","actionType":"skip","segment":[0,20.934],
    "UUID":"5ba43c74…","videoDuration":231,"locked":0,"votes":0,"description":""}]

# 官方 hash 前缀格式（一个前缀回来多个视频）
GET https://bsbsb.top/api/skipSegments/d5c2
→ [{"videoID":"BV11Kc2zZEDK","segments":[{...}]}, {"videoID":"BV1koabzUEWh","segments":[...]}]

# 无片段的视频：两种格式都返回 []（空数组），不是 404
```
