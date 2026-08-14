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
  PrivateMessageItem, PrivateMessagePageData, BiliEmotePackage } from '../model/Models';
import { LiveChatMessage, LiveDanmakuInfo, LiveDanmakuServer, LivePlayInfo, LiveQualityOption,
  LiveRoomInfo, LiveRoomItem } from '../model/LiveModels';

export class ActionResult {
  ok: boolean = false;
  message: string = '';

  constructor(ok: boolean, message: string) {
    this.ok = ok;
    this.message = message;
  }
}

// 弹幕数据
export class DanmakuItem {
  time: number = 0;    // 出现时间（秒）
  mode: number = 1;    // 1-3 滚动, 4 底部, 5 顶部
  color: number = 0xFFFFFF;
  text: string = '';

  constructor(time: number, mode: number, color: number, text: string) {
    this.time = time;
    this.mode = mode;
    this.color = color;
    this.text = text;
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

class SpaceDecorationInfo {
  light: string = '';
  dark: string = '';
  pendant: string = '';
}

// ===== 通用：解析 code/data =====
function getData(resp: HttpResponse): Record<string, Object> | null {
  if (!resp.ok) {
    return null;
  }
  const json: Record<string, Object> = resp.json();
  const code: number = asNumber(json['code'], -1);
  if (code !== 0) {
    return null;
  }
  return asObject(json['data']);
}

export class BiliApi {
  /** 登录用户优先请求 Web 个性化推荐；接口失败时再回退到 App 公共推荐流。 */
  static async getRecommend(idx: number): Promise<Array<VideoItem>> {
    const loggedIn: boolean = HttpClient.getCookie('SESSDATA').length > 0 &&
      HttpClient.getCookie('DedeUserID').length > 0;
    if (loggedIn) {
      const personalized: Array<VideoItem> = await BiliApi.getRecommendWeb(idx);
      if (personalized.length > 0) return personalized;
    }
    return BiliApi.getRecommendApp(idx);
  }

  private static async getRecommendWeb(idx: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = {
      'version': '1',
      'feed_version': 'V8',
      'homepage_ver': '1',
      'ps': '20',
      'fresh_idx': String(idx),
      'brush': String(idx),
      'fresh_type': '4',
    };
    await WbiSign.encWbi(params);
    const url: string = Api.recommendListWeb + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const source: Array<Object> = asArray(data['item']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < source.length; i++) {
      const raw: Record<string, Object> = asObject(source[i]);
      if (asString(raw['goto'], '') !== 'av' || Object.keys(asObject(raw['owner'])).length === 0) continue;
      const item: VideoItem = VideoItem.fromWebRecommendItem(source[i]);
      if (item.aid > 0 || item.bvid.length > 0) result.push(item);
    }
    return result;
  }

  // ===== 首页推荐（app 端） =====
  static async getRecommendApp(idx: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = RecommendParams.build(idx);
    const query: string = HttpClient.buildQuery(params);
    const url: string = Api.recommendListApp + '?' + query;
    const headers: Record<string, string> = HttpClient.merge(Constants.appHeaders, { 'buvid': HttpClient.buvid });
    const resp: HttpResponse = await HttpClient.get(url, headers);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const items: Array<Object> = asArray(data['items']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < items.length; i++) {
      const item: Record<string, Object> = asObject(items[i]);
      const cardGoto: string = asString(item['card_goto'], '');
      const canPlay: number = asNumber(item['can_play'], 0);
      const adInfo: Object | undefined = item['ad_info'];
      // 过滤广告卡片与不可播放卡片（与 PiliPlus 一致）
      if (cardGoto === 'ad_av' || cardGoto === 'ad_web_s' || canPlay !== 1 || adInfo !== undefined) {
        continue;
      }
      result.push(VideoItem.fromAppItem(items[i]));
    }
    return result;
  }

  // ===== 热门 =====
  static async getHot(pn: number, ps: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = { 'pn': String(pn), 'ps': String(ps) };
    const url: string = Api.hotList + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const list: Array<Object> = asArray(data['list']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < list.length; i++) {
      result.push(VideoItem.fromHotItem(list[i]));
    }
    return result;
  }

  // ===== 直播（只读观看） =====
  static async getLiveRooms(page: number, pageSize: number = 20): Promise<Array<LiveRoomItem>> {
    const params: Record<string, string> = {
      'platform': 'web', 'page': String(page), 'page_size': String(pageSize),
    };
    const resp: HttpResponse = await HttpClient.get(Api.liveRoomList + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const source: Array<Object> = asArray(data['recommend_room_list']);
    const result: Array<LiveRoomItem> = [];
    for (let i: number = 0; i < source.length; i++) {
      const raw: Record<string, Object> = asObject(source[i]);
      if (asNumber(raw['is_ad'], 0) === 1) continue;
      const item: LiveRoomItem = LiveRoomItem.from(source[i]);
      if (item.roomId > 0) result.push(item);
    }
    return result;
  }

  static async getLiveRoomInfo(roomId: number, uid: number = 0): Promise<LiveRoomInfo | null> {
    const roomResp: HttpResponse = await HttpClient.get(Api.liveRoomInfo + '?' +
      HttpClient.buildQuery({ 'room_id': String(roomId) }),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
    const roomData: Record<string, Object> | null = getData(roomResp);
    if (roomData === null) return null;
    const info: LiveRoomInfo = new LiveRoomInfo();
    info.roomId = asNumber(roomData['room_id'], roomId);
    info.uid = asNumber(roomData['uid'], uid);
    info.liveStatus = asNumber(roomData['live_status'], 0);
    info.title = str(roomData, 'title', '');
    info.cover = toHttps(str(roomData, 'keyframe', str(roomData, 'user_cover', '')));
    info.areaName = str(roomData, 'area_name', str(roomData, 'parent_area_name', ''));
    info.watched = asNumber(roomData['online'], 0) > 0 ? String(asNumber(roomData['online'], 0)) + '人气' : '';
    if (info.uid > 0) {
      const anchorResp: HttpResponse = await HttpClient.get(Api.liveAnchorInfo + '?' +
        HttpClient.buildQuery({ 'uid': String(info.uid) }),
        HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
      const anchorData: Record<string, Object> | null = getData(anchorResp);
      if (anchorData !== null) {
        const base: Record<string, Object> = asObject(anchorData['info']);
        info.uname = str(base, 'uname', '');
        info.face = toHttps(str(base, 'face', ''));
      }
    }
    return info;
  }

  /** 优先 HLS/fMP4 + AVC，随后回退 HLS/TS、FLV，避免 HEVC 兼容性和画面异常。 */
  static async getLivePlayInfo(roomId: number, qn: number = 10000): Promise<LivePlayInfo | null> {
    const params: Record<string, string> = {
      'room_id': String(roomId), 'protocol': '0,1', 'format': '0,1,2', 'codec': '0,1',
      'qn': String(qn), 'platform': 'web', 'ptype': '8', 'dolby': '5', 'panorama': '1',
    };
    const resp: HttpResponse = await HttpClient.get(Api.livePlayInfo + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return null;
    const info: LivePlayInfo = new LivePlayInfo();
    info.roomId = roomId;
    info.liveStatus = asNumber(data['live_status'], 0);
    const playurl: Record<string, Object> = asObject(asObject(data['playurl_info'])['playurl']);
    const descriptions: Array<Object> = asArray(playurl['g_qn_desc']);
    const labels: Map<number, string> = new Map<number, string>();
    for (let i: number = 0; i < descriptions.length; i++) {
      const d: Record<string, Object> = asObject(descriptions[i]);
      labels.set(asNumber(d['qn'], 0), str(d, 'desc', String(asNumber(d['qn'], 0))));
    }
    const streams: Array<Object> = asArray(playurl['stream']);
    let bestScore: number = -1;
    let selectedCodec: Record<string, Object> = {};
    const availableQn: Map<number, boolean> = new Map<number, boolean>();
    for (let i: number = 0; i < streams.length; i++) {
      const stream: Record<string, Object> = asObject(streams[i]);
      const protocol: string = str(stream, 'protocol_name', '');
      const formats: Array<Object> = asArray(stream['format']);
      for (let j: number = 0; j < formats.length; j++) {
        const format: Record<string, Object> = asObject(formats[j]);
        const formatName: string = str(format, 'format_name', '');
        const codecs: Array<Object> = asArray(format['codec']);
        for (let k: number = 0; k < codecs.length; k++) {
          const codec: Record<string, Object> = asObject(codecs[k]);
          if (str(codec, 'codec_name', '') !== 'avc') continue;
          const codecQn: Array<Object> = asArray(codec['accept_qn']);
          for (let q: number = 0; q < codecQn.length; q++) {
            const value: number = asNumber(codecQn[q], 0);
            if (value > 0) availableQn.set(value, true);
          }
          let score: number = 0;
          if (protocol === 'http_hls' && formatName === 'fmp4') score = 30;
          else if (protocol === 'http_hls' && formatName === 'ts') score = 20;
          else if (protocol === 'http_stream' && formatName === 'flv') score = 10;
          if (score > bestScore) {
            bestScore = score;
            selectedCodec = codec;
          }
        }
      }
    }
    if (bestScore < 0) return null;
    info.currentQn = asNumber(selectedCodec['current_qn'], qn);
    const qualityNumbers: Array<number> = Array.from(availableQn.keys());
    qualityNumbers.sort((a: number, b: number) => b - a);
    for (let i: number = 0; i < qualityNumbers.length; i++) {
      const optionQn: number = qualityNumbers[i];
      info.qualities.push(new LiveQualityOption(optionQn, labels.get(optionQn) ?? String(optionQn)));
    }
    if (info.qualities.length === 0 && info.currentQn > 0) {
      info.qualities.push(new LiveQualityOption(info.currentQn, labels.get(info.currentQn) ?? '当前画质'));
    }
    const baseUrl: string = str(selectedCodec, 'base_url', '');
    const urlInfo: Array<Object> = asArray(selectedCodec['url_info']);
    for (let i: number = 0; i < urlInfo.length; i++) {
      const part: Record<string, Object> = asObject(urlInfo[i]);
      const host: string = str(part, 'host', '');
      const extra: string = str(part, 'extra', '');
      if (host.length > 0 && baseUrl.length > 0) info.urls.push(toHttps(host + baseUrl + extra));
    }
    info.url = info.urls.length > 0 ? info.urls[0] : '';
    return info.url.length > 0 ? info : null;
  }

  static async getLiveDanmakuInfo(roomId: number): Promise<LiveDanmakuInfo | null> {
    // 当前接口已启用 WBI 风控；对齐 PiliPlus，必须携带 web_location 并签名。
    const params: Record<string, string> = { 'id': String(roomId), 'web_location': '444.8' };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await HttpClient.get(Api.liveDanmakuInfo + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return null;
    const info: LiveDanmakuInfo = new LiveDanmakuInfo();
    info.token = str(data, 'token', '');
    const hosts: Array<Object> = asArray(data['host_list']);
    for (let i: number = 0; i < hosts.length; i++) {
      const host: Record<string, Object> = asObject(hosts[i]);
      info.servers.push(new LiveDanmakuServer(str(host, 'host', ''), asNumber(host['wss_port'], 443)));
    }
    return info.token.length > 0 && info.servers.length > 0 ? info : null;
  }

  static async getLiveDanmakuHistory(roomId: number): Promise<Array<LiveChatMessage>> {
    const resp: HttpResponse = await HttpClient.get(Api.liveDanmakuHistory + '?' +
      HttpClient.buildQuery({ 'roomid': String(roomId) }),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const source: Array<Object> = asArray(data['room']);
    const result: Array<LiveChatMessage> = [];
    for (let i: number = 0; i < source.length; i++) {
      const raw: Record<string, Object> = asObject(source[i]);
      const msg: LiveChatMessage = new LiveChatMessage();
      msg.id = 'history_' + str(raw, 'id_str', String(i));
      msg.uname = str(raw, 'nickname', '');
      msg.text = str(raw, 'text', '');
      const user: Record<string, Object> = asObject(asObject(raw['user'])['base']);
      msg.face = toHttps(str(user, 'face', ''));
      msg.color = asNumber(asObject(asObject(raw['user'])['dm_config'])['color'], 0xFFFFFF);
      result.push(msg);
    }
    return result;
  }

  static async getLiveSuperChats(roomId: number): Promise<Array<LiveChatMessage>> {
    const resp: HttpResponse = await HttpClient.get(Api.liveSuperChat + '?' +
      HttpClient.buildQuery({ 'room_id': String(roomId) }),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const source: Array<Object> = asArray(data['list']);
    const result: Array<LiveChatMessage> = [];
    for (let i: number = 0; i < source.length; i++) result.push(LiveChatMessage.superChat(source[i]));
    return result;
  }

  // ===== 视频详情（aid 与 bvid 二选一） =====
  static async getVideoDetail(aid: number, bvid: string): Promise<VideoDetail | null> {
    const params: Record<string, string> = bvid.length > 0 ? { 'bvid': bvid } : { 'aid': String(aid) };
    const url: string = Api.videoIntro + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
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
      'fnval': '4048',
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

  // ===== 视频互动 =====
  static async getVideoRelation(aid: number, bvid: string): Promise<VideoRelationState | null> {
    const params: Record<string, string> = { 'aid': String(aid) };
    if (bvid.length > 0) params['bvid'] = bvid;
    const resp: HttpResponse = await HttpClient.get(Api.videoRelation + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    return data === null ? null : VideoRelationState.from(data);
  }

  /** 互动接口公共骨架：取 bili_jct 判空 → 发请求 → ok/code/message 统一转结果文案。 */
  private static async actionWithCsrf(csrfError: string, okMessage: string, failMessage: string,
    doRequest: (csrf: string) => Promise<HttpResponse>): Promise<ActionResult> {
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return new ActionResult(false, csrfError);
    const resp: HttpResponse = await doRequest(csrf);
    if (!resp.ok) return new ActionResult(false, '网络请求失败');
    const json: Record<string, Object> = resp.json();
    const ok: boolean = asNumber(json['code'], -1) === 0;
    return new ActionResult(ok, ok ? okMessage : str(json, 'message', failMessage));
  }

  private static async postVideoAction(url: string, params: Record<string, string>): Promise<ActionResult> {
    return BiliApi.actionWithCsrf('登录状态缺少 CSRF，请重新登录', '操作成功', '操作失败',
      (csrf: string): Promise<HttpResponse> => {
        params['csrf'] = csrf;
        return HttpClient.post(url, HttpClient.buildQuery(params), Constants.webHeaders);
      });
  }

  static async likeVideo(aid: number, bvid: string, like: boolean): Promise<ActionResult> {
    const params: Record<string, string> = {
      'aid': String(aid),
      'like': like ? '1' : '2',
    };
    if (bvid.length > 0) params['bvid'] = bvid;
    return BiliApi.postVideoAction(Api.likeVideo, params);
  }

  static async coinVideo(aid: number, bvid: string, multiply: number, selectLike: boolean): Promise<ActionResult> {
    const params: Record<string, string> = {
      'aid': String(aid),
      'multiply': String(multiply),
      'select_like': selectLike ? '1' : '0',
    };
    if (bvid.length > 0) params['bvid'] = bvid;
    return BiliApi.postVideoAction(Api.coinVideo, params);
  }

  static async reportShare(aid: number, bvid: string): Promise<ActionResult> {
    const params: Record<string, string> = { 'aid': String(aid) };
    if (bvid.length > 0) params['bvid'] = bvid;
    return BiliApi.postVideoAction(Api.shareVideo, params);
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
    return BiliApi.postVideoAction(Api.sendDanmaku, params);
  }

  // ===== 用户关系（与 PiliPlus 的 UserHttp.userRelation / VideoHttp.relationMod 对齐） =====
  static async getUserRelation(mid: number): Promise<number | null> {
    if (mid <= 0) return null;
    const url: string = Api.userRelation + '?' + HttpClient.buildQuery({ 'fid': String(mid) });
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    return data === null ? null : asNumber(data['attribute'], 0);
  }

  static async modifyUserRelation(mid: number, follow: boolean): Promise<ActionResult> {
    if (mid <= 0) return new ActionResult(false, 'UP 主信息无效');
    return BiliApi.postVideoAction(Api.modifyUserRelation, {
      'fid': String(mid),
      'act': follow ? '1' : '2',
      're_src': '11',
      'gaia_source': 'web_main',
    });
  }

  // ===== 相关视频（aid 与 bvid 二选一） =====
  static async getRelated(aid: number, bvid: string): Promise<Array<VideoItem>> {
    const params: Record<string, string> = bvid.length > 0 ? { 'bvid': bvid } : { 'aid': String(aid) };
    const url: string = Api.relatedList + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
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

  // ===== 评论（游客模式，WBI 签名 /wbi/main） =====
  static async getReplies(oid: number, type: number, cursor: string, mode: number = 3): Promise<ReplyData> {
    // 登录态用传统分页端点：它能稳定返回完整主评论总量；游客态继续使用 /main 的 next_offset。
    if (HttpClient.getCookie('SESSDATA').length > 0) {
      const pageNumber: number = Math.max(1, Number(cursor.length > 0 ? cursor : '1'));
      const legacyParams: Record<string, string> = {
        'oid': String(oid), 'type': String(type), 'pn': String(pageNumber), 'ps': '20',
        'sort': mode === 3 ? '1' : '0',
      };
      const legacyResp: HttpResponse = await HttpClient.get(Api.replyList + '?' + HttpClient.buildQuery(legacyParams),
        HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://www.bilibili.com/' }));
      const legacyData: Record<string, Object> | null = getData(legacyResp);
      if (legacyData !== null) return ReplyData.fromLegacy(legacyData, pageNumber);
    }
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'mode': String(mode),
      'pagination_str': JSON.stringify({ 'offset': cursor }),
    };
    // 对齐当前 PiliPlus：游客/通用评论流使用 /main 与 next_offset，不对该端点追加 WBI 参数。
    const url: string = Api.replyList + '/main?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url,
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://www.bilibili.com/' }));
    let data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      // 部分网络会对匿名 /main 返回 -352；回退到签名端点，避免评论区完全不可用。
      const fallback: Record<string, string> = {
        'oid': String(oid), 'type': String(type), 'mode': String(mode),
        'pagination_str': JSON.stringify({ 'offset': cursor }), 'web_location': '1315875',
      };
      await WbiSign.encWbi(fallback);
      const fallbackResp: HttpResponse = await HttpClient.get(Api.replyList + '/wbi/main?' + HttpClient.buildQuery(fallback),
        HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://www.bilibili.com/' }));
      data = getData(fallbackResp);
    }
    if (data === null) {
      return new ReplyData();
    }
    return ReplyData.from(data);
  }

  static async addReply(oid: number, type: number, message: string, root: number = 0, parent: number = 0): Promise<ActionResult> {
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'message': message,
      'plat': '1',
    };
    if (root > 0) params['root'] = String(root);
    if (parent > 0) params['parent'] = String(parent);
    return BiliApi.postVideoAction(Api.replyAdd, params);
  }

  // ===== 当前账号可用的 B 站表情包（评论/动态共用官方素材 URL） =====
  static async getUserEmotes(business: string = 'reply'): Promise<Array<BiliEmotePackage>> {
    const params: Record<string, string> = {
      'business': business,
      'web_location': '333.1245',
    };
    const resp: HttpResponse = await HttpClient.get(Api.userEmotes + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const packages: Array<Object> = asArray(data['packages']);
    const result: Array<BiliEmotePackage> = [];
    for (let i: number = 0; i < packages.length; i++) {
      const pkg: BiliEmotePackage = BiliEmotePackage.from(packages[i]);
      if (pkg.emotes.length > 0) result.push(pkg);
    }
    return result;
  }

  // ===== 单条评论的完整回复列表 =====
  static async getReplyReplies(oid: number, type: number, root: number, page: number): Promise<ReplyPageData> {
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'root': String(root),
      'pn': String(page),
      'ps': '20',
    };
    const url: string = Api.replyReplyList + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    return data === null ? new ReplyPageData() : ReplyPageData.from(data);
  }

  // ===== 观看历史 =====
  static async getHistory(max: number = 0, viewAt: number = 0): Promise<HistoryPageData> {
    const params: Record<string, string> = {
      'type': 'archive', 'ps': '20', 'max': String(max), 'view_at': String(viewAt),
    };
    const resp: HttpResponse = await HttpClient.get(Api.historyList + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: HistoryPageData = new HistoryPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.items.push(HistoryVideoItem.from(list[i]));
    if (result.items.length > 0) {
      const last: HistoryVideoItem = result.items[result.items.length - 1];
      result.max = last.video.aid;
      result.viewAt = last.viewAt;
    }
    result.hasMore = list.length >= 20;
    return result;
  }

  // ===== 收藏夹 =====
  static async getFavoriteFolders(mid: number, page: number): Promise<FavoriteFolderPageData> {
    const params: Record<string, string> = {
      'up_mid': String(mid), 'pn': String(page), 'ps': '20',
    };
    const resp: HttpResponse = await HttpClient.get(Api.favoriteFolders + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteFolderPageData = new FavoriteFolderPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.folders.push(FavoriteFolderItem.from(list[i]));
    result.hasMore = asBool(data['has_more'], list.length >= 20);
    return result;
  }

  /** 当前视频可用的自建收藏夹，同时返回每个收藏夹是否已包含该视频。 */
  static async getFavoriteFoldersForVideo(aid: number): Promise<Array<FavoriteFolderItem>> {
    const params: Record<string, string> = { 'rid': String(aid), 'type': '2' };
    const resp: HttpResponse = await HttpClient.get(Api.favoriteFoldersForVideo + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: Array<FavoriteFolderItem> = [];
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.push(FavoriteFolderItem.from(list[i]));
    return result;
  }

  static async modifyVideoFavorite(aid: number, addIds: Array<number>, deleteIds: Array<number>): Promise<ActionResult> {
    const params: Record<string, string> = {
      'rid': String(aid),
      'type': '2',
      'add_media_ids': addIds.map((id: number) => String(id)).join(','),
      'del_media_ids': deleteIds.map((id: number) => String(id)).join(','),
    };
    return BiliApi.postVideoAction(Api.favoriteResourceDeal, params);
  }

  static async getFavoriteVideos(mediaId: number, page: number): Promise<FavoriteVideoPageData> {
    const params: Record<string, string> = {
      'media_id': String(mediaId), 'pn': String(page), 'ps': '20', 'keyword': '',
      'order': 'mtime', 'type': '0', 'tid': '0', 'platform': 'web',
    };
    const resp: HttpResponse = await HttpClient.get(Api.favoriteResources + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteVideoPageData = new FavoriteVideoPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['medias']);
    for (let i: number = 0; i < list.length; i++) {
      const j: Record<string, Object> = asObject(list[i]);
      const upper: Record<string, Object> = asObject(j['upper']);
      const cnt: Record<string, Object> = asObject(j['cnt_info']);
      const video: VideoItem = new VideoItem();
      video.aid = asNumber(j['id'], 0);
      video.bvid = str(j, 'bvid', str(j, 'bv_id', ''));
      video.title = str(j, 'title', '');
      video.cover = toHttps(str(j, 'cover', ''));
      video.duration = asNumber(j['duration'], 0);
      video.upName = str(upper, 'name', '');
      video.upMid = asNumber(upper['mid'], 0);
      video.play = asNumber(cnt['play'], 0);
      video.danmaku = asNumber(cnt['danmaku'], 0);
      result.videos.push(video);
    }
    result.hasMore = asBool(data['has_more'], list.length >= 20);
    return result;
  }

  // ===== 订阅收藏集：官方“我的订阅”与合集详情 =====
  static async getCollectedFolders(mid: number, page: number): Promise<FavoriteFolderPageData> {
    const params: Record<string, string> = {
      'up_mid': String(mid), 'pn': String(page), 'ps': '20', 'platform': 'web',
    };
    const resp: HttpResponse = await HttpClient.get(Api.collectedFolders + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteFolderPageData = new FavoriteFolderPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.folders.push(FavoriteFolderItem.from(list[i]));
    result.hasMore = asBool(data['has_more'], list.length >= 20);
    return result;
  }

  static async getCollectionVideos(seasonId: number, page: number): Promise<FavoriteVideoPageData> {
    const params: Record<string, string> = {
      'season_id': String(seasonId), 'pn': String(page), 'ps': '20',
    };
    const resp: HttpResponse = await HttpClient.get(Api.collectionResources + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    const result: FavoriteVideoPageData = new FavoriteVideoPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['medias']);
    for (let i: number = 0; i < list.length; i++) {
      const j: Record<string, Object> = asObject(list[i]);
      const cnt: Record<string, Object> = asObject(j['cnt_info']);
      const video: VideoItem = new VideoItem();
      video.aid = asNumber(j['id'], 0);
      video.bvid = str(j, 'bvid', '');
      video.title = str(j, 'title', '');
      video.cover = toHttps(str(j, 'cover', ''));
      video.duration = asNumber(j['duration'], 0);
      video.pubdate = asNumber(j['pubtime'], 0);
      video.play = asNumber(cnt['play'], 0);
      video.danmaku = asNumber(cnt['danmaku'], 0);
      result.videos.push(video);
    }
    const info: Record<string, Object> = asObject(data['info']);
    const total: number = asNumber(info['media_count'], result.videos.length);
    result.hasMore = page * 20 < total;
    return result;
  }

  // ===== 私信 =====
  static async getMessageSessions(beginTs: number = 0): Promise<MessageSessionPageData> {
    const params: Record<string, string> = {
      'session_type': '4', 'group_fold': '0', 'unfollow_fold': '0', 'sort_rule': '2',
      'size': '30', 'build': '0', 'mobi_app': 'web',
    };
    if (beginTs > 0) params['begin_ts'] = String(beginTs);
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await HttpClient.get(Api.sessionList + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    const data: Record<string, Object> | null = getData(resp);
    const result: MessageSessionPageData = new MessageSessionPageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['session_list']);
    const accountIds: Array<string> = [];
    for (let i: number = 0; i < list.length; i++) {
      const session: MessageSessionItem = MessageSessionItem.from(list[i]);
      result.sessions.push(session);
      if (session.name.length === 0 && session.talkerId > 0) accountIds.push(String(session.talkerId));
    }
    if (accountIds.length > 0) await BiliApi.fillSessionAccounts(result.sessions, accountIds);
    result.hasMore = asNumber(data['has_more'], 0) === 1 || asBool(data['has_more']);
    return result;
  }

  private static async fillSessionAccounts(sessions: Array<MessageSessionItem>, ids: Array<string>): Promise<void> {
    const params: Record<string, string> = { 'uids': ids.join(','), 'build': '0', 'mobi_app': 'web' };
    const resp: HttpResponse = await HttpClient.get(Api.sessionAccountList + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    if (!resp.ok) return;
    const json: Record<string, Object> = resp.json();
    if (asNumber(json['code'], -1) !== 0) return;
    const raw: Object | undefined = json['data'];
    const cards: Array<Object> = Array.isArray(raw) ? asArray(raw) : asArray(asObject(raw)['cards']);
    for (let i: number = 0; i < cards.length; i++) {
      const card: Record<string, Object> = asObject(cards[i]);
      const mid: number = asNumber(card['mid'], asNumber(card['uid'], 0));
      for (let j: number = 0; j < sessions.length; j++) {
        if (sessions[j].talkerId === mid) {
          sessions[j].name = str(card, 'name', str(card, 'uname', '用户' + String(mid)));
          sessions[j].avatar = toHttps(str(card, 'face', str(card, 'pic', '')));
        }
      }
    }
  }

  static async getPrivateMessages(talkerId: number, beginSeqno: number = 0): Promise<PrivateMessagePageData> {
    const params: Record<string, string> = {
      'talker_id': String(talkerId), 'session_type': '1', 'size': '30', 'sender_device_id': '1',
      'build': '0', 'mobi_app': 'web', 'web_location': '333.1296',
    };
    if (beginSeqno > 0) params['begin_seqno'] = String(beginSeqno);
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await HttpClient.get(Api.sessionMessages + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
    const data: Record<string, Object> | null = getData(resp);
    const result: PrivateMessagePageData = new PrivateMessagePageData();
    if (data === null) return result;
    const list: Array<Object> = asArray(data['messages']);
    for (let i: number = 0; i < list.length; i++) result.messages.push(PrivateMessageItem.from(list[i]));
    result.messages.sort((a: PrivateMessageItem, b: PrivateMessageItem) => a.seqno - b.seqno);
    if (result.messages.length > 0) result.minSeqno = result.messages[0].seqno;
    result.hasMore = asNumber(data['has_more'], 0) === 1 || list.length >= 30;
    return result;
  }

  /** 将指定会话确认到最后一条已展示消息，对齐 PiliPlus 的 update_ack 行为。 */
  static async markPrivateMessagesRead(talkerId: number, ackSeqno: number): Promise<ActionResult> {
    if (talkerId <= 0 || ackSeqno <= 0) return new ActionResult(false, '无可确认的私信');
    return BiliApi.actionWithCsrf('登录状态缺少 CSRF', '已读', '标记已读失败',
      async (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'talker_id': String(talkerId), 'session_type': '1', 'ack_seqno': String(ackSeqno),
          'build': '0', 'mobi_app': 'web', 'csrf_token': csrf, 'csrf': csrf,
        };
        await WbiSign.encWbi(params);
        return HttpClient.get(Api.ackSessionMessage + '?' + HttpClient.buildQuery(params),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }

  static async sendPrivateMessage(senderId: number, receiverId: number, content: string): Promise<ActionResult> {
    const devId: string = randomString(8) + '-' + randomString(4) + '-4' + randomString(3) + '-a' + randomString(3) + '-' + randomString(12);
    return BiliApi.actionWithCsrf('登录状态缺少 CSRF，请重新登录', '发送成功', '发送失败',
      async (csrf: string): Promise<HttpResponse> => {
        const query: Record<string, string> = {
          'w_sender_uid': String(senderId), 'w_receiver_id': String(receiverId), 'w_dev_id': devId,
        };
        await WbiSign.encWbi(query);
        const body: Record<string, string> = {
          'msg[sender_uid]': String(senderId), 'msg[receiver_id]': String(receiverId), 'msg[receiver_type]': '1',
          'msg[msg_type]': '1', 'msg[msg_status]': '0', 'msg[dev_id]': devId,
          'msg[timestamp]': String(Math.floor(Date.now() / 1000)), 'msg[new_face_version]': '1',
          'msg[content]': JSON.stringify({ 'content': content }), 'csrf_token': csrf, 'csrf': csrf,
          'build': '0', 'mobi_app': 'web',
        };
        return HttpClient.post(Api.sendMessage + '?' + HttpClient.buildQuery(query),
          HttpClient.buildQuery(body), HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://message.bilibili.com/' }));
      });
  }

  // ===== 热搜 =====
  static async getHotSearch(): Promise<Array<HotSearchItem>> {
    const resp: HttpResponse = await HttpClient.get(Api.hotSearchList, Constants.webHeaders);
    if (!resp.ok) {
      return [];
    }
    const json: Record<string, Object> = resp.json();
    const list: Array<Object> = asArray(json['list']);
    const result: Array<HotSearchItem> = [];
    for (let i: number = 0; i < list.length; i++) {
      result.push(HotSearchItem.from(list[i]));
    }
    return result;
  }

  // ===== 搜索（综合，取视频结果） =====
  static async search(keyword: string, page: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = {
      'keyword': keyword,
      'page': String(page),
    };
    await WbiSign.encWbi(params);
    const url: string = Api.searchAll + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const results: Array<Object> = asArray(data['result']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < results.length; i++) {
      const r: Record<string, Object> = asObject(results[i]);
      const rtype: string = asString(r['result_type'], '');
      if (rtype !== 'video') {
        continue;
      }
      const vids: Array<Object> = asArray(r['data']);
      for (let j: number = 0; j < vids.length; j++) {
        result.push(VideoItem.fromSearchItem(vids[j]));
      }
    }
    return result;
  }

  // ===== 分类搜索（search/type，WBI 签名；extra 为类型专属筛选参数，参与签名） =====
  static async searchByType(keyword: string, searchType: string, page: number, order: string = '',
    extra?: Record<string, string>): Promise<Record<string, Object> | null> {
    const params: Record<string, string> = {
      'keyword': keyword,
      'search_type': searchType,
      'page': String(page),
    };
    if (order.length > 0) {
      params['order'] = order;
    }
    if (extra !== undefined) {
      const keys: Array<string> = Object.keys(extra);
      for (let i: number = 0; i < keys.length; i++) {
        params[keys[i]] = extra[keys[i]];
      }
    }
    await WbiSign.encWbi(params);
    const url: string = Api.searchByType + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    return getData(resp);
  }

  // ===== 视频搜索（order 排序 + 时长/发布时间/分区筛选） =====
  static async searchVideosByType(keyword: string, page: number, order: string, duration: number,
    pubtimeBegin: number, tids: number): Promise<VideoSearchResult> {
    const extra: Record<string, string> = {};
    if (duration > 0) {
      extra['duration'] = String(duration);
    }
    if (pubtimeBegin > 0) {
      extra['pubtime_begin_s'] = String(pubtimeBegin);
      extra['pubtime_end_s'] = String(Math.floor(Date.now() / 1000));
    }
    if (tids > 0) {
      extra['tids'] = String(tids);
    }
    const result: VideoSearchResult = new VideoSearchResult();
    const data: Record<string, Object> | null = await BiliApi.searchByType(keyword, SearchTypes.video, page, order, extra);
    if (data === null) {
      return result;
    }
    result.numResults = asNumber(data['numResults'], 0);
    const list: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < list.length; i++) {
      result.videos.push(VideoItem.fromSearchItem(list[i]));
    }
    return result;
  }

  // ===== 用户搜索（order: ''/fans/level，v1 固定降序 order_sort=0） =====
  static async searchUsers(keyword: string, page: number, order: string): Promise<UserSearchResult> {
    const extra: Record<string, string> = {};
    if (order.length > 0) {
      extra['order_sort'] = '0';
    }
    const result: UserSearchResult = new UserSearchResult();
    const data: Record<string, Object> | null = await BiliApi.searchByType(keyword, SearchTypes.biliUser, page, order, extra);
    if (data === null) {
      return result;
    }
    result.numResults = asNumber(data['numResults'], 0);
    const list: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < list.length; i++) {
      result.users.push(UserSearchItem.from(list[i]));
    }
    return result;
  }

  // ===== 搜索建议 =====
  static async searchSuggest(term: string): Promise<Array<string>> {
    const params: Record<string, string> = { 'term': term, 'main_ver': 'v1' };
    const url: string = Api.searchSuggest + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    if (!resp.ok) {
      return [];
    }
    const json: Record<string, Object> = resp.json();
    const resultObj: Record<string, Object> = asObject(json['result']);
    const tag: Array<Object> = asArray(resultObj['tag']);
    const out: Array<string> = [];
    for (let i: number = 0; i < tag.length; i++) {
      const t: Record<string, Object> = asObject(tag[i]);
      const v: string = asString(t['value'], '');
      if (v.length > 0) {
        out.push(v);
      }
    }
    return out;
  }

  // ===== 当前登录用户（nav） =====
  static async getNav(): Promise<UserInfo> {
    const resp: HttpResponse = await HttpClient.get(Api.userInfo, Constants.webHeaders);
    if (!resp.ok) {
      return new UserInfo();
    }
    return UserInfo.fromNav(resp.json());
  }

  // ===== 用户统计 =====
  static async getUserStat(mid: number): Promise<UserStat> {
    const url: string = Api.userStat + '?' + HttpClient.buildQuery({ 'vmid': String(mid) });
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    if (!resp.ok) {
      return new UserStat();
    }
    return UserStat.from(resp.json());
  }

  // ===== 用户空间：用户信息（WBI 签名） =====
  static async getUserSpaceInfo(mid: number): Promise<UserSpaceInfo | null> {
    const decorationPromise: Promise<SpaceDecorationInfo> = BiliApi.getUserSpaceDecoration(mid);
    const params: Record<string, string> = { 'mid': String(mid) };
    await WbiSign.encWbi(params);
    const url: string = Api.memberInfo + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return null;
    }
    const result: UserSpaceInfo = UserSpaceInfo.from(data);
    const decoration: SpaceDecorationInfo = await decorationPromise;
    if (decoration.light.length > 0) result.topPhoto = decoration.light;
    result.topPhotoDark = decoration.dark;
    if (result.pendant.length === 0 && decoration.pendant.length > 0) result.pendant = decoration.pendant;
    return result;
  }

  /** App 空间接口才会返回当前生效的日/夜间空间装扮，Web top_photo 仅作回退。 */
  private static async getUserSpaceDecoration(mid: number): Promise<SpaceDecorationInfo> {
    const result: SpaceDecorationInfo = new SpaceDecorationInfo();
    const params: Record<string, string> = {
      'build': '8430300',
      'version': '8.43.0',
      'c_locale': 'zh_CN',
      'channel': 'master',
      'mobi_app': 'android',
      'platform': 'android',
      's_locale': 'zh_CN',
      'statistics': Constants.statisticsApp,
      'vmid': String(mid),
    };
    await appSign(params);
    const url: string = Api.memberSpaceApp + '?' + HttpClient.buildQuery(params);
    const headers: Record<string, string> = HttpClient.merge(Constants.appHeaders, {
      'User-Agent': Constants.userAgentApp,
      'app-key': 'android64',
    });
    const resp: HttpResponse = await HttpClient.get(url, headers);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return result;
    const images: Record<string, Object> = asObject(data['images']);
    result.light = toHttps(str(images, 'imgUrl', str(images, 'img_url', '')));
    result.dark = toHttps(str(images, 'night_imgurl', ''));
    const collection: Record<string, Object> = asObject(images['collection_top_simple']);
    const top: Record<string, Object> = asObject(collection['top']);
    const imgUrls: Array<Object> = asArray(top['img_urls']);
    if (imgUrls.length > 0) {
      const first: Record<string, Object> = asObject(imgUrls[0]);
      const collectionImage: string = toHttps(str(first, 'img_url', str(first, 'url', asString(imgUrls[0], ''))));
      if (collectionImage.length > 0) result.light = collectionImage;
    }
    const card: Record<string, Object> = asObject(data['card']);
    const pendant: Record<string, Object> = asObject(card['pendant']);
    result.pendant = toHttps(str(pendant, 'image_enhance', str(pendant, 'image', '')));
    return result;
  }

  /** 只自动跳过赞助和无偿推广；片头/片尾/高能点保留给用户正常观看。 */
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
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
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

  // ===== 用户空间：投稿列表（WBI 签名，order: pubdate 最新 / click 最多播放 / stow 最多收藏） =====
  static async getUserSpaceArcs(mid: number, pn: number, order: string): Promise<SpaceArcData> {
    const params: Record<string, string> = {
      'mid': String(mid),
      'pn': String(pn),
      'ps': '30',
      'order': order,
    };
    await WbiSign.encWbi(params);
    const url: string = Api.memberArcSearch + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const result: SpaceArcData = new SpaceArcData();
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return result;
    }
    const page: Record<string, Object> = asObject(data['page']);
    result.total = asNumber(page['count'], 0);
    const list: Record<string, Object> = asObject(data['list']);
    const vlist: Array<Object> = asArray(list['vlist']);
    for (let i: number = 0; i < vlist.length; i++) {
      result.videos.push(VideoItem.fromSpaceItem(vlist[i]));
    }
    return result;
  }

  // ===== 动态 feed（关注动态，未登录为空） =====
  static async getDynamicFeed(offset: string): Promise<DynamicPageData> {
    const params: Record<string, string> = {
      'timezone_offset': '-480',
      // all 才会同时返回关注用户发布的视频、图文、专栏等动态。
      'type': 'all',
      'page': '1',
      'features': Constants.dynFeatures,
      'offset': offset,
    };
    const url: string = Api.followDynamic + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    return BiliApi.parseDynamicPage(resp);
  }

  // ===== 用户空间动态（公开数据，WBI 签名） =====
  static async getUserDynamicFeed(mid: number, offset: string): Promise<DynamicPageData> {
    const params: Record<string, string> = {
      'offset': offset,
      'host_mid': String(mid),
      'timezone_offset': '-480',
      'features': Constants.dynFeatures,
      'platform': 'web',
      'web_location': '333.1387',
      'dm_img_list': '[]',
      'dm_img_str': randomString(32),
      'dm_cover_img_str': randomString(64),
      'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
      'x-bili-device-req-json': '{"platform":"web","device":"pc","spmid":"333.1387"}',
    };
    await WbiSign.encWbi(params);
    const url: string = Api.memberDynamic + '?' + HttpClient.buildQuery(params);
    const headers: Record<string, string> = HttpClient.merge(Constants.webHeaders, {
      'Origin': 'https://space.bilibili.com',
      'Referer': 'https://space.bilibili.com/' + String(mid) + '/dynamic',
    });
    const resp: HttpResponse = await HttpClient.get(url, headers);
    return BiliApi.parseDynamicPage(resp);
  }

  private static parseDynamicPage(resp: HttpResponse): DynamicPageData {
    const data: Record<string, Object> | null = getData(resp);
    const result: DynamicPageData = new DynamicPageData();
    if (data === null) {
      return result;
    }
    const items: Array<Object> = asArray(data['items']);
    for (let i: number = 0; i < items.length; i++) {
      result.items.push(DynamicItem.from(items[i]));
    }
    result.offset = str(data, 'offset', '');
    result.hasMore = asBool(data['has_more'], result.offset.length > 0 && items.length > 0);
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
  const cookieInfo: Record<string, Object> = asObject(data['cookie_info']);
  const cookieArr: Array<Object> = asArray(cookieInfo['cookies']);
  for (let i: number = 0; i < cookieArr.length; i++) {
    const c: Record<string, Object> = asObject(cookieArr[i]);
    result.cookies.push(new CookiePair(asString(c['name'], ''), asString(c['value'], '')));
  }
  return result;
}
