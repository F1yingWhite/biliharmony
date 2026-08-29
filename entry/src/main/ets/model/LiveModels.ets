/** 直播只读数据模型：列表、播放清晰度、弹幕和醒目留言。 */
import { asArray, asNumber, asObject, asString, formatCount, str, toHttps } from '../common/Utils';

export class LiveRoomItem {
  roomId: number = 0;
  uid: number = 0;
  title: string = '';
  uname: string = '';
  face: string = '';
  cover: string = '';
  areaName: string = '';
  watched: string = '';
  online: number = 0;

  static from(o: Object): LiveRoomItem {
    const j: Record<string, Object> = asObject(o);
    const watchedShow: Record<string, Object> = asObject(j['watched_show']);
    const item: LiveRoomItem = new LiveRoomItem();
    item.roomId = asNumber(j['roomid'], asNumber(j['room_id'], 0));
    item.uid = asNumber(j['uid'], 0);
    item.title = str(j, 'title', '');
    item.uname = str(j, 'uname', '');
    item.face = toHttps(str(j, 'face', ''));
    item.cover = toHttps(str(j, 'keyframe', str(j, 'cover', '')));
    item.areaName = str(j, 'area_v2_name', str(j, 'area_name', ''));
    item.online = asNumber(j['online'], 0);
    item.watched = str(watchedShow, 'text_small', str(watchedShow, 'text_large', ''));
    if (item.watched.length === 0 && item.online > 0) item.watched = formatCount(item.online) + '人气';
    return item;
  }

  /** 搜索结果（wbi/search/type live_room）的直播间字段与推荐流不同，单独解析。 */
  static fromSearch(o: Object): LiveRoomItem {
    const j: Record<string, Object> = asObject(o);
    const item: LiveRoomItem = new LiveRoomItem();
    item.roomId = asNumber(j['roomid'], asNumber(j['room_id'], 0));
    item.uid = asNumber(j['uid'], 0);
    // 搜索标题可能带高亮 <em> 标签，去除
    item.title = str(j, 'title', '').replace(/<[^>]*>/g, '');
    item.uname = str(j, 'uname', '');
    item.face = toHttps(str(j, 'uface', str(j, 'face', '')));
    item.cover = toHttps(str(j, 'cover', str(j, 'user_cover', '')));
    item.areaName = str(j, 'cate_name', str(j, 'area_name', ''));
    item.online = asNumber(j['online'], 0);
    if (item.online > 0) item.watched = formatCount(item.online) + '人气';
    return item;
  }
}

/** 直播一级分区。 */
export class LiveZone {
  id: number = 0;
  name: string = '';
}

/** 批量查询的 UP 开播状态（room/v1/Room/get_status_info_by_uids）。 */
export class LiveStatusItem {
  uid: number = 0;
  liveStatus: number = 0;      // 1 = 直播中
  roomId: number = 0;
  title: string = '';
  uname: string = '';
}

/** 直播搜索（search_type=live_room）分页结果。 */
export class LiveSearchResult {
  rooms: Array<LiveRoomItem> = [];
  numResults: number = 0;
}

export class LiveQualityOption {
  qn: number = 0;
  label: string = '';

  constructor(qn: number = 0, label: string = '') {
    this.qn = qn;
    this.label = label;
  }
}

export class LivePlayInfo {
  roomId: number = 0;
  liveStatus: number = 0;
  url: string = '';
  urls: Array<string> = [];
  currentQn: number = 0;
  qualities: Array<LiveQualityOption> = [];
}

export class LiveRoomInfo {
  roomId: number = 0;
  uid: number = 0;
  liveStatus: number = 0;
  title: string = '';
  uname: string = '';
  face: string = '';
  cover: string = '';
  areaName: string = '';
  watched: string = '';

  static from(o: Object): LiveRoomInfo {
    const j: Record<string, Object> = asObject(o);
    const roomInfo: Record<string, Object> = asObject(j['room_info']);
    const anchorInfo: Record<string, Object> = asObject(j['anchor_info']);
    const baseInfo: Record<string, Object> = asObject(anchorInfo['base_info']);
    const watchedShow: Record<string, Object> = asObject(roomInfo['watched_show']);
    const info: LiveRoomInfo = new LiveRoomInfo();
    info.roomId = asNumber(roomInfo['room_id'], asNumber(j['room_id'], 0));
    info.uid = asNumber(roomInfo['uid'], asNumber(baseInfo['uid'], 0));
    info.liveStatus = asNumber(roomInfo['live_status'], 0);
    info.title = str(roomInfo, 'title', str(j, 'title', ''));
    info.uname = str(baseInfo, 'uname', str(j, 'uname', ''));
    info.face = toHttps(str(baseInfo, 'face', str(j, 'face', '')));
    info.cover = toHttps(str(roomInfo, 'keyframe', str(roomInfo, 'cover', '')));
    info.areaName = str(roomInfo, 'area_name', str(roomInfo, 'parent_area_name', ''));
    info.watched = str(watchedShow, 'text_large', str(watchedShow, 'text_small', ''));
    return info;
  }
}

export class LiveDanmakuServer {
  host: string = '';
  wssPort: number = 443;

  constructor(host: string = '', wssPort: number = 443) {
    this.host = host;
    this.wssPort = wssPort;
  }
}

export class LiveDanmakuInfo {
  token: string = '';
  servers: Array<LiveDanmakuServer> = [];
}

export class LiveEmoteItem {
  emoji: string = '';
  url: string = '';
  width: number = 0;
  height: number = 0;
  unique: string = '';
  /** 允许在播放器区域突出显示；不能单独作为表情尺寸分类。 */
  bulgeDisplay: number = 0;
  inPlayerArea: number = 0;

  static from(o: Object): LiveEmoteItem {
    const j: Record<string, Object> = asObject(o);
    const item: LiveEmoteItem = new LiveEmoteItem();
    item.emoji = str(j, 'emoji', '');
    item.url = toHttps(str(j, 'url', ''));
    item.width = asNumber(j['width'], 0);
    item.height = asNumber(j['height'], item.width);
    item.unique = str(j, 'emoticon_unique', '');
    item.bulgeDisplay = asNumber(j['bulge_display'], 0);
    item.inPlayerArea = asNumber(j['in_player_area'], 0);
    return item;
  }
}

export class LiveEmotePackage {
  icon: string = '';
  packageType: number = 0;
  emotes: Array<LiveEmoteItem> = [];
}

export class LiveChatMessage {
  id: string = '';
  type: string = 'danmaku';
  uname: string = '';
  text: string = '';
  color: number = 0xFFFFFF;
  /** 用户等级（UL，info[4][0]）；0 表示未知不展示。 */
  ulLevel: number = 0;
  /** 粉丝团牌子（info[3]）：名称为空不展示。 */
  medalName: string = '';
  medalLevel: number = 0;
  medalColor: number = 0;
  price: number = 0;
  face: string = '';
  emotes: Array<LiveEmoteItem> = [];
  backgroundColor: string = '#FB7299';
  timestamp: number = 0;

  static danmaku(o: Object, index: number = 0): LiveChatMessage {
    const msg: LiveChatMessage = new LiveChatMessage();
    const j: Record<string, Object> = asObject(o);
    const info: Array<Object> = asArray(j['info']);
    msg.id = 'dm_' + String(Date.now()) + '_' + String(index);
    msg.timestamp = Math.floor(Date.now() / 1000);
    if (info.length > 1) msg.text = asString(info[1], '');
    if (info.length > 2) {
      const user: Array<Object> = asArray(info[2]);
      if (user.length > 1) msg.uname = asString(user[1], '');
    }
    // 粉丝团牌子 info[3] = [等级, 牌子名, 主播名, 房间号, 颜色, …]；未佩戴为空数组。
    if (info.length > 3) {
      const medal: Array<Object> = asArray(info[3]);
      if (medal.length > 1) {
        msg.medalLevel = asNumber(medal[0], 0);
        msg.medalName = asString(medal[1], '');
        if (medal.length > 4) msg.medalColor = asNumber(medal[4], 0);
      }
    }
    // 用户等级 info[4] = [UL 等级, …]。
    if (info.length > 4) {
      const ul: Array<Object> = asArray(info[4]);
      if (ul.length > 0) msg.ulLevel = asNumber(ul[0], 0);
    }
    if (info.length > 0) {
      const meta: Array<Object> = asArray(info[0]);
      if (meta.length > 3) msg.color = asNumber(meta[3], 0xFFFFFF);
      // 独立直播表情位于 info[0][13]，内容本身通常只是 emoticon_unique。
      if (meta.length > 13) {
        const directEmote: LiveEmoteItem = LiveEmoteItem.from(meta[13]);
        if (directEmote.url.length > 0) msg.emotes.push(directEmote);
      }
      // 新版协议把可读字段收进 info[0][15]，同时兼容旧版数组。
      if (meta.length > 15) {
        const detail: Record<string, Object> = asObject(meta[15]);
        const user: Record<string, Object> = asObject(asObject(detail['user'])['base']);
        if (msg.uname.length === 0) msg.uname = str(user, 'name', '');
        if (msg.text.length === 0) msg.text = str(detail, 'content', '');
        const extraRaw: string = str(detail, 'extra', '');
        if (extraRaw.length > 0) {
          try {
            const extra: Record<string, Object> = asObject(JSON.parse(extraRaw) as Object);
            if (msg.text.length === 0) msg.text = str(extra, 'content', '');
            const messageId: string = str(extra, 'id_str', str(extra, 'dmid', ''));
            if (messageId.length > 0) msg.id = 'live_' + messageId;
            msg.color = asNumber(extra['font_color'], msg.color);
            const emoteMap: Record<string, Object> = asObject(extra['emots']);
            const emoteKeys: Array<string> = Object.keys(emoteMap);
            for (let i: number = 0; i < emoteKeys.length; i++) {
              const emote: LiveEmoteItem = LiveEmoteItem.from(emoteMap[emoteKeys[i]]);
              if (emote.emoji.length === 0) emote.emoji = emoteKeys[i];
              if (emote.url.length > 0) msg.emotes.push(emote);
            }
          } catch (e) {
            // extra 不是合法 JSON 时继续使用旧协议字段。
          }
        }
      }
    }
    return msg;
  }

  static history(o: Object, index: number = 0): LiveChatMessage {
    const raw: Record<string, Object> = asObject(o);
    const msg: LiveChatMessage = new LiveChatMessage();
    const fallbackId: string = str(raw, 'timeline', '') + '_' + str(raw, 'nickname', '') + '_' +
      str(raw, 'text', '') + '_' + String(index);
    msg.id = 'live_' + str(raw, 'id_str', str(raw, 'id', fallbackId));
    msg.uname = str(raw, 'nickname', str(asObject(asObject(raw['user'])['base']), 'name', ''));
    msg.text = str(raw, 'text', '');
    const user: Record<string, Object> = asObject(asObject(raw['user'])['base']);
    msg.face = toHttps(str(user, 'face', ''));
    msg.color = asNumber(asObject(asObject(raw['user'])['dm_config'])['color'], 0xFFFFFF);
    const directEmote: LiveEmoteItem = LiveEmoteItem.from(raw['emoticon']);
    if (directEmote.url.length > 0) msg.emotes.push(directEmote);
    const emoteMap: Record<string, Object> = asObject(raw['emots']);
    const keys: Array<string> = Object.keys(emoteMap);
    for (let i: number = 0; i < keys.length; i++) {
      const emote: LiveEmoteItem = LiveEmoteItem.from(emoteMap[keys[i]]);
      if (emote.emoji.length === 0) emote.emoji = keys[i];
      if (emote.url.length > 0) msg.emotes.push(emote);
    }
    return msg;
  }

  static superChat(o: Object): LiveChatMessage {
    const j: Record<string, Object> = asObject(o);
    const user: Record<string, Object> = asObject(j['user_info']);
    const msg: LiveChatMessage = new LiveChatMessage();
    msg.type = 'sc';
    msg.id = 'sc_' + String(asNumber(j['id'], Date.now()));
    msg.uname = str(user, 'uname', '');
    msg.face = toHttps(str(user, 'face', ''));
    msg.text = str(j, 'message', '');
    msg.price = asNumber(j['price'], 0);
    msg.backgroundColor = str(j, 'background_bottom_color', str(j, 'background_color', '#FB7299'));
    msg.timestamp = asNumber(j['start_time'], Math.floor(Date.now() / 1000));
    return msg;
  }
}
