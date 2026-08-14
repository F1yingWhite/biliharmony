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

export class LiveChatMessage {
  id: string = '';
  type: string = 'danmaku';
  uname: string = '';
  text: string = '';
  color: number = 0xFFFFFF;
  price: number = 0;
  face: string = '';
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
    if (info.length > 0) {
      const meta: Array<Object> = asArray(info[0]);
      if (meta.length > 3) msg.color = asNumber(meta[3], 0xFFFFFF);
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
            msg.color = asNumber(extra['font_color'], msg.color);
          } catch (e) {
            // extra 不是合法 JSON 时继续使用旧协议字段。
          }
        }
      }
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
