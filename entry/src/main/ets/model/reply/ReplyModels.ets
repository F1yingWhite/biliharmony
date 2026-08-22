/** reply domain models. */
import { asObject, asNumber, asArray, asBool, str, toHttps } from '../../common/Utils';
import { BiliEmote } from '../library/LibraryModels';

// ===== 评论 =====
export class ReplyJump {
  label: string = '';
  url: string = '';
}
/** 评论正文中的可跳转 @ 用户。 */
export class ReplyMention {
  label: string = '';
  mid: number = 0;
}

export class ReplyItem {
  rpid: number = 0;
  /** 评论所属对象 id（视频=aid，动态=comment_id） */
  oid: number = 0;
  /** 评论所属对象类型（视频=1，动态见 comment_type） */
  type: number = 1;
  rootRpid: number = 0;
  parentRpid: number = 0;
  dialogRpid: number = 0;
  mid: number = 0;
  uname: string = '';
  avatar: string = '';
  content: string = '';
  like: number = 0;
  liked: boolean = false;
  disliked: boolean = false;
  /** UP 主赞过这条评论（up_action.like）；分享图展示"UP主觉得很赞"。 */
  upLiked: boolean = false;
  ctime: number = 0;
  count: number = 0;
  level: number = 0;
  location: string = '';
  pendant: string = '';
  nameplate: string = '';
  nameColor: string = '';
  cardBackground: string = '';
  cardNumberPrefix: string = 'NO.';
  cardNumber: string = '';
  cardNumberColor: string = '';
  emotes: Array<BiliEmote> = [];
  jumps: Array<ReplyJump> = [];
  mentions: Array<ReplyMention> = [];
  pictures: Array<string> = [];
  replies: Array<ReplyItem> = [];
  /** 本地修订号：乐观更新克隆时 +1，LazyForEach 键包含它才能让同 rpid 的卡片真正重渲染。 */
  rev: number = 0;

  /** 浅克隆：乐观更新后换对象引用，驱动 @Prop 子组件重新同步（同引用不会触发更新）。 */
  clone(): ReplyItem {
    const r: ReplyItem = new ReplyItem();
    r.rpid = this.rpid;
    r.oid = this.oid;
    r.type = this.type;
    r.rootRpid = this.rootRpid;
    r.parentRpid = this.parentRpid;
    r.dialogRpid = this.dialogRpid;
    r.mid = this.mid;
    r.uname = this.uname;
    r.avatar = this.avatar;
    r.content = this.content;
    r.like = this.like;
    r.liked = this.liked;
    r.disliked = this.disliked;
    r.upLiked = this.upLiked;
    r.ctime = this.ctime;
    r.count = this.count;
    r.level = this.level;
    r.location = this.location;
    r.pendant = this.pendant;
    r.nameplate = this.nameplate;
    r.nameColor = this.nameColor;
    r.cardBackground = this.cardBackground;
    r.cardNumberPrefix = this.cardNumberPrefix;
    r.cardNumber = this.cardNumber;
    r.cardNumberColor = this.cardNumberColor;
    r.emotes = this.emotes;
    r.jumps = this.jumps;
    r.mentions = this.mentions;
    r.pictures = this.pictures;
    r.replies = this.replies;
    r.rev = this.rev;
    return r;
  }

  static from(o: Object): ReplyItem {
    const j: Record<string, Object> = asObject(o);
    const member: Record<string, Object> = asObject(j['member']);
    const content: Record<string, Object> = asObject(j['content']);
    const r: ReplyItem = new ReplyItem();
    r.rpid = asNumber(j['rpid'], 0);
    r.oid = asNumber(j['oid'], 0);
    r.type = asNumber(j['type'], 1);
    r.rootRpid = asNumber(j['root'], 0);
    r.parentRpid = asNumber(j['parent'], 0);
    r.dialogRpid = asNumber(j['dialog'], 0);
    r.mid = asNumber(member['mid'], 0);
    r.uname = str(member, 'uname', '');
    r.avatar = toHttps(str(member, 'avatar', ''));
    r.content = str(content, 'message', '');
    r.like = asNumber(j['like'], 0);
    r.liked = asNumber(j['action'], 0) === 1;
    r.disliked = asNumber(j['action'], 0) === 2;
    const upAction: Record<string, Object> = asObject(j['up_action']);
    r.upLiked = asBool(upAction['like'], false);
    r.ctime = asNumber(j['ctime'], 0);
    // `count` 会保留已删除、折叠或当前账号不可见的历史回复数；楼中楼接口实际
    // 可返回的数量由 `rcount` 表示。优先使用 rcount，避免主列表显示“4 条回复”，
    // 进入详情后 page.count=0、replies=null 的假入口。旧协议没有 rcount 时再回退。
    r.count = j['rcount'] !== undefined && j['rcount'] !== null ?
      asNumber(j['rcount'], 0) : asNumber(j['count'], 0);
    const levelInfo: Record<string, Object> = asObject(member['level_info']);
    r.level = asNumber(levelInfo['current_level'], 0);
    const replyControl: Record<string, Object> = asObject(j['reply_control']);
    r.location = str(replyControl, 'location', '');
    const pendant: Record<string, Object> = asObject(member['pendant']);
    const sailingForPendant: Record<string, Object> = asObject(member['user_sailing']);
    const sailingPendant: Record<string, Object> = asObject(sailingForPendant['pendant']);
    r.pendant = toHttps(str(pendant, 'image_enhance', str(pendant, 'image',
      str(pendant, 'image_enhance_frame', str(sailingPendant, 'image_enhance', str(sailingPendant, 'image', ''))))));
    const nameplate: Record<string, Object> = asObject(member['nameplate']);
    r.nameplate = toHttps(str(nameplate, 'image_small', str(nameplate, 'image', '')));
    const vip: Record<string, Object> = asObject(member['vip']);
    r.nameColor = str(vip, 'nickname_color', '');
    // Web 新旧评论协议兼容：content.emote 是以“[表情名]”为 key 的对象。
    const emoteMap: Record<string, Object> = asObject(content['emote']);
    const emoteKeys: Array<string> = Object.keys(emoteMap);
    for (let i: number = 0; i < emoteKeys.length; i++) {
      const emote: BiliEmote = BiliEmote.from(emoteMap[emoteKeys[i]]);
      if (emote.text.length === 0) emote.text = emoteKeys[i];
      if (emote.url.length > 0) r.emotes.push(emote);
    }
    const jumpMap: Record<string, Object> = asObject(content['jump_url']);
    const jumpKeys: Array<string> = Object.keys(jumpMap);
    for (let i: number = 0; i < jumpKeys.length; i++) {
      const jumpObj: Record<string, Object> = asObject(jumpMap[jumpKeys[i]]);
      const jump: ReplyJump = new ReplyJump();
      jump.label = jumpKeys[i];
      jump.url = str(jumpObj, 'pc_url', str(jumpObj, 'app_url_schema', ''));
      if (jump.label.length > 0 && jump.url.length > 0) r.jumps.push(jump);
    }
    // 新旧评论接口分别可能返回 members 数组或 at_name_to_mid 映射；统一成
    // 带 UID 的文本片段，渲染层只让真实可解析的 @ 用户具有点击行为。
    const mentionMids: Set<number> = new Set<number>();
    const atNameMap: Record<string, Object> = asObject(content['at_name_to_mid']);
    const atNames: Array<string> = Object.keys(atNameMap);
    for (let i: number = 0; i < atNames.length; i++) {
      const mid: number = asNumber(atNameMap[atNames[i]], 0);
      if (mid <= 0 || mentionMids.has(mid)) continue;
      const mention: ReplyMention = new ReplyMention();
      mention.label = atNames[i].startsWith('@') ? atNames[i] : '@' + atNames[i];
      mention.mid = mid;
      r.mentions.push(mention);
      mentionMids.add(mid);
    }
    const members: Array<Object> = asArray(content['members']);
    for (let i: number = 0; i < members.length; i++) {
      const mentionMember: Record<string, Object> = asObject(members[i]);
      const mid: number = asNumber(mentionMember['mid'], 0);
      const uname: string = str(mentionMember, 'uname', '');
      if (mid <= 0 || uname.length === 0 || mentionMids.has(mid)) continue;
      const mention: ReplyMention = new ReplyMention();
      mention.label = '@' + uname;
      mention.mid = mid;
      r.mentions.push(mention);
      mentionMids.add(mid);
    }
    const pictures: Array<Object> = asArray(content['pictures']);
    for (let i: number = 0; i < pictures.length; i++) {
      const picture: Record<string, Object> = asObject(pictures[i]);
      const src: string = toHttps(str(picture, 'img_src', str(picture, 'url', '')));
      if (src.length > 0) r.pictures.push(src);
    }
    // 当前评论协议把装扮放在 member.user_sailing(_v2)；兼容早期字段。
    const memberV2: Record<string, Object> = asObject(j['member_v2']);
    const garb: Record<string, Object> = asObject(memberV2['garb']);
    const decoration: Record<string, Object> = asObject(member['decoration_card']);
    const sailing: Record<string, Object> = asObject(member['user_sailing']);
    const sailingV2: Record<string, Object> = asObject(member['user_sailing_v2']);
    const sailingCard: Record<string, Object> = asObject(sailing['cardbg']);
    const sailingCardWithFocus: Record<string, Object> = asObject(sailing['cardbg_with_focus']);
    const sailingCardV2: Record<string, Object> = asObject(sailingV2['card_bg']);
    const activeCard: Record<string, Object> = Object.keys(sailingCardV2).length > 0 ? sailingCardV2 :
      (Object.keys(sailingCardWithFocus).length > 0 ? sailingCardWithFocus : sailingCard);
    r.cardBackground = toHttps(str(activeCard, 'image',
      str(garb, 'card_image', str(decoration, 'card_url', ''))));
    const fan: Record<string, Object> = asObject(activeCard['fan']);
    r.cardNumberPrefix = str(fan, 'num_prefix', str(garb, 'card_number_prefix', 'NO.'));
    r.cardNumber = str(fan, 'num_desc', str(fan, 'num_str', str(garb, 'card_number', '')));
    r.cardNumberColor = str(fan, 'color', str(garb, 'card_fan_color', ''));
    const sub: Array<Object> = asArray(j['replies']);
    for (let i: number = 0; i < sub.length; i++) {
      r.replies.push(ReplyItem.from(sub[i]));
    }
    return r;
  }
}

export class ReplyPageData {
  replies: Array<ReplyItem> = [];
  hasMore: boolean = false;

  static from(o: Object): ReplyPageData {
    const j: Record<string, Object> = asObject(o);
    const result: ReplyPageData = new ReplyPageData();
    const replies: Array<Object> = asArray(j['replies']);
    for (let i: number = 0; i < replies.length; i++) {
      result.replies.push(ReplyItem.from(replies[i]));
    }
    const page: Record<string, Object> = asObject(j['page']);
    const count: number = asNumber(page['count'], result.replies.length);
    const num: number = asNumber(page['num'], 1);
    const size: number = asNumber(page['size'], 20);
    result.hasMore = num * size < count;
    return result;
  }
}

export class ReplyData {
  replies: Array<ReplyItem> = [];
  cursor: string = '';
  hasMore: boolean = true;

  static from(o: Object): ReplyData {
    const j: Record<string, Object> = asObject(o);
    const data: ReplyData = new ReplyData();
    const topArr: Array<Object> = asArray(j['top_replies']);
    const repliesArr: Array<Object> = asArray(j['replies']);
    for (let i: number = 0; i < topArr.length; i++) {
      data.replies.push(ReplyItem.from(topArr[i]));
    }
    for (let i: number = 0; i < repliesArr.length; i++) {
      data.replies.push(ReplyItem.from(repliesArr[i]));
    }
    const cursorObj: Record<string, Object> = asObject(j['cursor']);
    // 当前 /main 响应把 pagination_reply 放在 cursor 内；兼容少数旧响应的顶层位置。
    let paginationObj: Record<string, Object> = asObject(cursorObj['pagination_reply']);
    if (Object.keys(paginationObj).length === 0) {
      paginationObj = asObject(j['pagination_reply']);
    }
    // next_offset 是下一页必须原样回传的完整令牌，不能用 cursor.next 页码替代。
    const nextOffset: Object | undefined = paginationObj['next_offset'];
    if (typeof nextOffset === 'string') {
      data.cursor = nextOffset as string;
    } else if (nextOffset !== null && nextOffset !== undefined) {
      data.cursor = JSON.stringify(nextOffset);
    }
    if (data.cursor.length === 0) {
      const legacyNext: number = asNumber(cursorObj['next'], 0);
      data.cursor = legacyNext > 0 ? String(legacyNext) : '';
    }
    const isEnd: boolean = asBool(cursorObj['is_end'], false);
    data.hasMore = !isEnd && data.cursor.length > 0;
    return data;
  }

  static fromLegacy(o: Object, pageNumber: number): ReplyData {
    const data: ReplyData = ReplyData.from(o);
    const j: Record<string, Object> = asObject(o);
    const page: Record<string, Object> = asObject(j['page']);
    const count: number = asNumber(page['count'], data.replies.length);
    const size: number = Math.max(1, asNumber(page['size'], 20));
    data.hasMore = pageNumber * size < count;
    data.cursor = data.hasMore ? String(pageNumber + 1) : '';
    return data;
  }
}
