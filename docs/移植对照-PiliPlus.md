# 移植对照（PiliPlus → BiliHaromny）

记录上游 Flutter 实现与本工程 ArkTS 实现的模块对应关系，便于对照排查与跟进上游行为。
原始 PiliPlus 工程保留在 `docs/ref/PiliPlus/` 作为本地参考（git 忽略，不随仓库分发）。

| PiliPlus (Flutter) | BiliHaromny (ArkTS) |
| --- | --- |
| lib/utils/wbi_sign.dart | common/WbiSign.ets |
| lib/utils/app_sign.dart | common/AppSign.ets |
| lib/http/init.dart + dio | services/network/HttpClient.ets（@ohos.net.http） |
| lib/http/video.dart | BiliApi.getRecommendApp / getHot / getPlayUrl |
| lib/http/reply.dart | BiliApi.getReplies / addReply + ReplyTree.ets |
| lib/http/search.dart | BiliApi.search / searchByType / searchSuggest / getHotSearch |
| lib/http/login.dart（扫码/密码/短信） | AuthApi.getTVCode / getWebQRCode / loginByPassword / loginBySms + RsaUtil.ets |
| lib/http/live.dart + 弹幕 socket | BiliApi.getLive* + common/LiveDanmakuClient.ets |
| lib/http/msg.dart | BiliApi.getMessageSessions / sendPrivateMessage |
| lib/http/fav.dart / history | BiliApi.getFavorite* / getHistory |
| lib/utils/theme_utils.dart（Material You） | common/ColorUtil.ets + AppTheme.ets |
| mpv/media_kit 播放 | 系统 AVPlayer + 自研 Canvas 弹幕引擎 |
| lib/models/* | model/Models.ets 导出入口 + model/* 领域模型 |

其他参考：

- 空降助手参考 [BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock) 的公开协议、分类和交互设计原生实现（上游 GPL-3.0）。
- 首页卡片设计、频道胶囊样式与分区图标集参考 [BewlyBewly](https://github.com/BewlyBewly/BewlyBewly)（MIT License）。
