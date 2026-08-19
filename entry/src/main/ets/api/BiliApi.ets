/**
 * B 站 API 层：推荐/热门/视频详情/播放地址/评论/搜索/登录/动态/用户空间
 * 移植自 PiliPlus lib/http/*.dart
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { appSign } from '../common/AppSign';
import { RsaUtil } from '../common/RsaUtil';
import { md5Hex } from '../common/Md5';
import { Api, Constants, RecommendParams } from '../common/Constants';
import { asObject, asArray, asString, asNumber, asBool, str, randomString, toHttps } from '../common/Utils';
import { VideoItem, VideoDetail, PlayUrlInfo, ReplyData, ReplyItem, ReplyPageData, UserInfo, UserStat, DynamicItem, DynamicPageData, HotSearchItem, UserSearchItem, SearchTypes,
  UserSpaceInfo, SpaceArcData, VideoSearchResult, UserSearchResult, VideoRelationState, HistoryVideoItem, HistoryPageData,
  FavoriteFolderItem, FavoriteFolderPageData, FavoriteVideoPageData, MessageSessionItem, MessageSessionPageData,
  PrivateMessageItem, PrivateMessagePageData, BiliEmotePackage, RelationUserItem, RelationUserPageData,
  UserSpaceHeaderItem, BangumiSeason, MsgNotifyItem, MsgNotifyPageData, MsgFeedUnread, WatchLaterItem,
  PgcSearchItem, PgcSearchResult, ArticleSearchItem, ArticleSearchResult, SearchAllResult, SearchAllSection,
  PopularSeriesItem, PopularSeriesData, SubtitleCue, SubtitleTrack, WatchLaterSeasonItem,
  BangumiIndexItem, BangumiIndexPageData, FollowTagItem, TimeLineDay, TimeLineEpisode } from '../model/Models';
import { LiveChatMessage, LiveDanmakuInfo, LiveDanmakuServer, LiveEmoteItem, LiveEmotePackage, LivePlayInfo,
  LiveQualityOption, LiveRoomInfo, LiveRoomItem, LiveSearchResult, LiveStatusItem, LiveZone } from '../model/LiveModels';
import { parseDanmakuSegment, ProtoDanmaku } from '../common/DanmakuProto';
import { CommentApi } from './CommentApi';
import { DynamicApi } from './DynamicApi';
import { FavoriteApi } from './FavoriteApi';
import { FeedApi } from './FeedApi';
import { HistoryApi } from './HistoryApi';
import { LiveApi } from './LiveApi';
import { MessageApi } from './MessageApi';
import { SearchApi } from './SearchApi';
import { UserApi } from './UserApi';
import { ActionResult, getData, actionWithCsrf, postVideoAction, webGet, webPost } from './internal/ApiCommon';

// 统一走 internal/ApiCommon 的 ActionResult（唯一类型来源），此处 re-export 保持调用方 import 不变。
export { ActionResult };

// 弹幕屏蔽规则（x/dm/filter/user 的 rule 项；type 0 关键词 / 1 正则 / 2 用户）
export class DmFilterRule {
  id: number = 0;
  type: number = 0;
  filter: string = '';

  static from(o: Object): DmFilterRule {
    const j: Record<string, Object> = asObject(o);
    const r: DmFilterRule = new DmFilterRule();
    r.id = asNumber(j['id'], 0);
    r.type = asNumber(j['type'], 0);
    r.filter = str(j, 'filter', '');
    return r;
  }
}

// 弹幕数据
export class DanmakuItem {
  time: number = 0;    // 出现时间（秒）
  mode: number = 1;    // 1-3 滚动, 4 底部, 5 顶部, 6 逆向滚动, 7 高级弹幕
  color: number = 0xFFFFFF;
  text: string = '';
  /** 弹幕 id（dmid），protobuf 分段来源有值；超过 2^53 有精度损失，仅作是否存在判断 */
  id: number = 0;
  /** dmid 十进制原串：弹幕点赞/举报必须传它；XML 兜底为空串 */
  idStr: string = '';
  /** 发送字号档位：18 小 / 25 标准 / 36 大；渲染时按 25 为基准缩放。 */
  fontsize: number = 25;
  /** 智能云屏蔽权重 0-10（越大越优质）；低于用户设定屏蔽等级的弹幕不喷出。 */
  weight: number = 10;

  constructor(time: number, mode: number, color: number, text: string, id: number = 0,
    fontsize: number = 25, weight: number = 10, idStr: string = '') {
    this.time = time;
    this.mode = mode;
    this.color = color;
    this.text = text;
    this.id = id;
    this.idStr = idStr;
    this.fontsize = fontsize;
    this.weight = weight;
  }
}

export class SponsorSegment {
  start: number = 0;
  end: number = 0;
  category: string = '';
  uuid: string = '';
}

export class VideoChapter {
  from: number = 0;
  to: number = 0;
  title: string = '';
  image: string = '';
}

export class BiliApi {
  /** 当前分 P 同时在看人数；接口失败返回空串，UI 不伪造 0。 */
  static async getOnlineTotal(aid: number, bvid: string, cid: number): Promise<string> {
    if (cid <= 0 || (aid <= 0 && bvid.length === 0)) return '';
    const params: Record<string, string> = { 'cid': String(cid) };
    if (aid > 0) params['aid'] = String(aid);
    if (bvid.length > 0) params['bvid'] = bvid;
    const resp: HttpResponse = await webGet(Api.onlineTotal, params);
    const data: Record<string, Object> | null = getData(resp);
    return data === null ? '' : str(data, 'total', '');
  }

  // ===== 推荐/热门（委托 FeedApi） =====
  // ===== 直播（委托 LiveApi） =====
  // ===== 视频详情（aid 与 bvid 二选一） =====
  static async getVideoDetail(aid: number, bvid: string): Promise<VideoDetail | null> {
    const params: Record<string, string> = bvid.length > 0 ? { 'bvid': bvid } : { 'aid': String(aid) };
    const url: string = Api.videoIntro + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await webGet(url);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return null;
    }
    return VideoDetail.from(data);
  }

  // ===== 播放地址（DASH 分离音视频可提供 1080P+；aid 与 bvid 二选一） =====
  static async getPlayUrl(aid: number, bvid: string, cid: number, qn: number = 127): Promise<PlayUrlInfo | null> {
    const params: Record<string, string> = {
      'cid': String(cid),
      'qn': String(qn),
      // 4049 = 4048 | 1：在 DASH 之外同时请求 durl 单路 MP4。≤1080P 优先用 MP4 单流
      // （AVPlayer 内部音画同步、seek 只需单路 Range 请求）；高画质仍走 DASH 双轨。
      'fnval': '4049',
      'fnver': '0',
      'fourk': '1',
      'high_quality': '1',
      'https_url_req': '1',
      'voice_balance': '1',
    };
    if (bvid.length > 0) {
      params['bvid'] = bvid;
    } else {
      params['avid'] = String(aid);
    }
    const loggedIn: boolean = HttpClient.getCookie('SESSDATA').length > 0;
    const headers: Record<string, string> = HttpClient.merge(Constants.webHeaders,
      { 'Referer': 'https://www.bilibili.com/video/' + bvid });
    let data: Record<string, Object> | null = null;
    if (loggedIn) {
      // PiliPlus 使用 WBI playurl 获取登录用户真实权限。try_look 只适用于游客，会员请求携带它会退回试看档位。
      const wbiParams: Record<string, string> = {};
      const paramKeys: Array<string> = Object.keys(params);
      for (let i: number = 0; i < paramKeys.length; i++) {
        wbiParams[paramKeys[i]] = params[paramKeys[i]];
      }
      wbiParams['gaia_source'] = 'pre-load';
      wbiParams['isGaiaAvoided'] = 'true';
      wbiParams['web_location'] = '1315873';
      wbiParams['dm_img_list'] = '[]';
      wbiParams['dm_img_str'] = '';
      wbiParams['dm_cover_img_str'] = '';
      wbiParams['dm_img_inter'] = '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}';
      await WbiSign.encWbi(wbiParams);
      const wbiResp: HttpResponse = await HttpClient.get(Api.ugcWbiUrl + '?' + HttpClient.buildQuery(wbiParams), headers);
      data = getData(wbiResp);
    }
    if (data === null) {
      // WBI 被局部网络风控时回退旧端点；只有游客才开启 1080P 试看。
      if (!loggedIn) params['try_look'] = '1';
      const resp: HttpResponse = await HttpClient.get(Api.ugcUrl + '?' + HttpClient.buildQuery(params), headers);
      data = getData(resp);
    }
    if (data === null) {
      return null;
    }
    return PlayUrlInfo.fromPlayUrl(data, qn);
  }

  /** CC 字幕内容：subtitle_url 返回 { body: [{ from, to, content }] }。失败返回空数组，UI 静默降级。 */
  static async getSubtitleCues(url: string): Promise<Array<SubtitleCue>> {
    if (url.length === 0) return [];
    const resp: HttpResponse = await HttpClient.get(url);
    if (resp.ok === false) return [];
    const json: Record<string, Object> = resp.json();
    const body: Array<Object> = asArray(json['body']);
    const cues: Array<SubtitleCue> = [];
    for (let i: number = 0; i < body.length; i++) {
      const cue: SubtitleCue = SubtitleCue.from(body[i]);
      if (cue.content.length > 0) cues.push(cue);
    }
    return cues;
  }

  // ===== 视频互动 =====
  static async getVideoRelation(aid: number, bvid: string): Promise<VideoRelationState | null> {
    const params: Record<string, string> = { 'aid': String(aid) };
    if (bvid.length > 0) params['bvid'] = bvid;
    const resp: HttpResponse = await webGet(Api.videoRelation, params);
    const data: Record<string, Object> | null = getData(resp);
    return data === null ? null : VideoRelationState.from(data);
  }

  /** 互动接口公共骨架与 POST 交互归 ApiCommon（actionWithCsrf / postVideoAction 保持 import 自 internal/ApiCommon）。 */

  static async likeVideo(aid: number, bvid: string, like: boolean): Promise<ActionResult> {
    const params: Record<string, string> = {
      'aid': String(aid),
      // Web 协议：1 点赞、2 取消点赞；0 会被服务端以 -400 拒绝。
      'like': like ? '1' : '2',
    };
    if (bvid.length > 0) params['bvid'] = bvid;
    return postVideoAction(Api.likeVideo, params);
  }

  /** 一键三连（点赞+投一币+收藏）：web_normal 协议，返回 0 表示成功（data 有 like/coin/fav 计数）。 */
  static async likeTriple(aid: number): Promise<ActionResult> {
    if (aid <= 0) return new ActionResult(false, '参数无效');
    return postVideoAction(Api.likeTriple, {
      'aid': String(aid),
      'eab_x': '2',
      'ramval': '0',
      'source': 'web_normal',
      'ga': '1',
      'spmid': '333.788.0.0',
      'statistics': '{"appId":100,"platform":5}',
    });
  }

  /** 视频点踩只有 App 端协议；dislike=0 点踩、1 取消。 */
  static async dislikeVideo(aid: number, bvid: string, dislike: boolean): Promise<ActionResult> {
    const accessToken: string = HttpClient.getAppAccessToken();
    if (accessToken.length === 0) {
      return new ActionResult(false, '点踩需要 App 授权，请退出后重新登录', -101);
    }
    const params: Record<string, string> = {
      'aid': String(aid),
      'dislike': dislike ? '0' : '1',
      'access_key': accessToken,
      'mobi_app': 'android_hd',
      'platform': 'android',
    };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.dislikeVideo, HttpClient.buildQuery(params),
      HttpClient.merge(Constants.appHeaders, { 'buvid': HttpClient.buvid }));
    if (!resp.ok) return new ActionResult(false, '网络请求失败 (' + String(resp.status) + ')', resp.status);
    const json: Record<string, Object> = resp.json();
    const code: number = asNumber(json['code'], -1);
    if (code === 0) return new ActionResult(true, '操作成功', 0);
    const serverMessage: string = str(json, 'message', '');
    return new ActionResult(false,
      (serverMessage.length > 0 && serverMessage !== '0' ? serverMessage : '点踩失败') + ' (' + String(code) + ')', code);
  }

  static async coinVideo(aid: number, bvid: string, multiply: number, selectLike: boolean): Promise<ActionResult> {
    const params: Record<string, string> = {
      'aid': String(aid),
      'multiply': String(multiply),
      'select_like': selectLike ? '1' : '0',
    };
    if (bvid.length > 0) params['bvid'] = bvid;
    return postVideoAction(Api.coinVideo, params);
  }

  static async reportShare(aid: number, bvid: string): Promise<ActionResult> {
    const params: Record<string, string> = { 'aid': String(aid) };
    if (bvid.length > 0) params['bvid'] = bvid;
    return postVideoAction(Api.shareVideo, params);
  }

  /** 弹幕屏蔽规则列表（type 0 关键词 / 1 正则 / 2 用户）。 */
  static async getDanmakuFilter(): Promise<Array<DmFilterRule>> {
    const resp: HttpResponse = await webGet(Api.danmakuFilter);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const rule: Array<Object> = asArray(data['rule']);
    const rules: Array<DmFilterRule> = [];
    for (let i: number = 0; i < rule.length; i++) {
      const item: DmFilterRule = DmFilterRule.from(rule[i]);
      if (item.filter.length > 0) rules.push(item);
    }
    return rules;
  }

  /** 添加弹幕屏蔽词/正则/用户（type 0 关键词 / 1 正则 / 2 用户）。 */
  static async addDanmakuFilter(type: number, filter: string): Promise<ActionResult> {
    if (filter.trim().length === 0) return new ActionResult(false, '屏蔽内容不能为空');
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '屏蔽规则已添加', '添加屏蔽失败',
      (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'type': String(type),
          'filter': filter.trim(),
          'csrf': csrf,
        };
        return webPost(Api.danmakuFilterAdd, params);
      });
  }

  /** 删除弹幕屏蔽规则；ids 由服务端规则 id 组成。 */
  static async delDanmakuFilter(ids: Array<number>): Promise<ActionResult> {
    if (ids.length === 0) return new ActionResult(false, '请先选择要删除的规则');
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '屏蔽规则已删除', '删除屏蔽失败',
      (csrf: string): Promise<HttpResponse> => {
        const idList: string = ids.join(',');
        const params: Record<string, string> = {
          'ids': idList,
          'csrf': csrf,
        };
        return webPost(Api.danmakuFilterDel, params);
      });
  }

  /** 视频播放进度上报（web 心跳协议）：played_time 使用秒；未登录时直接跳过。 */
  static async reportHeartbeat(aid: number, bvid: string, cid: number, playedSeconds: number): Promise<void> {
    if (cid <= 0 || playedSeconds <= 0) return;
    if (HttpClient.getCookie('SESSDATA').length === 0) return;
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return;
    const params: Record<string, string> = {
      'cid': String(cid),
      'type': '3',
      'played_time': String(playedSeconds),
      'csrf': csrf,
    };
    if (bvid.length > 0) {
      params['bvid'] = bvid;
    } else {
      params['aid'] = String(aid);
    }
    await webPost(Api.heartBeat, params);
  }

  /** 发送普通滚动弹幕；progress 使用毫秒，与官方 Web 接口一致。 */
  static async sendDanmaku(aid: number, bvid: string, cid: number, progressSeconds: number,
    message: string): Promise<ActionResult> {
    if (cid <= 0 || message.trim().length === 0) return new ActionResult(false, '弹幕内容不能为空');
    const params: Record<string, string> = {
      'type': '1',
      'oid': String(cid),
      'msg': message.trim(),
      'progress': String(Math.max(0, Math.floor(progressSeconds * 1000))),
      'color': '16777215',
      'fontsize': '25',
      'pool': '0',
      'mode': '1',
      'rnd': String(Date.now()),
      'plat': '1',
    };
    if (aid > 0) params['aid'] = String(aid);
    if (bvid.length > 0) params['bvid'] = bvid;
    return postVideoAction(Api.sendDanmaku, params);
  }

  /** 弹幕举报（需登录；reason 参考: 1 违法违规 2 色情 3 低俗 5 人身攻击 6 垃圾广告 7 引战 10 其他） */
  static async reportDanmaku(cid: number, dmid: string, reason: number): Promise<ActionResult> {
    if (cid <= 0 || dmid.length === 0) {
      return new ActionResult(false, '弹幕数据不完整，当前分段弹幕暂不支持举报');
    }
    return postVideoAction(Api.reportDanmaku, {
      'cid': String(cid),
      'dmid': dmid,
      'reason': String(reason),
      'type': '1',
    });
  }

  /** 弹幕点赞（需登录；op 1 点赞 / 2 取消点赞；platform=web_player 与网页端一致） */
  static async likeDanmaku(cid: number, dmid: string, op: number): Promise<ActionResult> {
    if (cid <= 0 || dmid.length === 0) {
      return new ActionResult(false, '弹幕数据不完整，当前分段弹幕暂不支持点赞');
    }
    return postVideoAction(Api.danmakuThumbup, {
      'dmid': dmid,
      'oid': String(cid),
      'op': String(op),
      'platform': 'web_player',
    });
  }

  // ===== 番剧/影视（PGC）详情：season_id 与 ep_id 二选一；该接口数据主体在 result 而非 data =====
  static async getBangumiSeason(seasonId: number, epId: number): Promise<BangumiSeason | null> {
    if (seasonId <= 0 && epId <= 0) {
      return null;
    }
    const params: Record<string, string> = {};
    if (seasonId > 0) {
      params['season_id'] = String(seasonId);
    } else {
      params['ep_id'] = String(epId);
    }
    const url: string = Api.bangumiSeason + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await webGet(url);
    if (!resp.ok) {
      return null;
    }
    const json: Record<string, Object> = resp.json();
    if (asNumber(json['code'], -1) !== 0) {
      return null;
    }
    const result: Record<string, Object> = asObject(json['result']);
    if (Object.keys(result).length === 0) {
      return null;
    }
    return BangumiSeason.from(result);
  }

  // ===== 追番/取消追番（需登录，CSRF 与点赞投币同一模式） =====
  static async followBangumi(seasonId: number, follow: boolean): Promise<ActionResult> {
    if (seasonId <= 0) {
      return new ActionResult(false, '番剧信息无效');
    }
    return postVideoAction(follow ? Api.bangumiFollowAdd : Api.bangumiFollowDel, {
      'season_id': String(seasonId),
    });
  }

  // ===== 我的追番列表（需登录；space/bangumi/follow/list：type 1番剧 / 2国创·影视，vmid 由页面层传） =====
  static async getBangumiFollowList(type: number, page: number, mid: number): Promise<Array<WatchLaterSeasonItem>> {
    if (mid <= 0) return [];
    const params: Record<string, string> = {
      'vmid': String(mid),
      'type': String(type),
      'follow_status': '0',
      'pn': String(Math.max(1, page)),
    };
    const resp: HttpResponse = await webGet(Api.bangumiFollowList, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const items: Array<Object> = asArray(data['list']);
    const out: Array<WatchLaterSeasonItem> = [];
    for (let i: number = 0; i < items.length; i++) {
      out.push(WatchLaterSeasonItem.from(items[i]));
    }
    return out;
  }

  // ===== 番剧索引（season_type: 1番剧 2国创 4电影 5电视剧 3纪录片；isFinish: -1全部 0连载 1完结） =====
  static async getBangumiIndex(seasonType: number, isFinish: number, page: number,
    order: number = 0): Promise<BangumiIndexPageData> {
    const result: BangumiIndexPageData = new BangumiIndexPageData();
    const params: Record<string, string> = {
      'season_id': '-1', 'area': '-1', 'is_finish': String(isFinish),
      'copyright': '-1', 'season_status': '-1', 'year': '-1', 'style_id': '-1',
      'order': String(order), 'st': '1', 'sort': '0',
      'page': String(Math.max(1, page)), 'season_type': String(seasonType),
      'pagesize': '20', 'type': '1',
    };
    // PGC 索引接口需要带 referer 的浏览器 UA。
    const headers: Record<string, string> = HttpClient.merge(Constants.webHeaders, {
      'Referer': 'https://www.bilibili.com/anime/',
    });
    const resp: HttpResponse = await webGet(Api.bangumiIndex, params, undefined, headers);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return result;
    }
    result.hasNext = asBool(data['has_next'], false);
    result.total = asNumber(data['total'], 0);
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) {
      const item: BangumiIndexItem = BangumiIndexItem.from(asObject(list[i]));
      if (item.seasonId > 0) {
        result.items.push(item);
      }
    }
    return result;
  }

  /** 新番时间表：番剧(types=1)/国创(types=4) 前后 before/after 天的排播。 */
  static async getPgcTimeline(types: number, before: number, after: number): Promise<Array<TimeLineDay>> {
    const out: Array<TimeLineDay> = [];
    const params: Record<string, string> = {
      'types': String(types),
      'before': String(before),
      'after': String(after),
    };
    const resp: HttpResponse = await webGet(Api.pgcTimeline, params, 'https://www.bilibili.com/anime/timeline/');
    const json: Record<string, Object> = resp.json();
    if (asNumber(json['code'], -1) !== 0) return out;
    const result: Array<Object> = asArray(json['result']);
    for (let i: number = 0; i < result.length; i++) {
      const dayRaw: Record<string, Object> = asObject(result[i]);
      const day: TimeLineDay = new TimeLineDay();
      day.date = str(dayRaw, 'date', '');
      day.dayOfWeek = asNumber(dayRaw['day_of_week'], 0);
      const eps: Array<Object> = asArray(dayRaw['episodes']);
      for (let j: number = 0; j < eps.length; j++) {
        day.episodes.push(TimeLineEpisode.from(eps[j]));
      }
      out.push(day);
    }
    return out;
  }

  // ===== 用户关系（与 PiliPlus 的 UserHttp.userRelation / VideoHttp.relationMod 对齐） =====
  static async getUserRelation(mid: number): Promise<number | null> {
    if (mid <= 0) return null;
    const url: string = Api.userRelation + '?' + HttpClient.buildQuery({ 'fid': String(mid) });
    const resp: HttpResponse = await webGet(url);
    const data: Record<string, Object> | null = getData(resp);
    return data === null ? null : asNumber(data['attribute'], 0);
  }

  static async modifyUserRelation(mid: number, follow: boolean): Promise<ActionResult> {
    if (mid <= 0) return new ActionResult(false, 'UP 主信息无效');
    return postVideoAction(Api.modifyUserRelation, {
      'fid': String(mid),
      'act': follow ? '1' : '2',
      're_src': '11',
      'gaia_source': 'web_main',
    });
  }

  // ===== 黑名单（需登录；act=5 拉黑 / 6 解除，列表分页） =====
  static async getBlackList(page: number): Promise<RelationUserPageData> {
    const result: RelationUserPageData = new RelationUserPageData();
    const params: Record<string, string> = {
      'pn': String(Math.max(1, page)),
      'ps': '30',
    };
    const resp: HttpResponse = await webGet(Api.blackList, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return result;
    }
    result.total = asNumber(data['total'], 0);
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) {
      const item: RelationUserItem = RelationUserItem.from(list[i]);
      if (item.mid > 0) result.users.push(item);
    }
    return result;
  }

  static async blockUser(mid: number, block: boolean): Promise<ActionResult> {
    if (mid <= 0) return new ActionResult(false, '用户信息无效');
    return postVideoAction(Api.modifyUserRelation, {
      'fid': String(mid),
      'act': block ? '5' : '6',
      're_src': '11',
      'gaia_source': 'web_main',
    });
  }

  // ===== 相关视频（aid 与 bvid 二选一） =====
  static async getRelated(aid: number, bvid: string): Promise<Array<VideoItem>> {
    const params: Record<string, string> = bvid.length > 0 ? { 'bvid': bvid } : { 'aid': String(aid) };
    const url: string = Api.relatedList + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await webGet(url);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const list: Array<Object> = asArray(data);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < list.length; i++) {
      result.push(VideoItem.fromHotItem(list[i]));
    }
    return result;
  }

  // ===== 评论（委托 CommentApi） =====
  // ===== 历史/稍后再看（委托 HistoryApi） =====

  /** 删除单条观看历史（按 bvid）。 */
  static async deleteHistoryItem(bvid: string): Promise<ActionResult> {
    if (bvid.length === 0) return new ActionResult(false, '参数无效');
    return postVideoAction(Api.historyDelete, {
      'aid': '', 'kid': bvid, 'platform': 'web',
    });
  }

  /** 清空全部观看历史（需二次确认）。 */
  static async clearHistory(): Promise<ActionResult> {
    return postVideoAction(Api.historyClear, { 'platform': 'web' });
  }

  // ===== 动态（委托 DynamicApi） =====
  // ===== 发布动态（纯文字，需登录；type=4 纯文字；未登录由 csrf 校验失败兜底） =====
  static async publishDynamic(content: string): Promise<ActionResult> {
    const text: string = content.trim();
    if (text.length === 0) return new ActionResult(false, '动态内容不能为空');
    if (text.length > 2000) return new ActionResult(false, '动态内容过长（最多 2000 字）');
    return postVideoAction(Api.createDynamic, {
      'dynamic': text,
      'type': '4',
      'at_uids': '',
      'topic_id': '',
    });
  }
  /** 动态举报（需要 dynId + reason；reason 参考：1 违法违规 2 色情低俗 … 99 其他）。 */
  static async reportDynamic(dynId: string, reason: string): Promise<ActionResult> {
    if (dynId.length === 0) return new ActionResult(false, '动态信息不完整');
    return postVideoAction(Api.dynamicReport, {
      'dyn_id': dynId,
      'reason': reason,
      'content': '',
    });
  }


  // ===== 收藏夹/合集（委托 FavoriteApi） =====
  // ===== 私信/消息通知（委托 MessageApi） =====
  // ===== 搜索/排行（委托 SearchApi） =====
    // ===== 用户（委托 UserApi） =====
  // ===== 关注分组（关注标签） =====
  /** 我的关注分组列表（x/relation/tags），返回 {tagid, name, count}。 */
  static async getFollowTags(): Promise<Array<FollowTagItem>> {
    const resp: HttpResponse = await webGet(Api.followTags, undefined, 'https://space.bilibili.com/');
    const data: Record<string, Object> | null = getData(resp);
    const result: Array<FollowTagItem> = [];
    if (data === null) return result;
    const list: Array<Object> = asArray(data['data']);
    for (let i: number = 0; i < list.length; i++) {
      const o: Record<string, Object> = asObject(list[i]);
      const t: FollowTagItem = new FollowTagItem();
      t.tagid = asNumber(o['tagid'], 0);
      t.name = str(o, 'name', '');
      t.count = asNumber(o['count'], 0);
      if (t.tagid > 0) result.push(t);
    }
    return result;
  }

  /** 创建关注分组，返回新 tagid（失败/未登录返回 0）。 */
  static async createFollowTag(tagName: string): Promise<number> {
    if (tagName.length === 0) return 0;
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return 0;
    const resp: HttpResponse = await webPost(Api.followTagCreate, { 'tag': tagName, 'csrf': csrf }, 'https://space.bilibili.com/');
    const json: Record<string, Object> = resp.json();
    if (asNumber(json['code'], -1) !== 0) return 0;
    const data: Record<string, Object> = asObject(json['data']);
    return asNumber(data['tagid'], 0);
  }

  /** 设置某 UP 所属关注分组：tagids 为空串 = 默认分组。 */
  static async addUserToTags(mid: number, tagIds: Array<number>): Promise<ActionResult> {
    return postVideoAction(Api.followTagsAddUsers, {
      'fids': String(mid),
      'tagids': tagIds.map((id: number) => String(id)).join(','),
    });
  }

  /** 举报用户（需登录；reason 1 违法违规 2 色情 3 垃圾广告 4 人身攻击 5 其他；响应按 status 判断）。 */
  static async reportMember(mid: number, reason: string): Promise<ActionResult> {
    if (mid <= 0) return new ActionResult(false, '用户信息无效');
    if (HttpClient.getCookie('SESSDATA').length === 0) {
      return new ActionResult(false, '登录状态已失效，请重新登录', -101);
    }
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return new ActionResult(false, '登录状态缺少 CSRF，请重新登录', -111);
    const params: Record<string, string> = {
      'mid': String(mid),
      'reason': reason,
      'reason_v2': '5',
      'csrf': csrf,
    };
    const resp: HttpResponse = await webPost(Api.reportMember, params, undefined, { 'Origin': 'https://space.bilibili.com' });
    if (!resp.ok) return new ActionResult(false, '网络请求失败 (' + String(resp.status) + ')', resp.status);
    const json: Record<string, Object> = resp.json();
    const ok: boolean = json['status'] === true || Number(json['status'] ?? 0) === 1;
    return new ActionResult(ok, ok ? '已提交举报，感谢反馈' : (String(json['data'] ?? '举报失败')), ok ? 0 : -1);
  }
  static async getSponsorSegments(bvid: string, cid: number): Promise<Array<SponsorSegment>> {
    if (bvid.length === 0) return [];
    const url: string = Api.sponsorSegments + '?' + HttpClient.buildQuery({ 'videoID': bvid, 'cid': String(cid) });
    const resp: HttpResponse = await HttpClient.get(url, {
      'Origin': 'harmony://com.piliplus.harmony',
      'x-ext-version': 'BiliHarmony/1.0',
      'Accept': 'application/json',
    });
    if (!resp.ok) return [];
    const raw: Array<Object> = resp.jsonArray();
    const result: Array<SponsorSegment> = [];
    for (let i: number = 0; i < raw.length; i++) {
      const item: Record<string, Object> = asObject(raw[i]);
      const category: string = str(item, 'category', '');
      if (category !== 'sponsor' && category !== 'selfpromo') continue;
      if (str(item, 'actionType', 'skip') !== 'skip') continue;
      const segment: Array<Object> = asArray(item['segment']);
      if (segment.length < 2) continue;
      const start: number = asNumber(segment[0], -1);
      const end: number = asNumber(segment[1], -1);
      if (start < 0 || end <= start) continue;
      const parsed: SponsorSegment = new SponsorSegment();
      parsed.start = start;
      parsed.end = end;
      parsed.category = category;
      parsed.uuid = str(item, 'UUID', '');
      result.push(parsed);
    }
    result.sort((a: SponsorSegment, b: SponsorSegment) => a.start - b.start);
    return result;
  }

  static async getVideoChapters(aid: number, bvid: string, cid: number): Promise<Array<VideoChapter>> {
    if (cid <= 0 || (aid <= 0 && bvid.length === 0)) return [];
    const params: Record<string, string> = { 'cid': String(cid) };
    if (bvid.length > 0) params['bvid'] = bvid;
    else params['aid'] = String(aid);
    await WbiSign.encWbi(params);
    const url: string = Api.playerInfo + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await webGet(url);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const points: Array<Object> = asArray(data['view_points']);
    const result: Array<VideoChapter> = [];
    for (let i: number = 0; i < points.length; i++) {
      const item: Record<string, Object> = asObject(points[i]);
      if (asNumber(item['type'], 0) !== 2) continue;
      const chapter: VideoChapter = new VideoChapter();
      chapter.from = asNumber(item['from'], 0);
      chapter.to = asNumber(item['to'], chapter.from);
      chapter.title = str(item, 'content', '章节 ' + String(i + 1));
      chapter.image = toHttps(str(item, 'imgUrl', str(item, 'img_url', '')));
      result.push(chapter);
    }
    return result;
  }

  // ===== 弹幕（xml 协议） =====
  static async getDanmaku(cid: number): Promise<Array<DanmakuItem>> {
    const url: string = Api.danmakuXml + cid + '.xml';
    const resp: HttpResponse = await HttpClient.get(url, {
      'User-Agent': Constants.browserUa,
    });
    if (!resp.ok) {
      return [];
    }
    return BiliApi.parseDanmakuXml(resp.body);
  }

  // ===== 弹幕（protobuf 分段协议：每 6 分钟一段，与网页端一致） =====
  /**
   * 拉取指定分段（1 基）。网络失败或数据无法解析返回 null（调用方回退 XML 或稍后重试）；
   * 空段（200 且无有效条目）返回空数组，视为加载成功。
   */
  static async getDanmakuSeg(cid: number, aid: number, segmentIndex: number): Promise<Array<DanmakuItem> | null> {
    if (cid <= 0 || segmentIndex <= 0) {
      return null;
    }
    const params: Record<string, string> = {
      'type': '1',
      'oid': String(cid),
      'segment_index': String(segmentIndex),
    };
    if (aid > 0) {
      params['pid'] = String(aid);
    }
    const url: string = Api.danmakuSeg + '?' + HttpClient.buildQuery(params);
    const buffer: ArrayBuffer | null = await HttpClient.getBinary(url, {
      'User-Agent': Constants.browserUa,
    });
    if (buffer === null) {
      return null;
    }
    try {
      const elems: Array<ProtoDanmaku> = parseDanmakuSegment(buffer);
      const result: Array<DanmakuItem> = [];
      for (let i: number = 0; i < elems.length; i++) {
        result.push(new DanmakuItem(elems[i].time, elems[i].mode, elems[i].color, elems[i].text,
          elems[i].id, elems[i].fontsize, elems[i].weight, elems[i].idStr));
      }
      return result;
    } catch (e) {
      return null;
    }
  }

  static parseDanmakuXml(xml: string): Array<DanmakuItem> {
    const result: Array<DanmakuItem> = [];
    const re: RegExp = /<d p="([^"]*)">([^<]*)<\/d>/g;
    let m: RegExpExecArray | null = re.exec(xml);
    while (m !== null) {
      const p: string = m[1];
      const text: string = BiliApi.decodeXmlEntities(m[2]);
      const parts: Array<string> = p.split(',');
      if (parts.length >= 4) {
        const time: number = Number(parts[0]);
        const mode: number = Number(parts[1]);
        const color: number = Number(parts[3]);
        if (!Number.isNaN(time)) {
          // mode/color 脏数据回退默认值，避免 NaN 进入渲染
          result.push(new DanmakuItem(time,
            Number.isNaN(mode) ? 1 : mode,
            Number.isNaN(color) ? 0xFFFFFF : color, text));
        }
      }
      m = re.exec(xml);
    }
    return result;
  }

  static decodeXmlEntities(s: string): string {
    let out: string = s;
    out = out.replace(/&amp;/g, '&');
    out = out.replace(/&lt;/g, '<');
    out = out.replace(/&gt;/g, '>');
    out = out.replace(/&quot;/g, '"');
    out = out.replace(/&#39;/g, "'");
    out = out.replace(/&apos;/g, "'");
    out = out.replace(/<[^>]*>/g, '');
    return out;
  }

  // ===== 登录：申请 TV 扫码 =====
  static async getTVCode(): Promise<TVCodeResult | null> {
    const params: Record<string, string> = {
      'local_id': '0',
      'platform': 'android',
      'mobi_app': 'android_hd',
    };
    await appSign(params);
    const body: string = HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.post(Api.getTVCode, body, HttpClient.merge(Constants.appHeaders, {}));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return null;
    }
    const result: TVCodeResult = new TVCodeResult();
    result.authCode = asString(data['auth_code'], '');
    result.url = asString(data['url'], '');
    return result;
  }

  // ===== 登录：轮询扫码结果 =====
  static async pollTVCode(authCode: string): Promise<TVPollResult> {
    const params: Record<string, string> = {
      'auth_code': authCode,
      'local_id': '0',
    };
    await appSign(params);
    const body: string = HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.post(Api.qrcodePoll, body, HttpClient.merge(Constants.appHeaders, {}));
    const json: Record<string, Object> = resp.json();
    const result: TVPollResult = new TVPollResult();
    result.code = asNumber(json['code'], -1);
    result.message = asString(json['message'], '');
    const data: Record<string, Object> = asObject(json['data']);
    result.mid = asNumber(data['mid'], 0);
    // TV 扫码返回的 access_token 直接位于 data；兼容也包装在 token_info 中的登录响应。
    result.accessToken = asString(data['access_token'],
      asString(asObject(data['token_info'])['access_token'], ''));
    const cookieInfo: Record<string, Object> = asObject(data['cookie_info']);
    const cookieArr: Array<Object> = asArray(cookieInfo['cookies']);
    for (let i: number = 0; i < cookieArr.length; i++) {
      const c: Record<string, Object> = asObject(cookieArr[i]);
      result.cookies.push(new CookiePair(asString(c['name'], ''), asString(c['value'], '')));
    }
    return result;
  }

  // ===== 登录：passport app 端请求头（buvid 参与风控识别） =====
  private static loginHeaders(): Record<string, string> {
    return HttpClient.merge(Constants.appHeaders, { 'buvid': HttpClient.buvid });
  }

  // ===== 登录：获取 RSA 公钥与 salt（hash + key） =====
  static async getLoginWebKey(): Promise<LoginWebKey | null> {
    const resp: HttpResponse = await HttpClient.get(Api.loginWebKey, BiliApi.loginHeaders());
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return null;
    }
    const result: LoginWebKey = new LoginWebKey();
    result.hash = asString(data['hash'], '');
    result.key = asString(data['key'], '');
    if (result.key.length === 0) {
      return null;
    }
    return result;
  }

  // ===== 登录：密码登录（移植自 PiliPlus LoginHttp.loginByPwd） =====
  static async loginByPassword(username: string, password: string): Promise<LoginResult> {
    const result: LoginResult = new LoginResult();
    // 1. 获取 RSA 公钥与 salt
    const webKey: LoginWebKey | null = await BiliApi.getLoginWebKey();
    if (webKey === null) {
      result.message = '获取登录密钥失败，请检查网络';
      return result;
    }
    // 2. RSA 加密：password = RSA(salt + 明文密码)；dt = RSA(16 位随机串)（设备令牌，与 PiliPlus 一致）
    let encPwd: string = '';
    let dt: string = '';
    try {
      encPwd = await RsaUtil.encryptWithPublicKey(webKey.key, webKey.hash + password);
      dt = await RsaUtil.encryptWithPublicKey(webKey.key, randomString(16));
    } catch (e) {
      result.message = '密码加密失败';
      return result;
    }
    const deviceId: string = await getLoginDeviceId();
    const buvid: string = HttpClient.buvid;
    const params: Record<string, string> = {
      'bili_local_id': deviceId,
      'build': '2001100',
      'buvid': buvid,
      'c_locale': 'zh_CN',
      'channel': 'master',
      'device': 'phone',
      'device_id': deviceId,
      'device_name': 'HarmonyOS',
      'device_platform': 'HarmonyOS',
      'disable_rcmd': '0',
      'dt': dt,
      'from_pv': 'main.homepage.avatar-nologin.all.click',
      'from_url': 'bilibili://pegasus/promo',
      'local_id': buvid,
      'mobi_app': 'android_hd',
      'password': encPwd,
      'permission': 'ALL',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'username': username,
    };
    await appSign(params);
    const body: string = HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.post(Api.loginByPassword, body, BiliApi.loginHeaders());
    return parseLoginResult(resp, result);
  }

  // ===== 登录：发送短信验证码（移植自 PiliPlus LoginHttp.sendSmsCode） =====
  static async sendSmsCode(tel: string): Promise<SmsSendResult> {
    const result: SmsSendResult = new SmsSendResult();
    const buvid: string = HttpClient.buvid;
    const tsMs: number = Date.now();
    const params: Record<string, string> = {
      'build': '2001100',
      'buvid': buvid,
      'c_locale': 'zh_CN',
      'channel': 'master',
      'cid': '86',
      'disable_rcmd': '0',
      'local_id': buvid,
      // login_session_id = md5(buvid + 毫秒时间戳)，见 PiliPlus 注释 https://chinggg.github.io/post/appre/
      'login_session_id': await md5Hex(buvid + String(tsMs)),
      'mobi_app': 'android_hd',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'tel': tel,
    };
    await appSign(params); // 会补上 appkey/ts/sign
    const body: string = HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.post(Api.smsSend, body, BiliApi.loginHeaders());
    const json: Record<string, Object> = resp.json();
    result.code = asNumber(json['code'], -1);
    result.message = asString(json['message'], '');
    const data: Record<string, Object> = asObject(json['data']);
    // 需要极验滑块时服务端返回非空 recaptcha_url（参考 PiliPlus 成功判定 code==0 && recaptcha_url==""）
    result.needCaptcha = asString(data['recaptcha_url'], '').length > 0;
    if (result.code === 0 && !result.needCaptcha) {
      result.captchaKey = asString(data['captcha_key'], '');
    }
    return result;
  }

  // ===== 登录：短信验证码登录（移植自 PiliPlus LoginHttp.loginBySms） =====
  static async loginBySms(tel: string, code: string, captchaKey: string): Promise<LoginResult> {
    const result: LoginResult = new LoginResult();
    // dt 设备令牌需要 RSA 公钥，获取失败则留空（非关键参数）
    let dt: string = '';
    const webKey: LoginWebKey | null = await BiliApi.getLoginWebKey();
    if (webKey !== null) {
      try {
        dt = await RsaUtil.encryptWithPublicKey(webKey.key, randomString(16));
      } catch (e) {
        // dt 加密失败不阻断登录
      }
    }
    const deviceId: string = await getLoginDeviceId();
    const buvid: string = HttpClient.buvid;
    const params: Record<string, string> = {
      'bili_local_id': deviceId,
      'build': '2001100',
      'buvid': buvid,
      'c_locale': 'zh_CN',
      'captcha_key': captchaKey,
      'channel': 'master',
      'cid': '86',
      'code': code,
      'device': 'phone',
      'device_id': deviceId,
      'device_name': 'HarmonyOS',
      'device_platform': 'HarmonyOS',
      'disable_rcmd': '0',
      'dt': dt,
      'from_pv': 'main.my-information.my-login.0.click',
      'from_url': 'bilibili://user_center/mine',
      'local_id': buvid,
      'mobi_app': 'android_hd',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statistics,
      'tel': tel,
    };
    await appSign(params);
    const body: string = HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.post(Api.loginBySms, body, BiliApi.loginHeaders());
    return parseLoginResult(resp, result);
  }
}

// ===== 登录结果类型 =====
export class CookiePair {
  name: string;
  value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

export class TVCodeResult {
  authCode: string = '';
  url: string = '';
}

export class TVPollResult {
  code: number = 0;
  message: string = '';
  cookies: Array<CookiePair> = [];
  mid: number = 0;
  accessToken: string = '';
}

// ===== 密码 / 短信登录结果类型 =====
export class LoginWebKey {
  hash: string = '';  // salt，拼在明文密码前再加密
  key: string = '';   // PEM 格式 RSA 公钥
}

export class LoginResult {
  code: number = -1;         // 接口 code，0 为成功
  message: string = '';
  dataStatus: number = 0;    // 密码登录 data.status，2 表示命中风控需手机二次验证
  cookies: Array<CookiePair> = [];
  accessToken: string = '';
}

export class SmsSendResult {
  code: number = -1;
  message: string = '';
  captchaKey: string = '';   // 发送成功后用于 login/sms 的 captcha_key
  needCaptcha: boolean = false;  // 需要先完成极验滑块（recaptcha_url 非空）
}

// 登录用设备指纹（随机生成后缓存，参考 PiliPlus genDeviceId 的随机方案）
let loginDeviceId: string = '';

async function getLoginDeviceId(): Promise<string> {
  if (loginDeviceId.length === 0) {
    loginDeviceId = await md5Hex(randomString(64));
  }
  return loginDeviceId;
}

// 解析密码/短信登录响应，提取 cookie_info.cookies
function parseLoginResult(resp: HttpResponse, result: LoginResult): LoginResult {
  const json: Record<string, Object> = resp.json();
  result.code = asNumber(json['code'], -1);
  result.message = asString(json['message'], '');
  const data: Record<string, Object> = asObject(json['data']);
  result.dataStatus = asNumber(data['status'], 0);
  result.accessToken = asString(asObject(data['token_info'])['access_token'], '');
  const cookieInfo: Record<string, Object> = asObject(data['cookie_info']);
  const cookieArr: Array<Object> = asArray(cookieInfo['cookies']);
  for (let i: number = 0; i < cookieArr.length; i++) {
    const c: Record<string, Object> = asObject(cookieArr[i]);
    result.cookies.push(new CookiePair(asString(c['name'], ''), asString(c['value'], '')));
  }
  return result;
}
