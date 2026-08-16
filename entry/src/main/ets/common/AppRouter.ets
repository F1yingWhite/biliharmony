/**
 * 全局导航：Navigation 根（pages/Index）持有唯一 NavPathStack，
 * 全应用统一通过 AppNavStack 跳转（替代旧版 @kit.ArkUI router）。
 */

/** 视频详情页跳转参数 */
export interface VideoDetailParam {
  bvid: string;
  aid: number;
  title: string;
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

/** 全屏图片查看参数 */
export interface ImageViewerParam {
  images: Array<string>;
  initialIndex: number;
  /** ArkUI 原生共享元素 ID；来源图与查看器使用同一 ID 即可自动往返。 */
  transitionId?: string;
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

/** 全局唯一导航栈，由 Index 页的 Navigation 挂载 */
export const AppNavStack: NavPathStack = new NavPathStack();
