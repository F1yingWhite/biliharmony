/**
 * 视频详情页：沉浸式播放器 + 封面取色动态主题 + 简介/评论/相关
 */
import { display, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { inputMethod } from '@kit.IMEKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Immersive } from '../common/Immersive';
import { Haptic } from '../common/Haptic';
import { AppNavStack, NAV_LOGIN, NAV_VIDEO_DETAIL, NAV_USER_SPACE, VideoDetailParam,
  UserSpaceParam } from '../common/AppRouter';
import { VideoDetail, VideoItem, ReplyItem, PlayUrlInfo, VideoPage, VideoQualityOption, VideoRelationState,
  BiliEmote, BiliEmotePackage, FavoriteFolderItem, UserStat, SpaceArcData, SubtitleTrack, UgcSeasonEpisode } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { PlayerView } from '../components/PlayerView';
import { PlayerDanmakuEngine } from '../components/PlayerDanmakuEngine';
import { LoadingView } from '../components/LoadingView';
import { ImageColor, ImagePalette } from '../common/ImageColor';
import { UserStore } from '../common/UserStore';
import { colorWithAlpha, formatCount, formatRelativeTime, formatDate, formatDuration } from '../common/Utils';
import { DecoratedAvatar, UserDecorationBanner } from '../components/UserDecorations';
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { PlayerCommandBus } from '../common/PlayerCommandBus';
import { BasicDataSource } from '../common/BasicDataSource';
import { ReplyReactionHooks, runReplyDislike, runReplyLike } from '../common/ReplyMutation';
import { ReplyCard } from '../components/ReplyCard';
import { ReplyComposer } from '../components/ReplyComposer';
import { ReplyEmotePanel } from '../components/ReplyEmotePanel';
import { ReplyThreadPanel } from '../components/ReplyThreadPanel';
import { VideoActionItem } from '../components/VideoActionItem';
import { buildReplyTree, ReplyTreeMeta, ReplyTreeSnapshot } from '../common/ReplyTree';
import { ReplyShareCard, makeReplyQr, sharePixelMapAsImage } from '../components/ReplyShareCard';
import { ReplySortChips } from '../components/ReplySortChips';
import { safeToast } from '../common/Toast';
import { CommentApi } from '../api/CommentApi';
import { FavoriteApi } from '../api/FavoriteApi';
import { FeedApi } from '../api/FeedApi';
import { HistoryApi } from '../api/HistoryApi';
import { UserApi } from '../api/UserApi';

/** 「加载更多」底部块参数：对象字面量按引用传入，状态变化才能驱动 @Builder 刷新。 */
interface LoadMoreFooterOptions {
  loading: boolean;
  hasMore: boolean;
  moreText: string;
  endText: string;
  onTap: () => void;
}

@Component
export struct VideoDetailPage {
  @State loading: boolean = true;
  @State errorText: string = '';
  @State detail: VideoDetail = new VideoDetail();
  @State playUrl: string = '';
  @State playUrls: Array<string> = [];
  @State playAudioUrls: Array<string> = [];
  @State qualityOptions: Array<VideoQualityOption> = [];
  @State subtitleTracks: Array<SubtitleTrack> = [];
  @State currentQuality: number = 0;
  @State currentCid: number = 0;
  @State currentPageIndex: number = 0;
  @State pageSwitchingCid: number = 0;
  @State playerSourceVersion: number = 0;
  @State initialSeekSeconds: number = 0;
  @State ugcCount: number = 0;
  @State ugcPanelOpen: boolean = false;
  @State related: Array<VideoItem> = [];
  @State relatedLoading: boolean = false;
  @State relatedLoadError: string = '';
  // 播完结束画面的推荐卡（推荐列表第一条 / 合集下一集）
  @State endRecTitle: string = '';
  @State endRecCover: string = '';
  @State endRecUpName: string = '';
  @State endRecPlayText: string = '';
  @State endRecDuration: number = 0;
  @State endRecToken: number = 0;
  /** 播完态：播放区高度收敛为统一的推荐画面高度；重播/换视频/恢复播放时复位。 */
  @State playerEnded: boolean = false;
  @State upFollowerCount: number = -1;
  @State upVideoCount: number = -1;
  @State replyCursor: string = '';
  @State replyHasMore: boolean = true;
  @State replyLoading: boolean = false;
  @State replyPrefetchCount: number = 0;
  // 回复详情是视频页内的二级导航状态；放入 AppStorage 供 NavDestination
  // 的系统返回/侧滑回调优先关闭，避免直接把整个视频页弹出。
  @StorageLink('videoReplyThreadOpen') replyThreadOpen: boolean = false;
  @StorageLink('videoReplyThreadCloseRequest') @Watch('onReplyThreadCloseRequested') replyThreadCloseRequest: number = 0;
  @State replyThreadRoot: ReplyItem = new ReplyItem();
  @State threadPage: number = 0;
  @State threadHasMore: boolean = true;
  @State threadLoading: boolean = false;
  @State threadPrefetchCount: number = 0;
  @State replyTargetRpid: number = 0;
  @State replyTargetName: string = '';
  @State replyFocusTick: number = 0;
  @State replyDraft: string = '';
  @State replySending: boolean = false;
  @State replyLikeVersion: number = 0;
  @State replyViewOffsetY: number = 0;
  @State replyViewOpacity: number = 1;
  @State replySortMode: number = 3; // 3 热度，2 时间
  @State emotePackages: Array<BiliEmotePackage> = [];
  @State emotePackageIndex: number = 0;
  @State emotePanelOpen: boolean = false;
  @State emoteLoading: boolean = false;
  @State tab: number = 0; // 0 简介 / 1 评论（相关推荐已并入简介底部）
  @State visualTab: number = 0; // 仅驱动标签颜色/下划线，不反向打断 Tabs 位移动画
  @State descExpanded: boolean = false;
  @State descNeedsExpand: boolean = false;
  @State pageTint: string = '#FB7299';
  @State liked: boolean = false;
  @State disliked: boolean = false;
  @State coinCountByMe: number = 0;
  @State likeCount: number = 0;
  @State coinCount: number = 0;
  @State favoriteCount: number = 0;
  @State favorited: boolean = false;
  @State actionBusy: boolean = false;
  @State coinSheetOpen: boolean = false;
  @State coinChoice: number = 1;
  @State coinWithLike: boolean = true;
  @State following: boolean = false;
  @State followLoading: boolean = false;
  @State @Watch('onPlayerGeomChanged') playerFullscreen: boolean = false;
  @State playerPlaying: boolean = false;
  /** 播放器上报的在线观看人数（"X人正在看"），展示在播放量信息行的时间后面。 */
  @State playerOnlineTotal: string = '';
  @State @Watch('onPlayerGeomChanged') playerCollapse: number = 0;
  /** AVPlayer 解码后回传的真实视频尺寸；未拿到前先用接口 dimension 兜底。 */
  @State realVideoWidth: number = 0;
  @State realVideoHeight: number = 0;
  @State danmakuOn: boolean = true;
  @State danmakuDraft: string = '';
  @State danmakuSending: boolean = false;
  @State localDanmakuText: string = '';
  @State localDanmakuToken: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('loginVersion') @Watch('onLoginVersionChanged') loginVersion: number = 0;
  param: VideoDetailParam = { bvid: '', aid: 0, title: '' };
  private bvid: string = '';
  private aid: number = 0;
  private tabsController: TabsController = new TabsController();
  private introScroller: Scroller = new Scroller();
  private replyScroller: Scroller = new Scroller();
  private threadScroller: Scroller = new Scroller();
  private videoProgressSeconds: number = 0;
  private lastHeartbeatSeconds: number = -1;
  private pageSwitchRequest: number = 0;
  private relatedRecommendIdx: number = 0;
  private destroyed: boolean = false;
  private timers: Set<number> = new Set<number>();
  private replyLikeBusy: Set<number> = new Set<number>();
  private replyThreadAnimating: boolean = false;
  private likeActionVersion: number = 0;
  private coinActionVersion: number = 0;
  private favoriteActionVersion: number = 0;
  // 屏幕尺寸只在出现/布局变化时同步一次，避免滚动帧回调里反复 getDefaultDisplaySync。
  private screenWidthVp: number = 0;
  private screenHeightVp: number = 0;
  private playerHeightKey: string = '';
  private playerHeightValue: number = 0;
  /** 页面级弹幕独立层的画布上下文：下移给 PlayerView 换绑其弹幕引擎，画布移出被收起动画
   *  逐帧 resize 的播放器容器，消除动画期 Canvas 清缓冲导致的弹幕闪烁。 */
  private danmakuCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private dmEngineRef: PlayerDanmakuEngine | null = null;
  // playerCollapse 的未量化原值；@State 只按阈值量化写入，降低滚动期整页重排频率。
  private playerCollapseRaw: number = 0;
  private replySource: BasicDataSource<ReplyItem> = new BasicDataSource<ReplyItem>();
  private threadSource: BasicDataSource<ReplyItem> = new BasicDataSource<ReplyItem>();
  private ugcSource: BasicDataSource<UgcSeasonEpisode> = new BasicDataSource<UgcSeasonEpisode>();
  @State threadAllReplies: Array<ReplyItem> = [];
  private threadCollapsed: Set<number> = new Set<number>();
  // 回复详情里「回复 @xx」的昵称表，随楼层数据加载重建一次，替代逐条线性查找。
  private threadNameMap: Map<number, string> = new Map<number, string>();
  private threadMetaMap: Map<number, ReplyTreeMeta> = new Map<number, ReplyTreeMeta>();
  // 评论分享卡离屏渲染用的待截内容；只在生成分享图期间短暂赋值。
  private shareCardItem: ReplyItem = new ReplyItem();
  private shareCardQr: image.PixelMap | null = null;
  private shareCardBusy: boolean = false;

  onReplyThreadCloseRequested(): void {
    this.closeReplyThread();
  }

  closeReplyThread(): void {
    if (!this.replyThreadOpen) return;
    this.emotePanelOpen = false;
    this.replyThreadOpen = false;
    this.replyThreadAnimating = false;
  }

  /** 楼中楼里删掉一条子回复：连同其子孙一起从 threadSource 移除。 */
  private threadRemoveReply(target: ReplyItem): void {
    const blocked: Set<number> = new Set<number>();
    blocked.add(target.rpid);
    // 收集 target 的直接子回复（rootRpid=target.rpid）及更外层子孙，用深度优先收集。
    let changed: boolean = true;
    const all: Array<ReplyItem> = this.threadSource.getAll();
    while (changed) {
      changed = false;
      for (let i: number = 0; i < all.length; i++) {
        if (!blocked.has(all[i].rpid) && blocked.has(all[i].rootRpid)) {
          blocked.add(all[i].rpid);
          changed = true;
        }
      }
    }
    this.threadSource.reset(all.filter((x: ReplyItem) => !blocked.has(x.rpid)));
  }

  private refreshScreenSize(): void {
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      this.screenWidthVp = this.getUIContext().px2vp(screen.width);
      this.screenHeightVp = this.getUIContext().px2vp(screen.height);
      // 旋转/分屏后屏幕尺寸变化，弹幕视口一并同步。
      this.syncDanmakuViewport();
    } catch (e) {
      // 读取失败保留旧值，playerHeight 会回退到默认高度。
    }
  }

  private playerHeight(): number {
    const key: string = String(this.currentCid) + '|' + String(this.detail.aid) + '|' +
      String(this.screenWidthVp) + 'x' + String(this.screenHeightVp) + '|' +
      String(this.realVideoWidth) + 'x' + String(this.realVideoHeight);
    if (key === this.playerHeightKey && this.playerHeightValue > 0) return this.playerHeightValue;
    const value: number = this.computePlayerHeight();
    this.playerHeightKey = key;
    this.playerHeightValue = value;
    return value;
  }

  private resetPlaybackSize(): void {
    this.realVideoWidth = 0;
    this.realVideoHeight = 0;
    this.playerHeightValue = 0;
  }

  private onVideoSizeChange(width: number, height: number): void {
    if (width <= 0 || height <= 0) return;
    if (this.realVideoWidth === width && this.realVideoHeight === height) return;
    this.realVideoWidth = width;
    this.realVideoHeight = height;
    this.playerHeightValue = 0;
    // 真实画幅变化会改变播放区高度，弹幕视口一并同步。
    this.syncDanmakuViewport();
  }

  private computePlayerHeight(): number {
    try {
      if (this.screenWidthVp <= 0 || this.screenHeightVp <= 0) this.refreshScreenSize();
      if (this.screenWidthVp <= 0 || this.screenHeightVp <= 0) return 220;
      const widthVp: number = this.screenWidthVp;
      const usableHeight: number = Math.max(480,
        this.screenHeightVp - Immersive.statusBarHeight() - Immersive.bottomInset());
      // 常规横屏按 16:9；竖屏按真实比例增高，最高不超过可用高度，优先避免被 AVPlayer 裁掉上下区域。
      const regularHeight: number = widthVp * 9 / 16;
      // 竖屏视频封顶到可用高度的 60%：避免几乎占满整屏挤没评论区，想看大图可走竖屏全屏。
      const maximumHeight: number = Math.max(regularHeight, Math.floor(usableHeight * 0.6));
      let videoWidth: number = this.realVideoWidth > 0 ? this.realVideoWidth : this.detail.width;
      let videoHeight: number = this.realVideoHeight > 0 ? this.realVideoHeight : this.detail.height;
      let videoRotate: number = this.detail.rotate;
      for (let i: number = 0; i < this.detail.pages.length; i++) {
        if (this.detail.pages[i].cid === this.currentCid && this.detail.pages[i].width > 0 &&
          this.detail.pages[i].height > 0) {
          if (this.realVideoWidth <= 0 || this.realVideoHeight <= 0) {
            videoWidth = this.detail.pages[i].width;
            videoHeight = this.detail.pages[i].height;
          }
          videoRotate = this.detail.pages[i].rotate;
          break;
        }
      }
      if ((this.realVideoWidth <= 0 || this.realVideoHeight <= 0) && Math.abs(videoRotate) % 180 !== 0) {
        const rotatedWidth: number = videoHeight;
        videoHeight = videoWidth;
        videoWidth = rotatedWidth;
      }
      if (videoWidth <= 0 || videoHeight <= 0) return regularHeight;
      const naturalHeight: number = widthVp * videoHeight / videoWidth;
      return Math.max(regularHeight, Math.min(maximumHeight, naturalHeight));
    } catch (e) {
      return 220;
    }
  }

  private minPlayerHeight(): number {
    // 播放中下限抬高到屏幕高的 1/4：竖屏/长屏视频在播放时不会被收成一条细横幅，
    // 画幅未知的加载期也能保持稳定高度，避免“有时很小有时很大”的跳变感。
    // 暂停后才允许收成 112vp 的继续播放横幅（能完整容纳暂停黑幕和居中继续播放提示）。
    if (this.playerPlaying && this.screenHeightVp > 0) {
      return Math.max(160, Math.floor(this.screenHeightVp / 4));
    }
    return 112;
  }

  /** 当前分 P 时长（秒）：弹幕分段数预估用；取不到时回退详情总时长。 */
  private currentPageDuration(): number {
    for (let i: number = 0; i < this.detail.pages.length; i++) {
      if (this.detail.pages[i].cid === this.currentCid && this.detail.pages[i].duration > 0) {
        return this.detail.pages[i].duration;
      }
    }
    return this.detail.duration;
  }

  /** 播放中仅长屏/竖向画幅收缩；暂停后任何画幅都可收成继续播放横幅。 */
  private shouldCollapsePlayer(): boolean {
    if (!this.playerPlaying) return true;
    let width: number = this.realVideoWidth > 0 ? this.realVideoWidth : this.detail.width;
    let height: number = this.realVideoHeight > 0 ? this.realVideoHeight : this.detail.height;
    let rotate: number = this.detail.rotate;
    for (let i: number = 0; i < this.detail.pages.length; i++) {
      if (this.detail.pages[i].cid === this.currentCid && this.detail.pages[i].width > 0 &&
        this.detail.pages[i].height > 0) {
        if (this.realVideoWidth <= 0 || this.realVideoHeight <= 0) {
          width = this.detail.pages[i].width;
          height = this.detail.pages[i].height;
        }
        rotate = this.detail.pages[i].rotate;
        break;
      }
    }
    if ((this.realVideoWidth <= 0 || this.realVideoHeight <= 0) && Math.abs(rotate) % 180 !== 0) {
      const oldWidth: number = width;
      width = height;
      height = oldWidth;
    }
    return width > 0 && height > width;
  }

  private visiblePlayerHeight(): number {
    // 播完推荐画面与原画幅解耦：统一收敛到一个固定合适高度（接近常规 16:9 播放区），
    // 竖屏长视频播完时不再拖着一整条高黑屏。
    if (this.playerEnded) {
      const widthVp: number = this.screenWidthVp > 0 ? this.screenWidthVp : 360;
      return Math.max(220, widthVp * 9 / 16);
    }
    const base: number = this.playerHeight();
    return Math.max(this.minPlayerHeight(), base - this.playerCollapse);
  }

  /** 弹幕独立层画布高度：收起动画期间保持恒定（展开态高度），只有外层裁剪窗口收缩。 */
  private danmakuCanvasHeight(): number {
    if (this.playerFullscreen) {
      return this.screenHeightVp > 0 ? this.screenHeightVp : 640;
    }
    return this.playerHeight();
  }

  /**
   * 弹幕引擎视口同步：视口恒等于画布尺寸（展开态/全屏高度），收起/展开只改外层裁剪窗口，
   * 弹幕轨道不重排、不跳变；超出可视区的弹幕留在原处被裁掉，重新拉大时原位显示。
   * setViewport 内部幂等（变化 <0.5vp 直接返回），可高频调用。
   */
  private syncDanmakuViewport(): void {
    const engine: PlayerDanmakuEngine | null = this.dmEngineRef;
    if (engine === null) return;
    if (this.screenWidthVp <= 0 || this.screenHeightVp <= 0) this.refreshScreenSize();
    if (this.screenWidthVp <= 0) return;
    const h: number = this.playerFullscreen ? this.screenHeightVp : this.playerHeight();
    if (h <= 0) return;
    engine.setViewport(this.screenWidthVp, h);
    // 暂停/缓冲时没有渲染循环，视口变化后补一帧避免画布空置（播放中由循环下一帧自然覆盖）。
    if (!this.playerPlaying && engine.active.length > 0) engine.drawFrame(false);
  }

  /** 播放器几何相关 @State（收起量/全屏）变化时同步弹幕视口。 */
  private onPlayerGeomChanged(): void {
    this.syncDanmakuViewport();
  }

  /** 回复详情只占用播放器下方的评论区，不再覆盖视频。 */
  private replySheetHeight(): number {
    if (this.screenHeightVp <= 0) this.refreshScreenSize();
    const available: number = this.screenHeightVp - Immersive.statusBarHeight() - this.visiblePlayerHeight();
    return Math.max(1, available);
  }

  onPlayerPlayingChange(playing: boolean): void {
    if (this.playerPlaying === playing) return;
    this.playerPlaying = playing;
    // 重播/恢复播放：退出播完态，播放区恢复原画幅高度。
    if (playing) this.playerEnded = false;
    if (playing === false) this.reportVideoHeartbeat(this.videoProgressSeconds, true);
  }

  private toast(message: string): void {
    safeToast(this.getUIContext(), message);
  }

  /** 播放进度心跳：播放中每 5 秒报一次；暂停/离场强制补报。未登录时 BiliApi 内部直接跳过。 */
  private reportVideoHeartbeat(seconds: number, force: boolean = false): void {
    if (seconds <= 0) return;
    if (force === false && (this.playerPlaying === false || seconds - this.lastHeartbeatSeconds < 5)) return;
    this.lastHeartbeatSeconds = seconds;
    BiliApi.reportHeartbeat(this.detail.aid, this.detail.bvid, this.currentCid, seconds).catch(() => {
    });
  }

  expandPlayerForResume(): void {
    if (this.playerCollapseRaw <= 0) return;
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.playerCollapseRaw = 0;
      this.playerCollapse = 0;
    });
  }

  /**
   * 评论列表的滚动增量先用于收放播放器；返回值才交给 List 消费。
   * 这样列表位于顶部时不会因为容器改高而丢失后续手势。
   */
  isScrollerAtTop(scroller: Scroller): boolean {
    try {
      return scroller.currentOffset().yOffset <= 0.5;
    } catch (e) {
      return true;
    }
  }

  /**
   * 收放量的量化写入：raw 始终精确跟踪，@State 只在跨过约 2% 行程或
   * 0/最大边界时更新，避免滚动每帧的亚像素变化驱动整页重渲染。
   */
  private setPlayerCollapse(raw: number): void {
    const maxCollapse: number = Math.max(0, this.playerHeight() - this.minPlayerHeight());
    const clamped: number = Math.max(0, Math.min(maxCollapse, raw));
    this.playerCollapseRaw = clamped;
    const threshold: number = Math.max(1, maxCollapse * 0.02);
    if (Math.abs(clamped - this.playerCollapse) >= threshold ||
      (clamped === 0 && this.playerCollapse !== 0) ||
      (clamped === maxCollapse && this.playerCollapse !== maxCollapse)) {
      this.playerCollapse = clamped;
    }
  }

  onContentScrollFrame(offset: number, scroller: Scroller, state: ScrollState): number {
    // onScrollStart 在部分系统版本晚于首批 frame 回调，旧门闩会把整次手势漏掉。
    // Idle 代表非动画的程序化滚动；触摸拖动与惯性滚动则直接参与播放器联动。
    if (state === ScrollState.Idle) return offset;
    if (Math.abs(offset) < 0.1) return offset;
    if (!this.shouldCollapsePlayer()) return offset;
    const maxCollapse: number = Math.max(0, this.playerHeight() - this.minPlayerHeight());
    if (offset > 0 && this.playerCollapseRaw < maxCollapse) {
      const consumed: number = Math.min(offset, maxCollapse - this.playerCollapseRaw);
      this.setPlayerCollapse(this.playerCollapseRaw + consumed);
      return offset - consumed;
    }
    if (offset < 0 && this.isScrollerAtTop(scroller) && this.playerCollapseRaw > 0) {
      const consumed: number = Math.min(-offset, this.playerCollapseRaw);
      this.setPlayerCollapse(this.playerCollapseRaw - consumed);
      return offset + consumed;
    }
    return offset;
  }

  aboutToAppear(): void {
    this.destroyed = false;
    // 上次离页时未完成的请求会因 destroyed 跳过 finally 写状态；返回页面时统一解锁。
    this.replyLoading = false;
    this.threadLoading = false;
    this.replySending = false;
    this.emoteLoading = false;
    this.actionBusy = false;
    this.followLoading = false;
    this.danmakuSending = false;
    this.pageSwitchingCid = 0;
    this.replyThreadOpen = false;
    this.bvid = this.param.bvid;
    this.aid = this.param.aid;
    this.refreshScreenSize();
    this.init().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.reportVideoHeartbeat(this.videoProgressSeconds, true);
    this.timers.forEach((id: number) => {
      clearTimeout(id);
    });
    this.timers.clear();
  }

  /** 统一登记延时任务：页面销毁时清理，回调执行前检查 destroyed。 */
  private scheduleTimeout(callback: () => void, delayMs: number): void {
    const id: number = setTimeout(() => {
      this.timers.delete(id);
      if (this.destroyed) return;
      callback();
    }, delayMs);
    this.timers.add(id);
  }

  /** 只有简介在当前宽度下确实超过折叠行数时，才展示展开入口。 */
  private updateDescOverflow(width: Length): void {
    const desc: string = this.detail.desc;
    const widthVp: number = Number.parseFloat(String(width));
    if (desc.length === 0 || !Number.isFinite(widthVp) || widthVp <= 0) {
      if (this.descNeedsExpand) this.descNeedsExpand = false;
      return;
    }
    const fullSize: SizeOptions = this.getUIContext().getMeasureUtils().measureTextSize({
      textContent: desc,
      constraintWidth: widthVp,
      fontSize: 13,
      lineHeight: 20,
    });
    const foldedSize: SizeOptions = this.getUIContext().getMeasureUtils().measureTextSize({
      textContent: desc,
      constraintWidth: widthVp,
      fontSize: 13,
      lineHeight: 20,
      maxLines: 8,
      overflow: TextOverflow.Ellipsis,
    });
    const fullHeight: number = Number.parseFloat(String(fullSize.height));
    const foldedHeight: number = Number.parseFloat(String(foldedSize.height));
    const needsExpand: boolean = Number.isFinite(fullHeight) && Number.isFinite(foldedHeight) &&
      fullHeight > foldedHeight + 0.5;
    if (needsExpand !== this.descNeedsExpand) this.descNeedsExpand = needsExpand;
  }

  /** 相关接口与推荐流会交叉返回同一稿件；aid 或 bvid 任一命中都视为重复。 */
  private appendUniqueRelated(incoming: Array<VideoItem>): number {
    const seenAid: Set<number> = new Set<number>();
    const seenBvid: Set<string> = new Set<string>();
    if (this.detail.aid > 0) seenAid.add(this.detail.aid);
    if (this.detail.bvid.length > 0) seenBvid.add(this.detail.bvid);
    for (let i: number = 0; i < this.related.length; i++) {
      if (this.related[i].aid > 0) seenAid.add(this.related[i].aid);
      if (this.related[i].bvid.length > 0) seenBvid.add(this.related[i].bvid);
    }
    const next: Array<VideoItem> = this.related.slice();
    let appended: number = 0;
    for (let i: number = 0; i < incoming.length; i++) {
      const item: VideoItem = incoming[i];
      if (item.aid <= 0 && item.bvid.length === 0) continue;
      if ((item.aid > 0 && seenAid.has(item.aid)) ||
        (item.bvid.length > 0 && seenBvid.has(item.bvid))) continue;
      if (item.aid > 0) seenAid.add(item.aid);
      if (item.bvid.length > 0) seenBvid.add(item.bvid);
      next.push(item);
      appended++;
    }
    if (appended > 0) this.related = next;
    return appended;
  }

  private loadUpStats(mid: number): void {
    if (mid <= 0) {
      this.upFollowerCount = 0;
      this.upVideoCount = 0;
      return;
    }
    UserApi.getUserStat(mid).then((stat: UserStat) => {
      if (!this.destroyed && this.detail.upMid === mid) this.upFollowerCount = stat.follower;
    }).catch(() => {
      // 粉丝统计失败时保留占位，不伪造为 0。
    });
    UserApi.getUserSpaceArcs(mid, 1, 'pubdate').then((data: SpaceArcData) => {
      if (!this.destroyed && this.detail.upMid === mid) this.upVideoCount = data.total;
    }).catch(() => {
      // 投稿统计失败时保留占位，用户仍可正常进入 UP 空间。
    });
  }

  private upStatsText(): string {
    const followers: string = this.upFollowerCount >= 0 ? formatCount(this.upFollowerCount) : '--';
    const videos: string = this.upVideoCount >= 0 ? formatCount(this.upVideoCount) : '--';
    return followers + ' 粉丝 · ' + videos + ' 视频';
  }

  /** 首次播放地址：先用默认 cid 请求，若服务端返回 last_play_cid 指向其他分 P，则改拉该分 P 并续播。 */
  private async loadInitialPlayback(detail: VideoDetail): Promise<void> {
    const initialCid: number = detail.cid > 0 ? detail.cid : (detail.pages.length > 0 ? detail.pages[0].cid : 0);
    let targetCid: number = initialCid;
    this.resetPlaybackSize();
    this.currentCid = initialCid;
    this.currentPageIndex = 0;
    for (let i: number = 0; i < detail.pages.length; i++) {
      if (detail.pages[i].cid === initialCid) {
        this.currentPageIndex = i;
        break;
      }
    }
    let info: PlayUrlInfo | null = await BiliApi.getPlayUrl(detail.aid, detail.bvid, initialCid);
    if (info === null || info.urls.length === 0 || this.destroyed) return;
    // 多 P 视频上次停在其他分 P：直接切到该分 P 的地址，让续播位置与画面匹配。
    if (info.lastPlayCid > 0 && info.lastPlayCid !== initialCid && detail.pages.length > 1) {
      for (let i: number = 0; i < detail.pages.length; i++) {
        if (detail.pages[i].cid === info.lastPlayCid) {
          const lastInfo: PlayUrlInfo | null = await BiliApi.getPlayUrl(detail.aid, detail.bvid, info.lastPlayCid);
          if (lastInfo !== null && lastInfo.urls.length > 0 && this.destroyed === false) {
            info = lastInfo;
            targetCid = info.lastPlayCid;
            this.currentPageIndex = i;
          }
          break;
        }
      }
    }
    if (this.destroyed) return;
    this.currentCid = targetCid;
    this.playUrl = info.url;
    this.playUrls = info.urls;
    this.playAudioUrls = info.audioUrls;
    this.qualityOptions = info.qualities;
    this.subtitleTracks = info.subtitles;
    this.currentQuality = info.quality;
    // last_play_time 为毫秒；续播位置 = 上次进度。
    this.initialSeekSeconds = Math.max(0, Math.floor(info.lastPlayTime / 1000));
    this.lastHeartbeatSeconds = -1;
  }

  private async loadInitialRelated(aid: number, bvid: string): Promise<void> {
    if (this.relatedLoading) return;
    this.relatedLoading = true;
    this.relatedLoadError = '';
    try {
      const list: Array<VideoItem> = await BiliApi.getRelated(aid, bvid);
      if (this.destroyed) return;
      this.appendUniqueRelated(list);
      if (this.related.length === 0) this.relatedLoadError = '相关推荐加载失败，点击刷新';
    } catch (e) {
      if (!this.destroyed) this.relatedLoadError = '相关推荐加载失败，点击刷新';
    } finally {
      if (!this.destroyed) this.relatedLoading = false;
    }
  }

  private async loadMoreRelated(): Promise<void> {
    if (this.relatedLoading) return;
    this.relatedLoading = true;
    this.relatedLoadError = '';
    const idx: number = this.relatedRecommendIdx;
    try {
      const list: Array<VideoItem> = await FeedApi.getRecommend(idx);
      if (this.destroyed) return;
      if (list.length === 0) {
        this.relatedLoadError = '暂时没有刷新到新推荐，点击重试';
        return;
      }
      this.relatedRecommendIdx = idx + list.length;
      if (this.appendUniqueRelated(list) === 0) {
        this.relatedLoadError = '这批推荐已看过，点击继续刷新';
      }
    } catch (e) {
      if (!this.destroyed) this.relatedLoadError = '刷新推荐失败，点击重试';
    } finally {
      if (!this.destroyed) this.relatedLoading = false;
    }
  }

  async init(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    this.descExpanded = false;
    this.descNeedsExpand = false;
    this.related = [];
    this.relatedLoading = false;
    this.relatedLoadError = '';
    this.relatedRecommendIdx = 0;
    this.upFollowerCount = -1;
    this.upVideoCount = -1;
    try {
      const detail: VideoDetail | null = await BiliApi.getVideoDetail(this.aid, this.bvid);
      if (this.destroyed) return;
      if (detail === null) {
        this.errorText = '视频不存在或已失效';
        return;
      }
      this.detail = detail;
      this.likeCount = detail.like;
      this.coinCount = detail.coin;
      this.favoriteCount = detail.favorite;
      this.rebuildUgcSource();
      this.loadUpStats(detail.upMid);

      // 封面取色仅用于本页播放区氛围光，不改全局主题色（主题色由用户自选）
      ImageColor.extract(detail.cover).then((palette: ImagePalette) => {
        if (!this.destroyed) this.pageTint = palette.dominant;
      }).catch(() => {
        // 取色失败仅影响氛围光，保留默认主题色。
      });

      // 并行加载相关 / 评论；播放地址单独走续播定位逻辑。
      this.loadInitialPlayback(detail).catch(() => {
        // 播放地址失败由占位封面的「获取播放地址失败」文案呈现。
      });
      this.loadInitialRelated(detail.aid, detail.bvid).catch(() => {
        // 方法内部已经维护错误态；这里仅防止未处理的异步异常。
      });
      this.loadReplies(true);
      if (UserStore.isLogin) {
        const likeVersion: number = this.likeActionVersion;
        const coinVersion: number = this.coinActionVersion;
        const favoriteVersion: number = this.favoriteActionVersion;
        BiliApi.getVideoRelation(detail.aid, detail.bvid).then((relation: VideoRelationState | null) => {
          if (relation !== null && !this.destroyed) {
            // 用户可能在关系请求返回前已经操作过；旧响应不能覆盖较新的本地成功状态。
            if (likeVersion === this.likeActionVersion) {
              this.liked = relation.liked;
              this.disliked = relation.disliked;
            }
            if (coinVersion === this.coinActionVersion) this.coinCountByMe = relation.coin;
            if (favoriteVersion === this.favoriteActionVersion) this.favorited = relation.favorite;
          }
        }).catch(() => {
          // 互动状态拉取失败保持默认的未点赞/未投币/未收藏。
        });
        this.loadFollowState();
        this.loadEmotes();
      }
    } catch (e) {
      if (!this.destroyed) this.errorText = '加载失败，请检查网络后重试';
    } finally {
      if (!this.destroyed) this.loading = false;
    }
  }

  async loadEmotes(): Promise<void> {
    if (this.emoteLoading || this.emotePackages.length > 0 || !UserStore.isLogin) return;
    this.emoteLoading = true;
    try {
      let packages: Array<BiliEmotePackage> = await CommentApi.getUserEmotes('reply');
      // 'reply' 为空时回退 'dynamic'（与 EmoteResolver.ensureLoaded 的回退一致），
      // 部分账号默认包只在某一 business 下下发。
      if (packages.length === 0) packages = await CommentApi.getUserEmotes('dynamic');
      if (this.destroyed) return;
      this.emotePackages = packages;
      if (this.emotePackageIndex >= this.emotePackages.length) this.emotePackageIndex = 0;
    } catch (e) {
      // 表情加载失败不影响评论主流程，面板显示空态。
    } finally {
      if (!this.destroyed) this.emoteLoading = false;
    }
  }

  openEmotePanel(): void {
    if (!this.ensureLogin()) return;
    const opening: boolean = !this.emotePanelOpen;
    this.emotePanelOpen = opening;
    if (opening) {
      this.loadEmotes();
      try {
        inputMethod.getController().hideTextInput().catch(() => {});
      } catch (e) {
      }
    } else {
      this.scheduleTimeout(() => {
        try {
          inputMethod.getController().showTextInput().catch(() => {});
        } catch (e) {
        }
      }, 16);
    }
  }

  private requestReplyKeyboard(): void {
    if (!this.emotePanelOpen) return;
    this.emotePanelOpen = false;
    this.scheduleTimeout(() => {
      try {
        inputMethod.getController().showTextInput().catch(() => {});
      } catch (e) {
      }
    }, 16);
  }

  insertEmote(item: BiliEmote): void {
    this.replyDraft += item.text;
  }

  onLoginVersionChanged(): void {
    this.loadFollowState();
  }

  async loadFollowState(): Promise<void> {
    if (!UserStore.isLogin || this.detail.upMid <= 0) {
      this.following = false;
      this.followLoading = false;
      return;
    }
    this.followLoading = true;
    try {
      const attribute: number | null = await BiliApi.getUserRelation(this.detail.upMid);
      if (this.destroyed) return;
      if (attribute !== null) {
        // 2 为已关注，6 为互相关注；128 是拉黑，不能误显示为已关注。
        this.following = attribute === 2 || attribute === 6;
      }
    } catch (e) {
      // 关注状态拉取失败保持现状，不阻塞页面其他功能。
    } finally {
      if (!this.destroyed) this.followLoading = false;
    }
  }

  async actionFollow(): Promise<void> {
    if (!this.ensureLogin() || this.followLoading || this.detail.upMid <= 0) return;
    if (UserStore.current !== null && UserStore.current.mid === this.detail.upMid) {
      this.toast('不能关注自己');
      return;
    }
    const previous: boolean = this.following;
    const next: boolean = !previous;
    this.following = next;
    this.followLoading = true;
    try {
      const result: ActionResult = await BiliApi.modifyUserRelation(this.detail.upMid, next);
      if (this.destroyed) return;
      if (!result.ok) {
        this.following = previous;
        this.toast(result.message);
        return;
      }
      this.toast(next ? '关注成功' : '已取消关注');
    } catch (e) {
      if (!this.destroyed) {
        this.following = previous;
        this.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.destroyed) this.followLoading = false;
    }
  }

  private ensureLogin(): boolean {
    if (UserStore.isLogin) return true;
    this.toast('请先登录后再操作');
    AppNavStack.pushPathByName(NAV_LOGIN, null);
    return false;
  }

  async actionLike(): Promise<void> {
    if (!this.ensureLogin() || this.actionBusy) return;
    this.actionBusy = true;
    this.likeActionVersion++;
    const next: boolean = !this.liked;
    // 先给出本地主题色反馈，网络失败再回滚，避免按钮点击后长时间仍是灰色。
    this.liked = next;
    this.likeCount = Math.max(0, this.likeCount + (next ? 1 : -1));
    // 赞与踩互斥：点赞成功时顺带清掉本地踩状态（服务端 like=1 会自动取消踩）。
    if (next && this.disliked) this.disliked = false;
    try {
      const result: ActionResult = await BiliApi.likeVideo(this.detail.aid, this.detail.bvid, next);
      if (this.destroyed) return;
      if (!result.ok) {
        this.liked = !next;
        this.likeCount = Math.max(0, this.likeCount + (next ? -1 : 1));
        this.toast(result.message);
        return;
      }
      this.toast(next ? '点赞成功' : '已取消点赞');
    } catch (e) {
      if (!this.destroyed) {
        this.liked = !next;
        this.likeCount = Math.max(0, this.likeCount + (next ? -1 : 1));
        this.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.destroyed) this.actionBusy = false;
    }
  }

  /** 点赞按钮长按：一键三连（点赞+投一币+收藏），弹确认后执行。 */
  private actionTriple(): void {
    if (!this.ensureLogin() || this.actionBusy) return;
    if (this.liked && this.coinCountByMe > 0 && this.favorited) {
      this.toast('已三连过啦');
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '一键三连',
        message: '点赞 + 投 1 枚硬币 + 收藏',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '三连', color: this.accent },
        ],
      }).then((dialogResult) => {
        if (Number(dialogResult.index) !== 1) return;
        this.doTriple();
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  private async doTriple(): Promise<void> {
    this.actionBusy = true;
    try {
      const result: ActionResult = await BiliApi.likeTriple(this.detail.aid);
      if (this.destroyed) return;
      if (result.ok) {
        this.liked = true;
        this.coinCountByMe = 1;
        this.favorited = true;
        this.favoriteCount = this.favoriteCount + 1;
        this.toast('三连成功 🎉');
      } else {
        this.toast(result.message);
      }
    } catch (e) {
      if (!this.destroyed) this.toast('三连失败，请稍后重试');
    } finally {
      if (!this.destroyed) this.actionBusy = false;
    }
  }

  async actionFavorite(): Promise<void> {
    if (!this.ensureLogin() || this.actionBusy) return;
    this.actionBusy = true;
    this.favoriteActionVersion++;
    const next: boolean = !this.favorited;
    this.favorited = next;
    this.favoriteCount = Math.max(0, this.favoriteCount + (next ? 1 : -1));
    try {
      const selfMid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      let folders: Array<FavoriteFolderItem> = await FavoriteApi.getFavoriteFoldersForVideo(this.detail.aid,
        selfMid);
      if (this.destroyed) return;
      if (folders.length === 0 && next) {
        // 没有可用收藏夹：先自动创建一个默认收藏夹再收藏，避免"未找到可用的收藏夹"卡住收藏。
        const created: ActionResult = await FavoriteApi.addFavoriteFolder('默认收藏夹');
        if (this.destroyed) return;
        if (created.ok) {
          folders = await FavoriteApi.getFavoriteFoldersForVideo(this.detail.aid, selfMid);
        }
        if (this.destroyed) return;
      }
      if (folders.length === 0) {
        this.favorited = !next;
        this.favoriteCount = Math.max(0, this.favoriteCount + (next ? -1 : 1));
        this.toast(next ? '收藏夹创建失败，请稍后重试' : '未找到可用的收藏夹');
        return;
      }
      const selected: Array<number> = [];
      for (let i: number = 0; i < folders.length; i++) {
        if (folders[i].favorited) selected.push(folders[i].id);
      }
      const addIds: Array<number> = next ? [folders[0].id] : [];
      const deleteIds: Array<number> = next ? [] : selected;
      if (!next && deleteIds.length === 0) deleteIds.push(folders[0].id);
      const result: ActionResult = await FavoriteApi.modifyVideoFavorite(this.detail.aid, addIds, deleteIds);
      if (this.destroyed) return;
      if (!result.ok) {
        this.favorited = !next;
        this.favoriteCount = Math.max(0, this.favoriteCount + (next ? -1 : 1));
        this.toast(result.message);
        return;
      }
      this.toast(next ? '收藏成功' : '已取消收藏');
    } catch (e) {
      if (!this.destroyed) {
        this.favorited = !next;
        this.favoriteCount = Math.max(0, this.favoriteCount + (next ? -1 : 1));
        this.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.destroyed) this.actionBusy = false;
    }
  }

  // ===== 收藏夹多选：长按收藏按钮弹出夹列表勾选 =====
  @State favPickOpen: boolean = false;
  @State favPickFolders: Array<FavoriteFolderItem> = [];
  @State favPickChecked: Array<number> = [];
  @State favPickLoading: boolean = false;

  /** 长按收藏：弹出多选夹弹层。 */
  private async actionFavoritePick(): Promise<void> {
    if (!this.ensureLogin() || this.actionBusy) return;
    this.favPickLoading = true;
    this.favPickOpen = true;
    try {
      const selfMid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      const folders: Array<FavoriteFolderItem> = await FavoriteApi.getFavoriteFoldersForVideo(this.detail.aid, selfMid);
      if (this.destroyed) return;
      this.favPickFolders = folders;
      const checked: Array<number> = [];
      for (let i: number = 0; i < folders.length; i++) {
        if (folders[i].favorited) checked.push(folders[i].id);
      }
      this.favPickChecked = checked;
    } catch (e) {
      if (!this.destroyed) {
        this.favPickOpen = false;
        this.toast('收藏夹加载失败，请稍后重试');
      }
    } finally {
      if (!this.destroyed) this.favPickLoading = false;
    }
  }

  private toggleFavPick(id: number): void {
    this.favPickChecked = this.favPickChecked.indexOf(id) >= 0 ?
      this.favPickChecked.filter((x: number) => x !== id) : this.favPickChecked.concat([id]);
  }

  /** 保存多选结果：目标集合=勾选夹；原集合=夹的 favorited 状态。 */
  private async saveFavPick(): Promise<void> {
    if (this.actionBusy) return;
    this.actionBusy = true;
    try {
      const all: Array<FavoriteFolderItem> = this.favPickFolders;
      const prev: Array<number> = [];
      for (let i: number = 0; i < all.length; i++) {
        if (all[i].favorited) prev.push(all[i].id);
      }
      const keep: Array<number> = [];
      for (let i: number = 0; i < this.favPickChecked.length; i++) {
        if (prev.indexOf(this.favPickChecked[i]) < 0) keep.push(this.favPickChecked[i]);
      }
      const drop: Array<number> = [];
      for (let i: number = 0; i < prev.length; i++) {
        if (this.favPickChecked.indexOf(prev[i]) < 0) drop.push(prev[i]);
      }
      const result: ActionResult = await FavoriteApi.modifyVideoFavorite(this.detail.aid, keep, drop);
      if (this.destroyed) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.favorited = this.favPickChecked.length > 0;
      this.favPickOpen = false;
      this.toast('收藏已更新');
    } catch (e) {
      if (!this.destroyed) this.toast('保存失败，请稍后重试');
    } finally {
      if (!this.destroyed) this.actionBusy = false;
    }
  }

  /** 收藏夹多选弹层：底部抽屉。 */
  @Builder
  FavPickSheet() {
    Column() {
      Blank()
      Column({ space: 10 }) {
        Text('选择收藏夹')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        if (this.favPickLoading) {
          Text('加载中…').fontSize(13).fontColor('#9499A0').padding(14)
        } else if (this.favPickFolders.length === 0) {
          Text('还没有收藏夹').fontSize(12).fontColor('#9499A0').padding(14)
        } else {
          List() {
            ForEach(this.favPickFolders, (f: FavoriteFolderItem) => {
              ListItem() {
                Row({ space: 10 }) {
                  Text(f.title).fontSize(14)
                    .fontColor(this.isDark ? '#FFFFFF' : '#18191C').layoutWeight(1).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Stack({ alignContent: Alignment.Center }) {
                    Circle().width(18).height(18)
                      .fill(this.favPickChecked.indexOf(f.id) >= 0 ? this.accent : '#00000000')
                      .border({ width: 1.5, color: this.favPickChecked.indexOf(f.id) >= 0 ? this.accent : '#B4B6BA' })
                    if (this.favPickChecked.indexOf(f.id) >= 0) {
                      Text('✓').fontSize(11).fontColor('#FFFFFF')
                    }
                  }
                  .width(24).height(24)
                }
                .width('100%').padding({ top: 8, bottom: 8 })
                .onClick(() => this.toggleFavPick(f.id))
              }
            }, (f: FavoriteFolderItem) => String(f.id))
          }
          .width('100%')
          .constraintSize({ maxHeight: 300 })
          .scrollBar(BarState.Off)
        }
        Row({ space: 10 }) {
          Text('取消').fontSize(14).fontColor('#9499A0')
            .layoutWeight(1).height(38).textAlign(TextAlign.Center)
            .backgroundColor(this.isDark ? '#2A2C31' : '#F5F7F9').borderRadius(19)
            .onClick(() => this.favPickOpen = false)
          Text('保存').fontSize(14).fontColor('#FFFFFF').backgroundColor(this.accent)
            .layoutWeight(1).height(38).textAlign(TextAlign.Center).borderRadius(19)
            .onClick(() => {
              this.saveFavPick().catch(() => {
              });
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: Immersive.bottomInset() + 14 })
      .backgroundColor(this.isDark ? '#1E2024' : '#FFFFFF')
      .borderRadius({ topLeft: 14, topRight: 14 })
    }
    .width('100%').height('100%').justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }

  /** 加入稍后再看：无本地状态需要乐观更新，直接请求后按结果 toast。 */
  async actionWatchLater(): Promise<void> {
    if (!this.ensureLogin() || this.actionBusy) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await HistoryApi.addWatchLater(this.detail.aid, this.detail.bvid);
      if (this.destroyed) return;
      // 新代码统一走 UIContext 版 PromptAction，避开全局 promptAction 的废弃告警。
      this.toast(result.ok ? '已加入稍后再看' : result.message);
    } catch (e) {
      if (!this.destroyed) {
        this.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.destroyed) this.actionBusy = false;
    }
  }

  async switchVideoPage(page: VideoPage, index: number): Promise<void> {
    if (page.cid <= 0 || page.cid === this.currentCid) return;
    const request: number = ++this.pageSwitchRequest;
    this.pageSwitchingCid = page.cid;
    try {
      const qn: number = this.currentQuality > 0 ? this.currentQuality : 127;
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(this.detail.aid, this.detail.bvid, page.cid, qn);
      // 已有更新的分 P 请求在途时，结果与标志复位都归更新的请求处理。
      if (request !== this.pageSwitchRequest || this.destroyed) return;
      this.pageSwitchingCid = 0;
      if (info === null || info.urls.length === 0) {
        this.toast('该分 P 暂时无法播放');
        return;
      }
      this.playUrl = info.url;
      this.playUrls = info.urls;
      this.playAudioUrls = info.audioUrls;
      this.qualityOptions = info.qualities;
      this.subtitleTracks = info.subtitles;
      this.currentQuality = info.quality;
      this.initialSeekSeconds = 0;
      this.lastHeartbeatSeconds = -1;
      this.resetPlaybackSize();
      this.currentCid = page.cid;
      this.currentPageIndex = index;
      this.playerCollapseRaw = 0;
      this.playerCollapse = 0;
      this.playerEnded = false;
      // 所有播放源属性先更新，最后递增版本号，让播放器一次性读取同一分 P 的完整数据。
      this.playerSourceVersion++;
    } catch (e) {
      if (request === this.pageSwitchRequest && !this.destroyed) {
        this.pageSwitchingCid = 0;
        this.toast('网络异常，切换分 P 失败');
      }
    }
  }

  private rebuildUgcSource(): void {
    const list: Array<UgcSeasonEpisode> = [];
    const season = this.detail.ugcSeason;
    if (season !== null) {
      for (let i: number = 0; i < season.sections.length; i++) {
        const section = season.sections[i];
        for (let j: number = 0; j < section.episodes.length; j++) {
          const ep: UgcSeasonEpisode = section.episodes[j];
          ep.sectionTitle = section.title;
          list.push(ep);
        }
      }
    }
    this.ugcSource.reset(list);
    this.ugcCount = this.ugcSource.totalCount();
  }

  private currentUgcEpisodeIndex(): number {
    const list: Array<UgcSeasonEpisode> = this.ugcSource.getAll();
    for (let i: number = 0; i < list.length; i++) {
      const ep: UgcSeasonEpisode = list[i];
      if (ep.cid === this.currentCid && ep.bvid === this.detail.bvid) return i;
      if (ep.cid === this.currentCid && ep.aid === this.detail.aid && ep.bvid.length === 0) return i;
    }
    return -1;
  }

  private nextUgcEpisode(): UgcSeasonEpisode | null {
    if (this.detail.ugcSeason === null || this.ugcCount <= 0) return null;
    const idx: number = this.currentUgcEpisodeIndex();
    if (idx < 0 || idx + 1 >= this.ugcCount) return null;
    return this.ugcSource.getData(idx + 1);
  }

  private openUgcEpisode(ep: UgcSeasonEpisode): void {
    if (ep.aid <= 0 && ep.bvid.length === 0) return;
    if (ep.cid === this.currentCid && (ep.bvid === this.detail.bvid ||
      (ep.bvid.length === 0 && ep.aid === this.detail.aid))) return;
    const param: VideoDetailParam = { bvid: ep.bvid, aid: ep.aid, title: ep.title };
    AppNavStack.replacePathByName(NAV_VIDEO_DETAIL, param);
  }

  private onPlayerEnded(): void {
    // 播完：播放区收敛到统一高度（visiblePlayerHeight 读取 playerEnded）。
    this.playerEnded = true;
    this.syncDanmakuViewport();
    // 播完：自动填入"推荐列表第一条"作为结束画面的推荐卡。
    // 优先合集下一集（合集里连续观看），否则用相关推荐第一条。
    const next: UgcSeasonEpisode | null = this.nextUgcEpisode();
    if (next !== null) {
      this.endRecTitle = next.title;
      this.endRecCover = next.cover;
      this.endRecUpName = this.detail.upName;
      this.endRecPlayText = '';
      this.endRecDuration = 0;
      this.endRecToken++;
      return;
    }
    if (this.related.length > 0) {
      const related: VideoItem = this.related[0];
      if (related.aid > 0 || related.bvid.length > 0) {
        this.endRecTitle = related.title;
        this.endRecCover = related.cover;
        this.endRecUpName = related.upName;
        this.endRecPlayText = related.playText;
        this.endRecDuration = related.duration;
        this.endRecToken++;
        return;
      }
    }
    this.endRecTitle = '';
    this.endRecCover = '';
    this.endRecUpName = '';
    this.endRecPlayText = '';
    this.endRecDuration = 0;
    this.endRecToken++;
  }

  /** 结束画面「立即播放」：与旧"自动连播"同一跳转逻辑。 */
  private onPlayerEndPlayNow(): void {
    const next: UgcSeasonEpisode | null = this.nextUgcEpisode();
    if (next !== null) {
      this.openUgcEpisode(next);
      return;
    }
    if (this.related.length > 0) {
      const related: VideoItem = this.related[0];
      if (related.aid > 0 || related.bvid.length > 0) {
        const param: VideoDetailParam = { bvid: related.bvid, aid: related.aid, title: related.title };
        AppNavStack.replacePathByName(NAV_VIDEO_DETAIL, param);
      }
    }
  }

  openCoinSheet(): void {
    if (!this.ensureLogin()) return;
    if (this.coinCountByMe >= 2) {
      this.toast('这个视频已经投过 2 枚硬币了');
      return;
    }
    this.coinChoice = this.coinCountByMe === 1 ? 1 : 2;
    this.coinSheetOpen = true;
  }

  async submitCoin(): Promise<void> {
    if (this.actionBusy) return;
    const available: number = Math.max(0, 2 - this.coinCountByMe);
    const multiply: number = Math.min(this.coinChoice, available);
    if (multiply <= 0) {
      this.coinSheetOpen = false;
      return;
    }
    this.actionBusy = true;
    this.coinActionVersion++;
    if (this.coinWithLike) this.likeActionVersion++;
    // 乐观更新：先变红并收起弹层，失败再整体回滚。
    const likedBefore: boolean = this.liked;
    this.coinCountByMe += multiply;
    this.coinCount += multiply;
    if (this.coinWithLike && !this.liked) {
      this.liked = true;
      this.likeCount++;
    }
    this.coinSheetOpen = false;
    const rollback = () => {
      this.coinCountByMe = Math.max(0, this.coinCountByMe - multiply);
      this.coinCount = Math.max(0, this.coinCount - multiply);
      if (this.coinWithLike && !likedBefore) {
        this.liked = false;
        this.likeCount = Math.max(0, this.likeCount - 1);
      }
    };
    try {
      const result: ActionResult = await BiliApi.coinVideo(this.detail.aid, this.detail.bvid, multiply, this.coinWithLike);
      if (this.destroyed) return;
      if (!result.ok) {
        rollback();
        this.toast(result.message);
        return;
      }
      this.toast('投币成功');
    } catch (e) {
      if (!this.destroyed) {
        rollback();
        this.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.destroyed) this.actionBusy = false;
    }
  }

  actionShare(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      this.toast('无法打开系统分享');
      return;
    }
    const url: string = 'https://www.bilibili.com/video/' + this.detail.bvid;
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: 'general.hyperlink',
      title: this.detail.title,
      content: url,
      description: this.detail.desc,
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL }).catch((error: Error) => {
      this.toast('分享失败：' + error.message);
    });
    if (UserStore.isLogin) {
      BiliApi.reportShare(this.detail.aid, this.detail.bvid);
    }
  }

  async loadReplies(reset: boolean): Promise<void> {
    if (this.replyLoading) {
      return;
    }
    this.replyLoading = true;
    if (reset) this.replyPrefetchCount = 0;
    const cursor: string = reset ? '' : this.replyCursor;
    let loaded: boolean = false;
    try {
      const data = await CommentApi.getReplies(this.detail.aid, 1, cursor, this.replySortMode);
      if (this.destroyed) return;
      if (reset) {
        this.replySource.reset(data.replies);
      } else {
        this.appendUniqueReplies(this.replySource, data.replies);
      }
      this.replyCursor = data.cursor;
      this.replyHasMore = data.hasMore;
      loaded = true;
    } catch (e) {
      // 评论加载失败保持现有列表，replyLoading 复位后空态/重试入口正常可用。
    } finally {
      if (!this.destroyed) this.replyLoading = false;
    }
    if (!loaded) return;
    // 某些视频首页只返回置顶/精选的少量评论，自动继续取页直到首屏够用。
    if (this.replyHasMore && this.replySource.totalCount() < 20 && this.replyPrefetchCount < 5) {
      this.replyPrefetchCount++;
      await this.loadReplies(false);
    }
  }

  changeReplySort(mode: number): void {
    if (this.replySortMode === mode || this.replyLoading) {
      return;
    }
    this.replySortMode = mode;
    this.replyCursor = '';
    this.replyHasMore = true;
    this.replySource.clear();
    this.replyThreadOpen = false;
    this.loadReplies(true);
  }

  mergeUniqueReplies(base: Array<ReplyItem>, incoming: Array<ReplyItem>): Array<ReplyItem> {
    const indexes: Map<number, number> = new Map<number, number>();
    const result: Array<ReplyItem> = [];
    for (let i: number = 0; i < base.length; i++) {
      indexes.set(base[i].rpid, result.length);
      result.push(base[i]);
    }
    for (let i: number = 0; i < incoming.length; i++) {
      const oldIndex: number | undefined = indexes.get(incoming[i].rpid);
      if (oldIndex === undefined) {
        indexes.set(incoming[i].rpid, result.length);
        result.push(incoming[i]);
      } else {
        // 主评论预览只携带精简回复；完整 reply/reply 响应到达后必须替换旧对象，
        // 否则头像挂件、评论装扮、dialog/parent 等字段会永久停留在预览版本。
        result[oldIndex] = incoming[i];
      }
    }
    return result;
  }

  /** 分页追加时按 rpid 去重，只把新楼层推进数据源。 */
  private appendUniqueReplies(source: BasicDataSource<ReplyItem>, incoming: Array<ReplyItem>): void {
    const existing: Set<number> = new Set<number>();
    const all: Array<ReplyItem> = source.getAll();
    for (let i: number = 0; i < all.length; i++) {
      existing.add(all[i].rpid);
    }
    const fresh: Array<ReplyItem> = [];
    for (let i: number = 0; i < incoming.length; i++) {
      if (!existing.has(incoming[i].rpid)) {
        existing.add(incoming[i].rpid);
        fresh.push(incoming[i]);
      }
    }
    source.append(fresh);
  }

  private rebuildThreadTree(): void {
    const snapshot: ReplyTreeSnapshot = buildReplyTree(this.replyThreadRoot.rpid,
      this.threadAllReplies, this.threadCollapsed);
    this.threadNameMap = snapshot.names;
    this.threadMetaMap = snapshot.meta;
    this.threadSource.reset(snapshot.visible);
  }

  private threadMeta(item: ReplyItem): ReplyTreeMeta {
    const meta: ReplyTreeMeta | undefined = this.threadMetaMap.get(item.rpid);
    return meta !== undefined ? meta : new ReplyTreeMeta();
  }

  private toggleThreadBranch(item: ReplyItem): void {
    const meta: ReplyTreeMeta = this.threadMeta(item);
    if (!meta.hasChildren) return;
    if (this.threadCollapsed.has(item.rpid)) this.threadCollapsed.delete(item.rpid);
    else this.threadCollapsed.add(item.rpid);
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
      this.rebuildThreadTree();
    });
  }

  async openReplyThread(item: ReplyItem): Promise<void> {
    if (this.replyThreadAnimating) return;
    this.replyThreadAnimating = true;
    this.replyThreadRoot = item;
    this.threadAllReplies = this.mergeUniqueReplies([], item.replies);
    this.threadCollapsed.clear();
    this.rebuildThreadTree();
    this.threadPage = 0;
    this.threadHasMore = true;
    this.threadPrefetchCount = 0;
    this.replyTargetRpid = item.rpid;
    this.replyTargetName = item.uname;
    // 先取回并排好首批树节点，再打开与动态页相同的系统 Sheet；入场期间内容高度不再二次跳变。
    await this.loadThreadReplies(true, false);
    if (this.destroyed) {
      this.replyThreadAnimating = false;
      return;
    }
    this.replyThreadOpen = true;
    this.replyThreadAnimating = false;
  }

  async loadThreadReplies(reset: boolean, allowPrefetch: boolean = true): Promise<void> {
    if (this.threadLoading || (!reset && !this.threadHasMore)) {
      return;
    }
    this.threadLoading = true;
    const page: number = reset ? 1 : this.threadPage + 1;
    let loaded: boolean = false;
    try {
      const data = await CommentApi.getReplyReplies(this.detail.aid, 1, this.replyThreadRoot.rpid, page);
      if (this.destroyed) return;
      // 保留 item.replies 里的预览回复：接口偶尔返回空列表时，楼中楼不会变成“有数字但没内容”。
      this.threadAllReplies = this.mergeUniqueReplies(this.threadAllReplies, data.replies);
      this.rebuildThreadTree();
      this.threadPage = page;
      this.threadHasMore = data.hasMore;
      loaded = true;
    } catch (e) {
      // 回复加载失败保持现有内容，threadLoading 复位后可点击继续加载重试。
    } finally {
      if (!this.destroyed) this.threadLoading = false;
    }
    if (!loaded) return;
    const target: number = Math.min(20, Math.max(1, this.replyThreadRoot.count));
    if (allowPrefetch && this.threadHasMore && this.threadAllReplies.length < target && this.threadPrefetchCount < 5) {
      this.threadPrefetchCount++;
      await this.loadThreadReplies(false);
    }
  }

  @Builder
  VideoThreadEmotePanel() {
    this.EmotePanel()
  }

  private navigateFromReplyThread(action: () => void): void {
    this.closeReplyThread();
    this.scheduleTimeout(() => {
      if (!this.destroyed) action();
    }, 260);
  }

  @Builder
  VideoThreadSheet() {
    ReplyThreadPanel({
      root: this.replyThreadRoot,
      replies: this.threadAllReplies,
      loading: this.threadLoading,
      hasMore: this.threadHasMore,
      version: this.replyLikeVersion,
      draft: this.replyDraft,
      sending: this.replySending,
      replyTargetName: this.replyTargetName,
      upMid: this.detail.upMid,
      showEmoteButton: true,
      emoteOpen: this.emotePanelOpen,
      emotePackages: this.emotePackages,
      emotePanel: (): void => {
        this.VideoThreadEmotePanel()
      },
      onClose: () => this.closeReplyThread(),
      onLike: (item: ReplyItem) => this.actionReplyLike(item),
      onDislike: (item: ReplyItem) => this.actionReplyDislike(item),
      onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
      focusTick: this.replyFocusTick,
      onSelectReply: (item: ReplyItem) => {
        this.replyTargetRpid = item.rpid;
        this.replyTargetName = item.uname;
        this.replyFocusTick++;
      },
      onDeleted: (item: ReplyItem) => {
        this.threadRemoveReply(item);
      },
      onLoadMore: () => {
        this.loadThreadReplies(false).catch(() => {
        });
      },
      onDraftChange: (value: string) => this.replyDraft = value,
      onSend: () => this.sendReply(),
      onToggleEmote: () => this.openEmotePanel(),
      onRequestKeyboard: () => this.requestReplyKeyboard(),
      onNavigate: (action: () => void) => this.navigateFromReplyThread(action),
    })
  }

  async sendReply(): Promise<void> {
    const content: string = this.replyDraft.trim();
    if (content.length === 0 || this.replySending || !this.ensureLogin()) return;
    this.replySending = true;
    try {
      const root: number = this.replyThreadOpen ? this.replyThreadRoot.rpid : 0;
      const parent: number = this.replyThreadOpen ?
        (this.replyTargetRpid > 0 ? this.replyTargetRpid : root) : 0;
      const result: ActionResult = await CommentApi.addReply(this.detail.aid, 1, content, root, parent);
      if (this.destroyed) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.replyDraft = '';
      this.toast(this.replyThreadOpen ? '回复成功' : '评论成功');
      if (this.replyThreadOpen) {
        this.replyTargetRpid = this.replyThreadRoot.rpid;
        this.replyTargetName = this.replyThreadRoot.uname;
        this.threadAllReplies = [];
        this.threadCollapsed.clear();
        this.rebuildThreadTree();
        this.threadPage = 0;
        this.threadHasMore = true;
        await this.loadThreadReplies(true);
      } else {
        this.replyCursor = '';
        this.replyHasMore = true;
        await this.loadReplies(true);
      }
    } catch (e) {
      if (!this.destroyed) this.toast('网络异常，发送失败');
    } finally {
      if (!this.destroyed) this.replySending = false;
    }
  }

  async sendVideoDanmaku(): Promise<void> {
    const message: string = this.danmakuDraft.trim();
    if (message.length === 0 || this.danmakuSending || !this.ensureLogin()) return;
    this.danmakuSending = true;
    try {
      const result: ActionResult = await BiliApi.sendDanmaku(this.detail.aid, this.detail.bvid,
        this.currentCid, this.videoProgressSeconds, message);
      if (this.destroyed) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.danmakuDraft = '';
      this.localDanmakuText = message;
      this.localDanmakuToken++;
      if (!this.danmakuOn) this.danmakuOn = true;
      this.toast('弹幕发送成功');
    } catch (e) {
      if (!this.destroyed) this.toast('网络异常，发送失败');
    } finally {
      if (!this.destroyed) this.danmakuSending = false;
    }
  }

  /**
   * 只查找评论真身，不修改也不触发重建。
   * 用于点赞/点踩前读取当前状态，避免“先空 mutate 再真实 mutate”导致 UI 闪烁两次。
   */
  private findReplyItem(rpid: number): ReplyItem | null {
    const list: Array<ReplyItem> = this.replySource.getAll();
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].rpid === rpid) return list[i];
    }
    for (let i: number = 0; i < this.threadAllReplies.length; i++) {
      if (this.threadAllReplies[i].rpid === rpid) return this.threadAllReplies[i];
    }
    if (this.replyThreadRoot.rpid === rpid) return this.replyThreadRoot;
    return null;
  }

  /**
   * 评论项状态修改的统一入口。
   * 注意：ReplyCard 的 @Prop item 是深拷贝快照，改它既不影响数据源也不会刷新 UI。
   * 必须在数据源里的"真身"上执行修改，再克隆换引用触发 @Prop 重新同步。
   * 同一 rpid 可能同时存在于主列表、楼中楼列表和 replyThreadRoot，逐处各改一次（它们各自渲染）。
   */
  private mutateReplyItem(rpid: number, mutate: (target: ReplyItem) => void): ReplyItem | null {
    let found: ReplyItem | null = null;
    const list: Array<ReplyItem> = this.replySource.getAll();
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].rpid === rpid) {
        found = list[i];
        mutate(list[i]);
        const next1: ReplyItem = list[i].clone();
        next1.rev = list[i].rev + 1;
        this.replySource.updateItem(i, next1);
        break;
      }
    }
    // 回复详情 Sheet 的数据源是 threadAllReplies（透传给 ReplyThreadPanel 的 @Prop replies）。
    // 必须在数组里替换成克隆对象并换新数组引用，子组件的 @Watch 才会重建树并刷新点赞态。
    let threadChanged: boolean = false;
    for (let i: number = 0; i < this.threadAllReplies.length; i++) {
      if (this.threadAllReplies[i].rpid === rpid) {
        if (found === null) found = this.threadAllReplies[i];
        mutate(this.threadAllReplies[i]);
        const next2: ReplyItem = this.threadAllReplies[i].clone();
        next2.rev = this.threadAllReplies[i].rev + 1;
        const nextThread: Array<ReplyItem> = this.threadAllReplies.slice();
        nextThread[i] = next2;
        this.threadAllReplies = nextThread;
        threadChanged = true;
        break;
      }
    }
    if (threadChanged) {
      // 同步旧的内嵌 ReplyThreadView / threadSource 路径，保持两套实现状态一致。
      this.rebuildThreadTree();
    }
    if (this.replyThreadRoot.rpid === rpid) {
      if (found === null) found = this.replyThreadRoot;
      mutate(this.replyThreadRoot);
      const next3: ReplyItem = this.replyThreadRoot.clone();
      next3.rev = this.replyThreadRoot.rev + 1;
      this.replyThreadRoot = next3;
    }
    this.replyLikeVersion++;
    return found;
  }

  /** 评论点赞：委托给共享实现 runReplyLike（登录检查/busy/乐观更新/失败回滚统一在一处）。 */
  async actionReplyLike(item: ReplyItem): Promise<void> {
    await runReplyLike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.mutateReplyItem(rpid, mutate),
      this.replyReactionHooks(true));
  }

  /** 评论点踩：同理走共享实现（踩赞互斥逻辑在模块内）。 */
  async actionReplyDislike(item: ReplyItem): Promise<void> {
    await runReplyDislike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.mutateReplyItem(rpid, mutate),
      this.replyReactionHooks(false));
  }

  private replyReactionHooks(isLike: boolean): ReplyReactionHooks {
    return {
      ensureLogin: () => {
        if (UserStore.isLogin) return true;
        this.toast('请先登录后再操作');
        AppNavStack.pushPathByName(NAV_LOGIN, null);
        return false;
      },
      toast: (message: string) => this.toast(message),
      isDestroyed: () => this.destroyed,
      resolveOid: (it: ReplyItem) => it.oid > 0 ? it.oid : this.detail.aid,
      resolveType: (it: ReplyItem) => it.type > 0 ? it.type : 1,
      clearDislikeOnLike: true,
    };
  }

  /** 评论分享：离屏渲染分享卡 → 截成 PNG → 系统分享面板（对齐 B 站"评论分享成图片"）。 */
  private shareReplyAsImage(item: ReplyItem): void {
    if (this.shareCardBusy) return;
    this.shareCardBusy = true;
    this.toast('正在生成分享图片…');
    const link: string = 'https://www.bilibili.com/video/' + this.detail.bvid + '#reply' + String(item.rpid);
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uiContext: UIContext = this.getUIContext();
    (async () => {
      this.shareCardItem = item;
      this.shareCardQr = await makeReplyQr(link);
      // checkImageStatus=true 等头像/附图在线图片解码完成再截图。
      const pixelMap: image.PixelMap = await uiContext.getComponentSnapshot()
        .createFromBuilder((): void => { this.ReplyShareCardBuilder(); }, 400, true);
      await sharePixelMapAsImage(context, pixelMap, 'reply_share_' + String(item.rpid));
    })()
      .catch(() => {
        // 分享面板不可用/截图失败时兜底为复制链接，保证"转发"始终有结果。
        this.copyTextToClipboard(link);
        this.toast('分享面板暂不可用，已复制评论链接');
      })
      .finally(() => {
        this.shareCardBusy = false;
      });
  }

  /** 复制文本到系统剪贴板；失败静默。 */
  private copyTextToClipboard(content: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content);
      pasteboard.getSystemPasteboard().setData(data).catch(() => {
      });
    } catch (e) {
      // 剪贴板不可用时忽略。
    }
  }

  /** 离屏分享卡内容；字段在截图前一次性赋值，渲染期间不变化。 */
  @Builder
  ReplyShareCardBuilder() {
    ReplyShareCard({
      item: this.shareCardItem,
      upMid: this.detail.upMid,
      qr: this.shareCardQr,
      linkLabel: 'www.bilibili.com/video/' + this.detail.bvid,
      sourceCover: this.detail.cover,
      sourceTitle: this.detail.title,
      sourceUpName: this.detail.upName,
    })
  }

  @Builder
  IntroTab() {
    Scroll(this.introScroller) {
      Column({ space: 12 }) {
        // UP 主信息置于标题之前，副信息展示可量化的粉丝数与投稿数。
        Row({ space: 10 }) {
          Row({ space: 10 }) {
            Stack({ alignContent: Alignment.Center }) {
              Circle()
                .width(42)
                .height(42)
                .fill(this.accent)
              Image(this.detail.upFace)
                .width(42)
                .height(42)
                .borderRadius(21)
                .objectFit(ImageFit.Cover)
                .clip(true)
            }
            .width(42)
            .height(42)
            Column({ space: 3 }) {
              Text(this.detail.upName)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
              Text(this.upStatsText())
                .fontSize(11)
                .fontColor('#9499A0')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .layoutWeight(1)
          .onClick(() => {
            if (this.detail.upMid > 0) {
              PlayerCommandBus.stop();
              const param: UserSpaceParam = { mid: this.detail.upMid };
              AppNavStack.pushPathByName(NAV_USER_SPACE, param);
            }
          })
          Text(this.followLoading ? '处理中…' : (this.following ? '已关注' : '+ 关注'))
            .fontSize(13)
            .fontColor(this.following ? (this.isDark ? '#D0D0D4' : '#61666D') : '#FFFFFF')
            .backgroundColor(this.following ? (this.isDark ? '#333438' : '#EEF0F2') : this.accent)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(15)
            .enabled(!this.followLoading)
            .onClick(() => {
              Haptic.tap();
              this.actionFollow();
            })
        }
        .width('100%')

        // 标题
        Text(this.detail.title)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .width('100%')
          .lineHeight(24)
        // 数据行：播放 / 弹幕 / 发布日期 · 分区
        Row() {
          Image($r('app.media.ic_play'))
            .width(14)
            .height(14)
            .fillColor('#9499A0')
          Text(formatCount(this.detail.view))
            .fontSize(12)
            .fontColor('#9499A0')
            .margin({ left: 4 })
          Image($r('app.media.ic_danmaku_on'))
            .width(14)
            .height(14)
            .fillColor('#9499A0')
            .margin({ left: 10 })
          Text(formatCount(this.detail.danmaku))
            .fontSize(12)
            .fontColor('#9499A0')
            .margin({ left: 4 })
          Text((formatDate(this.detail.pubdate)) +
            (this.playerOnlineTotal.length > 0 ? ' · ' + this.playerOnlineTotal + '人正在看' : '') +
            (this.detail.tname.length > 0 ? ' · ' + this.detail.tname : ''))
            .fontSize(12)
            .fontColor('#9499A0')
            .margin({ left: 10, right: 10 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 操作行：B 站风格素材 + 真实点赞/投币/分享状态。
        // 注意必须直接在 build 里创建组件：经按值传参的 @Builder 中转后参数不跟踪状态，按钮会永远停在初始颜色。
        Row() {
          VideoActionItem({ icon: $r('app.media.bilix_icon_like'), value: formatCount(this.likeCount),
            active: this.liked, busy: this.actionBusy, onTap: () => this.actionLike(),
            onLongPress: () => this.actionTriple() })
          // 视频点踩已移除：B 站点踩仅 App 端协议（需 access_key），cookie 登录无法调用。
          VideoActionItem({ icon: $r('app.media.bilix_icon_coin'), value: formatCount(this.coinCount),
            active: this.coinCountByMe > 0, busy: this.actionBusy, onTap: () => this.openCoinSheet() })
          VideoActionItem({ icon: $r('app.media.bilix_icon_fav'), value: formatCount(this.favoriteCount),
            active: this.favorited, busy: this.actionBusy, onTap: () => this.actionFavorite(),
            onLongPress: () => this.actionFavoritePick() })
          VideoActionItem({ icon: $r('app.media.bilix_icon_share'), value: formatCount(this.detail.share),
            active: false, busy: this.actionBusy, onTap: () => this.actionShare() })
          VideoActionItem({ icon: $r('app.media.ic_watch_later'), value: '稍后',
            active: false, busy: this.actionBusy, onTap: () => this.actionWatchLater() })
        }
        .width('100%')
        .border({ width: { top: 0.5, bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })

        // 简介
        Column({ space: 8 }) {
          Row() {
            Text('简介')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          }
          .width('100%')
          Text(this.detail.desc.length > 0 ? this.detail.desc : 'UP主没有填写简介')
            .fontSize(13)
            .fontColor(this.isDark ? '#B0B0B0' : '#5A5F66')
            .width('100%')
            .lineHeight(20)
            .maxLines(this.descExpanded ? 10000 : 8)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.updateDescOverflow(newValue.width);
            })
          if (this.descNeedsExpand) {
            Row() {
              Blank()
              Text(this.descExpanded ? '收起' : '展开全文')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.accent)
                .padding({ left: 8, right: 2, top: 4, bottom: 4 })
            }
            .width('100%')
            .onClick(() => {
              this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                this.descExpanded = !this.descExpanded;
              });
            })
          }
          // 分P
          if (this.detail.pages.length > 1) {
            Column() {
              ForEach(this.detail.pages, (page: VideoPage, index: number) => {
                Row() {
                  Text('P' + page.page + ' ' + page.part)
                    .fontSize(13)
                    .fontColor(this.isDark ? '#D0D0D0' : '#222222')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(page.cid === this.pageSwitchingCid ? '切换中…' : (page.cid === this.currentCid ? '播放中' : ''))
                    .fontSize(11)
                    .fontColor(this.accent)
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .backgroundColor(page.cid === this.currentCid ? colorWithAlpha(this.accent, '14') : '#00000000')
                .borderRadius(6)
                .onClick(() => {
                  this.switchVideoPage(page, index);
                })
              }, (page: VideoPage) => String(page.cid))
            }
            .width('100%')
            .padding({ left: 10, right: 10 })
            .borderRadius(8)
            .backgroundColor(this.isDark ? '#2A2C31' : '#F6F7F8')
          }
          // UGC 合集选集：展示在当前简介流中，点击/连播均替换为对应稿件详情。
          if (this.detail.ugcSeason !== null && this.detail.ugcSeason.sections.length > 0) {
            Column() {
              Row() {
                Text('合集 · ' + this.detail.ugcSeason.title)
                  .fontSize(13)
                  .fontColor(this.isDark ? '#D0D0D0' : '#222222')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.ugcPanelOpen ? '收起' : '展开')
                  .fontSize(11)
                  .fontColor(this.accent)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .onClick(() => {
                this.ugcPanelOpen = this.ugcPanelOpen ? false : true;
                if (this.ugcPanelOpen) this.rebuildUgcSource();
              })
              if (this.ugcPanelOpen && this.ugcCount > 0) {
                List({ space: 4 }) {
                  LazyForEach(this.ugcSource, (ep: UgcSeasonEpisode) => {
                    ListItem() {
                      Row({ space: 8 }) {
                        if (ep.cover.length > 0) {
                          Image(ep.cover).width(72).height(42).objectFit(ImageFit.Cover).borderRadius(5)
                        }
                        Column({ space: 3 }) {
                          Text(ep.sectionTitle.length > 0 ? ep.sectionTitle + ' · ' + ep.title : ep.title)
                            .fontSize(12)
                            .fontColor(this.isDark ? '#D0D0D0' : '#222222')
                            .maxLines(2)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          Text(ep.cid === this.currentCid ? '播放中' : '')
                            .fontSize(10)
                            .fontColor(this.accent)
                        }
                        .alignItems(HorizontalAlign.Start)
                        .layoutWeight(1)
                      }
                      .width('100%')
                      .padding({ top: 6, bottom: 6 })
                      .borderRadius(6)
                      .backgroundColor(ep.cid === this.currentCid ? colorWithAlpha(this.accent, '14') : '#00000000')
                      .onClick(() => {
                        this.openUgcEpisode(ep);
                      })
                    }
                  }, (ep: UgcSeasonEpisode) => String(ep.id) + '_' + ep.bvid + '_' + String(ep.cid))
                }
                .width('100%')
                .height(240)
                .scrollBar(BarState.Off)
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10 })
            .borderRadius(8)
            .backgroundColor(this.isDark ? '#2A2C31' : '#F6F7F8')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 相关推荐跟随简介向下滚动，不再占用独立标签页。
        Column({ space: 4 }) {
          Text('相关推荐')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            .width('100%')
            .padding({ top: 6, bottom: 4 })
          if (this.related.length === 0) {
            Text(this.relatedLoading ? '相关推荐加载中…' : this.relatedLoadError)
              .fontSize(12)
              .fontColor(this.relatedLoadError.length > 0 ? this.accent : '#9499A0')
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              .onClick(() => {
                if (!this.relatedLoading) this.loadMoreRelated();
              })
          } else {
            ForEach(this.related, (item: VideoItem) => {
              this.RelatedRow(item)
            }, (item: VideoItem) => item.bvid + String(item.aid))
            if (this.relatedLoading) {
              Text('正在刷新更多推荐…')
                .fontSize(12)
                .fontColor('#9499A0')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
            } else if (this.relatedLoadError.length > 0) {
              Text(this.relatedLoadError)
                .fontSize(12)
                .fontColor(this.accent)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
                .onClick(() => {
                  this.loadMoreRelated();
                })
            }
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(14)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      return { offsetRemain: this.onContentScrollFrame(offset, this.introScroller, state) };
    })
    .onReachEnd(() => {
      this.loadMoreRelated();
    })
  }

  threadParentName(item: ReplyItem): string {
    if (item.parentRpid === this.replyThreadRoot.rpid) return this.replyThreadRoot.uname;
    const name: string | undefined = this.threadNameMap.get(item.parentRpid);
    return name !== undefined ? name : '上一条回复';
  }

  @Builder
  ReplySortBar() {
    Row({ space: 8 }) {
      Text('评论 ' + formatCount(this.detail.reply))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
      // 排序切换与动态/番剧详情共用 chips 样式（最热 mode=3 / 最新 mode=2）。
      ReplySortChips({
        mode: this.replySortMode,
        onChange: (mode: number) => {
          this.changeReplySort(mode);
        },
      })
    }
    .width('100%')
    .height(42)
    .padding({ left: 14, right: 14 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  @Builder
  ReplyInputBar() {
    ReplyComposer({
      text: this.replyDraft,
      emotePackages: this.emotePackages,
      placeholder: this.replyThreadOpen ? '回复 ' +
        (this.replyTargetName.length > 0 ? this.replyTargetName : this.replyThreadRoot.uname) : '发一条友善的评论',
      sending: this.replySending,
      emoteOpen: this.emotePanelOpen,
      focusTick: this.replyFocusTick,
      onChange: (value: string) => {
        this.replyDraft = value;
      },
      onSend: () => this.sendReply(),
      onToggleEmote: () => this.openEmotePanel(),
      onRequestKeyboard: () => this.requestReplyKeyboard(),
    })
  }

  private emoteKeyboardHeight(): number {
    if (this.screenHeightVp <= 0) return 310;
    const base: number = Math.min(360, Math.max(280, this.screenHeightVp * 0.36));
    if (this.replyThreadOpen) {
      // 回复详情 Sheet 高度有限，表情键盘必须给顶部返回行 + 输入栏留出空间，
      // 否则小屏/播放器展开时面板会把输入栏顶出可视区，导致键盘/表情切换按钮点不到。
      const maxForSheet: number = this.replySheetHeight() - 160;
      return Math.min(base, Math.max(210, maxForSheet));
    }
    return base;
  }

  @Builder
  EmotePanel() {
    ReplyEmotePanel({
      packages: this.emotePackages,
      currentIndex: this.emotePackageIndex,
      loading: this.emoteLoading,
      panelHeight: this.emoteKeyboardHeight(),
      screenWidth: this.screenWidthVp,
      onPackageChange: (index: number) => this.emotePackageIndex = index,
      onSelect: (item: BiliEmote) => this.insertEmote(item),
    })
  }

  // 「加载更多」底部块：loading / 继续加载 / 到底啦 三分支，评论与回复详情共用。
  @Builder
  LoadMoreFooter(options: LoadMoreFooterOptions) {
    Row() {
      if (options.loading) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.accent)
      } else if (options.hasMore) {
        Text(options.moreText)
          .fontSize(12)
          .fontColor(this.accent)
      } else {
        Text(options.endText)
          .fontSize(12)
          .fontColor('#9499A0')
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 16 })
    .onClick(() => {
      options.onTap();
    })
  }

  @Builder
  ReplyThreadView() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(25)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text('回复 ' + this.replyThreadRoot.count)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      .width('100%')
      .height(42)
      .padding({ left: 12, right: 12 })
      .onClick(() => {
        this.closeReplyThread();
      })
      List({ scroller: this.threadScroller }) {
        ListItem() {
          ReplyCard({
            item: this.replyThreadRoot,
            showPreview: false,
            version: this.replyLikeVersion,
            upMid: this.detail.upMid,
            onLike: (item: ReplyItem) => this.actionReplyLike(item),
            onDislike: (item: ReplyItem) => this.actionReplyDislike(item),
            onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
            onSelectReply: (item: ReplyItem) => {
              this.replyTargetRpid = item.rpid;
              this.replyTargetName = item.uname;
              this.replyFocusTick++;
            },
            onDeleted: (item: ReplyItem) => {
              // 楼中楼面板的根评论被删除：关闭面板并移除主列表中对应行。
              this.closeReplyThread();
              this.replySource.reset(this.replySource.getAll().filter((x: ReplyItem) => x.rpid !== item.rpid));
              this.detail.reply = Math.max(0, this.detail.reply - 1);
            },
          })
        }
        ListItem() {
          Column() {
            Divider()
              .strokeWidth(0.5)
              .color(this.isDark ? '#3A3B40' : '#E3E5E7')
            Row({ space: 5 }) {
              Text('相关回复')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
              Text('共 ' + formatCount(this.replyThreadRoot.count) + ' 条')
                .fontSize(11)
                .fontColor('#9499A0')
            }
            .width('100%')
            .height(42)
          }
          .width('100%')
        }
        LazyForEach(this.threadSource, (item: ReplyItem) => {
          ListItem() {
            ReplyCard({
              item: item,
              showPreview: false,
              threadDepth: this.threadMeta(item).depth,
              threadGuides: this.threadMeta(item).guides,
              threadHasChildren: this.threadMeta(item).hasChildren,
              threadCollapsed: this.threadMeta(item).collapsed,
              parentLabel: item.parentRpid > 0 && item.parentRpid !== this.replyThreadRoot.rpid ?
                this.threadParentName(item) : '',
              version: this.replyLikeVersion,
              upMid: this.detail.upMid,
              onLike: (reply: ReplyItem) => this.actionReplyLike(reply),
              onDislike: (reply: ReplyItem) => this.actionReplyDislike(reply),
              onShare: (reply: ReplyItem) => this.shareReplyAsImage(reply),
              onSelectReply: (reply: ReplyItem) => {
                this.replyTargetRpid = reply.rpid;
                this.replyTargetName = reply.uname;
                this.replyFocusTick++;
              },
              onToggleThread: (reply: ReplyItem) => this.toggleThreadBranch(reply),
              onDeleted: (reply: ReplyItem) => {
                this.threadRemoveReply(reply);
              },
            })
          }
          // 稳定 key + updateItem(onDataChange)定向刷新：key 变化会销毁重建组件导致"闪"，
          // 因此 key 只取 rpid；点赞/点在 mutate 后经 BasicDataSource.updateItem 通知该项重渲染。
        }, (item: ReplyItem) => String(item.rpid))
        ListItem() {
          this.LoadMoreFooter({
            loading: this.threadLoading,
            hasMore: this.threadHasMore,
            moreText: '继续加载更多回复',
            endText: '—— 回复到底啦 ——',
            onTap: () => {
              if (this.threadHasMore && !this.threadLoading) this.loadThreadReplies(false);
            },
          })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.Off)
      .cachedCount(3)
      .onReachEnd(() => {
        this.loadThreadReplies(false);
      })
      .onScrollFrameBegin((offset: number, state: ScrollState) => {
        return { offsetRemain: this.onContentScrollFrame(offset, this.threadScroller, state) };
      })
      this.ReplyInputBar()
      if (this.emotePanelOpen) this.EmotePanel()
    }
    .width('100%')
    .height('100%')
    .translate({ y: this.replyViewOffsetY })
    .opacity(this.replyViewOpacity)
  }

  @Builder
  ReplyTab() {
      Column() {
        this.ReplySortBar()
        if (this.replySource.isEmpty()) {
          Column() {
            LoadingView({
              loading: this.replyLoading,
              empty: !this.replyLoading,
              emptyText: '还没有评论，快来抢沙发～',
              onRetry: () => {
                this.loadReplies(true);
              },
            })
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          List({ scroller: this.replyScroller }) {
            LazyForEach(this.replySource, (item: ReplyItem) => {
              ListItem() {
                ReplyCard({
                  item: item,
                  showPreview: true,
                  version: this.replyLikeVersion,
                  upMid: this.detail.upMid,
                  onLike: (reply: ReplyItem) => this.actionReplyLike(reply),
              onDislike: (reply: ReplyItem) => this.actionReplyDislike(reply),
                  onShare: (reply: ReplyItem) => this.shareReplyAsImage(reply),
                  // 主评论列表："回复"按钮 = 打开该评论的楼中楼面板（与 B 站一致），
                  // 面板内的"相关回复"列表再负责逐一选中/回复。
                  onSelectReply: (reply: ReplyItem) => this.openReplyThread(reply),
                  onOpenThread: (reply: ReplyItem) => this.openReplyThread(reply),
                  onDeleted: (reply: ReplyItem) => {
                    this.replySource.reset(this.replySource.getAll().filter((x: ReplyItem) => x.rpid !== reply.rpid));
                    this.detail.reply = Math.max(0, this.detail.reply - 1);
                  },
                })
              }
              // 稳定 key + updateItem 定向刷新（不重建组件）。rev 进 key 会引发重建闪烁。
            }, (item: ReplyItem) => String(item.rpid))
            ListItem() {
              this.LoadMoreFooter({
                loading: this.replyLoading,
                hasMore: this.replyHasMore,
                moreText: '继续加载更多评论',
                endText: '—— 评论到底啦 ——',
                onTap: () => {
                  if (this.replyHasMore && !this.replyLoading) this.loadReplies(false);
                },
              })
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 12, right: 12 })
          .scrollBar(BarState.Off)
          .cachedCount(3)
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            return { offsetRemain: this.onContentScrollFrame(offset, this.replyScroller, state) };
          })
          .onReachEnd(() => {
            if (this.replyHasMore) {
              this.loadReplies(false);
            }
          })
        }
        this.ReplyInputBar()
        if (this.emotePanelOpen) this.EmotePanel()
      }
      .width('100%')
      .height('100%')
      .translate({ y: this.replyViewOffsetY })
      .opacity(this.replyViewOpacity)
  }

  @Builder
  RelatedRow(item: VideoItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(item.cover)
          .width(120)
          .height(68)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
        Text(formatDuration(item.duration))
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#88000000')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(3)
          .margin({ right: 4, bottom: 4 })
      }
      .width(120)
      .clip(true)
      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(13)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
        Row({ space: 8 }) {
          Text(item.upName)
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(1)
            .layoutWeight(1)
          Row({ space: 3 }) {
            Image($r('app.media.ic_play'))
              .width(12).height(12).fillColor('#9499A0')
            Text(item.playText)
              .fontSize(10).fontColor('#9499A0')
          }
          Row({ space: 3 }) {
            Image($r('app.media.ic_comment'))
              .width(12).height(12).fillColor('#9499A0')
            Text(formatCount(item.reply))
              .fontSize(10).fontColor('#9499A0')
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    // 标题/UP 与封面上端对齐（Row 默认垂直居中会让文字偏下）
    .alignItems(VerticalAlign.Top)
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
      AppNavStack.replacePathByName(NAV_VIDEO_DETAIL, param);
    })
  }

  @Builder
  CompactDetailTab(label: string, index: number) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(this.visualTab === index ? 15 : 14)
        .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.visualTab === index ? (this.isDark ? '#F1F2F3' : '#18191C') : '#9499A0')
        .animation({ duration: 220, curve: Curve.EaseOut })
      Row()
        .width(20).height(3).borderRadius(1.5)
        .backgroundColor(this.accent)
        .opacity(this.visualTab === index ? 1 : 0)
        .scale({ x: this.visualTab === index ? 1 : 0.35, y: 1 })
        .animation({ duration: 220, curve: Curve.EaseOut })
    }
    .height(44)
    .padding({ left: 9, right: 9 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.tabsController.changeIndex(index);
      if (index === 0) this.replyThreadOpen = false;
    })
  }

  @Builder
  DetailToolbar() {
    Row({ space: 5 }) {
      this.CompactDetailTab('简介', 0)
      this.CompactDetailTab('评论 ' + formatCount(this.detail.reply), 1)
      Blank()
      Row() {
        TextInput({ text: this.danmakuDraft,
          placeholder: this.danmakuSending ? '发送中…' : '点我发弹幕' })
          .layoutWeight(1)
          .height(36)
          .fontSize(13)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .placeholderColor(this.isDark ? '#8E9198' : '#9A9EA5')
          .backgroundColor('#00000000')
          .padding({ left: 12, right: 6 })
          .enterKeyType(EnterKeyType.Send)
          .onChange((value: string) => {
            this.danmakuDraft = value;
          })
          .onSubmit(() => this.sendVideoDanmaku())
        Stack({ alignContent: Alignment.Center }) {
          Text('弹')
            .width(27)
            .height(27)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#C1C4CA' : '#676B72')
            .textAlign(TextAlign.Center)
            .border({ width: 1.5, color: this.isDark ? '#8D9199' : '#7B7F86' })
            .borderRadius(7)
          if (this.danmakuOn) {
            Text('✓')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.accent)
              .width(14)
              .height(14)
              .textAlign(TextAlign.Center)
              .backgroundColor(this.isDark ? '#292B30' : '#F5F6F7')
              .position({ x: 27, y: 22 })
          }
        }
        .width(44)
        .height(36)
        .border({ width: { left: 0.5 }, color: this.isDark ? '#42444A' : '#E1E3E7' })
        .onClick(() => this.danmakuOn = !this.danmakuOn)
      }
      .width(Math.min(168, Math.max(132, this.screenWidthVp * 0.39)))
      .height(36)
      .borderRadius(18)
      .border({ width: 0.5, color: this.isDark ? '#42444A' : '#E1E3E7' })
      .backgroundColor(this.isDark ? '#292B30' : '#F5F6F7')
      .clip(true)
    }
    .width('100%').height(56)
    .padding({ left: 6, right: 10 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }

  // 简介 / 评论：相关视频已并入简介底部。
  @Builder
  DetailTabs() {
    Tabs({ barPosition: BarPosition.Start, index: this.tab, controller: this.tabsController }) {
      TabContent() {
        this.IntroTab()
      }
      .tabBar('')
      TabContent() {
        this.ReplyTab()
      }
      .tabBar('')
    }
    .width('100%')
    .layoutWeight(1)
    .barHeight(0)
    .barMode(BarMode.Fixed)
    .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
    .animationMode(AnimationMode.CONTENT_FIRST)
    .animationDuration(320)
    .animationCurve(Curve.EaseInOut)
    .onAnimationStart((index: number, targetIndex: number, extraInfo: TabsAnimationEvent) => {
      // 只更新标签视觉状态；不能在这里改 Tabs 绑定 index，否则会中途强制跳页。
      this.visualTab = targetIndex;
      if (targetIndex === 0) this.replyThreadOpen = false;
    })
    .onChange((index: number) => {
      this.tab = index;
      this.visualTab = index;
      if (index === 0) this.replyThreadOpen = false;
    })
    .divider({ strokeWidth: 0 })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .clip(true)
  }

  // 投币动图仅作视觉素材，选项文案保持为清晰的“1 枚 / 2 枚”。
  @Builder
  CoinOption(characterImage: Resource, choice: number, enabled: boolean) {
    Column({ space: 2 }) {
      Image(characterImage)
        .width(84)
        .height(112)
        .objectFit(ImageFit.Contain)
      Text(String(choice) + ' 枚')
        .fontSize(12)
        .fontWeight(this.coinChoice === choice ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.coinChoice === choice ? this.accent : (this.isDark ? '#D8D8DC' : '#5A5F66'))
    }
    .layoutWeight(1)
    .height(150)
    .padding({ left: 6, right: 6, top: 7, bottom: 8 })
    .borderRadius(14)
    .border({ width: this.coinChoice === choice ? 2 : 0.5, color: this.coinChoice === choice ? this.accent : '#33808080' })
    .backgroundColor(this.coinChoice === choice ? colorWithAlpha(this.accent, '14') : '#0A808080')
    .opacity(enabled ? 1 : 0.38)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      if (enabled) this.coinChoice = choice;
    })
  }

  @Builder
  CoinSheet() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          if (!this.actionBusy) this.coinSheetOpen = false;
        })
      Column({ space: 12 }) {
        Row() {
          Text('给 UP 主投硬币')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Blank()
          Image($r('app.media.ic_close'))
            .width(20)
            .height(20)
            .fillColor('#9499A0')
            .onClick(() => {
              if (!this.actionBusy) this.coinSheetOpen = false;
            })
        }
        .width('100%')
        Text('单个视频最多可投 2 枚，已投 ' + String(this.coinCountByMe) + ' 枚')
          .fontSize(12)
          .fontColor('#9499A0')
          .width('100%')
        Row({ space: 12 }) {
          this.CoinOption($r('app.media.bili_coin_22'), 1, true)
          this.CoinOption($r('app.media.bili_coin_33'), 2, this.coinCountByMe === 0)
        }
        .width('100%')
        Row({ space: 8 }) {
          Checkbox({ name: 'coinLike', group: 'coin' })
            .width(20)
            .height(20)
            .select(this.coinWithLike)
            .selectedColor(this.accent)
            .onChange((checked: boolean) => {
              this.coinWithLike = checked;
            })
          Text('同时点赞视频')
            .fontSize(13)
            .fontColor(this.isDark ? '#D8D8DC' : '#5A5F66')
        }
        .width('100%')
        Button(this.actionBusy ? '投币中…' : '确认投币')
          .width('100%')
          .height(42)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accent)
          .borderRadius(21)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.submitCoin();
          })
      }
      .width(Math.min(322, Math.max(280, this.screenWidthVp - 24)))
      .padding({ left: 18, right: 18, top: 18, bottom: 18 })
      .borderRadius(20)
      .backgroundColor(this.isDark ? '#25262A' : '#FFFFFF')
      .shadow({ radius: 28, color: '#66000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }

  /** 模糊底图用小尺寸封面，借助 B 站图片缩略参数降低下载与解码开销。 */
  private coverThumb(url: string): string {
    return url.startsWith('http') ? url + '@480w_270h_1c.webp' : url;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 播放器始终保活。进入评论仅用黑色栏遮住并收起高度，避免切 Tab 时销毁 AVPlayer 导致暂停。
        Stack({ alignContent: Alignment.Center }) {
          if (this.playUrl.length > 0) {
            PlayerView({
              videoUrl: this.playUrl,
              videoUrls: this.playUrls,
              audioUrls: this.playAudioUrls,
              qualityOptions: this.qualityOptions,
              subtitles: this.subtitleTracks,
              currentQuality: this.currentQuality,
              sourceVersion: this.playerSourceVersion,
              initialSeekSeconds: this.initialSeekSeconds,
              aid: this.detail.aid,
              bvid: this.bvid,
              cid: this.currentCid,
              videoDuration: this.currentPageDuration(),
              videoTitle: this.detail.title,
              videoCover: this.detail.cover,
              ownerName: this.detail.upName,
              ownerFace: this.detail.upFace,
              liked: this.liked,
              coined: this.coinCountByMe > 0,
              favorited: this.favorited,
              externalDanmakuOn: this.danmakuOn,
              externalDanmakuCtx: this.danmakuCtx,
              onDanmakuEngineReady: (engine: PlayerDanmakuEngine) => {
                this.dmEngineRef = engine;
                this.syncDanmakuViewport();
              },
              localDanmakuText: this.localDanmakuText,
              localDanmakuToken: this.localDanmakuToken,
              compactMode: !this.playerFullscreen && this.visiblePlayerHeight() < 176,
              onBack: () => {
                AppNavStack.pop();
              },
              onFullscreenChange: (fullscreen: boolean) => {
                this.playerFullscreen = fullscreen;
                // 全屏时评论回复 Sheet 应随评论区一起隐藏，不能叠在视频画面上。
                if (fullscreen) this.closeReplyThread();
              },
              onPlayingChange: (playing: boolean) => {
                this.onPlayerPlayingChange(playing);
              },
              onVideoSizeChange: (width: number, height: number) => {
                this.onVideoSizeChange(width, height);
              },
              onResumeRequest: () => {
                this.expandPlayerForResume();
              },
              onDanmakuChange: (enabled: boolean) => {
                this.danmakuOn = enabled;
              },
              dmDraft: this.danmakuDraft,
              dmSending: this.danmakuSending,
              onDmDraftChange: (value: string) => {
                this.danmakuDraft = value;
              },
              onDmSend: () => {
                this.sendVideoDanmaku();
              },
              onProgress: (seconds: number) => {
                this.videoProgressSeconds = seconds;
                this.reportVideoHeartbeat(seconds);
              },
              onOnlineCount: (value: string) => {
                this.playerOnlineTotal = value;
              },
              onEnded: () => {
                this.onPlayerEnded();
              },
              onEndPlayNow: () => {
                this.onPlayerEndPlayNow();
              },
              endRecTitle: this.endRecTitle,
              endRecCover: this.endRecCover,
              endRecUpName: this.endRecUpName,
              endRecPlayText: this.endRecPlayText,
              endRecDuration: this.endRecDuration,
              endRecToken: this.endRecToken,
              onLike: () => {
                this.actionLike();
              },
              onCoin: () => {
                this.openCoinSheet();
              },
              onFavorite: () => {
                this.actionFavorite();
              },
              onShare: () => {
                this.actionShare();
              },
            })
          } else {
            Stack({ alignContent: Alignment.Center }) {
              Image(this.coverThumb(this.detail.cover))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .blur(18)
                .brightness(0.5)
              // 封面取色氛围光晕
              Column()
                .width('100%')
                .height('100%')
                .radialGradient({
                  center: ['50%', '40%'],
                  radius: '70%',
                  colors: [[colorWithAlpha(this.pageTint, '66'), 0.0], [colorWithAlpha(this.pageTint, '00'), 1.0]],
                })
              Column({ space: 8 }) {
                Image(this.detail.cover)
                  .width(140)
                  .aspectRatio(16 / 9)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(8)
                Text(this.playUrl.length === 0 && !this.loading ? '获取播放地址失败' : '加载播放地址中...')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
              }
            }
          }
        }
        .width('100%')
        .height(this.playerFullscreen ? '100%' : this.visiblePlayerHeight())
        .clip(true)
        .backgroundColor('#000000')

        // 信息区
        if (!this.playerFullscreen) {
          // 黑色衬底条：垫在信息区圆角背后，圆角缝隙露出的是黑底而不是视频画面（竖屏视频播放区很高，缝里会透出画面）。
          Row()
            .width('100%')
            .height(12)
            .backgroundColor('#000000')
            .margin({ bottom: -12 })
          if (this.loading) {
            LoadingView({ loading: true })
          } else if (this.errorText.length > 0) {
            LoadingView({
              loading: false,
              empty: false,
              errorText: this.errorText,
              onRetry: () => {
                this.init();
              },
            })
          } else {
            Column() {
              this.DetailToolbar()
              this.DetailTabs()
            }
            .width('100%')
            .layoutWeight(1)
            // 小圆角上沿：面板顶部与播放区底边齐平，圆角缝只露出上方黑色衬底条。
            .borderRadius({ topLeft: 12, topRight: 12 })
            .clip(true)
            .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
          }
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.playerFullscreen ? 0 : Immersive.statusBarHeight() })

      // 视频上方状态栏固定纯黑，避免封面倒影干扰。
      if (!this.playerFullscreen) {
        Column()
        .width('100%')
        .height(Immersive.statusBarHeight())
        .backgroundColor('#000000')
        .hitTestBehavior(HitTestMode.None)

      }

      // 弹幕独立层：移出被收起动画逐帧 resize 的播放器容器。画布节点尺寸恒定
      // （展开态/全屏高度），收起/展开只收缩外层裁剪窗口，避免 Canvas 后备缓冲
      // 被反复清空造成的弹幕闪烁。整层不拦截触摸（弹幕点按由 PlayerView 根手势处理，
      // 两者坐标系一致：均以播放区左上角为原点）。
      if (this.playUrl.length > 0) {
        // alignContent TopStart：画布与视频一律顶边对齐（引擎坐标原点 = 播放区左上角），
        // 收起时画布超高部分从底部裁掉，而不是居中导致弹幕整体下偏。
        Stack({ alignContent: Alignment.TopStart }) {
          Canvas(this.danmakuCtx)
            .width('100%')
            .height(this.danmakuCanvasHeight())
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height(this.playerFullscreen ? '100%' : this.visiblePlayerHeight())
        .margin({ top: this.playerFullscreen ? 0 : Immersive.statusBarHeight() })
        .clip(true)
        .hitTestBehavior(HitTestMode.None)
        .visibility(this.danmakuOn ? Visibility.Visible : Visibility.Hidden)
      }

      if (this.coinSheetOpen) {
        this.CoinSheet()
      }
      if (this.favPickOpen) {
        this.FavPickSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .onAreaChange(() => {
      this.refreshScreenSize();
    })
    .bindSheet($$this.replyThreadOpen, this.VideoThreadSheet(), {
      height: this.replySheetHeight(),
      dragBar: false,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: this.isDark ? '#18191C' : '#FFFFFF',
      // 允许 Sheet 外继续与页面交互：点击视频不会误关回复；系统侧滑返回仍由
      // NavDestination onBackPressed 拦截并关闭回复 Sheet。
      enableOutsideInteractive: true,
    })
  }
}
