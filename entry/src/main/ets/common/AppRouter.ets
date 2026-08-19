/**
 * 全局导航：Navigation 根（pages/Index）持有唯一 NavPathStack，
 * 全应用统一通过 AppNavStack 跳转（替代旧版 @kit.ArkUI router）。
 */
import { FavoriteFolderItem } from '../model/Models';

/** 视频详情页跳转参数 */
export interface VideoDetailParam {
  bvid: string;
  aid: number;
  title: string;
  /** 点击卡片的窗口矩形（vp）：有值时详情页从卡片位置手动放大入场（根页面 push 无共享元素转场）。 */
  srcRect?: ImageViewerSrcRect;
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
  /** 源缩略图在窗口中的矩形（vp）。Tabs 内 geometryTransition 坐标系错乱（按 Tabs 轨道
   *  布局坐标计算，非首屏 tab 整体偏移 N 屏宽），此时改用本字段做手动"从缩略图放大"入场。 */
  srcRect?: ImageViewerSrcRect;
  /** 以全屏 Cover 形态展示时的关闭回调（Navigation 根页面无法走 NavDestination 转场，
   *  根页面 push 会被系统强制叠加从右滑入动画，故根页面场景改用 bindContentCover 呈现）。 */
  onRequestClose?: () => void;
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
