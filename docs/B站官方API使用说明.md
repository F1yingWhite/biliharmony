# B 站官方 API 使用说明（BiliHarmony 实测整理）

> 本文档整理本工程当前对接的 B 站官方公开 API：端点、请求方式、签名要求、
> 登录态要求与页面映射，作为后续重构/新增功能时的接口依据。
> 所有接口均为 B 站公开接口，仅供学习交流。

## 0. 请求基础设施

| 组件                         | 路径                        | 职责                                           |
| ---------------------------- | --------------------------- | ---------------------------------------------- |
| `common/HttpClient.ets`      | `@ohos.net.http` 封装       | GET/POST、Cookie 罐、CSRF 注入、统一错误码处理 |
| `common/Constants.ets`       | 域名 / UA / appKey / 请求头 | 见下表头部分                                   |
| `common/WbiSign.ets`         | WBI 签名                    | 需要 wbi 的端点自动附加 `w_rid` / `wts`        |
| `common/AppSign.ets`         | App 端签名                  | app 端接口的 `appkey` / `sign` 参数            |
| `common/Md5.ets`             | 纯 ArkTS MD5                | 供 AppSign / 密码加密使用                      |
| `common/RsaUtil.ets`         | RSA 公钥加密                | 密码登录二次加密                               |
| `api/internal/ApiCommon.ets` | `ActionResult` 等公共返回   | 统一成功/失败判定                              |
| `api/BiliApi.ets`            | 门面类                      | 向页面暴露全部接口（各领域 API 类汇总转发）    |

**返回结构约定**：`getData()` 抽 `data` 字段；`ActionResult{ok, message}` 统一表达成功/失败；
失败时 message 直接用于 toast。

## 二、域名与请求头

```ts
baseUrl        https://www.bilibili.com
apiBaseUrl     https://api.bilibili.com      // 绝大多数接口
tUrl           https://api.vc.bilibili.com   // 私信会话/消息
appBaseUrl     https://app.bilibili.com      // app 端：推荐/空间
liveBaseUrl    https://api.live.bilibili.com // 直播
passBaseUrl    https://passport.bilibili.com // 登录
searchBaseUrl  https://s.search.bilibili.com // 搜索
commentBaseUrl https://comment.bilibili.com  // 弹幕 xml
```

- web 端接口：`webHeaders`（浏览器 UA + Referer + Origin）
- app 端接口：`appHeaders`（BiliDroid UA + app-key + trace-id + fp）
- 登录态：`Cookie` 罐持久化（SESSDATA 等），`postVideoAction` 自动带 CSRF

## 三、API 模块与端点清单

### 1. FeedApi —— 首页推荐 / 热门

| 函数                   | 端点                                                                | 说明                                         |
| ---------------------- | ------------------------------------------------------------------- | -------------------------------------------- |
| `getRecommend(idx)`    | `app.bilibili.com/x/v2/feed/index?fnval=976&qn=32...`（app 端签名） | 首页推荐双列流，`idx` 游标;失败降级 web rcmd |
| `getRecommendApp(idx)` | app 端 `feed/index`                                                 | 同上游 app 参数                              |
| `getRecommendWeb(idx)` | `api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd`          | web 降级路径                                 |
| `getHot(pn, ps)`       | `api.bilibili.com/x/web-interface/popular`                          | 热门视频列表                                 |

### 2. SearchApi（搜索 / 排行榜 / 热搜）

| 函数                                                                                        | 端点                                                                                               |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `getHotSearch()`                                                                            | `s.search.bilibili.com/main/hotword`                                                               |
| `getSearchDefault()`                                                                        | `api.bilibili.com/x/web-interface/wbi/search/default`（搜索框默认占位词，data.show_name 为字符串） |
| `searchSuggest(term)`                                                                       | `s.search.bilibili.com/main/suggest`                                                               |
| `search(keyword, page)`                                                                     | `api.bilibili.com/x/web-interface/wbi/search/all/v2`                                               |
| `searchAll`                                                                                 | 同上（综合聚合）                                                                                   |
| `searchVideosByType` / `searchUsers` / `searchMedia` / `searchLiveRooms` / `searchArticles` | `wbi/search/type` 各 type                                                                          |
| `getRankVideos(rid)`                                                                        | `x/web-interface/ranking/v2`                                                                       |
| `getPopularSeriesList/One/Precious`                                                         | 每周必看 / 入站必刷                                                                                |

### 3. LiveApi（直播）

| 函数                    | 端点（域 lives）                                       |
| ----------------------- | ------------------------------------------------------ |
| `getLiveRooms`          | `/xlive/web-interface/v1/webMain/getList`              |
| `getLiveRoomInfo`       | `/room/v1/Room/get_info`                               |
| `getLivePlayInfo`       | `/xlive/web-room/v2/index/getRoomPlayInfo`（多画质）   |
| `getLiveDanmakuInfo`    | `/xlive/web-room/v1/index/getDanmuInfo`（WS 弹幕鉴权） |
| `getLiveDanmakuHistory` | `/xlive/web-room/v1/dM/gethistory`                     |
| `sendLiveDanmaku`       | `/msg/send`                                            |
| `getLiveEmoticons`      | `/xlive/web-ucenter/v2/emoticon/GetEmoticons`          |
| `getLiveSuperChats`     | `/av/v1/SuperChat/getMessageList`                      |

### 4. CommentApi（评论区）

| 函数                                     | 端点                                     | 说明                                                                     |
| ---------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------ |
| `getReplies(oid, type, cursor, mode)`    | `x/v2/reply?sort=1` 或 `/x/v2/replymain` | 有登录态走 legacy 分页可得总数;游客走 `/main` + `offset`;`-352` 降级 wbi |
| `getReplyReplies(oid, type, root, page)` | `x/v2/reply/reply?pn&ps`                 | 楼中楼分页                                                               |
| `addReply(oid, type, msg, root, parent)` | `/x/v2/reply/add`                        | root=楼中楼根,parent=被回复者                                            |
| `likeReply(oid, type, rpid, liked)`      | `/x/v2/reply/action`                     | action=0/1                                                               |
| `hateReply`                              | `/x/v2/reply/hate`                       |                                                                          |
| `getUserEmotes`                          | `/x/emote/user/panel/web`                | 登录后表情包                                                             |

### 5. DynamicApi（动态）

| 函数                              | 端点                                   |
| --------------------------------- | -------------------------------------- |
| `getDynamicDetail(id)`            | `/x/polymer/web-dynamic/v1/detail?id=` |
| `getDynamicFeed(offset, dynType)` | `/x/polymer/web-dynamic/v1/feed/all`   |
| `likeDynamic(dynId, like)`        | `/x/dynamic/feed/dyn/thumb`            |
| `repostDynamic(dynId)`            | `/x/dynamic/feed/create/dyn`           |
| `getUserDynamicFeed(mid)`         | `/x/polymer/web-dynamic/v1/feed/space` |

### 6. FavoriteApi（收藏 / 收藏夹管理）

| 函数                                             | 端点                                  |
| ------------------------------------------------ | ------------------------------------- |
| `getFavoriteFolders` / `getAllFavoriteFolders`   | `/x/v3/fav/folder/created/list(-all)` |
| `getFavoriteVideos`                              | `/x/v3/fav/resourcelist`              |
| `modifyVideoFavorite`                            | `/x/v3/fav/resource/batch-deal`       |
| `add/edit/delFavoriteFolder`                     | `/x/v3/fav/folder/add\|edit\|del`     |
| `delFavoriteResources` / `moveFavoriteResources` | `/x/v3/fav/resource/delemove`         |
| `getCollectedFolders`                            | `/x/v3/fav/folder/collected/list`     |
| `getCollectionVideos`                            | `/x/space/fav/season/list`            |

### 7. HistoryApi（历史 / 稍后再看）

| 函数                                                  | 端点                                                     |
| ----------------------------------------------------- | -------------------------------------------------------- |
| `getHistory`                                          | `/x/web-interface/history/cursor`（游标分页 + 观看进度） |
| `getWatchLaterList`                                   | `/x/v2/history/toview`                                   |
| `addWatchLater` / `delWatchLater` / `clearWatchLater` | `/x/v2/history/toview/(add                               | v2/dels | clear)` |

### 8. MessageApi（私信 / 消息通知）

| 函数                             | 端点（域 api.vc）                                  |
| -------------------------------- | -------------------------------------------------- |
| `getMessageSessions`             | `/session_svr/v1/session_svr/get_sessions?`        |
| `getPrivateMessages`             | `/svr_sync/v1/svr_sync/fetch_session_msgs?`        |
| `markPrivateMessagesReadoRead`   | `/session_svr/v1/session_svr/update_ack`           |
| `sendPrivateMessage`             | `/web_im/v1/web_im/send_msg`                       |
| `getMsgFeedUnread/Reply/At/Like` | `/x/msgfeed/…`                                     |
| `getSysNotifications`            | `message.bilibili.com/x/sys-msg/query_notify_list` |

### 9. UserApi（用户 / 空间）

| 函数               | 端点                                 |
| ------------------ | ------------------------------------ |
| `getNav`           | `/x/web-interface/nav`（登录态概览） |
| `getUserStat`      | `/x/relation/stat`                   |
| `getRelationUsers` | `/x/relation/followings\|followers`  |
| `getUserSpaceInfo` | `/x/space/wbi/acc/info`（wbi）       |
| `getUserSpaceArcs` | `/x/v2/space`（app 端投稿）          |

### 10. BiliApi（视频详情 / 播放 / 互动 / 登录 / 弹幕 — 汇总门面）

**视频详情与播放**
- `getVideoDetail` → `/x/web-interface/view`
- `getPlayUrl` → `/x/player/playurl`（fnval=4048 DASH，多 URL 容错）
- `getRelated` → `/x/web-interface/archive/related`
- `getOnlineTotal` → `/x/pl/online/total`
- `getVideoChapters` → `/x/pl/v2`（章节）
- `getSubtitleCues` → CC 字幕
- `SponsorBlockApi.getSegments` → `bsbsb.top/api/skipSegments/{SHA256(BVID)[:4]}`（按当前 cid 过滤，直查协议回退）
- `SponsorBlockApi.submit/vote/reportViewed` → 空降片段投稿、投票与跳过统计
- `SponsorBlockApi.getUserInfo/setUsername/acknowledgeWarning` → 空降社区身份与提醒

**互动（登录 + CSRF）**
- `likeVideo` / `dislikeVideo` / `coinVideo` / `reportShare`
- `reportHeartbeat` → `/x/click-interface/web/heartbeat`

**弹幕**
- `getDanmaku(cid)` → xml 兜底
- `getDanmakuSeg(cid, aid, segIndex)` → `/x/v2/dm/web/seg.so`（protobuf 分段，6 分钟/段）
- `sendDanmaku` → `/x/v2/dm/post`
- `getDanmakuFilter` / `addDanmakuFilter` / `delDanmakuFilter` → `/x/dm/filter/user`

**番剧（PGC）**
- `getBangumiSeason` → `/pgc/view/web/season`
- `followBangumi` → `/pgc/web/follow/add|del`
- `getBangumiFollowList` → `/pgc/web/follow/list?type&pn`（我的追番/追剧，需登录；type=1 番剧 / 2 影视）

**登录**
- `getTVCode` / `pollTVCode` → `/x/passport-tv-login/qrcode/*`
- `getLoginWebKey` → `/x/passport-login/web/key`
- `loginByPassword` → `/x/passport-login/oauth2/login`
- `sendSmsCode` / `loginBySms` → `/x/passport-login/sms/*`
- `CookiePair` / `TVCodeResult` … 结果模型

## 四、签名与登录态要点

1. **WBI 签名**：`WbiSign.encWbi(params)` 从 `nav` 接口拉 img/sub url 提取密钥，
   按官方算法对 query 排序后 `MD5`，附加 `w_rid` + `wts`。部分接口直接跑在
   `/wbi/` 前缀路径（如 `search/all/v2`）。
2. **app 签名**：`AppSign` 用 `appKey=dfca71928277209b` + `appSec` 对参数
   MD5 得到 `sign`。
3. **CSRF**：`postVideoAction` 自动注入 `csrf` 参数（Cookie `bili_jct`）。
4. **登录态判据**：`UserStore.isLogin` = Cookie 罐是否有 `SESSDATA`。

## 五、页面 ↔ API 映射速查

| 页面                           | 使用的 API                                                        |
| ------------------------------ | ----------------------------------------------------------------- |
| 首页 Index / HomeView          | FeedApi.getRecommend / getHot / LiveApi.getLiveRooms              |
| 分区频道 ZoneChannel           | SearchApi.getRankVideos(rid)（rid 即分区 id）                     |
| 我的追番 BangumiList           | BiliApi.getBangumiFollowList                                      |
| 搜索 Search                    | SearchApi 全家族                                                  |
| 视频 VideoDetail               | BiliApi.getVideoDetail/PlayUrl/Relation/… + CommentApi + 弹幕 API |
| 直播 LiveRoom                  | LiveApi 全家族 + LiveDanmakuClient(WS)                            |
| 动态 DynamicView/DynamicDetail | DynamicApi + CommentApi(评论区)                                   |
| 私信 Messages                  | MessageApi                                                        |
| 用户 UserSpace                 | UserApi + SearchApi.getRankVideos                                 |
| 历史/收藏/稍后 LibraryPages    | HistoryApi + FavoriteApi                                          |
| 登录 Login                     | BiliApi 登录三件套                                                |
| 排行榜 RankPage                | SearchApi rank 家族                                               |

## 六、重构建议（基于本清单）

1. **门面瘦身**：`BiliApi.ets` 目前同时是"门面"和"播放/登录/弹幕实现"，
   建议把播放/登录/弹幕逻辑下沉到独立 `PlayerApi`（或保留在 BiliApi 内只留播放域），
   让 `BiliApi` 成为纯转发门面（现已在做，Feed/Comment/… 均已拆分）。
2. **评论区复用**：三个页面（视频详情/动态详情/番剧详情）各有一份 `mutateReplyItem`+
   评论加载逻辑，建议提取 `common/ReplyMutation.ets` 已做核心;页面侧可继续抽 `ReplySection` 组件。
3. **返回模型统一**：`HistoryApi/DynamicApi/…` 返回模型与 `model/Models.ets` 对齐良好;
   `sponsorSegments` 为三方服务（非官方），保留但标注。
