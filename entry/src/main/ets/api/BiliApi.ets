/**
 * 视频播放域 API：详情、播放地址、互动、弹幕、章节与预览图。
 * 移植自 PiliPlus lib/http/*.dart
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { appSign } from '../common/AppSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asString, asNumber, str, toHttps } from '../common/Utils';
import { PlayUrlInfo, SubtitleCue, SubtitleTrack, VideoDetail, VideoItem,
  VideoRelationState } from '../model/Models';
import { parseDanmakuSegment, ProtoDanmaku } from '../common/DanmakuProto';
import { ActionResult, actionWithCsrf, getData, postVideoAction, webGet, webPost } from './internal/ApiCommon';

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

/** 视频拖动预览：每张 image 是 xLen * yLen 的雪碧图，index 为每格对应的秒数。 */
export class VideoShotData {
  images: Array<string> = [];
  index: Array<number> = [];
  xLen: number = 10;
  yLen: number = 10;
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

  static async getVideoShots(aid: number, bvid: string, cid: number): Promise<VideoShotData | null> {
    if (cid <= 0 || (aid <= 0 && bvid.length === 0)) return null;
    const params: Record<string, string> = { 'cid': String(cid), 'index': '1' };
    if (aid > 0) params['aid'] = String(aid);
    if (bvid.length > 0) params['bvid'] = bvid;
    const resp: HttpResponse = await webGet(Api.videoShot, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return null;
    const rawImages: Array<Object> = asArray(data['image']);
    const rawIndex: Array<Object> = asArray(data['index']);
    if (rawImages.length === 0 || rawIndex.length === 0) return null;
    const result: VideoShotData = new VideoShotData();
    result.xLen = Math.max(1, Math.floor(asNumber(data['img_x_len'], 10)));
    result.yLen = Math.max(1, Math.floor(asNumber(data['img_y_len'], 10)));
    for (let i: number = 0; i < rawImages.length; i++) {
      const url: string = toHttps(asString(rawImages[i], ''));
      if (url.length > 0) result.images.push(url);
    }
    for (let i: number = 0; i < rawIndex.length; i++) {
      result.index.push(Math.max(0, asNumber(rawIndex[i], 0)));
    }
    return result.images.length > 0 && result.index.length > 0 ? result : null;
  }

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
      // 必须纯 DASH（4048）：带 durl 位（4049）时服务端只回 mp4 协议并整体隐藏 DASH，
      // accept_quality/support_formats 只剩 ≤720P，清晰度菜单里的 1080P/1080P60/4K 会消失。
      // MP4 单流改在拿到 DASH 结果后按画质二次请求补换（见本方法尾部）。
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
    const info: PlayUrlInfo = PlayUrlInfo.fromPlayUrl(data, qn);
    // ≤1080P 补发 MP4 单流请求（fnval=1）换用单轨地址：单 AVPlayer 内部音画同步、
    // seek 只需单文件 Range 请求。菜单/字幕/续播位仍取自上面的 DASH 响应（其画质列表是全量的）；
    // 高画质（>80，仅 DASH 提供）不换，保持双轨。
    if (info.isDash && info.quality <= 80 && info.url.length > 0) {
      const mp4Params: Record<string, string> = {
        'cid': String(cid),
        'qn': String(info.quality),
        'fnval': '1',
        'fnver': '0',
        'https_url_req': '1',
      };
      if (bvid.length > 0) {
        mp4Params['bvid'] = bvid;
      } else {
        mp4Params['avid'] = String(aid);
      }
      try {
        const mp4Resp: HttpResponse = await HttpClient.get(Api.ugcUrl + '?' + HttpClient.buildQuery(mp4Params), headers);
        const mp4Data: Record<string, Object> | null = getData(mp4Resp);
        if (mp4Data !== null) {
          const mp4: PlayUrlInfo = PlayUrlInfo.fromPlayUrl(mp4Data, info.quality);
          if (mp4.url.length > 0) {
            info.isDash = false;
            info.format = mp4.format;
            info.urls = mp4.urls;
            info.url = mp4.url;
            info.audioUrl = '';
            info.audioUrls = [];
          }
        }
      } catch (e) {
        // MP4 换源失败保持 DASH 双轨播放，不影响可用。
      }
    }
    return info;
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

}
