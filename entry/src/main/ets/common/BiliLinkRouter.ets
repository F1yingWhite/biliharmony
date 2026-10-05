import { BiliApi } from '../api/BiliApi';
import { DynamicItem, VideoDetail, VideoPage } from '../model/Models';
import { ArticlePageParam, BangumiDetailParam, DynamicDetailParam, LiveRoomParam, UserSpaceParam, VideoDetailParam,
  NAV_ARTICLE, NAV_BANGUMI_DETAIL, NAV_DYNAMIC_DETAIL, NAV_LIVE_ROOM, NAV_USER_SPACE, NAV_VIDEO_DETAIL } from './AppRouter';
import { BiliLinkTarget } from './BiliLinkParser';

export class BiliLinkNavigation {
  name: string = '';
  param: Object;

  constructor() {
    const initial: VideoDetailParam = { aid: 0, bvid: '', title: '' };
    this.param = initial;
  }
}

/** Existing page contracts own navigation, including CID-based multipart/time continuation. */
export async function createBiliLinkNavigation(target: BiliLinkTarget, title: string): Promise<BiliLinkNavigation> {
  const navigation: BiliLinkNavigation = new BiliLinkNavigation();
  if (target.kind === 'video') {
    const param: VideoDetailParam = { aid: target.aid, bvid: target.bvid, title: title };
    if (target.page > 1 || target.hasSeek) {
      const detail: VideoDetail | null = await BiliApi.getVideoDetail(target.aid, target.bvid);
      if (detail === null) throw new Error('视频链接已失效');
      const page: VideoPage | undefined = detail.pages.find((item: VideoPage): boolean => item.page === target.page);
      const cid: number = page !== undefined ? page.cid : (target.page === 1 ? detail.cid : 0);
      if (cid <= 0) throw new Error('视频分P不存在');
      param.cid = cid;
      param.resumePosition = target.seconds;
    }
    navigation.name = NAV_VIDEO_DETAIL;
    navigation.param = param;
  } else if (target.kind === 'bangumi') {
    const param: BangumiDetailParam = { seasonId: target.seasonId, epId: target.epId, title: title };
    navigation.name = NAV_BANGUMI_DETAIL; navigation.param = param;
  } else if (target.kind === 'space') {
    const param: UserSpaceParam = { mid: target.mid };
    navigation.name = NAV_USER_SPACE; navigation.param = param;
  } else if (target.kind === 'dynamic') {
    const item: DynamicItem = new DynamicItem(); item.dynId = target.dynId;
    const param: DynamicDetailParam = { item: item };
    navigation.name = NAV_DYNAMIC_DETAIL; navigation.param = param;
  } else if (target.kind === 'live') {
    const param: LiveRoomParam = { roomId: target.roomId, uid: 0, title: title, uname: '', face: '', cover: '' };
    navigation.name = NAV_LIVE_ROOM; navigation.param = param;
  } else if (target.kind === 'article') {
    const param: ArticlePageParam = { id: target.articleId, title: title };
    navigation.name = NAV_ARTICLE; navigation.param = param;
  }
  return navigation;
}
