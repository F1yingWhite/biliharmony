import { UIContext } from '@kit.ArkUI';
import { MotionTokens } from '../../common/MotionTokens';
import { DynamicItem } from '../../model/Models';
import { AppNavStack, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  NAV_DYNAMIC_DETAIL, NAV_IMAGE_VIEWER, NAV_LIVE_ROOM, NAV_VIDEO_DETAIL, DynamicDetailParam,
  ImageViewerParam, ImageViewerSrcRect, LiveRoomParam, VideoDetailParam, NAV_BANGUMI_DETAIL,
  BangumiDetailParam, setHeroBgSnapshot } from '../../common/AppRouter';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { image } from '@kit.ImageKit';

/** 卡片导航和共享元素几何采集，不持有业务状态或发起动态请求。 */
export class DynamicCardNavigation {
  private item: DynamicItem;
  private detailMode: boolean;
  private sharedImageTransition: boolean;
  private idPrefix: string;
  private getUIContext: () => UIContext;

  constructor(item: DynamicItem, detailMode: boolean, sharedImageTransition: boolean,
    idPrefix: string, getUIContext: () => UIContext) {
    this.item = item;
    this.detailMode = detailMode;
    this.sharedImageTransition = sharedImageTransition;
    this.idPrefix = idPrefix;
    this.getUIContext = getUIContext;
  }

  bind(item: DynamicItem, detailMode: boolean, sharedImageTransition: boolean, idPrefix: string): void {
    this.item = item;
    this.detailMode = detailMode;
    this.sharedImageTransition = sharedImageTransition;
    this.idPrefix = idPrefix;
  }

  imgId(dynId: string, index: number): string {
    return this.idPrefix + 'dynamic-host-' + this.item.dynId + '-img-' + dynId + '-' + String(index);
  }

  imgTransitionId(dynId: string, index: number): string {
    return this.idPrefix + 'image-viewer-host-' + this.item.dynId + '-img-' + dynId + '-' + String(index);
  }

  cardId(): string {
    return this.idPrefix + 'dynamic-card-' + this.item.dynId;
  }

  videoCoverId(item: DynamicItem): string {
    const videoId: string = item.bvid.length > 0 ? item.bvid : 'a' + String(item.aid);
    return this.idPrefix + 'dynamic-video-host-' + this.item.dynId + '-cover-' + item.dynId + '-' + videoId;
  }

  videoCardId(item: DynamicItem): string {
    const videoId: string = item.bvid.length > 0 ? item.bvid : 'a' + String(item.aid);
    return this.idPrefix + 'dynamic-video-host-' + this.item.dynId + '-card-' + item.dynId + '-' + videoId;
  }

  openDetail(focusComments: boolean = false): void {
    if (this.detailMode || this.item.dynId.length === 0) return;
    if (MotionTokens.isReduced()) {
      const direct: DynamicDetailParam = { item: this.item as Object, focusComments: focusComments };
      AppNavStack.pushPathByName(NAV_DYNAMIC_DETAIL, direct, false);
      return;
    }
    let srcRect: ImageViewerSrcRect | undefined = undefined;
    try {
      const area = this.getUIContext().getComponentUtils().getRectangleById(this.cardId());
      if (area.size.width > 0 && area.size.height > 0 && area.windowOffset.x >= 0) {
        srcRect = {
          x: this.getUIContext().px2vp(area.windowOffset.x),
          y: this.getUIContext().px2vp(area.windowOffset.y),
          w: this.getUIContext().px2vp(area.size.width),
          h: this.getUIContext().px2vp(area.size.height),
        };
      }
    } catch (e) {
      // 取不到卡片矩形时保持普通导航。
    }
    const param: DynamicDetailParam = { item: this.item as Object, focusComments: focusComments, srcRect: srcRect };
    if (srcRect !== undefined) {
      AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
      AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 380);
    }
    AppNavStack.pushPathByName(NAV_DYNAMIC_DETAIL, param);
  }

  openItemDetail(item: DynamicItem): void {
    if (item.dynId.length === 0) return;
    const param: DynamicDetailParam = { item: item as Object };
    AppNavStack.pushPathByName(NAV_DYNAMIC_DETAIL, param);
  }

  openLive(item: DynamicItem): void {
    if (item.liveRoomId <= 0) return;
    const param: LiveRoomParam = {
      roomId: item.liveRoomId,
      uid: item.liveUid > 0 ? item.liveUid : item.mid,
      title: item.title,
      uname: item.uname,
      face: item.face,
      cover: item.cover,
    };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  openMajor(item: DynamicItem): void {
    if (item.liveRoomId > 0) {
      this.openLive(item);
    } else if (item.seasonId > 0 || item.epId > 0) {
      // PGC（番剧/影视）卡片进番剧详情页；UGC 合集卡没有 season_id/epid，仍走视频详情。
      const param: BangumiDetailParam = { seasonId: item.seasonId, epId: item.epId, title: item.title };
      AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
    } else if (item.bvid.length > 0 || item.aid > 0) {
      this.openVideo(item);
    } else {
      this.openItemDetail(item);
    }
  }

  /** 动态里的投稿视频与首页视频共用整卡扩展；快照失败时回退原有封面转场。 */
  openVideo(item: DynamicItem): void {
    const entryCoverWidth: number = item.dynId === this.item.dynId ? 480 : 240;
    const param: VideoDetailParam = {
      bvid: item.bvid,
      aid: item.aid,
      title: item.title,
      // 与卡片实际显示的缩略图保持同一 URL，hero 可直接复用已解码纹理。
      cover: biliImageThumbnail(item.cover, entryCoverWidth),
      // 动态流位于根 Tabs 的懒加载列表中，视频页覆盖期间来源卡可能被回收。
      // 保留入场放大，返回使用普通出栈，避免详情页缩回后因目标节点缺失而悬停。
      mirrorHeroReturn: false,
    };
    if (MotionTokens.isReduced()) {
      AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param, false);
      return;
    }
    try {
      const cardArea = this.getUIContext().getComponentUtils().getRectangleById(this.videoCardId(item));
      if (cardArea.size.width > 0 && cardArea.size.height > 0 &&
        cardArea.windowOffset.x >= 0 && cardArea.windowOffset.y >= 0) {
        const snapshot: image.PixelMap = this.getUIContext().getComponentSnapshot().getSync(this.videoCardId(item), {
          waitUntilRenderFinished: true,
        });
        param.cardRect = {
          x: this.getUIContext().px2vp(cardArea.windowOffset.x),
          y: this.getUIContext().px2vp(cardArea.windowOffset.y),
          w: this.getUIContext().px2vp(cardArea.size.width),
          h: this.getUIContext().px2vp(cardArea.size.height),
        };
        setHeroBgSnapshot(snapshot);
        AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
        AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
        return;
      }
    } catch (e) {
      // 组件快照不可用时继续走下方已验证的封面矩形动画。
    }
    let srcRect: ImageViewerSrcRect | undefined = undefined;
    try {
      const area = this.getUIContext().getComponentUtils().getRectangleById(this.videoCoverId(item));
      if (area.size.width > 0 && area.size.height > 0 && area.windowOffset.x >= 0 && area.windowOffset.y >= 0) {
        srcRect = {
          x: this.getUIContext().px2vp(area.windowOffset.x),
          y: this.getUIContext().px2vp(area.windowOffset.y),
          w: this.getUIContext().px2vp(area.size.width),
          h: this.getUIContext().px2vp(area.size.height),
        };
      }
    } catch (e) {
      // 无封面或尚未完成布局时退回普通导航。
    }
    if (srcRect !== undefined) {
      param.srcRect = srcRect;
      AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
      AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
    }
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  openItemImage(item: DynamicItem, index: number): void {
    const images: Array<string> = item.images;
    if (MotionTokens.isReduced()) {
      const direct: ImageViewerParam = { images: images, initialIndex: index };
      AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, direct, false);
      return;
    }
    const rects: Array<ImageViewerSrcRect> = this.collectImageRects(item);
    const rect: ImageViewerSrcRect | undefined = index < rects.length && rects[index].w > 0 ? rects[index] : undefined;
    const ids: Array<string> = [];
    const transitionIds: Array<string> = [];
    const previews: Array<string> = [];
    for (let i: number = 0; i < images.length; i++) {
      // 第 10 张以后都由第 9 格的“+N”入口承载，返回时也以该格为实时目标。
      ids.push(this.imgId(item.dynId, Math.min(i, 8)));
      transitionIds.push(this.imgTransitionId(item.dynId, Math.min(i, 8)));
      previews.push(biliImageThumbnail(images[i], images.length === 1 ? 900 : 320));
    }
    const viewer: ImageViewerParam = {
      images: images,
      initialIndex: index,
      srcRect: rect,
      srcRects: rects,
      srcIds: ids,
      srcPreviews: previews,
    };
    if (this.sharedImageTransition) {
      viewer.transitionId = this.imgTransitionId(item.dynId, Math.min(index, 8));
      viewer.transitionIds = transitionIds;
    }
    this.pushViewer(viewer);
  }

  /** 记录宫格每一格的窗口矩形；超过 9 张的图片统一收回“+N”所在的第 9 格。 */
  collectImageRects(item: DynamicItem): Array<ImageViewerSrcRect> {
    const rects: Array<ImageViewerSrcRect> = [];
    let overflowRect: ImageViewerSrcRect = { x: 0, y: 0, w: 0, h: 0 };
    for (let i: number = 0; i < item.images.length; i++) {
      if (i >= 9) {
        rects.push(overflowRect);
        continue;
      }
      let rect: ImageViewerSrcRect = { x: 0, y: 0, w: 0, h: 0 };
      try {
        const area = this.getUIContext().getComponentUtils().getRectangleById(this.imgId(item.dynId, i));
        if (area.size.width > 0 && area.size.height > 0 && area.windowOffset.x >= 0) {
          rect = {
            x: this.getUIContext().px2vp(area.windowOffset.x),
            y: this.getUIContext().px2vp(area.windowOffset.y),
            w: this.getUIContext().px2vp(area.size.width),
            h: this.getUIContext().px2vp(area.size.height),
          };
        }
      } catch (e) {
        // 未布局的格子保留零矩形，退出时退化为淡出。
      }
      rects.push(rect);
      if (i === 8) overflowRect = rect;
    }
    return rects;
  }

  /** 普通 Navigation 层级使用 geometryTransition；根 Tabs 则使用窗口矩形 hero 规避坐标系偏移。 */
  pushViewer(viewer: ImageViewerParam): void {
    if ((viewer.transitionId ?? '').length > 0) {
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
        AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer, false);
      });
      return;
    }
    AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
    AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
    AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer);
  }

}
