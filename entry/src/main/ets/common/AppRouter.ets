/**
 * 全局导航：Navigation 根（pages/Index）持有唯一 NavPathStack，
 * 全应用统一通过 AppNavStack 跳转（替代旧版 @kit.ArkUI router）。
 */
import { FavoriteFolderItem } from '../model/Models';

/** Index 根 Stack 的组件 id：需要整页过渡底衬时可截取该组件。 */
export const APP_ROOT_SNAPSHOT_ID: string = 'bili-app-root';

/** AppStorage 键：整卡一镜到底的临时 PixelMap。走 AppStorage 而非路由参数——NavPathStack 会克隆
 *  参数对象，原生 PixelMap 传不过去；push 前写入，目标页 aboutToAppear 读取并删除键。 */
export const HERO_BG_SNAPSHOT_KEY: string = 'heroBgSnapshot';
/** 使用 Navigation 官方自定义内容转场保活来源页，供独立 hero 在两页之上完成飞行。 */
export const HERO_NAV_TRANSITION_ACTIVE_KEY: string = 'heroNavTransitionActive';
export const HERO_NAV_TRANSITION_DURATION_KEY: string = 'heroNavTransitionDuration';
/** 页面内 hero 动画完成后递增，通知 Navigation 立即提交本次自定义转场。 */
export const HERO_NAV_TRANSITION_FINISH_REQUEST_KEY: string = 'heroNavTransitionFinishRequest';

/** 视频详情页跳转参数 */
export interface VideoDetailParam {
  bvid: string;
  aid: number;
  title: string;
  /** 卡片封面：detail 数据回来前先垫在播放区/底图，入场期不出"加载中"占位。 */
  cover?: string;
  /** 点击卡片的窗口矩形（vp）：有值时详情页从卡片位置手动放大入场（根页面 push 无共享元素转场）。 */
  srcRect?: ImageViewerSrcRect;
  /** 首页整卡一镜到底的窗口矩形（vp）；快照通过 HERO_BG_SNAPSHOT_KEY 单独传递。 */
  cardRect?: ImageViewerSrcRect;
  /** 是否在返回时镜面收回来源卡。Tabs 懒加载列表的来源节点不稳定，应设为 false 走普通出栈。 */
  mirrorHeroReturn?: boolean;
}

/** 用户空间页跳转参数 */
export interface UserSpaceParam {
  mid: number;
}

export interface RelationListParam {
  mid: number;
  mode: string; // following | follower
}

/** 直播间只读观看参数，列表信息用于首屏即时展示。 */
export interface LiveRoomParam {
  roomId: number;
  uid: number;
  title: string;
  uname: string;
  face: string;
  cover: string;
}

/** 收藏夹排序页参数：待排序的自建收藏夹（已去除默认收藏夹）。 */
export interface FavSortParam {
  folders: Array<FavoriteFolderItem>;
}

/** 全屏图片查看参数 */
export interface ImageViewerParam {
  images: Array<string>;
  initialIndex: number;
  /** ArkUI 原生共享元素 ID；来源图与查看器使用同一 ID 即可自动往返。 */
  transitionId?: string;
  /** 多图场景逐张对应的共享元素 ID；横滑后按当前图片匹配来源缩略格。 */
  transitionIds?: Array<string>;
  /** 源缩略图在窗口中的矩形（vp）。Tabs 内 geometryTransition 坐标系错乱（按 Tabs 轨道
   *  布局坐标计算，非首屏 tab 整体偏移 N 屏宽），此时改用本字段做手动"从缩略图放大"入场。 */
  srcRect?: ImageViewerSrcRect;
  /** 每张图片各自的源缩略图矩形；左右滑动后按 currentIndex 收回对应格子。 */
  srcRects?: Array<ImageViewerSrcRect>;
  /** 每张源缩略图的组件 ID；关闭前重新测量实时位置，避免列表滚动后飞回打开时的旧坐标。 */
  srcIds?: Array<string>;
  /** 来源页实际渲染的缩略图 URL；hero 复用已解码资源，避免换一档缩略图重新加载造成闪帧。 */
  srcPreviews?: Array<string>;
}

/** 源缩略图窗口矩形（vp 单位）。 */
export interface ImageViewerSrcRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 番剧/影视（PGC）详情页跳转参数；seasonId 与 epId 至少一个有效 */
export interface BangumiDetailParam {
  seasonId: number;
  epId: number;
  title: string;
}

/** 动态详情页参数。item 使用内存对象首屏直出，详情接口随后补全。 */
export interface DynamicDetailParam {
  item: Object;
  focusComments?: boolean;
  /** 点击的整张动态卡窗口矩形（vp），用于卡片容器展开到详情页并原路收回。 */
  srcRect?: ImageViewerSrcRect;
}

/** 专栏阅读页参数。 */
export interface ArticlePageParam {
  id: number;
  title: string;
}

/** NavDestination 路由名 */
export const NAV_SEARCH: string = 'Search';
export const NAV_VIDEO_DETAIL: string = 'VideoDetail';
export const NAV_LOGIN: string = 'Login';
export const NAV_USER_SPACE: string = 'UserSpace';
export const NAV_MESSAGES: string = 'Messages';
export const NAV_HISTORY: string = 'History';
export const NAV_FAVORITES: string = 'Favorites';
export const NAV_WATCH_LATER: string = 'WatchLater';
export const NAV_LIVE_ROOM: string = 'LiveRoom';
export const NAV_IMAGE_VIEWER: string = 'ImageViewer';
export const NAV_DYNAMIC_DETAIL: string = 'DynamicDetail';
export const NAV_RELATION_LIST: string = 'RelationList';
export const NAV_BANGUMI_DETAIL: string = 'BangumiDetail';
export const NAV_RANK: string = 'Rank';
export const NAV_ARTICLE: string = 'Article';
export const NAV_BANGUMI_LIST: string = 'BangumiList';
export const NAV_BANGUMI_INDEX: string = 'BangumiIndex';
export const NAV_ZONE: string = 'Zone';
export const NAV_BLACK_LIST: string = 'BlackList';
export const NAV_LIVE_ZONE: string = 'LiveZone';
export const NAV_FAV_SORT: string = 'FavSort';
export const NAV_BANGUMI_TIMELINE: string = 'BangumiTimeline';

/** 全局唯一导航栈，由 Index 页的 Navigation 挂载 */
export const AppNavStack: NavPathStack = new NavPathStack();
