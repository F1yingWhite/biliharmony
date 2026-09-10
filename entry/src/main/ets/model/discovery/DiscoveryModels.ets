/** discovery domain models. */
import { asObject, asString, asNumber, asArray, str, formatCount, toHttps } from '../../common/Utils';
import { VideoItem } from '../video/VideoModels';

// ===== 热搜 =====
export class HotSearchItem {
  keyword: string = '';
  showName: string = '';
  icon: string = '';
  heatScore: number = 0;

  static from(o: Object): HotSearchItem {
    const j: Record<string, Object> = asObject(o);
    const h: HotSearchItem = new HotSearchItem();
    h.keyword = str(j, 'keyword', '');
    h.showName = str(j, 'show_name', '');
    h.icon = str(j, 'icon', '');
    h.heatScore = asNumber(j['heat_score'], 0);
    return h;
  }
}
// ===== 搜索类型常量（v1 实现 video/bili_user，其余预留，参考 PiliPlus search_type.dart） =====
export class SearchTypes {
  static readonly video: string = 'video';
  static readonly biliUser: string = 'bili_user';
  static readonly mediaBangumi: string = 'media_bangumi';
  static readonly mediaFt: string = 'media_ft';
  static readonly article: string = 'article';
  static readonly liveRoom: string = 'live_room';
}

// 字符串型搜索选项（label 展示文案 / value 请求参数值）
export interface SearchOption {
  label: string;
  value: string;
}

// 数值型搜索选项（时长 / 发布时间 / 分区）
export interface SearchNumOption {
  label: string;
  value: number;
}

// 视频排序（order 参数，参考 PiliPlus ArchiveFilterType）
export const VIDEO_ORDER_OPTIONS: Array<SearchOption> = [
  { label: '默认排序', value: 'totalrank' },
  { label: '新发布', value: 'pubdate' },
  { label: '播放多', value: 'click' },
  { label: '弹幕多', value: 'dm' },
  { label: '最多收藏', value: 'stow' },
];

// 用户排序（order 参数，v1 只做降序 order_sort=0，参考 PiliPlus UserOrderType）
export const USER_ORDER_OPTIONS: Array<SearchOption> = [
  { label: '默认', value: '' },
  { label: '粉丝数', value: 'fans' },
  { label: '等级', value: 'level' },
];

// 用户类型筛选（user_type 参数：0 不限 / 1 认证UP主 / 2 普通用户 / 3 认证用户，参考网页端筛选）
export const USER_TYPE_OPTIONS: Array<SearchOption> = [
  { label: '全部', value: '0' },
  { label: 'UP主', value: '1' },
  { label: '普通', value: '2' },
  { label: '认证', value: '3' },
];

// 直播间排序（order 参数，参考 PiliPlus LiveOrderType）
export const LIVE_ORDER_OPTIONS: Array<SearchOption> = [
  { label: '人气', value: 'online' },
  { label: '最新开播', value: 'live_time' },
];

// 视频时长筛选（duration 参数）
export const VIDEO_DURATION_OPTIONS: Array<SearchNumOption> = [
  { label: '不限', value: 0 },
  { label: '10分钟以下', value: 1 },
  { label: '10-30分钟', value: 2 },
  { label: '30-60分钟', value: 3 },
  { label: '60分钟以上', value: 4 },
];

// 视频发布时间筛选（value 为秒数偏移，客户端换算 pubtime_begin_s/pubtime_end_s）
export const VIDEO_PUBTIME_OPTIONS: Array<SearchNumOption> = [
  { label: '不限', value: 0 },
  { label: '一天内', value: 86400 },
  { label: '一周内', value: 604800 },
  { label: '半年内', value: 15724800 },
];

// 视频分区筛选（tids 参数，取 PiliPlus VideoZoneType 主要分区）
export const VIDEO_ZONE_OPTIONS: Array<SearchNumOption> = [
  { label: '不限', value: 0 },
  { label: '动画', value: 1 },
  { label: '音乐', value: 3 },
  { label: '游戏', value: 4 },
  { label: '知识', value: 36 },
  { label: '科技', value: 188 },
  { label: '生活', value: 160 },
  { label: '舞蹈', value: 129 },
  { label: '鬼畜', value: 119 },
  { label: '影视', value: 181 },
  { label: '美食', value: 221 },
];

// ===== 用户空间：用户信息（x/space/wbi/acc/info） =====
/** 用户空间普通/典藏头图。动画典藏仅让当前页加载 video，preview 用于相邻页预览。 */
export class UserSpaceHeaderItem {
  preview: string = '';
  fullCover: string = '';
  animationUrl: string = '';
  sourceWidth: number = 0;
  sourceHeight: number = 0;
  focusX: number = 0.5;
  focusY: number = 0.5;
}

export class UserSpaceInfo {
  mid: number = 0;
  name: string = '';
  face: string = '';
  sex: string = '';
  sign: string = '';
  level: number = 0;
  officialType: number = -1;   // 0 个人认证 1 机构认证 -1 无认证
  officialDesc: string = '';
  topPhoto: string = '';       // 空间头图，可能没有
  topPhotoDark: string = '';   // App 空间装扮提供的深色头图
  collectionHeaders: Array<UserSpaceHeaderItem> = []; // 典藏卡头图（静态或 MP4 动画）
  pendant: string = '';        // 头像框/头像挂件
  liveStatus: number = 0;
  liveRoomId: number = 0;
  liveTitle: string = '';
  liveCover: string = '';
  // 空间统计：x/space/wbi/acc/info 响应自带 stat 字段
  // （/x/relation/stat 已半废弃，2025 起大量返回空，这里直接复用 acc/info 的数值）。
  follower: number = 0;
  following: number = 0;
  likeNum: number = 0;

  static from(o: Object): UserSpaceInfo {
    const j: Record<string, Object> = asObject(o);
    const stat: Record<string, Object> = asObject(j['stat']);
    const u: UserSpaceInfo = new UserSpaceInfo();
    u.mid = asNumber(j['mid'], 0);
    u.name = str(j, 'name', '');
    // search/type 的 bili_user 结果使用 upic；部分旧接口才返回 face。
    u.face = toHttps(str(j, 'upic', str(j, 'face', '')));
    u.sex = str(j, 'sex', '');
    u.sign = str(j, 'sign', '');
    u.level = asNumber(j['level'], 0);
    const official: Record<string, Object> = asObject(j['official']);
    u.officialType = asNumber(official['type'], -1);
    u.officialDesc = str(official, 'title', str(official, 'desc', ''));
    u.topPhoto = toHttps(str(j, 'top_photo', ''));
    const pendant: Record<string, Object> = asObject(j['pendant']);
    u.pendant = toHttps(str(pendant, 'image', ''));
    // x/space/wbi/acc/info 的直播字段使用 live_room.liveStatus / roomid。
    // 同时兼容少量代理接口返回的 snake_case 字段。
    const liveRoom: Record<string, Object> = asObject(j['live_room']);
    u.liveStatus = asNumber(liveRoom['liveStatus'], asNumber(liveRoom['live_status'], 0));
    u.liveRoomId = asNumber(liveRoom['roomid'], asNumber(liveRoom['room_id'], 0));
    u.liveTitle = str(liveRoom, 'title', '');
    u.liveCover = toHttps(str(liveRoom, 'cover', str(liveRoom, 'keyframe', '')));
    u.follower = asNumber(stat['follower'], 0);
    u.following = asNumber(stat['following'], 0);
    u.likeNum = asNumber(stat['like_num'], 0);
    return u;
  }
}

// ===== 用户空间：投稿分页结果 =====
export class SpaceArcData {
  videos: Array<VideoItem> = [];
  total: number = 0;
}

// ===== 分类搜索结果（携带 numResults 总数，用于结果页 Tab 徽标） =====
export class VideoSearchResult {
  videos: Array<VideoItem> = [];
  numResults: number = 0;
}

export class UserSearchResult {
  users: Array<UserSearchItem> = [];
  numResults: number = 0;
}
export class UserSearchItem {
  mid: number = 0;
  uname: string = '';
  face: string = '';
  fans: number = 0;
  videos: number = 0;
  usign: string = '';
  level: number = 0;
  verifyType: number = -1;   // 0 个人认证 1 机构认证 -1 无认证
  verifyDesc: string = '';
  liveStatus: number = 0;
  liveRoomId: number = 0;
  /** 综合搜索用户卡片自带的近期投稿（all/v2 的 res 字段）。 */
  recentVideos: Array<VideoItem> = [];

  static from(o: Object): UserSearchItem {
    const j: Record<string, Object> = asObject(o);
    const u: UserSearchItem = new UserSearchItem();
    u.mid = asNumber(j['mid'], 0);
    // 昵称里可能包含高亮 <em> 标签，去除
    u.uname = str(j, 'uname', '').replace(/<[^>]*>/g, '');
    // search/type 的 bili_user 返回 upic；face/pic/avatar 仅用于兼容旧版和代理接口。
    u.face = toHttps(str(j, 'upic', str(j, 'face', str(j, 'pic', str(j, 'avatar', '')))));
    u.fans = asNumber(j['fans'], 0);
    u.videos = asNumber(j['videos'], 0);
    u.usign = str(j, 'usign', '');
    u.level = asNumber(j['level'], 0);
    const verify: Record<string, Object> = asObject(j['official_verify']);
    u.verifyType = asNumber(verify['type'], -1);
    u.verifyDesc = str(verify, 'desc', '');
    u.liveStatus = asNumber(j['is_live'], asNumber(j['live_status'], 0));
    u.liveRoomId = asNumber(j['room_id'], asNumber(j['roomid'], 0));
    const recent: Array<Object> = asArray(j['res']);
    for (let i: number = 0; i < recent.length; i++) {
      const video: VideoItem = VideoItem.fromSearchItem(recent[i]);
      if (video.aid <= 0 && video.bvid.length === 0) continue;
      if (video.upName.length === 0) video.upName = u.uname;
      if (video.upMid <= 0) video.upMid = u.mid;
      u.recentVideos.push(video);
    }
    return u;
  }
}

// ===== 番剧/影视搜索（media_bangumi / media_ft，参考 PiliPlus SearchPgcItemModel） =====
export class PgcSearchItem {
  seasonId: number = 0;
  title: string = '';
  cover: string = '';
  areas: string = '';
  styles: string = '';
  desc: string = '';
  score: number = 0;
  /** 连载状态，如「已完结」「更新至第12话」 */
  indexShow: string = '';
  /** 类型角标，如「番剧」「电影」 */
  seasonTypeName: string = '';

  static from(o: Object): PgcSearchItem {
    const j: Record<string, Object> = asObject(o);
    const item: PgcSearchItem = new PgcSearchItem();
    item.seasonId = asNumber(j['season_id'], 0);
    // 搜索标题可能带高亮 <em> 标签，去除
    item.title = str(j, 'title', '').replace(/<[^>]*>/g, '');
    item.cover = toHttps(str(j, 'cover', ''));
    item.areas = str(j, 'areas', '');
    item.styles = str(j, 'styles', '');
    item.desc = str(j, 'desc', '').replace(/<[^>]*>/g, '');
    item.indexShow = str(j, 'index_show', '');
    item.seasonTypeName = str(j, 'season_type_name', '');
    const mediaScore: Record<string, Object> = asObject(j['media_score']);
    item.score = asNumber(mediaScore['score'], 0);
    return item;
  }

  /** 评分文案，无评分时为空串 */
  scoreText(): string {
    return this.score > 0 ? this.score.toFixed(1) + '分' : '';
  }
}

export class PgcSearchResult {
  items: Array<PgcSearchItem> = [];
  numResults: number = 0;
}

// ===== 直播搜索（live_room）结果包装，条目解析见 LiveModels.LiveRoomItem.fromSearch =====
// ===== 专栏搜索（article，参考 PiliPlus SearchArticleItemModel） =====
export class ArticleSearchItem {
  id: number = 0;
  title: string = '';
  desc: string = '';
  cover: string = '';
  mid: number = 0;
  upName: string = '';
  view: number = 0;
  reply: number = 0;
  like: number = 0;
  categoryName: string = '';

  static from(o: Object): ArticleSearchItem {
    const j: Record<string, Object> = asObject(o);
    const item: ArticleSearchItem = new ArticleSearchItem();
    item.id = asNumber(j['id'], 0);
    item.title = str(j, 'title', '').replace(/<[^>]*>/g, '');
    item.desc = str(j, 'desc', '').replace(/<[^>]*>/g, '');
    const imageUrls: Array<Object> = asArray(j['image_urls']);
    if (imageUrls.length > 0) {
      item.cover = toHttps(asString(imageUrls[0], ''));
    }
    item.mid = asNumber(j['mid'], 0);
    // 文章搜索多数时候不返回昵称，保留 author/uname 兜底
    item.upName = str(j, 'author', str(j, 'uname', '')).replace(/<[^>]*>/g, '');
    item.view = asNumber(j['view'], 0);
    item.reply = asNumber(j['reply'], 0);
    item.like = asNumber(j['like'], 0);
    item.categoryName = str(j, 'category_name', '');
    return item;
  }
}

export class ArticleSearchResult {
  articles: Array<ArticleSearchItem> = [];
  numResults: number = 0;
}

// ===== 综合搜索（all/v2）聚合结果：按 result_type 分区，仅第一页包含番剧/用户分区 =====
export class SearchAllSection {
  /** video / bili_user / media_bangumi / media_ft / article */
  type: string = '';
  videos: Array<VideoItem> = [];
  users: Array<UserSearchItem> = [];
  pgc: Array<PgcSearchItem> = [];
  articles: Array<ArticleSearchItem> = [];
}

export class SearchAllResult {
  sections: Array<SearchAllSection> = [];
  /** 各分类结果总数徽标（data.pageinfo），key 为 result_type */
  totals: Map<string, number> = new Map<string, number>();
}

// ===== 排行榜 / 必看榜单 =====
/** popular/series/list 项：每周必看期号 */
export class PopularSeriesItem {
  number: number = 0;
  name: string = '';

  static from(o: Object): PopularSeriesItem {
    const j: Record<string, Object> = asObject(o);
    const item: PopularSeriesItem = new PopularSeriesItem();
    item.number = asNumber(j['number'], 0);
    item.name = str(j, 'name', '');
    return item;
  }
}

/** popular/series/one 结果：期次信息 + 视频列表 */
export class PopularSeriesData {
  label: string = '';
  name: string = '';
  reminder: string = '';
  videos: Array<VideoItem> = [];
}

/** 索引列表中的单部番剧/作品（pgc/season/index/result 的 list 元素）。 */
export class BangumiIndexItem {
  seasonId: number = 0;
  title: string = '';
  /** 副标题（"携手保护独角兽岛" 等） */
  subTitle: string = '';
  /** 封面（竖版横版自适应，优先竖版） */
  cover: string = '';
  /** 更新状态描述（"更新至第18话" / 评分） */
  indexShow: string = '';
  /** 会员/付费角标，空串表示免费 */
  badge: string = '';
  score: string = '';
  isFinish: boolean = false;
  /** 分季类型：1番剧 2国创 3纪录片 4电影 5电视剧 */
  seasonType: number = 1;
  /** 今日/星期更新提示（"今天10:00更新" 等） */
  orderP: string = '';
  /** 海报角标色 */
  badgeBgColor: string = '#FB7299';

  static from(o: Object): BangumiIndexItem {
    const j: Record<string, Object> = asObject(o);
    const item: BangumiIndexItem = new BangumiIndexItem();
    item.seasonId = asNumber(j['season_id'], 0);
    item.title = str(j, 'title', '');
    item.subTitle = str(j, 'subTitle', '');
    item.cover = toHttps(str(j, 'cover', ''));
    item.indexShow = str(j, 'index_show', '');
    item.isFinish = asNumber(j['is_finish'], 0) === 1;
    item.seasonType = asNumber(j['season_type'], 1);
    item.orderP = str(j, 'order', '');
    // score 字段可能为空字符串或缺省。
    const score: Object = j['score'];
    item.score = typeof score === 'string' ? score as string : str(j, 'score', '');
    const badgeInfo: Record<string, Object> = asObject(j['badge_info']);
    item.badge = str(badgeInfo, 'text', str(j, 'badge', ''));
    const bg: string = str(badgeInfo, 'bg_color', '');
    if (bg.length > 0) item.badgeBgColor = bg;
    // cover 缺竖版时回退 first_ep.cover 或横版 cover。
    if (item.cover.length === 0) {
      item.cover = toHttps(str(asObject(j['first_ep']), 'cover', ''));
    }
    return item;
  }
}

/** 番剧索引分页返回（pgc/season/index/result 的 data）。 */
export class BangumiIndexPageData {
  items: Array<BangumiIndexItem> = [];
  hasNext: boolean = false;
  total: number = 0;
}

/** 用户追番/追剧列表中的单部作品（pgc/web/follow/list 的 list 元素）。 */
export class WatchLaterSeasonItem {
  seasonId: number = 0;
  title: string = '';
  /** 状态描述（"已更新至第 x 话" / "已完结" 等） */
  desc: string = '';
  /** 封面（竖版） */
  cover: string = '';
  /** 追番/追剧标识，如"番剧" */
  typeText: string = '';
  /** 追番数等副信息 */
  subText: string = '';
  /** 最新剧集描述 */
  newEpDesc: string = '';
  followed: boolean = true;

  static from(o: Object): WatchLaterSeasonItem {
    const j: Record<string, Object> = asObject(o);
    const item: WatchLaterSeasonItem = new WatchLaterSeasonItem();
    item.seasonId = asNumber(j['season_id'], 0);
    item.title = str(j, 'title', '');
    item.desc = str(j, 'desc', '');
    // new_ep 是对象（含 index/title/cover），不要直接 str()；优先用接口的文案字段。
    const newEpRaw: Record<string, Object> = asObject(j['new_ep']);
    const newEpTitle: string = str(newEpRaw, 'title', '');
    const newEpDesc: string = str(j, 'new_ep_desc', '');
    if (newEpDesc.length > 0) {
      item.newEpDesc = newEpDesc;
    } else if (newEpTitle.length > 0) {
      item.newEpDesc = newEpTitle;
    } else {
      item.newEpDesc = '';
    }
    item.cover = toHttps(str(j, 'square_cover', str(j, 'cover', '')));
    // season_type_name 是字符串字段（不是对象），旧代码却把它当对象 + '' 取 key，
    // 恒取到空串，然后凭空 fallback，属于拼写/类型不匹配 bug。
    item.typeText = str(j, 'season_type_name', '');
    if (item.typeText.length === 0) {
      item.typeText = str(j, 'type_name', '');
    }
    const stat: Record<string, Object> = asObject(j['stat']);
    const count: number = asNumber(stat['favorites'], 0);
    const play: number = asNumber(stat['views'], 0);
    item.subText = (play > 0 ? formatCount(play) + ' 播放' : '') +
      (count > 0 ? ' · ' + formatCount(count) + ' 追番' : '');
    return item;
  }
}

// ===== 新番时间表（pgc/web/timeline） =====

/** 时间表里的一天（date 空表示"未知日期"）。 */
export class TimeLineDay {
  date: string = '';
  /** 1-7 对应 周一~周日 */
  dayOfWeek: number = 0;
  episodes: Array<TimeLineEpisode> = [];

  weekLabel(week: Array<string>): string {
    if (this.dayOfWeek >= 1 && this.dayOfWeek <= 7) return week[this.dayOfWeek - 1];
    return '';
  }

  dayOfWeekLabel(): string {
    const week: Array<string> = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return this.weekLabel(week);
  }
}

/** 时间表单集播放项。 */
export class TimeLineEpisode {
  seasonId: number = 0;
  seasonType: number = 1;
  title: string = '';
  cover: string = '';
  /** 集数描述（"第1话" / 空） */
  index: string = '';
  /** 开播时间（"10:00"） */
  pubTime: string = '';
  /** 电视台/来源（如 "bilibili"） */
  badge: string = '';

  static from(o: Object): TimeLineEpisode {
    const j: Record<string, Object> = asObject(o);
    const ep: TimeLineEpisode = new TimeLineEpisode();
    ep.seasonId = asNumber(j['season_id'], 0);
    ep.seasonType = asNumber(j['season_type'], 1);
    ep.title = str(j, 'title', '');
    ep.cover = toHttps(str(j, 'cover', ''));
    ep.index = str(j, 'index', '');
    ep.pubTime = str(j, 'pub_time', '');
    ep.badge = str(j, 'badge', '');
    return ep;
  }
}
