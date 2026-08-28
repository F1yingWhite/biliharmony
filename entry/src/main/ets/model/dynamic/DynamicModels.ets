/** dynamic domain models. */
import { asObject, asNumber, asArray, asBool, str, toHttps } from '../../common/Utils';
import { BiliEmote } from '../library/LibraryModels';

// ===== 动态 =====
export class DynamicRichNode {
  text: string = '';
  emote: BiliEmote | null = null;
}
export class DynamicItem {
  dynId: string = '';
  type: string = '';
  mid: number = 0;
  uname: string = '';
  face: string = '';
  content: string = '';
  title: string = '';
  cover: string = '';
  bvid: string = '';
  aid: number = 0;
  cid: number = 0;
  like: number = 0;
  liked: boolean = false;
  comment: number = 0;
  forward: number = 0;
  pubtime: number = 0;
  pendant: string = '';
  decorationCard: string = '';
  decorationNumber: string = '';
  decorationColor: string = '';
  majorType: string = '';
  badge: string = '';
  subtitle: string = '';
  images: Array<string> = [];
  emotes: Array<BiliEmote> = [];
  /** 按接口原始顺序保存正文节点，避免从合并文本反查表情时错位或重复。 */
  richNodes: Array<DynamicRichNode> = [];
  commentId: number = 0;
  commentType: number = 0;
  liveRoomId: number = 0;
  liveUid: number = 0;
  liveStatus: number = 0;
  /** PGC（番剧/影视）卡片的季 ID 与单集 ID；UGC 合集卡没有这两个字段，保持 0。 */
  seasonId: number = 0;
  epId: number = 0;
  original: DynamicItem | null = null;

  static from(o: Object): DynamicItem {
    const j: Record<string, Object> = asObject(o);
    const modules: Record<string, Object> = asObject(j['modules']);
    const author: Record<string, Object> = asObject(modules['module_author']);
    const stat: Record<string, Object> = asObject(modules['module_stat']);
    const dynamic: Record<string, Object> = asObject(modules['module_dynamic']);
    const d: DynamicItem = new DynamicItem();
    // 动态 ID 已超过 JS 安全整数范围，必须保留字符串，否则分页/去重会串卡。
    d.dynId = str(j, 'id_str', '');
    if (d.dynId.length === 0) d.dynId = String(asNumber(j['id'], 0));
    d.type = str(j, 'type', '');
    const basic: Record<string, Object> = asObject(j['basic']);
    d.commentId = Number(str(basic, 'comment_id_str', '0'));
    if (Number.isNaN(d.commentId)) d.commentId = 0;
    d.commentType = asNumber(basic['comment_type'], 0);
    d.mid = asNumber(author['mid'], 0);
    d.uname = str(author, 'name', '');
    d.face = toHttps(str(author, 'face', ''));
    const pendant: Record<string, Object> = asObject(author['pendant']);
    d.pendant = toHttps(str(pendant, 'image', ''));
    const decorate: Record<string, Object> = asObject(author['decorate']);
    const decorationCard: Record<string, Object> = Object.keys(decorate).length > 0 ? decorate : asObject(author['decoration_card']);
    d.decorationCard = toHttps(str(decorationCard, 'card_url', ''));
    const fan: Record<string, Object> = asObject(decorationCard['fan']);
    d.decorationNumber = str(fan, 'num_str', str(fan, 'num_desc', ''));
    d.decorationColor = str(fan, 'color', '');
    d.pubtime = asNumber(author['pub_ts'], 0);
    const likeStat: Record<string, Object> = asObject(stat['like']);
    const commentStat: Record<string, Object> = asObject(stat['comment']);
    const forwardStat: Record<string, Object> = asObject(stat['forward']);
    d.like = asNumber(likeStat['count'], asNumber(stat['like'], 0));
    d.liked = asBool(likeStat['status'], false);
    d.comment = asNumber(commentStat['count'], asNumber(stat['comment'], 0));
    d.forward = asNumber(forwardStat['count'], asNumber(stat['forward'], 0));
    // 图文动态内容
    const descObj: Record<string, Object> = asObject(dynamic['desc']);
    d.content = str(descObj, 'text', '');
    const descNodes: Array<Object> = asArray(descObj['rich_text_nodes']);
    for (let i: number = 0; i < descNodes.length; i++) {
      const node: Record<string, Object> = asObject(descNodes[i]);
      const richNode: DynamicRichNode = new DynamicRichNode();
      richNode.text = str(node, 'orig_text', str(node, 'text', ''));
      let emoji: Record<string, Object> = asObject(node['emoji']);
      if (Object.keys(emoji).length === 0 && str(node, 'type', '').indexOf('EMOJI') >= 0 &&
        str(node, 'icon_url', '').length > 0) {
        emoji = node;
      }
      if (Object.keys(emoji).length > 0) {
        const emote: BiliEmote = BiliEmote.from(emoji);
        emote.text = str(node, 'orig_text', str(node, 'text', emote.text));
        if (emote.text.length > 0 && emote.url.length > 0) {
          d.emotes.push(emote);
          richNode.emote = emote;
        }
      }
      if (richNode.text.length > 0 || richNode.emote !== null) d.richNodes.push(richNode);
    }
    // 视频动态卡片
    const major: Record<string, Object> = asObject(dynamic['major']);
    d.majorType = str(major, 'type', '');
    let card: Record<string, Object> = asObject(major['archive']);
    if (Object.keys(card).length === 0) card = asObject(major['ugc_season']);
    if (Object.keys(card).length === 0) card = asObject(major['pgc']);
    if (Object.keys(card).length === 0) card = asObject(major['courses']);
    if (Object.keys(card).length === 0) card = asObject(major['medialist']);
    if (Object.keys(card).length === 0) card = asObject(major['common']);
    if (Object.keys(card).length === 0) card = asObject(major['upower_common']);
    if (Object.keys(card).length === 0) card = asObject(major['music']);
    if (Object.keys(card).length === 0) card = asObject(major['live']);
    d.title = str(card, 'title', '');
    d.cover = toHttps(str(card, 'cover', ''));
    d.bvid = str(card, 'bvid', '');
    d.aid = asNumber(card['aid'], asNumber(card['id'], 0));
    d.cid = asNumber(card['cid'], 0);
    // PGC 卡片带 season_id/epid（参考 PiliPlus DynamicArchiveModel），用于跳番剧详情页。
    d.seasonId = asNumber(card['season_id'], 0);
    d.epId = asNumber(card['epid'], asNumber(card['ep_id'], 0));
    d.subtitle = str(card, 'sub_title', str(card, 'desc', str(card, 'label', str(card, 'desc_first', ''))));
    d.liveRoomId = asNumber(card['room_id'], asNumber(card['roomid'], 0));
    d.liveUid = asNumber(card['uid'], 0);
    d.liveStatus = asNumber(card['live_status'], asNumber(card['live_state'], 0));
    // MAJOR_TYPE_LIVE 的房间号字段名就是 id，不是 room_id。
    if (d.liveRoomId <= 0 && d.type === 'DYNAMIC_TYPE_LIVE') {
      d.liveRoomId = asNumber(card['id'], 0);
    }
    const badge: Record<string, Object> = asObject(card['badge']);
    d.badge = str(badge, 'text', '');
    // 图文/专栏卡片使用 opus 图片；普通图文也可能放在 major.draw.items。
    const opus: Record<string, Object> = asObject(major['opus']);
    if (d.title.length === 0) d.title = str(opus, 'title', '');
    const summary: Record<string, Object> = asObject(opus['summary']);
    const summaryText: string = str(summary, 'text', '');
    const summaryNodes: Array<Object> = asArray(summary['rich_text_nodes']);
    // OPUS 的 desc 常是 feed 摘要，而 summary 才是完整正文。正文和表情节点必须取自同一套数据，
    // 否则长表情会留下半截占位文字，图片也会被插到错误位置。
    if (summaryText.length > 0) {
      d.content = summaryText;
      if (summaryNodes.length > 0) {
        d.emotes = [];
        d.richNodes = [];
      }
    }
    for (let i: number = 0; i < summaryNodes.length; i++) {
      const node: Record<string, Object> = asObject(summaryNodes[i]);
      const richNode: DynamicRichNode = new DynamicRichNode();
      richNode.text = str(node, 'orig_text', str(node, 'text', ''));
      let emoji: Record<string, Object> = asObject(node['emoji']);
      if (Object.keys(emoji).length === 0 && str(node, 'type', '').indexOf('EMOJI') >= 0 &&
        str(node, 'icon_url', '').length > 0) {
        emoji = node;
      }
      if (Object.keys(emoji).length > 0) {
        const emote: BiliEmote = BiliEmote.from(emoji);
        emote.text = str(node, 'orig_text', str(node, 'text', emote.text));
        if (emote.text.length > 0 && emote.url.length > 0) {
          d.emotes.push(emote);
          richNode.emote = emote;
        }
      }
      if (richNode.text.length > 0 || richNode.emote !== null) d.richNodes.push(richNode);
    }
    let pics: Array<Object> = asArray(opus['pics']);
    const draw: Record<string, Object> = asObject(major['draw']);
    if (pics.length === 0) pics = asArray(draw['items']);
    for (let i: number = 0; i < pics.length; i++) {
      const pic: Record<string, Object> = asObject(pics[i]);
      const src: string = toHttps(str(pic, 'url', str(pic, 'src', '')));
      if (src.length > 0) d.images.push(src);
    }
    // 直播推荐卡把实际信息封装在 content JSON 字符串中。
    const liveRcmd: Record<string, Object> = asObject(major['live_rcmd']);
    const liveContent: string = str(liveRcmd, 'content', '');
    if (liveContent.length > 0) {
      try {
        const liveJson: Record<string, Object> = asObject(JSON.parse(liveContent) as Object);
        const liveInfo: Record<string, Object> = asObject(liveJson['live_play_info']);
        d.title = str(liveInfo, 'title', d.title);
        d.cover = toHttps(str(liveInfo, 'cover', d.cover));
        d.subtitle = str(liveInfo, 'area_name', d.subtitle);
        d.badge = '直播';
        d.liveRoomId = asNumber(liveInfo['room_id'], asNumber(liveInfo['roomid'], d.liveRoomId));
        d.liveUid = asNumber(liveInfo['uid'], d.liveUid);
        d.liveStatus = asNumber(liveInfo['live_status'], 1);
      } catch (e) {
        // 无效直播卡不阻断整个动态 feed。
      }
    }
    // 预约开播动态使用 subscription_new.live_rcmd，content 结构与 live_rcmd 一致。
    const subscriptionNew: Record<string, Object> = asObject(major['subscription_new']);
    const subscriptionLive: Record<string, Object> = asObject(subscriptionNew['live_rcmd']);
    const subscriptionContent: string = str(subscriptionLive, 'content', '');
    if (subscriptionContent.length > 0) {
      try {
        const subscriptionJson: Record<string, Object> = asObject(JSON.parse(subscriptionContent) as Object);
        const subscriptionInfo: Record<string, Object> = asObject(subscriptionJson['live_play_info']);
        d.title = str(subscriptionInfo, 'title', d.title);
        d.cover = toHttps(str(subscriptionInfo, 'cover', d.cover));
        d.subtitle = str(subscriptionInfo, 'area_name', d.subtitle);
        d.badge = '直播';
        d.liveRoomId = asNumber(subscriptionInfo['room_id'], asNumber(subscriptionInfo['roomid'], d.liveRoomId));
        d.liveUid = asNumber(subscriptionInfo['uid'], d.liveUid);
        d.liveStatus = asNumber(subscriptionInfo['live_status'], d.liveStatus);
      } catch (e) {
        // 无效预约卡不阻断整个动态 feed。
      }
    }
    // 转发动态的原始卡片与当前动态同构，保留完整媒体与跳转信息。
    const original: Record<string, Object> = asObject(j['orig']);
    if (Object.keys(original).length > 0) d.original = DynamicItem.from(original);
    return d;
  }
}

export class DynamicPageData {
  items: Array<DynamicItem> = [];
  offset: string = '';
  hasMore: boolean = false;
}
