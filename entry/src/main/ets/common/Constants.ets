/**
 * Bilibili API 常量：域名、密钥、UA、请求头等
 * 移植自 PiliPlus (Flutter) lib/http/constants.dart 与 lib/common/constants.dart
 */

export class HttpString {
  static readonly baseUrl: string = 'https://www.bilibili.com';
  static readonly apiBaseUrl: string = 'https://api.bilibili.com';
  static readonly tUrl: string = 'https://api.vc.bilibili.com';
  static readonly appBaseUrl: string = 'https://app.bilibili.com';
  static readonly liveBaseUrl: string = 'https://api.live.bilibili.com';
  static readonly passBaseUrl: string = 'https://passport.bilibili.com';
  static readonly messageBaseUrl: string = 'https://message.bilibili.com';
  static readonly spaceBaseUrl: string = 'https://space.bilibili.com';
  static readonly accountBaseUrl: string = 'https://account.bilibili.com';
  static readonly searchBaseUrl: string = 'https://s.search.bilibili.com';
  static readonly commentBaseUrl: string = 'https://comment.bilibili.com';
}

export class Constants {
  // Android 移动端 (PiliPlus 使用)
  static readonly appKey: string = 'dfca71928277209b';
  static readonly appSec: string = 'b5475a8825547a4fc26c7d518eaaa02e';

  static readonly traceId: string =
    '11111111111111111111111111111111:1111111111111111:0:0';

  // HD 端 UA（用于 app 端接口）
  static readonly userAgent: string =
    'Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2';

  // 手机 app 端 UA
  static readonly userAgentApp: string =
    'Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/8430300 channel/master innerVer/8430300 osVer/15 network/2';

  // 浏览器 UA（用于 web 端接口）
  static readonly browserUa: string =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15';

  static readonly statistics: string =
    '{"appId":5,"platform":3,"version":"2.0.1","abtest":""}';

  static readonly statisticsApp: string =
    '{"appId":1,"platform":3,"version":"8.43.0","abtest":""}';

  // 动态接口能力开关，与当前 PiliPlus 保持一致。
  static readonly dynFeatures: string = 'itemOpusStyle,listOnlyfans,onlyfansQaCard';

  // app 端接口通用请求头
  static readonly appHeaders: Record<string, string> = {
    'env': 'prod',
    'app-key': 'android_hd',
    'User-Agent': Constants.userAgent,
    'x-bili-trace-id': Constants.traceId,
    'x-bili-aurora-eid': '',
    'x-bili-aurora-zone': '',
    'bili-http-engine': 'cronet',
    'fp_local': '1111111111111111111111111111111111111111111111111111111111111111',
    'fp_remote': '1111111111111111111111111111111111111111111111111111111111111111',
    'session_id': '11111111',
  };

  // web 端接口通用请求头
  static readonly webHeaders: Record<string, string> = {
    'User-Agent': Constants.browserUa,
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
  };

  // B 站品牌色
  static readonly brandPink: string = '#FB7299';
  static readonly brandPinkDark: string = '#D44E7D';
  static readonly brandBlue: string = '#008AC5';
  static readonly brandBlueDark: string = '#2C9CC8';
  static readonly brandYellow: string = '#FFCC00';
}

export class Api {
  // ===== 推荐 / 热门 =====
  static readonly recommendListApp: string = HttpString.appBaseUrl + '/x/v2/feed/index';
  static readonly recommendListWeb: string = HttpString.apiBaseUrl + '/x/web-interface/wbi/index/top/feed/rcmd';
  static readonly hotList: string = HttpString.apiBaseUrl + '/x/web-interface/popular';

  // ===== 直播（仅观看，不包含开播、送礼或充值） =====
  static readonly liveRoomList: string = HttpString.liveBaseUrl + '/xlive/web-interface/v1/webMain/getList';
  static readonly liveRoomInfo: string = HttpString.liveBaseUrl + '/room/v1/Room/get_info';
  static readonly liveAnchorInfo: string = HttpString.liveBaseUrl + '/live_user/v1/Master/info';
  static readonly livePlayInfo: string = HttpString.liveBaseUrl + '/xlive/web-room/v2/index/getRoomPlayInfo';
  static readonly liveDanmakuHistory: string = HttpString.liveBaseUrl + '/xlive/web-room/v1/dM/gethistory';
  static readonly liveDanmakuInfo: string = HttpString.liveBaseUrl + '/xlive/web-room/v1/index/getDanmuInfo';
  static readonly liveSuperChat: string = HttpString.liveBaseUrl + '/av/v1/SuperChat/getMessageList';
  static readonly liveSendDanmaku: string = HttpString.liveBaseUrl + '/msg/send';
  static readonly liveEmoticons: string = HttpString.liveBaseUrl + '/xlive/web-ucenter/v2/emoticon/GetEmoticons';

  // ===== 视频 =====
  static readonly videoIntro: string = HttpString.apiBaseUrl + '/x/web-interface/view';
  // wbi 版 playurl 在部分网络/设备上被 412 风控，用非签名版（实测可匿名返回 durl）
  static readonly ugcUrl: string = HttpString.apiBaseUrl + '/x/player/playurl';
  static readonly ugcWbiUrl: string = HttpString.apiBaseUrl + '/x/player/wbi/playurl';
  static readonly relatedList: string = HttpString.apiBaseUrl + '/x/web-interface/archive/related';
  static readonly ab2c: string = HttpString.apiBaseUrl + '/x/player/pagelist';
  static readonly onlineTotal: string = HttpString.apiBaseUrl + '/x/player/online/total';
  static readonly playerInfo: string = HttpString.apiBaseUrl + '/x/player/wbi/v2';
  static readonly heartBeat: string = HttpString.apiBaseUrl + '/x/click-interface/web/heartbeat';
  static readonly videoRelation: string = HttpString.apiBaseUrl + '/x/web-interface/archive/relation';
  static readonly likeVideo: string = HttpString.apiBaseUrl + '/x/web-interface/archive/like';
  static readonly dislikeVideo: string = HttpString.appBaseUrl + '/x/v2/view/dislike';
  static readonly coinVideo: string = HttpString.apiBaseUrl + '/x/web-interface/coin/add';
  static readonly shareVideo: string = HttpString.apiBaseUrl + '/x/web-interface/share/add';

  // ===== 番剧/影视（PGC） =====
  static readonly bangumiSeason: string = HttpString.apiBaseUrl + '/pgc/view/web/season';
  static readonly bangumiFollowAdd: string = HttpString.apiBaseUrl + '/pgc/web/follow/add';
  static readonly bangumiFollowDel: string = HttpString.apiBaseUrl + '/pgc/web/follow/del';

  // ===== 评论 =====
  static readonly replyList: string = HttpString.apiBaseUrl + '/x/v2/reply';
  static readonly replyReplyList: string = HttpString.apiBaseUrl + '/x/v2/reply/reply';
  static readonly replyAdd: string = HttpString.apiBaseUrl + '/x/v2/reply/add';
  static readonly replyLike: string = HttpString.apiBaseUrl + '/x/v2/reply/action';
  static readonly replyHate: string = HttpString.apiBaseUrl + '/x/v2/reply/hate';
  static readonly userEmotes: string = HttpString.apiBaseUrl + '/x/emote/user/panel/web';

  // ===== 私信 =====
  static readonly sessionList: string = HttpString.tUrl + '/session_svr/v1/session_svr/get_sessions';
  static readonly sessionAccountList: string = HttpString.tUrl + '/account/v1/user/cards';
  static readonly sessionMessages: string = HttpString.tUrl + '/svr_sync/v1/svr_sync/fetch_session_msgs';
  static readonly ackSessionMessage: string = HttpString.tUrl + '/session_svr/v1/session_svr/update_ack';
  static readonly sendMessage: string = HttpString.tUrl + '/web_im/v1/web_im/send_msg';

  // ===== 消息通知（回复我的 / @我 / 收到的赞 / 系统通知，移植自 PiliPlus lib/http/msg.dart） =====
  static readonly msgFeedUnread: string = HttpString.apiBaseUrl + '/x/msgfeed/unread';
  static readonly msgFeedReply: string = HttpString.apiBaseUrl + '/x/msgfeed/reply';
  static readonly msgFeedAt: string = HttpString.apiBaseUrl + '/x/msgfeed/at';
  static readonly msgFeedLike: string = HttpString.apiBaseUrl + '/x/msgfeed/like';
  static readonly msgSysNotify: string = HttpString.messageBaseUrl + '/x/sys-msg/query_notify_list';
  static readonly msgSysUpdateCursor: string = HttpString.messageBaseUrl + '/x/sys-msg/update_cursor';

  // ===== 历史 / 收藏 =====
  static readonly historyList: string = HttpString.apiBaseUrl + '/x/web-interface/history/cursor';
  static readonly dynamicDetail: string = HttpString.apiBaseUrl + '/x/polymer/web-dynamic/v1/detail';
  static readonly favoriteFolders: string = HttpString.apiBaseUrl + '/x/v3/fav/folder/created/list';
  static readonly favoriteFoldersForVideo: string = HttpString.apiBaseUrl + '/x/v3/fav/folder/created/list-all';
  static readonly favoriteResourceDeal: string = HttpString.apiBaseUrl + '/x/v3/fav/resource/batch-deal';
  static readonly favoriteResources: string = HttpString.apiBaseUrl + '/x/v3/fav/resource/list';
  static readonly collectedFolders: string = HttpString.apiBaseUrl + '/x/v3/fav/folder/collected/list';
  static readonly collectionResources: string = HttpString.apiBaseUrl + '/x/space/fav/season/list';

  // ===== 稍后再看（端点与 PiliPlus lib/http/api.dart 对齐） =====
  static readonly toviewList: string = HttpString.apiBaseUrl + '/x/v2/history/toview';
  static readonly toviewAdd: string = HttpString.apiBaseUrl + '/x/v2/history/toview/add';
  static readonly toviewDel: string = HttpString.apiBaseUrl + '/x/v2/history/toview/v2/dels';
  static readonly toviewClear: string = HttpString.apiBaseUrl + '/x/v2/history/toview/clear';

  // ===== 收藏夹管理（需登录 + CSRF） =====
  static readonly favFolderAdd: string = HttpString.apiBaseUrl + '/x/v3/fav/folder/add';
  static readonly favFolderEdit: string = HttpString.apiBaseUrl + '/x/v3/fav/folder/edit';
  static readonly favFolderDel: string = HttpString.apiBaseUrl + '/x/v3/fav/folder/del';
  static readonly favResourceDel: string = HttpString.apiBaseUrl + '/x/v3/fav/resource/del';
  static readonly favResourceMove: string = HttpString.apiBaseUrl + '/x/v3/fav/resource/move';

  // ===== 搜索 =====
  static readonly hotSearchList: string = HttpString.searchBaseUrl + '/main/hotword';
  static readonly searchSuggest: string = HttpString.searchBaseUrl + '/main/suggest';
  static readonly searchDefault: string = HttpString.apiBaseUrl + '/x/web-interface/wbi/search/default';
  static readonly searchAll: string = HttpString.apiBaseUrl + '/x/web-interface/wbi/search/all/v2';
  static readonly searchByType: string = HttpString.apiBaseUrl + '/x/web-interface/wbi/search/type';

  // ===== 排行榜 / 必看榜单（移植自 PiliPlus lib/http/video.dart） =====
  static readonly rankAll: string = HttpString.apiBaseUrl + '/x/web-interface/ranking/v2';
  static readonly popularSeriesOne: string = HttpString.apiBaseUrl + '/x/web-interface/popular/series/one';
  static readonly popularSeriesList: string = HttpString.apiBaseUrl + '/x/web-interface/popular/series/list';
  static readonly popularPrecious: string = HttpString.apiBaseUrl + '/x/web-interface/popular/precious';

  // ===== 用户 =====
  static readonly userInfo: string = HttpString.apiBaseUrl + '/x/web-interface/nav';
  static readonly userStat: string = HttpString.apiBaseUrl + '/x/relation/stat';
  static readonly userRelation: string = HttpString.apiBaseUrl + '/x/relation';
  static readonly modifyUserRelation: string = HttpString.apiBaseUrl + '/x/relation/modify';
  static readonly userFollowings: string = HttpString.apiBaseUrl + '/x/relation/followings';
  static readonly userFollowers: string = HttpString.apiBaseUrl + '/x/relation/followers';
  static readonly memberInfo: string = HttpString.apiBaseUrl + '/x/space/wbi/acc/info';
  static readonly memberSpaceApp: string = HttpString.appBaseUrl + '/x/v2/space';
  // 小电视空降助手公开的 SponsorBlock for Bilibili 片段接口。
  static readonly sponsorSegments: string = 'https://bsbsb.top/api/skipSegments';
  static readonly memberArcSearch: string = HttpString.apiBaseUrl + '/x/space/wbi/arc/search';

  // ===== 动态 =====
  static readonly followDynamic: string = HttpString.apiBaseUrl + '/x/polymer/web-dynamic/v1/feed/all';
  static readonly memberDynamic: string = HttpString.apiBaseUrl + '/x/polymer/web-dynamic/v1/feed/space';
  static readonly thumbDynamic: string = HttpString.apiBaseUrl + '/x/dynamic/feed/dyn/thumb';
  static readonly createDynamic: string = HttpString.apiBaseUrl + '/x/dynamic/feed/create/dyn';

  // ===== 登录 (TV 扫码) =====
  static readonly getTVCode: string = HttpString.passBaseUrl + '/x/passport-tv-login/qrcode/auth_code';
  static readonly qrcodePoll: string = HttpString.passBaseUrl + '/x/passport-tv-login/qrcode/poll';

  // ===== 登录 (密码 / 短信验证码，app 端 passport，移植自 PiliPlus lib/http/api.dart) =====
  static readonly loginWebKey: string = HttpString.passBaseUrl + '/x/passport-login/web/key';
  static readonly loginByPassword: string = HttpString.passBaseUrl + '/x/passport-login/oauth2/login';
  static readonly smsSend: string = HttpString.passBaseUrl + '/x/passport-login/sms/send';
  static readonly loginBySms: string = HttpString.passBaseUrl + '/x/passport-login/login/sms';

  // ===== 弹幕 (xml 协议兜底 + protobuf 分段) =====
  static readonly danmakuXml: string = HttpString.commentBaseUrl + '/';
  // 网页端分段弹幕（每 6 分钟一段，DmSegMobileReply protobuf）
  static readonly danmakuSeg: string = HttpString.apiBaseUrl + '/x/v2/dm/web/seg.so';
  static readonly sendDanmaku: string = HttpString.apiBaseUrl + '/x/v2/dm/post';
  // 弹幕屏蔽词/正则/用户（x/dm/filter/user；type 0 关键词 / 1 正则 / 2 用户）
  static readonly danmakuFilter: string = HttpString.apiBaseUrl + '/x/dm/filter/user';
  static readonly danmakuFilterAdd: string = HttpString.apiBaseUrl + '/x/dm/filter/user/add';
  static readonly danmakuFilterDel: string = HttpString.apiBaseUrl + '/x/dm/filter/user/del';
}

// app 端推荐接口参数模板
export class RecommendParams {
  static build(idx: number): Record<string, string> {
    return {
      'build': '2001100',
      'c_locale': 'zh_CN',
      'channel': 'master',
      'column': '4',
      'device': 'pad',
      'device_name': 'android',
      'device_type': '0',
      'disable_rcmd': '0',
      'flush': '5',
      'fnval': '976',
      'fnver': '0',
      'force_host': '2',
      'fourk': '1',
      'guidance': '0',
      'https_url_req': '0',
      'idx': String(idx),
      'mobi_app': 'android_hd',
      'network': 'wifi',
      'platform': 'android',
      'player_net': '1',
      'pull': idx == 0 ? 'true' : 'false',
      'qn': '32',
      'recsys_mode': '0',
      's_locale': 'zh_CN',
      'splash_id': '',
      'statistics': Constants.statistics,
      'voice_balance': '0',
    };
  }
}
