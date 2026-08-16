/**
 * 直播域 API：推荐直播间 / 房间信息 / 播放地址 / 弹幕连接与历史 / 表情 / 发送弹幕 / 醒目留言。
 * 移植自 PiliPlus lib/http/live*.dart
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asNumber, str, toHttps } from '../common/Utils';
import { LiveChatMessage, LiveDanmakuInfo, LiveDanmakuServer, LiveEmoteItem, LiveEmotePackage, LivePlayInfo,
  LiveQualityOption, LiveRoomInfo, LiveRoomItem, LiveStatusItem, LiveZone } from '../model/LiveModels';
import { ActionResult, actionWithCsrf, getData } from './internal/ApiCommon';

export class LiveApi {
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

  // ===== 直播分区（一级分区列表 + 区内直播间，需登录过风控） =====
  static async getLiveZones(): Promise<Array<LiveZone>> {
    const resp: HttpResponse = await HttpClient.get(Api.liveZoneList,
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' }));
    const result: Array<LiveZone> = [];
    const json: Record<string, Object> = resp.json();
    const list: Array<Object> = asArray(json['data']);
    for (let i: number = 0; i < list.length; i++) {
      const item: Record<string, Object> = asObject(list[i]);
      const zone: LiveZone = new LiveZone();
      zone.id = asNumber(item['id'], 0);
      zone.name = str(item, 'name', '');
      if (zone.id > 0 && zone.name.length > 0) result.push(zone);
    }
    return result;
  }

  static async getLiveZoneRooms(zoneId: number, page: number, pageSize: number = 20): Promise<Array<LiveRoomItem>> {
    if (zoneId <= 0) return [];
    const params: Record<string, string> = {
      'parent_area_id': String(zoneId), 'area_id': '0',
      'sort_type': 'online', 'page': String(page), 'page_size': String(pageSize),
    };
    const resp: HttpResponse = await HttpClient.get(Api.liveZoneRooms + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    // room/v3/Area/getRoomList 直接返回 data.list 数组。
    const list: Array<Object> = asArray(data['list']);
    const result: Array<LiveRoomItem> = [];
    for (let i: number = 0; i < list.length; i++) {
      const raw: Record<string, Object> = asObject(list[i]);
      const item: LiveRoomItem = LiveRoomItem.from(raw);
      if (item.roomId > 0) result.push(item);
    }
    return result;
  }

  /** 批量查询一批 UP 的开播状态（room/v1/Room/get_status_info_by_uids：入参 uids[]，返回以 uid 为键的映射）。 */
  static async getLiveStatusByUids(uids: Array<number>): Promise<Array<LiveStatusItem>> {
    const result: Array<LiveStatusItem> = [];
    if (uids.length === 0) return result;
    const params: Record<string, string> = {};
    for (let i: number = 0; i < uids.length; i++) {
      params['uids[' + String(i) + ']'] = String(uids[i]);
    }
    const resp: HttpResponse = await HttpClient.get(Api.liveStatusByUids + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const json: Record<string, Object> = resp.json();
    const data: Record<string, Object> = asObject(json['data']);
    const keys: Array<string> = Object.keys(data);
    for (let i: number = 0; i < keys.length; i++) {
      const raw: Record<string, Object> = asObject(data[keys[i]]);
      const item: LiveStatusItem = new LiveStatusItem();
      item.uid = asNumber(raw['uid'], Number(keys[i]));
      item.liveStatus = asNumber(raw['live_status'], 0);
      item.roomId = asNumber(raw['room_id'], 0);
      item.title = str(raw, 'title', '');
      item.uname = str(raw, 'uname', '');
      result.push(item);
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
      result.push(LiveChatMessage.history(source[i], i));
    }
    return result;
  }

  static async getLiveEmoticons(roomId: number): Promise<Array<LiveEmotePackage>> {
    const params: Record<string, string> = { 'platform': 'pc', 'room_id': String(roomId) };
    const resp: HttpResponse = await HttpClient.get(Api.liveEmoticons + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const packages: Array<Object> = asArray(data['data']);
    const result: Array<LiveEmotePackage> = [];
    for (let i: number = 0; i < packages.length; i++) {
      const raw: Record<string, Object> = asObject(packages[i]);
      const pkg: LiveEmotePackage = new LiveEmotePackage();
      pkg.icon = toHttps(str(raw, 'current_cover', ''));
      pkg.packageType = asNumber(raw['pkg_type'], 0);
      const source: Array<Object> = asArray(raw['emoticons']);
      for (let j: number = 0; j < source.length; j++) {
        const emote: LiveEmoteItem = LiveEmoteItem.from(source[j]);
        if (emote.url.length > 0 && emote.unique.length > 0) pkg.emotes.push(emote);
      }
      if (pkg.emotes.length > 0) result.push(pkg);
    }
    return result;
  }

  static async sendLiveDanmaku(roomId: number, message: string, emote: LiveEmoteItem | null = null): Promise<ActionResult> {
    const emoteUnique: string = emote !== null ? emote.unique : '';
    if (roomId <= 0 || (message.trim().length === 0 && emoteUnique.length === 0)) {
      return new ActionResult(false, '弹幕内容不能为空');
    }
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '发送成功', '发送失败',
      async (csrf: string): Promise<HttpResponse> => {
        const query: Record<string, string> = { 'web_location': '444.8' };
        await WbiSign.encWbi(query);
        const body: Record<string, string> = {
          'bubble': '0',
          'msg': emoteUnique.length > 0 ? emoteUnique : message.trim(),
          'color': '16777215',
          'mode': '1',
          'fontsize': '25',
          'rnd': String(Math.floor(Date.now() / 1000)),
          'roomid': String(roomId),
          'csrf': csrf,
          'csrf_token': csrf,
        };
        if (emote !== null && emoteUnique.length > 0) {
          body['dm_type'] = '1';
          body['emoticonOptions'] = JSON.stringify({
            'bulge': 0,
            'emoticon_unique': emote.unique,
            'emoji': emote.emoji,
            'url': emote.url,
            'width': emote.width,
            'height': emote.height,
          });
        } else {
          body['room_type'] = '0';
          body['jumpfrom'] = '0';
          body['reply_mid'] = '0';
          body['reply_attr'] = '0';
          body['replay_dmid'] = '';
          body['statistics'] = '{"appId":100,"platform":5}';
          body['reply_type'] = '0';
          body['reply_uname'] = '';
        }
        return HttpClient.post(Api.liveSendDanmaku + '?' + HttpClient.buildQuery(query),
          HttpClient.buildQuery(body),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://live.bilibili.com/' + String(roomId) }));
      });
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
}
