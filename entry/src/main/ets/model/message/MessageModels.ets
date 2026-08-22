/** message domain models. */
import { asObject, asNumber, asArray, str, toHttps } from '../../common/Utils';

// ===== 私信 =====
export class MessageSessionItem {
  talkerId: number = 0;
  name: string = '';
  avatar: string = '';
  preview: string = '';
  timestamp: number = 0;
  unread: number = 0;
  sessionTs: number = 0;

  static from(o: Object): MessageSessionItem {
    const j: Record<string, Object> = asObject(o);
    const account: Record<string, Object> = asObject(j['account_info']);
    const lastMsg: Record<string, Object> = asObject(j['last_msg']);
    const item: MessageSessionItem = new MessageSessionItem();
    item.talkerId = asNumber(j['talker_id'], 0);
    item.name = str(account, 'name', '');
    item.avatar = toHttps(str(account, 'pic_url', ''));
    item.preview = messageContentText(str(lastMsg, 'content', ''), asNumber(lastMsg['msg_type'], 1));
    item.timestamp = asNumber(lastMsg['timestamp'], 0);
    item.sessionTs = asNumber(j['session_ts'], 0);
    item.unread = asNumber(j['unread_count'], 0) + asNumber(j['biz_msg_unread_count'], 0);
    return item;
  }

  clone(): MessageSessionItem {
    const next: MessageSessionItem = new MessageSessionItem();
    next.talkerId = this.talkerId;
    next.name = this.name;
    next.avatar = this.avatar;
    next.preview = this.preview;
    next.timestamp = this.timestamp;
    next.unread = this.unread;
    next.sessionTs = this.sessionTs;
    return next;
  }
}
export class MessageSessionPageData {
  sessions: Array<MessageSessionItem> = [];
  hasMore: boolean = false;
  /** 加载失败原因（空串表示成功；用于 UI 呈现与区分"真的没私信"） */
  error: string = '';
}

export class PrivateMessageItem {
  senderId: number = 0;
  receiverId: number = 0;
  text: string = '';
  timestamp: number = 0;
  seqno: number = 0;
  type: number = 1;
  /** 富文本/视频推荐卡片字段；普通文本消息为空。 */
  richTitle: string = '';
  richCover: string = '';
  richUrl: string = '';
  richBvid: string = '';
  richAid: number = 0;
  richDesc: string = '';
  /** msg_type=2 的原图及尺寸；与视频推荐卡字段分开，避免把图片 URL 当成跳转链接。 */
  imageUrl: string = '';
  imageWidth: number = 0;
  imageHeight: number = 0;

  static from(o: Object): PrivateMessageItem {
    const j: Record<string, Object> = asObject(o);
    const item: PrivateMessageItem = new PrivateMessageItem();
    item.senderId = asNumber(j['sender_uid'], 0);
    item.receiverId = asNumber(j['receiver_id'], 0);
    item.type = asNumber(j['msg_type'], 1);
    const raw: string = str(j, 'content', '');
    item.text = messageContentText(raw, item.type);
    try {
      const content: Record<string, Object> = asObject(JSON.parse(raw) as Object);
      item.richTitle = str(content, 'title', str(content, 'content', ''));
      item.richCover = toHttps(str(content, 'cover', str(content, 'pic', '')));
      item.richUrl = str(content, 'url', '');
      item.richBvid = str(content, 'bvid', '');
      item.richAid = asNumber(content['aid'], 0);
      item.richDesc = str(content, 'description', str(content, 'desc', ''));
      if (item.type === 2) {
        item.imageUrl = toHttps(str(content, 'url', str(content, 'image_url', str(content, 'pic_url', ''))));
        item.imageWidth = asNumber(content['width'], asNumber(content['image_width'], 0));
        item.imageHeight = asNumber(content['height'], asNumber(content['image_height'], 0));
      }
    } catch (e) {
      // 普通文本消息没有 JSON 富文本字段。
    }
    item.timestamp = asNumber(j['timestamp'], 0);
    item.seqno = asNumber(j['msg_seqno'], 0);
    return item;
  }
}

export class PrivateMessagePageData {
  messages: Array<PrivateMessageItem> = [];
  hasMore: boolean = false;
  minSeqno: number = 0;
  /** 加载失败原因；空串表示请求成功，避免失败被 UI 误判成空会话。 */
  error: string = '';
}

// ===== 消息通知（回复我的 / @我 / 收到的赞 / 系统通知），字段对齐 PiliPlus lib/models_new/msg =====
export class MsgNotifyItem {
  id: number = 0;
  /** 触发用户 mid；系统通知为 0 */
  mid: number = 0;
  nickname: string = '';
  avatar: string = '';
  /** 动作描述（如「 赞了我的视频」「 在评论中@了我」），紧跟昵称展示 */
  action: string = '';
  /** 通知正文：回复内容 / @ 内容 / 被赞内容标题 / 系统通知正文 */
  text: string = '';
  /** 来源内容摘要（被回复的评论 / 系统通知标题），列表中以引用样式展示 */
  source: string = '';
  timestamp: number = 0;
  /** 系统通知接口直接返回格式化时间文本，优先于 timestamp 展示 */
  timeText: string = '';
  /** 右侧缩略图（@我 / 收到的赞） */
  image: string = '';
  nativeUri: string = '';
  /** 从 nativeUri 解析出的视频目标；aid 与 bvid 均为空时点击不跳转 */
  aid: number = 0;
  bvid: string = '';
  /** 系统通知分页游标：纳秒级 int64，超出 number 精度按字符串保存 */
  sysCursor: string = '';

  static fromReply(o: Object): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const user: Record<string, Object> = asObject(j['user']);
    const item: Record<string, Object> = asObject(j['item']);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    out.mid = asNumber(user['mid'], 0);
    out.nickname = str(user, 'nickname', '');
    out.avatar = toHttps(str(user, 'avatar', ''));
    const counts: number = asNumber(j['counts'], 1);
    const multi: string = asNumber(j['is_multi'], 0) === 1 ? ' 等人' : '';
    out.action = multi + ' 对我的' + str(item, 'business', '内容') + '发布了' + String(counts) + '条评论';
    out.text = str(item, 'source_content', '');
    const target: string = str(item, 'target_reply_content', '');
    const root: string = str(item, 'root_reply_content', '');
    out.source = target.length > 0 ? target : root;
    out.timestamp = asNumber(j['reply_time'], 0);
    out.nativeUri = str(item, 'native_uri', '');
    fillNotifyVideoTarget(out);
    return out;
  }

  static fromAt(o: Object): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const user: Record<string, Object> = asObject(j['user']);
    const item: Record<string, Object> = asObject(j['item']);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    out.mid = asNumber(user['mid'], 0);
    out.nickname = str(user, 'nickname', '');
    out.avatar = toHttps(str(user, 'avatar', ''));
    out.action = ' 在' + str(item, 'business', '内容') + '中@了我';
    out.text = str(item, 'source_content', '');
    out.image = toHttps(str(item, 'image', ''));
    out.timestamp = asNumber(j['at_time'], 0);
    out.nativeUri = str(item, 'native_uri', '');
    fillNotifyVideoTarget(out);
    return out;
  }

  static fromLike(o: Object): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const item: Record<string, Object> = asObject(j['item']);
    const users: Array<Object> = asArray(j['users']);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    if (users.length > 0) {
      const first: Record<string, Object> = asObject(users[0]);
      out.mid = asNumber(first['mid'], 0);
      out.nickname = str(first, 'nickname', '');
      out.avatar = toHttps(str(first, 'avatar', ''));
    }
    const counts: number = asNumber(j['counts'], users.length);
    out.action = (counts > 1 ? ' 等' + String(counts) + '人' : '') + ' 赞了我的' + str(item, 'business', '内容');
    out.text = str(item, 'title', '');
    out.image = toHttps(str(item, 'image', ''));
    out.timestamp = asNumber(j['like_time'], 0);
    out.nativeUri = str(item, 'native_uri', '');
    fillNotifyVideoTarget(out);
    return out;
  }

  static fromSys(o: Object, cursor: string): MsgNotifyItem {
    const j: Record<string, Object> = asObject(o);
    const out: MsgNotifyItem = new MsgNotifyItem();
    out.id = asNumber(j['id'], 0);
    out.nickname = '系统通知';
    out.source = str(j, 'title', '');
    let content: string = str(j, 'content', '');
    // content 可能是 JSON（{"web":"..."}），对齐 PiliPlus 取 web 字段。
    if (content.startsWith('{')) {
      try {
        content = str(asObject(JSON.parse(content) as Object), 'web', content);
      } catch (e) {
      }
    }
    out.text = content;
    out.timeText = str(j, 'time_at', '');
    out.sysCursor = cursor;
    return out;
  }
}

/** 从通知的 bilibili:// 原生链接解析视频目标，用于点击跳详情；解析不出则不跳。 */
function fillNotifyVideoTarget(item: MsgNotifyItem): void {
  if (item.nativeUri.length === 0) return;
  const bv: RegExpMatchArray | null = item.nativeUri.match(/BV[0-9A-Za-z]{10}/);
  if (bv !== null) {
    item.bvid = bv[0];
    return;
  }
  const av: RegExpMatchArray | null = item.nativeUri.match(/(?:video|av)\/(\d{3,})/);
  if (av !== null) item.aid = Number(av[1]);
}

export class MsgNotifyPageData {
  items: Array<MsgNotifyItem> = [];
  hasMore: boolean = false;
  /** cursor.id / time 为 int64，按字符串透传避免 JSON.parse 丢失精度 */
  cursorId: string = '';
  cursorTime: string = '';
  /** 系统通知下一页游标（纳秒字符串） */
  sysCursor: string = '';
  /** 加载失败原因；空串表示请求成功 */
  error: string = '';
}

/** 消息中心各分类未读数（/x/msgfeed/unread）。 */
export class MsgFeedUnread {
  reply: number = 0;
  at: number = 0;
  like: number = 0;
  sysMsg: number = 0;

  total(): number {
    return this.reply + this.at + this.like + this.sysMsg;
  }
}

function messageContentText(raw: string, type: number): string {
  if (raw.length === 0) return '';
  try {
    const content: Record<string, Object> = asObject(JSON.parse(raw) as Object);
    if (type === 1) return str(content, 'content', raw);
    if (type === 2) return '[图片]';
    if (type === 5) return '撤回了一条消息';
    return str(content, 'text', str(content, 'title', '[消息]'));
  } catch (e) {
    return raw;
  }
}
