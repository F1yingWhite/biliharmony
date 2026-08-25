/**
 * 视频详情页：沉浸式播放器 + 封面取色动态主题 + 简介/评论/相关。
 * 大区块已按职责拆到组件：评论 Tab（VideoReplyTab）、相关推荐行（RelatedVideoRow）、
 * 投币弹窗（CoinSheetView）、收藏夹多选（FavPickSheetView）、楼中楼面板（ReplyThreadPanel）。
 */
import { display, FrameCallback, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { inputMethod } from '@kit.IMEKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Immersive } from '../common/Immersive';
import { Haptic } from '../common/Haptic';
import { AppNavStack, HERO_BG_SNAPSHOT_KEY, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  ImageViewerSrcRect, NAV_LOGIN, NAV_VIDEO_DETAIL, NAV_USER_SPACE, VideoDetailParam, UserSpaceParam } from '../common/AppRouter';
import { VideoDetail, VideoItem, ReplyItem, PlayUrlInfo, VideoPage, VideoQualityOption, VideoRelationState,
  BiliEmote, BiliEmotePackage, FavoriteFolderItem, UserStat, SpaceArcData, SubtitleTrack, UgcSeasonEpisode } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { PlayerView } from '../components/player/PlayerView';
import { AppTheme } from '../common/AppTheme';
import { PlayerDanmakuEngine } from '../components/player/PlayerDanmakuEngine';
import { LoadingView } from '../components/LoadingView';
import { ImageColor, ImagePalette } from '../common/ImageColor';
import { UserStore } from '../common/UserStore';
import { asNumber, asObject, colorWithAlpha, formatCount, formatDate } from '../common/Utils';
import { PlayerCommandBus } from '../common/PlayerCommandBus';
import { BasicDataSource } from '../common/BasicDataSource';
import { ReplyReactionHooks, runReplyDislike, runReplyLike } from '../common/ReplyMutation';
import { ReplyEmotePanel } from '../components/reply/ReplyEmotePanel';
import { ReplyThreadPanel } from '../components/reply/ReplyThreadPanel';
import { RelatedVideoRow } from '../components/video/VideoRelatedRow';
import { VideoReplyTab } from '../components/video/VideoReplyTab';
import { CoinSheetView } from '../components/video/CoinSheetView';
import { FavPickSheetView } from '../components/video/FavPickSheetView';
import { VideoActionItem } from '../components/video/VideoActionItem';
import { ReplyShareCard, makeReplyQr, makeReplyShareSnapshot,
  sharePixelMapAsImage } from '../components/reply/ReplyShareCard';
import { safeToast } from '../common/Toast';
import { CommentApi } from '../api/CommentApi';
import { FavoriteApi } from '../api/FavoriteApi';
import { FeedApi } from '../api/FeedApi';
import { HistoryApi } from '../api/HistoryApi';
import { UserApi } from '../api/UserApi';
import { CommentLog } from '../common/CommentLog';
import { VideoDetailGeometry } from '../common/VideoDetailGeometry';
import { VideoIntroSection } from '../components/video/VideoIntroSection';

/** showDialog 按钮声明（promptAction 的 Button 类型不便直接引用）。 */
interface ReportButtonItem {
  text: string;
  color: string;
}

/** 等下一次 VSync 已提交源矩形后再开始 hero，避免用固定延时猜首帧时机。 */
class VideoHeroFrameCallback extends FrameCallback {
  private task: () => void;

  constructor(task: () => void) {
    super();
    this.task = task;
  }

  onFrame(_frameTimeInNano: number): void {
    this.task();
  }
}

@Component
export struct VideoDetailPage {
  @State loading: boolean = true;
  @State errorText: string = '';
  @State detail: VideoDetail = new VideoDetail();
  @State playUrl: string = '';
  @State playUrls: Array<string> = [];
  @State playAudioUrls: Array<string> = [];
  @State playbackAddressFailed: boolean = false;
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
  // 相关推荐卡 ⋮ 菜单（举报/不想看）改用文末 RelatedMoreDot 组件：
  // 每行独立弹窗状态（页面级共享 @State 会让所有行的 bindPopup 同时弹出）。
  // 播完结束画面的推荐卡（推荐列表第一条 / 合集下一集）
  @State endRecTitle: string = '';
  @State endRecCover: string = '';
  @State endRecUpName: string = '';
  @State endRecPlayText: string = '';
  @State endRecDuration: number = 0;
  @State endRecToken: number = 0;
  /** 横屏结束画面推荐列表（首条与竖屏"立即播放"同目标）。 */
  @State endRecList: Array<VideoItem> = [];
  /** 播完态：播放区高度收敛为统一的推荐画面高度；重播/换视频/恢复播放时复位。 */
  @State playerEnded: boolean = false;
  @State upFollowerCount: number = -1;
  @State upVideoCount: number = -1;
  @State replyCursor: string = '';
  @State replyHasMore: boolean = true;
  @State replyLoading: boolean = false;
  @State replyLoadError: string = '';
  @State replyItemCount: number = 0;
  @State replyPrefetchCount: number = 0;
  // 回复详情是视频页内的二级导航状态；放入 AppStorage 供 NavDestination
  // 的系统返回/侧滑回调优先关闭，避免直接把整个视频页弹出。
  @StorageLink('videoReplyThreadOpen') replyThreadOpen: boolean = false;
  @StorageLink('videoReplyThreadCloseRequest') @Watch('onReplyThreadCloseRequested') replyThreadCloseRequest: number = 0;
  @StorageLink('videoReplyComposerCloseRequest') @Watch('onReplyComposerCloseRequested')
  replyComposerCloseRequest: number = 0;
  @State replyThreadRoot: ReplyItem = new ReplyItem();
  @State threadCursor: string = '';
  @State threadHasMore: boolean = true;
  @State threadLoading: boolean = false;
  @State threadPrefetchCount: number = 0;
  /** 当前输入栏回复所属的根评论；为 0 时发布一级评论。与详情面板是否打开相互独立。 */
  @State replyTargetRootRpid: number = 0;
  @State replyTargetRpid: number = 0;
  @State replyTargetName: string = '';
  /** 主评论输入栏与详情输入栏分别计数，避免两个已挂载编辑器同时抢焦点。 */
  @State replyFocusTick: number = 0;
  @State threadReplyFocusTick: number = 0;
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
  /** 退出全屏的视觉层：逻辑全屏保持到 DID_ROTATE，只让外层裁剪窗口边旋转边缩小。 */
  @State playerFullscreenExitVisual: boolean = false;
  @State playerFullscreenExitHeight: number = 0;
  @State playerFullscreenExitTop: number = 0;
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
  /** 卡片 hero：只移动封面边界，详情内容不参与缩放。 */
  @State entryContentOpacity: number = 1;
  @State heroVisible: boolean = false;
  @State heroSource: string = '';
  @State heroX: number = 0;
  @State heroY: number = 0;
  @State heroWidth: number = 0;
  @State heroHeight: number = 0;
  @State heroRadius: number = 0;
  @State heroOpacity: number = 1;
  /** 详情页级稳定封面：跨过占位节点 -> XComponent 的替换期，只在官方首帧确认后淡出。 */
  @State startupCoverVisible: boolean = true;
  /** 固定使用入口卡片携带的封面，详情接口返回后也不在起播途中换图。 */
  private entryCoverSource: string = '';
  /** 入场是否走了"卡片矩形放大"（有值且取到屏幕尺寸才算），退出时决定是否镜面收合。 */
  private entryFromRect: boolean = false;
  /** 首页整卡一镜到底：快照与固定尺寸详情内容共同放在裁剪容器中缩放。 */
  private entryFromWholeCard: boolean = false;
  @State wholeCardAnimating: boolean = false;
  @State wholeCardSnapshot: image.PixelMap | null = null;
  @State wholeCardSnapshotOpacity: number = 0;
  @State wholeCardScale: number = 1;
  @State wholeCardTranslateX: number = 0;
  @State wholeCardTranslateY: number = 0;
  @State wholeCardClipHeight: number = 0;
  @State wholeCardRadius: number = 0;
  private wholeCardSnapshotHeight: number = 0;
  /** 卡片封面已在源矩形就位，等待下一次 VSync 开始。 */
  private entranceArmed: boolean = false;
  /** 横屏结束页点推荐时，等系统真正旋回竖屏后再创建下一视频页。 */
  private pendingVideoNavigation: VideoDetailParam | null = null;
  private pendingVideoReplace: boolean = false;
  private initStarted: boolean = false;
  private closing: boolean = false;
  /** 系统返回/侧滑经 Index NavDestination 拦截后置位，页面内执行收合动画。 */
  @StorageProp('videoDetailCloseRequest') @Watch('onCloseRequested') closeRequest: number = 0;
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
  /** RESIZE 避让后的页面实际高度；键盘弹出时小于物理屏幕高度。 */
  @State pageHeightVp: number = 0;
  private playerHeightKey: string = '';
  private playerHeightValue: number = 0;
  /** 进入全屏前的竖屏播放区高度，旋转退出时的稳定落点。 */
  private playerFullscreenRestoreHeight: number = 0;
  private dmEngineRef: PlayerDanmakuEngine | null = null;
  // playerCollapse 的未量化原值；@State 只按阈值量化写入，降低滚动期整页重排频率。
  private playerCollapseRaw: number = 0;
  private replySource: BasicDataSource<ReplyItem> = new BasicDataSource<ReplyItem>();
  /** 已发布但评论列表接口尚未索引到的本地楼层；刷新/切排序时仍保留。 */
  private localSentReplies: Array<ReplyItem> = [];
  private ugcSource: BasicDataSource<UgcSeasonEpisode> = new BasicDataSource<UgcSeasonEpisode>();
  @State threadAllReplies: Array<ReplyItem> = [];
  // 评论分享卡离屏渲染用的待截内容；只在生成分享图期间短暂赋值。
  private shareCardItem: ReplyItem = new ReplyItem();
  private shareCardQr: image.PixelMap | null = null;
  private shareCardBusy: boolean = false;
  private mainReplyComposerFocused: boolean = false;
  private threadReplyComposerFocused: boolean = false;

  onReplyThreadCloseRequested(): void {
    this.closeReplyThread();
  }

  onReplyComposerCloseRequested(): void {
    this.dismissReplyComposer();
  }

  private syncReplyComposerActive(emoteOpen: boolean = this.emotePanelOpen): void {
    AppStorage.setOrCreate<boolean>('videoReplyComposerActive', emoteOpen ||
      this.mainReplyComposerFocused || this.threadReplyComposerFocused);
  }

  private onReplyComposerFocusChanged(focused: boolean, thread: boolean): void {
    if (thread) this.threadReplyComposerFocused = focused;
    else this.mainReplyComposerFocused = focused;
    // 系统键盘自行消费返回键时会触发 blur；空草稿同时退出定向回复态。
    if (!focused && !this.emotePanelOpen && this.replyDraft.trim().length === 0) {
      if (this.replyThreadOpen) {
        this.replyTargetRootRpid = this.replyThreadRoot.rpid;
        this.replyTargetRpid = this.replyThreadRoot.rpid;
        this.replyTargetName = this.replyThreadRoot.uname;
      } else {
        this.replyTargetRootRpid = 0;
        this.replyTargetRpid = 0;
        this.replyTargetName = '';
      }
    }
    this.syncReplyComposerActive();
  }

  private dismissReplyComposer(): void {
    this.emotePanelOpen = false;
    try {
      inputMethod.getController().hideTextInput().catch(() => {});
    } catch (e) {
    }
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
    }
    this.mainReplyComposerFocused = false;
    this.threadReplyComposerFocused = false;
    if (this.replyDraft.trim().length === 0) {
      if (this.replyThreadOpen) {
        this.replyTargetRootRpid = this.replyThreadRoot.rpid;
        this.replyTargetRpid = this.replyThreadRoot.rpid;
        this.replyTargetName = this.replyThreadRoot.uname;
      } else {
        this.replyTargetRootRpid = 0;
        this.replyTargetRpid = 0;
        this.replyTargetName = '';
      }
    }
    this.syncReplyComposerActive(false);
  }

  closeReplyThread(): void {
    if (!this.replyThreadOpen) return;
    CommentLog.info('ui.thread.close', 'aid=' + String(this.detail.aid) + ' root=' +
      String(this.replyThreadRoot.rpid) + ' rows=' + String(this.threadAllReplies.length));
    this.emotePanelOpen = false;
    this.mainReplyComposerFocused = false;
    this.threadReplyComposerFocused = false;
    this.syncReplyComposerActive(false);
    this.replyTargetRootRpid = 0;
    this.replyTargetRpid = 0;
    this.replyTargetName = '';
    this.replyThreadAnimating = true;
    this.getUIContext().animateTo({
      duration: 140,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.replyThreadAnimating = false;
      },
    }, () => {
      this.replyThreadOpen = false;
    });
  }

  /** 楼中楼里删掉一条子回复：连同其子孙一起从页面回复源集合移除（面板内视图树由组件自维护）。 */
  private threadRemoveReply(target: ReplyItem): void {
    const before: number = this.threadAllReplies.length;
    const blocked: Set<number> = new Set<number>();
    blocked.add(target.rpid);
    // 收集 target 的直接子回复（rootRpid=target.rpid）及更外层子孙，用深度优先收集。
    let changed: boolean = true;
    const all: Array<ReplyItem> = this.threadAllReplies;
    while (changed) {
      changed = false;
      for (let i: number = 0; i < all.length; i++) {
        if (!blocked.has(all[i].rpid) && blocked.has(all[i].rootRpid)) {
          blocked.add(all[i].rpid);
          changed = true;
        }
      }
    }
    this.threadAllReplies = all.filter((x: ReplyItem) => !blocked.has(x.rpid));
    CommentLog.info('ui.thread.remove', 'root=' + String(this.replyThreadRoot.rpid) + ' target=' +
      String(target.rpid) + ' removed=' + String(before - this.threadAllReplies.length) +
      ' remaining=' + String(this.threadAllReplies.length));
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
      return VideoDetailGeometry.playerHeight(this.detail, this.currentCid, this.screenWidthVp,
        this.screenHeightVp, Immersive.statusBarHeight(), Immersive.bottomInset(),
        this.realVideoWidth, this.realVideoHeight);
    } catch (e) {
      return 220;
    }
  }

  private minPlayerHeight(): number {
    // 播放中下限抬高到屏幕高的 1/4：竖屏/长屏视频在播放时不会被收成一条细横幅，
    // 画幅未知的加载期也能保持稳定高度，避免“有时很小有时很大”的跳变感。
    // 暂停后才允许收成 96vp 的继续播放横幅（能完整容纳暂停黑幕和居中继续播放提示）。
    if (this.playerPlaying && this.screenHeightVp > 0) {
      return Math.max(160, Math.floor(this.screenHeightVp / 4));
    }
    return 96;
  }

  /** 当前分 P 时长（秒）：弹幕分段数预估用；取不到时回退详情总时长。 */
  private currentPageDuration(): number {
    return VideoDetailGeometry.pageDuration(this.detail, this.currentCid);
  }

  /** 播放中仅长屏/竖向画幅收缩；暂停后任何画幅都可收成继续播放横幅。 */
  private shouldCollapsePlayer(): boolean {
    return VideoDetailGeometry.shouldCollapse(this.playerPlaying, this.detail, this.currentCid,
      this.realVideoWidth, this.realVideoHeight);
  }

  private visiblePlayerHeight(): number {
    // 播完推荐画面与原画幅解耦：收敛到结束画面内容高度（标题+推荐行+重播行+内边距≈154vp），
    // 既不像长视频那样拖一整条高黑屏，也不留中部空隙。
    if (this.playerEnded) {
      return 156;
    }
    const base: number = this.playerHeight();
    return Math.max(this.minPlayerHeight(), base - this.playerCollapse);
  }

  private beginPlayerFullscreenExit(): void {
    if (!this.playerFullscreen || this.playerFullscreenExitVisual) return;
    if (this.screenHeightVp <= 0) this.refreshScreenSize();
    const startHeight: number = this.screenHeightVp > 0 ? this.screenHeightVp : 640;
    const targetHeight: number = this.playerFullscreenRestoreHeight > 0 ?
      this.playerFullscreenRestoreHeight : this.playerHeight();
    this.playerFullscreenExitHeight = startHeight;
    this.playerFullscreenExitTop = 0;
    this.playerFullscreenExitVisual = true;
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      this.playerFullscreenExitHeight = targetHeight;
      this.playerFullscreenExitTop = Immersive.statusBarHeight();
    });
  }

  private finishPlayerFullscreenExit(): void {
    // 先读最终竖屏尺寸，再撤掉全屏标记；Watch 因此只会向弹幕引擎提交正确的竖屏视口。
    this.refreshScreenSize();
    this.playerFullscreen = false;
    this.playerFullscreenExitVisual = false;
    this.playerFullscreenExitHeight = 0;
    this.playerFullscreenExitTop = 0;
    this.flushPendingVideoNavigation();
  }

  /** ⋮ 面板高度 = “默认评论区”（播放区以下信息区）高度，顶边与播放区底边齐平。 */
  private moreSheetHeightValue(): number {
    if (this.playerFullscreen || this.screenHeightVp <= 0) return 0;
    const h: number = this.screenHeightVp - Immersive.statusBarHeight() - this.visiblePlayerHeight();
    return h > 260 ? h : 0;
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
  private replyViewportHeight(): number {
    if (this.screenHeightVp <= 0) this.refreshScreenSize();
    return this.pageHeightVp > 0 ? Math.min(this.screenHeightVp, this.pageHeightVp) : this.screenHeightVp;
  }

  private replySheetTop(): number {
    const normalTop: number = Immersive.statusBarHeight() + this.visiblePlayerHeight();
    // 键盘压缩后若播放器下方不足以容纳标题与展开态输入栏，面板只在此时向上覆盖一小段播放器。
    return Math.min(normalTop, Math.max(0, this.replyViewportHeight() - 180));
  }

  private replySheetHeight(): number {
    const available: number = this.replyViewportHeight() - this.replySheetTop();
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
    // NavDestination 返回时组件实例会复用；离场前的全屏状态不能污染竖屏布局。
    this.playerFullscreen = false;
    this.playerFullscreenExitVisual = false;
    this.playerFullscreenExitHeight = 0;
    this.playerFullscreenExitTop = 0;
    this.pendingVideoNavigation = null;
    this.pendingVideoReplace = false;
    // 上次离页时未完成的请求会因 destroyed 跳过 finally 写状态；返回页面时统一解锁。
    this.replyLoading = false;
    this.replyLoadError = '';
    this.replyItemCount = this.replySource.totalCount();
    this.threadLoading = false;
    this.replySending = false;
    this.emoteLoading = false;
    this.actionBusy = false;
    this.followLoading = false;
    this.danmakuSending = false;
    this.pageSwitchingCid = 0;
    this.replyThreadOpen = false;
    // 弹幕总开关从持久化设置恢复（其余弹幕项由 PlayerView 自行恢复后经此页透传/回传）。
    this.danmakuOn = AppTheme.loadDanmakuSettings().enabled;
    this.bvid = this.param.bvid;
    this.aid = this.param.aid;
    this.entryCoverSource = this.param.cover ?? '';
    this.entryFromRect = false;
    this.entryFromWholeCard = false;
    this.wholeCardAnimating = false;
    this.wholeCardSnapshot = null;
    this.wholeCardSnapshotOpacity = 0;
    this.wholeCardScale = 1;
    this.wholeCardTranslateX = 0;
    this.wholeCardTranslateY = 0;
    this.wholeCardClipHeight = 0;
    this.wholeCardRadius = 0;
    this.wholeCardSnapshotHeight = 0;
    this.entranceArmed = false;
    this.initStarted = false;
    this.closing = false;
    this.entryContentOpacity = 1;
    this.heroVisible = false;
    this.heroOpacity = 1;
    this.startupCoverVisible = true;
    this.refreshScreenSize();
    if (!this.prepareWholeCardEntrance()) this.prepareCardEntrance();
    // 首次 VSync 后立即移动封面；有 hero 时等飞行结束再启动详情加载，避免首帧大量状态更新抢占动画。
    if (this.entryFromWholeCard) this.triggerWholeCardExpansion();
    else this.triggerEntranceExpansion();
    if (!this.entryFromRect && !this.entryFromWholeCard) this.startInit();
  }

  /**
   * 华为官方 CardLongTakeTransition 的核心做法：目标页保持整屏布局，只缩放并裁剪外层容器；
   * 这样动画期间不会因为宽高连续变化而让播放器、标题和工具栏反复重排。
   */
  private prepareWholeCardEntrance(): boolean {
    const rect: ImageViewerSrcRect | undefined = this.param.cardRect;
    const snapshot: image.PixelMap | null = AppStorage.get<image.PixelMap>(HERO_BG_SNAPSHOT_KEY) ?? null;
    AppStorage.delete(HERO_BG_SNAPSHOT_KEY);
    if (rect === undefined || snapshot === null || rect.w <= 0 || rect.h <= 0 ||
      this.screenWidthVp <= 0 || this.screenHeightVp <= 0) return false;
    const scale: number = rect.w / this.screenWidthVp;
    if (!Number.isFinite(scale) || scale <= 0 || scale >= 1) return false;
    const clipHeight: number = rect.h / scale;
    this.entryFromWholeCard = true;
    this.wholeCardAnimating = true;
    this.wholeCardSnapshot = snapshot;
    this.wholeCardSnapshotOpacity = 1;
    this.wholeCardScale = scale;
    this.wholeCardClipHeight = clipHeight;
    this.wholeCardSnapshotHeight = clipHeight;
    this.wholeCardTranslateX = rect.x - (this.screenWidthVp - rect.w) / 2;
    this.wholeCardTranslateY = rect.y - (clipHeight - rect.h) / 2;
    // 圆角会随容器一起缩放，除以 scale 后起始画面恰好保持卡片原有的 6vp 圆角。
    this.wholeCardRadius = 6 / scale;
    this.entryContentOpacity = 0;
    return true;
  }

  private triggerWholeCardExpansion(): void {
    if (!this.entryFromWholeCard || this.destroyed || this.closing) return;
    this.getUIContext().postFrameCallback(new VideoHeroFrameCallback(() => {
      if (this.destroyed || this.closing) return;
      this.getUIContext().animateTo({ duration: 350, curve: Curve.EaseInOut, onFinish: () => {
        this.wholeCardSnapshotOpacity = 0;
        this.wholeCardAnimating = false;
        this.startInit();
      } }, () => {
        this.wholeCardScale = 1;
        this.wholeCardTranslateX = 0;
        this.wholeCardTranslateY = 0;
        this.wholeCardClipHeight = this.screenHeightVp;
        this.wholeCardRadius = 0;
      });
      this.getUIContext().animateTo({ duration: 100, curve: Curve.Sharp }, () => {
        this.entryContentOpacity = 1;
      });
      this.getUIContext().animateTo({ duration: 100, delay: 50, curve: Curve.Sharp }, () => {
        this.wholeCardSnapshotOpacity = 0;
      });
    }));
  }

  /** 播放区在窗口中的 hero 矩形。入场期详情尚未返回，天然稳定为 16:9。 */
  private playerHeroRect(): ImageViewerSrcRect | undefined {
    if (this.screenWidthVp <= 0) return undefined;
    return {
      x: 0,
      y: Immersive.statusBarHeight(),
      w: this.screenWidthVp,
      h: this.visiblePlayerHeight(),
    };
  }

  /** 有 srcRect 时，首帧只把一张独立封面放在源卡片封面上。 */
  private prepareCardEntrance(): void {
    const rect = this.param.srcRect;
    if (rect === undefined || rect.w <= 0 || rect.h <= 0) return;
    if (this.playerHeroRect() === undefined) return;
    this.entryFromRect = true;
    this.entryContentOpacity = 0;
    this.heroSource = this.entryCoverUrl();
    this.heroX = rect.x;
    this.heroY = rect.y;
    this.heroWidth = rect.w;
    this.heroHeight = rect.h;
    this.heroRadius = 10;
    this.heroOpacity = 1;
    this.heroVisible = true;
    this.entranceArmed = true;
  }

  /** VSync 驱动封面飞向播放区；正文稍后淡入，不再出现缩小的完整详情页。 */
  private triggerEntranceExpansion(): void {
    if (!this.entranceArmed || this.destroyed || this.closing) return;
    this.entranceArmed = false;
    const target: ImageViewerSrcRect | undefined = this.playerHeroRect();
    if (target === undefined) {
      this.heroVisible = false;
      this.entryContentOpacity = 1;
      this.startInit();
      return;
    }
    this.getUIContext().postFrameCallback(new VideoHeroFrameCallback(() => {
      if (this.destroyed || this.closing) return;
      this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut, onFinish: () => {
        // 节点透明保活：返回时复用同一张已解码封面，避免重新创建 Image 导致卡顿。
        this.heroOpacity = 0;
        this.startInit();
      } }, () => {
        this.heroX = target.x;
        this.heroY = target.y;
        this.heroWidth = target.w;
        this.heroHeight = target.h;
        this.heroRadius = 0;
      });
      this.getUIContext().animateTo({ duration: 190, delay: 100, curve: Curve.EaseOut }, () => {
        this.entryContentOpacity = 1;
      });
    }));
  }

  private startInit(): void {
    if (this.initStarted || this.destroyed) return;
    this.initStarted = true;
    this.init().catch(() => {
    });
  }

  onCloseRequested(): void {
    this.goBack();
  }

  private beginHeroNavPop(): void {
    AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
    AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
    AppNavStack.pop();
  }

  /** 镜面退出：当前播放区封面收回源封面，详情正文独立淡出。 */
  goBack(): void {
    if (this.closing) return;
    this.closing = true;
    if (this.entryFromWholeCard && this.param.cardRect !== undefined && this.screenWidthVp > 0) {
      const rect: ImageViewerSrcRect = this.param.cardRect;
      const scale: number = rect.w / this.screenWidthVp;
      const clipHeight: number = rect.h / scale;
      // 从正常的整屏布局切回固定尺寸动画层；两者此刻视觉尺寸相同，不会产生跳帧。
      this.wholeCardScale = 1;
      this.wholeCardTranslateX = 0;
      this.wholeCardTranslateY = 0;
      this.wholeCardClipHeight = this.screenHeightVp;
      this.wholeCardRadius = 0;
      this.wholeCardSnapshotOpacity = 0;
      this.entryContentOpacity = 1;
      this.wholeCardAnimating = true;
      this.getUIContext().postFrameCallback(new VideoHeroFrameCallback(() => {
        this.beginHeroNavPop();
        this.getUIContext().animateTo({ duration: 350, curve: Curve.EaseInOut }, () => {
          this.wholeCardScale = scale;
          this.wholeCardTranslateX = rect.x - (this.screenWidthVp - rect.w) / 2;
          this.wholeCardTranslateY = rect.y - (clipHeight - rect.h) / 2;
          this.wholeCardClipHeight = clipHeight;
          this.wholeCardRadius = 6 / scale;
        });
        this.getUIContext().animateTo({ duration: 50, delay: 150, curve: Curve.Friction }, () => {
          this.wholeCardSnapshotOpacity = 1;
        });
        this.getUIContext().animateTo({ duration: 50, delay: 200, curve: Curve.Friction }, () => {
          this.entryContentOpacity = 0;
        });
      }));
      return;
    }
    const rect = this.param.srcRect;
    if (this.entryFromRect && rect !== undefined) {
      const start: ImageViewerSrcRect | undefined = this.playerHeroRect();
      if (start !== undefined) {
        this.heroSource = this.entryCoverUrl();
        this.heroX = start.x;
        this.heroY = start.y;
        this.heroWidth = start.w;
        this.heroHeight = start.h;
        this.heroRadius = 0;
        this.heroVisible = true;
        this.heroOpacity = 1;
        this.getUIContext().postFrameCallback(new VideoHeroFrameCallback(() => {
          this.beginHeroNavPop();
          this.getUIContext().animateTo({ duration: 170, curve: Curve.EaseOut }, () => {
            this.entryContentOpacity = 0;
          });
          this.getUIContext().animateTo({ duration: 320, curve: Curve.EaseOut }, () => {
            this.heroX = rect.x;
            this.heroY = rect.y;
            this.heroWidth = rect.w;
            this.heroHeight = rect.h;
            this.heroRadius = 10;
          });
        }));
        return;
      }
    }
    AppNavStack.pop();
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
    return followers + ' 粉丝  ' + videos + ' 视频';
  }

  /** 首次播放地址：先用默认 cid 请求，若服务端返回 last_play_cid 指向其他分 P，则改拉该分 P 并续播。 */
  private async loadInitialPlayback(detail: VideoDetail): Promise<boolean> {
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
    // 当前没有自适应码率切换能力，“自动”若直接请求 127 会固定选中 4K。
    // 手机上默认封顶 1080P；高码率类偏好才请求最高画质，智能省流固定 720P。
    const qualityPref: number = AppStorage.get<number>('videoQualityPref') ?? 0;
    const initialQuality: number = qualityPref === 3 ? 64 : (qualityPref === 0 ? 80 : 127);
    let info: PlayUrlInfo | null = await BiliApi.getPlayUrl(detail.aid, detail.bvid, initialCid, initialQuality);
    if (info === null || info.urls.length === 0 || this.destroyed) return false;
    // 多 P 视频上次停在其他分 P：直接切到该分 P 的地址，让续播位置与画面匹配。
    if (info.lastPlayCid > 0 && info.lastPlayCid !== initialCid && detail.pages.length > 1) {
      for (let i: number = 0; i < detail.pages.length; i++) {
        if (detail.pages[i].cid === info.lastPlayCid) {
          const lastInfo: PlayUrlInfo | null = await BiliApi.getPlayUrl(detail.aid, detail.bvid, info.lastPlayCid,
            initialQuality);
          if (lastInfo !== null && lastInfo.urls.length > 0 && this.destroyed === false) {
            info = lastInfo;
            targetCid = info.lastPlayCid;
            this.currentPageIndex = i;
          }
          break;
        }
      }
    }
    if (this.destroyed) return false;
    // 最终线路与画质确定后一次性提交，避免 XComponent 在首帧前被两组地址连续驱动。
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
    return true;
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
    this.playbackAddressFailed = false;
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
      this.loadInitialPlayback(detail).then((loaded: boolean) => {
        if (!this.destroyed && !loaded) this.playbackAddressFailed = true;
      }).catch(() => {
        if (!this.destroyed) this.playbackAddressFailed = true;
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
    // @State 在当前事件完成后才刷新，直接使用 opening，避免这里读到切换前的旧值。
    this.syncReplyComposerActive(opening);
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
    this.syncReplyComposerActive(false);
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
      const attribute: number | null = await UserApi.getRelation(this.detail.upMid);
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
      const result: ActionResult = await UserApi.setFollowed(this.detail.upMid, next);
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

  /** 点踩（App 端协议，需 App 授权）：与赞本地互斥。 */
  async actionDislike(): Promise<void> {
    if (!this.ensureLogin() || this.actionBusy) return;
    this.actionBusy = true;
    const next: boolean = !this.disliked;
    this.disliked = next;
    if (next && this.liked) this.liked = false;
    try {
      const result: ActionResult = await BiliApi.dislikeVideo(this.detail.aid, this.detail.bvid, next);
      if (this.destroyed) return;
      if (!result.ok) {
        this.disliked = !next;
        this.toast(result.message);
        return;
      }
      this.toast(next ? '已点踩' : '已取消点踩');
    } catch (e) {
      if (!this.destroyed) {
        this.disliked = !next;
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
    this.navigateVideoDetail(param, true);
  }

  private performVideoNavigation(param: VideoDetailParam, replace: boolean): void {
    PlayerCommandBus.stop();
    if (replace) AppNavStack.replacePathByName(NAV_VIDEO_DETAIL, param);
    else AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  /** 全屏结束页必须先完成竖屏旋转，再让新页面读取窗口尺寸。 */
  private navigateVideoDetail(param: VideoDetailParam, replace: boolean): void {
    PlayerCommandBus.stop();
    if (this.playerFullscreen) {
      this.pendingVideoNavigation = param;
      this.pendingVideoReplace = replace;
      PlayerCommandBus.exitFullscreen();
      return;
    }
    this.performVideoNavigation(param, replace);
  }

  private flushPendingVideoNavigation(): void {
    const param: VideoDetailParam | null = this.pendingVideoNavigation;
    if (param === null || this.destroyed) return;
    const replace: boolean = this.pendingVideoReplace;
    this.pendingVideoNavigation = null;
    this.pendingVideoReplace = false;
    this.performVideoNavigation(param, replace);
  }

  /** 保留视频详情导航栈，返回时回到当前视频。 */
  private pushVideoDetail(param: VideoDetailParam): void {
    this.navigateVideoDetail(param, false);
  }

  private onPlayerEnded(): void {
    // 播完：播放区收敛到统一高度（visiblePlayerHeight 读取 playerEnded）。
    this.playerEnded = true;
    this.syncDanmakuViewport();
    // 横屏结束画面的多卡片列表（与下方单卡推荐同一目标源）。
    this.endRecList = this.buildEndRecList();
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
        // 用户主动点"立即播放"走入栈：返回回当前视频（播完好），而不是越过它。
        this.pushVideoDetail(param);
      }
    }
  }

  /** 横屏结束画面推荐列表：优先合集下一集（与竖屏"立即播放"同一目标），再补相关推荐，去重后最多 8 条。 */
  private buildEndRecList(): Array<VideoItem> {
    const list: Array<VideoItem> = [];
    const next: UgcSeasonEpisode | null = this.nextUgcEpisode();
    if (next !== null) {
      const item: VideoItem = new VideoItem();
      item.aid = next.aid;
      item.bvid = next.bvid;
      item.cid = next.cid;
      item.title = next.title;
      item.cover = next.cover;
      item.upName = this.detail.upName;
      list.push(item);
    }
    for (let i: number = 0; i < this.related.length && list.length < 8; i++) {
      const related: VideoItem = this.related[i];
      if (related.aid <= 0 && related.bvid.length === 0) continue;
      let dup: boolean = false;
      for (let j: number = 0; j < list.length; j++) {
        if ((related.aid > 0 && list[j].aid === related.aid) ||
          (related.bvid.length > 0 && related.bvid === list[j].bvid)) {
          dup = true;
          break;
        }
      }
      if (dup) continue;
      list.push(related);
    }
    return list;
  }

  /** 横屏结束画面点击推荐卡：push 入栈（返回回上一个视频，而非越过它）。 */
  private onPlayerEndRecOpen(item: VideoItem): void {
    if (item.aid <= 0 && item.bvid.length === 0) return;
    const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
    this.pushVideoDetail(param);
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
      CommentLog.warn('ui.replies.skip', 'reason=loading aid=' + String(this.detail.aid) +
        ' reset=' + String(reset));
      return;
    }
    this.replyLoading = true;
    this.replyLoadError = '';
    if (reset) this.replyPrefetchCount = 0;
    const cursor: string = reset ? '' : this.replyCursor;
    const startedAt: number = Date.now();
    const before: number = this.replySource.totalCount();
    CommentLog.info('ui.replies.start', 'aid=' + String(this.detail.aid) + ' reset=' + String(reset) +
      ' mode=' + String(this.replySortMode) + ' cursorLen=' + String(cursor.length) +
      ' before=' + String(before));
    let loaded: boolean = false;
    try {
      const data = await CommentApi.getReplies(this.detail.aid, 1, cursor, this.replySortMode);
      if (this.destroyed) {
        CommentLog.warn('ui.replies.drop', 'reason=destroyed aid=' + String(this.detail.aid) +
          ' rows=' + String(data.replies.length));
        return;
      }
      if (reset) {
        const sanitized: Array<ReplyItem> = this.sanitizeReplies(data.replies);
        const serverIds: Set<number> = new Set<number>();
        for (let i: number = 0; i < sanitized.length; i++) serverIds.add(sanitized[i].rpid);
        // 一旦服务端返回该楼层就移除本地快照，改用字段更完整的服务端对象；尚未索引到的
        // 继续置顶保留，避免发送后切排序或在途刷新把它“吞掉”。
        this.localSentReplies = this.localSentReplies.filter((item: ReplyItem) => !serverIds.has(item.rpid));
        this.replySource.reset(this.mergeUniqueReplies(this.localSentReplies, sanitized));
      } else {
        this.appendUniqueReplies(this.replySource, data.replies);
      }
      this.replyItemCount = this.replySource.totalCount();
      this.replyCursor = data.cursor;
      this.replyHasMore = data.hasMore;
      loaded = true;
      CommentLog.info('ui.replies.done', 'aid=' + String(this.detail.aid) + ' reset=' + String(reset) +
        ' incoming=' + String(data.replies.length) + ' before=' + String(before) + ' total=' +
        String(this.replySource.totalCount()) + ' cursorLen=' + String(this.replyCursor.length) +
        ' hasMore=' + String(this.replyHasMore) + ' ms=' + String(CommentLog.elapsed(startedAt)));
    } catch (e) {
      // 评论加载失败保持现有列表，replyLoading 复位后空态/重试入口正常可用。
      if (!this.destroyed && this.replySource.isEmpty()) {
        this.replyLoadError = '评论加载失败，请检查网络后重试';
      }
      CommentLog.error('ui.replies.error', 'aid=' + String(this.detail.aid) + ' reset=' + String(reset) +
        ' cursorLen=' + String(cursor.length) + ' ms=' + String(CommentLog.elapsed(startedAt)) +
        ' error=' + CommentLog.errorText(e as Object));
    } finally {
      if (!this.destroyed) this.replyLoading = false;
    }
    if (!loaded) return;
    // 某些视频首页只返回置顶/精选的少量评论，自动继续取页直到首屏够用。
    if (this.replyHasMore && this.replySource.totalCount() < 20 && this.replyPrefetchCount < 5) {
      this.replyPrefetchCount++;
      CommentLog.info('ui.replies.prefetch', 'aid=' + String(this.detail.aid) + ' attempt=' +
        String(this.replyPrefetchCount) + ' total=' + String(this.replySource.totalCount()) +
        ' cursorLen=' + String(this.replyCursor.length));
      await this.loadReplies(false);
    }
  }

  changeReplySort(mode: number): void {
    if (this.replySortMode === mode || this.replyLoading) {
      CommentLog.warn('ui.replies.sort.skip', 'current=' + String(this.replySortMode) + ' requested=' +
        String(mode) + ' loading=' + String(this.replyLoading));
      return;
    }
    CommentLog.info('ui.replies.sort', 'aid=' + String(this.detail.aid) + ' from=' +
      String(this.replySortMode) + ' to=' + String(mode));
    this.replySortMode = mode;
    this.replyCursor = '';
    this.replyHasMore = true;
    this.replySource.clear();
    this.replyItemCount = 0;
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

  /** 首屏重置路径同样要清洗：置顶与普通评论重叠、rpid 缺失的脏项会造成 LazyForEach
   *  重复 key（随机空行/错行/残留空白格）；无正文且无图的条目直接剔除（空评论卡）。 */
  private sanitizeReplies(list: Array<ReplyItem>): Array<ReplyItem> {
    const seen: Set<number> = new Set<number>();
    const result: Array<ReplyItem> = [];
    let invalid: number = 0;
    let duplicate: number = 0;
    let empty: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const item: ReplyItem = list[i];
      if (item.rpid <= 0) {
        invalid++;
        continue;
      }
      if (seen.has(item.rpid)) {
        duplicate++;
        continue;
      }
      seen.add(item.rpid);
      if (item.content.trim().length === 0 && item.pictures.length === 0) {
        empty++;
        continue;
      }
      result.push(item);
    }
    const event: string = invalid > 0 || duplicate > 0 || empty > 0 ? 'ui.replies.sanitize.drop' :
      'ui.replies.sanitize';
    const details: string = 'incoming=' + String(list.length) + ' kept=' + String(result.length) +
      ' invalid=' + String(invalid) + ' duplicate=' + String(duplicate) + ' empty=' + String(empty);
    if (invalid > 0 || duplicate > 0 || empty > 0) CommentLog.warn(event, details);
    else CommentLog.info(event, details);
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
    let duplicate: number = 0;
    let invalid: number = 0;
    for (let i: number = 0; i < incoming.length; i++) {
      if (incoming[i].rpid <= 0) {
        invalid++;
      }
      if (!existing.has(incoming[i].rpid)) {
        existing.add(incoming[i].rpid);
        fresh.push(incoming[i]);
      } else {
        duplicate++;
      }
    }
    source.append(fresh);
    CommentLog.info('ui.replies.append', 'incoming=' + String(incoming.length) + ' added=' +
      String(fresh.length) + ' duplicate=' + String(duplicate) + ' invalid=' + String(invalid) +
      ' total=' + String(source.totalCount()));
  }

  async openReplyThread(item: ReplyItem): Promise<void> {
    if (this.replyThreadAnimating) {
      CommentLog.warn('ui.thread.open.skip', 'reason=animating requestedRoot=' + String(item.rpid));
      return;
    }
    const latest: ReplyItem | null = this.findReplyItem(item.rpid);
    const root: ReplyItem = latest !== null ? latest : item;
    CommentLog.info('ui.thread.open', 'aid=' + String(this.detail.aid) + ' root=' + String(root.rpid) +
      ' declared=' + String(root.count) + ' preview=' + String(root.replies.length) +
      ' liked=' + String(root.liked));
    this.replyThreadAnimating = true;
    this.replyThreadRoot = root;
    this.threadAllReplies = this.mergeUniqueReplies([], root.replies);
    this.threadCursor = '';
    this.threadHasMore = true;
    this.threadPrefetchCount = 0;
    this.replyTargetRootRpid = root.rpid;
    this.replyTargetRpid = root.rpid;
    this.replyTargetName = root.uname;
    // 面板立即升起，网络请求在面板内以 loading 状态完成，点击反馈不再等待首批接口。
    const loading: Promise<void> = this.loadThreadReplies(true, false);
    this.getUIContext().animateTo({
      duration: 140,
      curve: Curve.EaseOut,
      onFinish: () => {
        this.replyThreadAnimating = false;
      },
    }, () => {
      this.replyThreadOpen = true;
    });
    CommentLog.info('ui.thread.shown', 'root=' + String(root.rpid) + ' rows=' +
      String(this.threadAllReplies.length) + ' loading=true');
    await loading;
    if (this.destroyed) return;
  }

  /** 主评论操作栏的“回复”只选中目标并聚焦底部输入栏，不打开楼中楼详情。 */
  private selectReplyForComposer(item: ReplyItem): void {
    const latest: ReplyItem | null = this.findReplyItem(item.rpid);
    const root: ReplyItem = latest !== null ? latest : item;
    this.replyThreadRoot = root;
    this.replyTargetRootRpid = root.rpid;
    this.replyTargetRpid = root.rpid;
    this.replyTargetName = root.uname;
    this.emotePanelOpen = false;
    this.replyFocusTick++;
    CommentLog.info('ui.reply.select', 'root=' + String(root.rpid) + ' target=' + String(root.rpid));
  }

  async loadThreadReplies(reset: boolean, allowPrefetch: boolean = true): Promise<void> {
    if (this.threadLoading || (!reset && !this.threadHasMore)) {
      CommentLog.warn('ui.thread.skip', 'root=' + String(this.replyThreadRoot.rpid) + ' reset=' +
        String(reset) + ' loading=' + String(this.threadLoading) + ' hasMore=' + String(this.threadHasMore));
      return;
    }
    this.threadLoading = true;
    const cursor: string = reset ? '' : this.threadCursor;
    const startedAt: number = Date.now();
    const before: number = this.threadAllReplies.length;
    CommentLog.info('ui.thread.start', 'aid=' + String(this.detail.aid) + ' root=' +
      String(this.replyThreadRoot.rpid) + ' reset=' + String(reset) + ' cursorLen=' +
      String(cursor.length) + ' before=' + String(before));
    let loaded: boolean = false;
    try {
      const data = await CommentApi.getReplyReplies(this.detail.aid, 1, this.replyThreadRoot.rpid, cursor);
      if (this.destroyed) return;
      // 保留 item.replies 里的预览回复：接口偶尔返回空列表时，楼中楼不会变成“有数字但没内容”。
      this.threadAllReplies = this.mergeUniqueReplies(this.threadAllReplies, data.replies);
      this.threadCursor = data.cursor;
      this.threadHasMore = data.hasMore;
      loaded = true;
      CommentLog.info('ui.thread.done', 'root=' + String(this.replyThreadRoot.rpid) + ' reset=' +
        String(reset) + ' incoming=' + String(data.replies.length) + ' before=' + String(before) +
        ' total=' + String(this.threadAllReplies.length) + ' cursorLen=' + String(this.threadCursor.length) +
        ' hasMore=' + String(this.threadHasMore) + ' ms=' + String(CommentLog.elapsed(startedAt)));
    } catch (e) {
      // 回复加载失败保持现有内容，threadLoading 复位后可点击继续加载重试。
      CommentLog.error('ui.thread.error', 'root=' + String(this.replyThreadRoot.rpid) + ' reset=' +
        String(reset) + ' ms=' + String(CommentLog.elapsed(startedAt)) + ' error=' +
        CommentLog.errorText(e as Object));
    } finally {
      if (!this.destroyed) this.threadLoading = false;
    }
    if (!loaded) return;
    const target: number = Math.min(20, Math.max(1, this.replyThreadRoot.count));
    if (allowPrefetch && this.threadHasMore && this.threadAllReplies.length < target && this.threadPrefetchCount < 5) {
      this.threadPrefetchCount++;
      CommentLog.info('ui.thread.prefetch', 'root=' + String(this.replyThreadRoot.rpid) + ' attempt=' +
        String(this.threadPrefetchCount) + ' total=' + String(this.threadAllReplies.length) +
        ' target=' + String(target));
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
    }, 150);
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
      scroller: this.threadScroller,
      emotePanel: (): void => {
        this.VideoThreadEmotePanel()
      },
      onClose: () => this.closeReplyThread(),
      onLike: (item: ReplyItem) => this.actionReplyLike(item),
      onDislike: (item: ReplyItem) => this.actionReplyDislike(item),
      onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
      focusTick: this.threadReplyFocusTick,
      focusId: 'video_thread_reply_composer_editor',
      onSelectReply: (item: ReplyItem) => {
        CommentLog.info('ui.thread.select', 'root=' + String(this.replyThreadRoot.rpid) +
          ' target=' + String(item.rpid));
        this.replyTargetRpid = item.rpid;
        this.replyTargetName = item.uname;
        this.threadReplyFocusTick++;
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
      onFocusChange: (focused: boolean) => this.onReplyComposerFocusChanged(focused, true),
      onScrollFrame: (offset: number, scroller: Scroller, state: ScrollState): number => {
        return this.onContentScrollFrame(offset, scroller, state);
      },
      onNavigate: (action: () => void) => this.navigateFromReplyThread(action),
    })
  }

  /** 用发布接口返回的 rpid 构造当前账号的新楼层，绕过评论索引的可见性延迟。 */
  private sentReplyItem(result: ActionResult, content: string, root: number, parent: number): ReplyItem | null {
    const returned: ReplyItem = ReplyItem.from(asObject(result.data['reply']));
    const rpid: number = returned.rpid > 0 ? returned.rpid :
      asNumber(result.data['rpid'], asNumber(result.data['rpid_str'], 0));
    if (rpid <= 0) {
      CommentLog.warn('ui.send.local.skip', 'reason=no-rpid root=' + String(root) +
        ' parent=' + String(parent));
      return null;
    }
    const item: ReplyItem = returned.rpid > 0 ? returned : new ReplyItem();
    const user = UserStore.current;
    item.rpid = rpid;
    item.oid = this.detail.aid;
    item.type = 1;
    item.rootRpid = root;
    item.parentRpid = parent;
    item.dialogRpid = asNumber(result.data['dialog'], item.dialogRpid);
    if (item.mid <= 0 && user !== null) item.mid = user.mid;
    if (item.uname.length === 0) item.uname = user !== null && user.uname.length > 0 ? user.uname : '我';
    if (item.avatar.length === 0 && user !== null) item.avatar = user.face;
    if (item.level <= 0 && user !== null) item.level = user.level;
    if (item.content.length === 0) item.content = content;
    if (item.ctime <= 0) item.ctime = Math.floor(Date.now() / 1000);
    // 发布响应通常只返回楼层 id，不返回 content.emote；从已加载的表情包补齐渲染信息。
    for (let i: number = 0; i < this.emotePackages.length; i++) {
      const emotes: Array<BiliEmote> = this.emotePackages[i].emotes;
      for (let j: number = 0; j < emotes.length; j++) {
        if (emotes[j].text.length > 0 && item.content.indexOf(emotes[j].text) >= 0) item.emotes.push(emotes[j]);
      }
    }
    return item;
  }

  /** 楼中楼新增子回复后，同步主列表中的回复数与预览，避免关掉面板又看到旧状态。 */
  private insertSentThreadReply(item: ReplyItem): void {
    this.threadAllReplies = [item].concat(this.threadAllReplies.filter((reply: ReplyItem) => reply.rpid !== item.rpid));
    const nextRoot: ReplyItem = this.replyThreadRoot.clone();
    nextRoot.count++;
    nextRoot.replies = [item].concat(nextRoot.replies.filter((reply: ReplyItem) => reply.rpid !== item.rpid));
    this.replyThreadRoot = nextRoot;
    const all: Array<ReplyItem> = this.replySource.getAll();
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].rpid !== nextRoot.rpid) continue;
      this.replySource.updateItem(i, nextRoot);
      break;
    }
  }

  /** 不进入详情也能即时把新回复写回主评论的计数与预览。 */
  private insertSentInlineReply(item: ReplyItem, rootRpid: number): void {
    const all: Array<ReplyItem> = this.replySource.getAll();
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].rpid !== rootRpid) continue;
      const root: ReplyItem = all[i].clone();
      root.count++;
      root.replies = [item].concat(root.replies.filter((reply: ReplyItem) => reply.rpid !== item.rpid));
      this.replySource.updateItem(i, root);
      this.replyThreadRoot = root;
      return;
    }
  }

  async sendReply(): Promise<void> {
    const content: string = this.replyDraft.trim();
    if (content.length === 0 || this.replySending) {
      CommentLog.warn('ui.send.skip', 'empty=' + String(content.length === 0) +
        ' sending=' + String(this.replySending));
      return;
    }
    if (!this.ensureLogin()) {
      CommentLog.warn('ui.send.skip', 'reason=login messageLen=' + String(content.length));
      return;
    }
    this.replySending = true;
    const startedAt: number = Date.now();
    try {
      const root: number = this.replyTargetRootRpid > 0 ? this.replyTargetRootRpid : 0;
      const parent: number = root > 0 ?
        (this.replyTargetRpid > 0 ? this.replyTargetRpid : root) : 0;
      CommentLog.info('ui.send.start', 'aid=' + String(this.detail.aid) + ' root=' + String(root) +
        ' parent=' + String(parent) + ' messageLen=' + String(content.length));
      const result: ActionResult = await CommentApi.addReply(this.detail.aid, 1, content, root, parent);
      if (this.destroyed) {
        CommentLog.warn('ui.send.drop', 'reason=destroyed root=' + String(root) + ' parent=' + String(parent));
        return;
      }
      if (!result.ok) {
        CommentLog.warn('ui.send.failed', 'root=' + String(root) + ' parent=' + String(parent) +
          ' code=' + String(result.code) + ' ms=' + String(CommentLog.elapsed(startedAt)));
        this.toast(result.message);
        return;
      }
      CommentLog.info('ui.send.done', 'root=' + String(root) + ' parent=' + String(parent) +
        ' ms=' + String(CommentLog.elapsed(startedAt)));
      const sent: ReplyItem | null = this.sentReplyItem(result, content, root, parent);
      this.replyDraft = '';
      this.toast(root > 0 ? '回复成功' : '评论成功');
      if (root > 0 && this.replyThreadOpen) {
        this.replyTargetRpid = this.replyThreadRoot.rpid;
        this.replyTargetName = this.replyThreadRoot.uname;
        if (sent !== null) {
          this.insertSentThreadReply(sent);
          this.detail.reply++;
          CommentLog.info('ui.send.local.thread', 'rpid=' + String(sent.rpid) + ' root=' + String(root) +
            ' total=' + String(this.threadAllReplies.length));
        } else {
          // 极少数兼容接口不返回 rpid，才退回服务端刷新路径。
          this.threadAllReplies = [];
          this.threadCursor = '';
          this.threadHasMore = true;
          await this.loadThreadReplies(true);
        }
      } else if (root > 0) {
        if (sent !== null) {
          this.insertSentInlineReply(sent, root);
          this.detail.reply++;
          CommentLog.info('ui.send.local.inline', 'rpid=' + String(sent.rpid) + ' root=' + String(root));
        } else {
          this.replyCursor = '';
          this.replyHasMore = true;
          await this.loadReplies(true);
        }
        this.replyTargetRootRpid = 0;
        this.replyTargetRpid = 0;
        this.replyTargetName = '';
      } else {
        if (sent !== null) {
          this.localSentReplies = [sent].concat(this.localSentReplies.filter((item: ReplyItem) =>
            item.rpid !== sent.rpid));
          this.replySource.prepend([sent]);
          this.replyItemCount = this.replySource.totalCount();
          this.detail.reply++;
          this.scheduleTimeout(() => {
            try {
              this.replyScroller.scrollToIndex(0, true, ScrollAlign.START);
            } catch (e) {
            }
          }, 16);
          CommentLog.info('ui.send.local.root', 'rpid=' + String(sent.rpid) + ' total=' +
            String(this.replySource.totalCount()));
        } else {
          this.replyCursor = '';
          this.replyHasMore = true;
          await this.loadReplies(true);
        }
      }
    } catch (e) {
      CommentLog.error('ui.send.error', 'aid=' + String(this.detail.aid) + ' ms=' +
        String(CommentLog.elapsed(startedAt)) + ' error=' + CommentLog.errorText(e as Object));
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

  private danmakuComposerWidth(): number {
    return Math.min(154, Math.max(126, this.screenWidthVp * 0.36));
  }

  private toggleToolbarDanmaku(): void {
    const enabled: boolean = !this.danmakuOn;
    if (!enabled) {
      try {
        inputMethod.getController().hideTextInput().catch(() => {});
      } catch (e) {
      }
      try {
        this.getUIContext().getFocusController().clearFocus();
      } catch (e) {
      }
    }
    Haptic.tap();
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseInOut }, () => {
      this.danmakuOn = enabled;
    });
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
    let mainChanged: boolean = false;
    let rootChanged: boolean = false;
    const list: Array<ReplyItem> = this.replySource.getAll();
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].rpid === rpid) {
        found = list[i];
        mutate(list[i]);
        const next1: ReplyItem = list[i].clone();
        next1.rev = list[i].rev + 1;
        this.replySource.updateItem(i, next1);
        mainChanged = true;
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
    if (this.replyThreadRoot.rpid === rpid) {
      if (found === null) found = this.replyThreadRoot;
      mutate(this.replyThreadRoot);
      const next3: ReplyItem = this.replyThreadRoot.clone();
      next3.rev = this.replyThreadRoot.rev + 1;
      this.replyThreadRoot = next3;
      rootChanged = true;
    }
    this.replyLikeVersion++;
    CommentLog.info('ui.reply.mutate', 'rpid=' + String(rpid) + ' main=' + String(mainChanged) +
      ' thread=' + String(threadChanged) + ' root=' + String(rootChanged) +
      ' found=' + String(found !== null) + ' version=' + String(this.replyLikeVersion));
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
      const pixelMap: image.PixelMap = await makeReplyShareSnapshot(uiContext,
        (): void => { this.ReplyShareCardBuilder(); });
      await sharePixelMapAsImage(context, pixelMap, 'reply_share_' + String(item.rpid));
    })()
      .catch((e: Object) => {
        CommentLog.error('share.reply.error', 'rpid=' + String(item.rpid) + ' error=' + CommentLog.errorText(e));
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
      scanHint: '长按扫码查看视频',
    })
  }

  @Builder
  IntroTab() {
    VideoIntroSection({
      detail: this.detail,
      accent: this.accent,
      isDark: this.isDark,
      upStats: this.upStatsText(),
      followLoading: this.followLoading,
      following: this.following,
      playerOnlineTotal: this.playerOnlineTotal,
      likeCount: this.likeCount,
      coinCount: this.coinCount,
      favoriteCount: this.favoriteCount,
      liked: this.liked,
      disliked: this.disliked,
      coinCountByMe: this.coinCountByMe,
      favorited: this.favorited,
      actionBusy: this.actionBusy,
      descExpanded: this.descExpanded,
      descNeedsExpand: this.descNeedsExpand,
      currentCid: this.currentCid,
      pageSwitchingCid: this.pageSwitchingCid,
      ugcPanelOpen: this.ugcPanelOpen,
      ugcCount: this.ugcCount,
      related: this.related,
      relatedLoading: this.relatedLoading,
      relatedLoadError: this.relatedLoadError,
      scroller: this.introScroller,
      ugcSource: this.ugcSource,
      onOpenUp: () => {
        if (this.detail.upMid > 0) {
          PlayerCommandBus.stop();
          const param: UserSpaceParam = { mid: this.detail.upMid };
          AppNavStack.pushPathByName(NAV_USER_SPACE, param);
        }
      },
      onFollow: () => {
        Haptic.tap();
        this.actionFollow();
      },
      onLike: () => this.actionLike(),
      onTriple: () => this.actionTriple(),
      onDislike: () => this.actionDislike(),
      onCoin: () => this.openCoinSheet(),
      onFavorite: () => this.actionFavorite(),
      onFavoritePick: () => this.actionFavoritePick(),
      onShare: () => this.actionShare(),
      onDescAreaChange: (width: Length) => this.updateDescOverflow(width),
      onToggleDescription: () => {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
          this.descExpanded = !this.descExpanded;
        });
      },
      onSwitchPage: (page: VideoPage, index: number) => this.switchVideoPage(page, index),
      onToggleUgc: () => {
        this.ugcPanelOpen = !this.ugcPanelOpen;
        if (this.ugcPanelOpen) this.rebuildUgcSource();
      },
      onOpenUgc: (episode: UgcSeasonEpisode) => this.openUgcEpisode(episode),
      onOpenRelated: (item: VideoItem) => this.openRelatedVideo(item),
      onReportRelated: (item: VideoItem) => this.reportRelated(item),
      onHideRelated: (item: VideoItem) => this.hideRelated(item),
      onLoadMoreRelated: () => this.loadMoreRelated(),
      onScrollFrame: (offset: number, scroller: Scroller, state: ScrollState): number =>
        this.onContentScrollFrame(offset, scroller, state),
    })
  }

  /** ⋮ 菜单-举报：选原因后给反馈（Web 端无视频举报接口，本地提示）。 */
  private reportRelated(item: VideoItem): void {
    if (!UserStore.isLogin) {
      this.toast('请先登录后再举报');
      return;
    }
    const reasons: Array<string> = ['违法违规', '色情低俗', '垃圾广告', '人身攻击', '引战', '其他'];
    const buttons: Array<ReportButtonItem> = [];
    for (let i: number = 0; i < reasons.length; i++) {
      buttons.push({ text: reasons[i], color: this.isDark ? '#CCFFFFFF' : '#18191C' });
    }
    buttons.push({ text: '取消', color: '#9499A0' });
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '举报视频',
        message: item.title.substring(0, Math.min(24, item.title.length)),
        buttons: buttons,
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        if (pick < 0 || pick >= reasons.length) return;
        if (!this.destroyed) this.toast('已提交举报，感谢反馈');
      });
    } catch (e) {
      // 组件销毁或窗口异常时忽略。
    }
  }

  /** ⋮ 菜单-不想看：移除该条相关推荐并提示。 */
  private hideRelated(item: VideoItem): void {
    const next: Array<VideoItem> = this.related.filter((v: VideoItem) =>
      !((item.aid > 0 && v.aid === item.aid) ||
        (item.bvid.length > 0 && v.bvid.length > 0 && v.bvid === item.bvid)));
    if (next.length !== this.related.length) this.related = next;
    this.toast('已减少相似推荐');
  }


  // 评论 Tab 的排序栏/输入栏已随 VideoReplyTab 组件拆出；此处保留表情键盘高度计算
  // （楼中楼 Sheet 的表情面板也走本方法取值）。
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

  /** 相关推荐卡点击开稿（覆盖区点击与 ⋮ 菜单分开绑定，避免整卡 onClick 把 ⋮ 也带飞）。
   *  用 push 入栈而非 replace：从推荐视频返回应回到上一个视频（栈式导航，与官方一致）。 */
  private openRelatedVideo(item: VideoItem): void {
    if (item.aid <= 0 && item.bvid.length === 0) return;
    const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
    this.pushVideoDetail(param);
  }

  @Builder
  CompactDetailTab(label: string, index: number) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(this.visualTab === index ? 15 : 14)
        .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.visualTab === index ? (this.isDark ? '#F1F2F3' : '#18191C') : '#9499A0')
        .animation({ duration: 140, curve: Curve.EaseOut })
      Row()
        .width(20).height(3).borderRadius(1.5)
        .backgroundColor(this.accent)
        .opacity(this.visualTab === index ? 1 : 0)
        .scale({ x: this.visualTab === index ? 1 : 0.35, y: 1 })
        .animation({ duration: 140, curve: Curve.EaseOut })
    }
    .height(40)
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
      Stack({ alignContent: Alignment.End }) {
        Row() {
          TextInput({ text: this.danmakuDraft,
            placeholder: this.danmakuSending ? '发送中…' : '点我发弹幕' })
            .width(this.danmakuOn ? this.danmakuComposerWidth() - 34 : 0)
            .height(32)
            .fontSize(12)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .placeholderColor(this.isDark ? '#8E9198' : '#9A9EA5')
            .backgroundColor('#00000000')
            .padding({ left: 10, right: 4 })
            .opacity(this.danmakuOn ? 1 : 0)
            .translate({ x: this.danmakuOn ? 0 : 8 })
            .enabled(this.danmakuOn)
            .enterKeyType(EnterKeyType.Send)
            .onChange((value: string) => {
              this.danmakuDraft = value;
            })
            .onSubmit(() => this.sendVideoDanmaku())
          Row()
            .width(34)
            .height(32)
            .border({ width: { left: this.danmakuOn ? 0.5 : 0 },
              color: this.isDark ? '#42444A' : '#E1E3E7' })
        }
        .width(this.danmakuOn ? this.danmakuComposerWidth() : 34)
        .height(32)
        .borderRadius(16)
        .border({ width: 0.5, color: this.isDark ? '#42444A' : '#E1E3E7' })
        .backgroundColor(this.isDark ? '#292B30' : '#F5F6F7')
        .clip(true)

        Stack({ alignContent: Alignment.Center }) {
          Image(this.danmakuOn ? $r('app.media.ic_danmaku_on') : $r('app.media.ic_danmaku_off'))
            .width(22)
            .height(22)
            .renderMode(ImageRenderMode.Template)
            .fillColor(this.danmakuOn ? this.accent : (this.isDark ? '#A4A8B0' : '#70747B'))
        }
        .width(34)
        .height(32)
        .onClick(() => this.toggleToolbarDanmaku())
      }
      .width(this.danmakuComposerWidth())
      .height(32)
    }
    .width('100%').height(48)
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
        // 评论 Tab 整体拆到 VideoReplyTab 组件（排序/列表/输入/表情/加载更多）。
        VideoReplyTab({
          replyCount: this.detail.reply,
          upMid: this.detail.upMid,
          sortMode: this.replySortMode,
          loading: this.replyLoading,
          hasMore: this.replyHasMore,
          errorText: this.replyLoadError,
          itemCount: this.replyItemCount,
          version: this.replyLikeVersion,
          draft: this.replyDraft,
          sending: this.replySending,
          placeholder: this.replyTargetRootRpid > 0 ? '回复 @' +
            (this.replyTargetName.length > 0 ? this.replyTargetName : this.replyThreadRoot.uname) : '发一条友善的评论',
          emoteOpen: this.emotePanelOpen,
          focusTick: this.replyFocusTick,
          emotePackages: this.emotePackages,
          emotePackageIndex: this.emotePackageIndex,
          emoteLoading: this.emoteLoading,
          emotePanelHeight: this.emoteKeyboardHeight(),
          screenWidth: this.screenWidthVp,
          source: this.replySource,
          scroller: this.replyScroller,
          onSortChange: (mode: number) => {
            this.changeReplySort(mode);
          },
          onLoadMore: (reset: boolean) => {
            this.loadReplies(reset);
          },
          onLike: (item: ReplyItem) => this.actionReplyLike(item),
          onDislike: (item: ReplyItem) => this.actionReplyDislike(item),
          onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
          onSelectReply: (item: ReplyItem) => this.selectReplyForComposer(item),
          onOpenThread: (item: ReplyItem) => this.openReplyThread(item),
          onDeleted: (item: ReplyItem) => {
            this.localSentReplies = this.localSentReplies.filter((x: ReplyItem) => x.rpid !== item.rpid);
            this.replySource.reset(this.replySource.getAll().filter((x: ReplyItem) => x.rpid !== item.rpid));
            this.replyItemCount = this.replySource.totalCount();
            this.detail.reply = Math.max(0, this.detail.reply - 1);
          },
          onDraftChange: (value: string) => {
            this.replyDraft = value;
          },
          onSend: () => this.sendReply(),
          onToggleEmote: () => this.openEmotePanel(),
          onRequestKeyboard: () => this.requestReplyKeyboard(),
          onFocusChange: (focused: boolean) => this.onReplyComposerFocusChanged(focused, false),
          onEmoteSelect: (item: BiliEmote) => this.insertEmote(item),
          onEmotePackageChange: (index: number) => {
            this.emotePackageIndex = index;
          },
          onScrollFrame: (offset: number, scroller: Scroller, state: ScrollState): number => {
            return this.onContentScrollFrame(offset, scroller, state);
          },
        })
        .translate({ y: this.replyViewOffsetY })
        .opacity(this.replyViewOpacity)
      }
      .tabBar('')
    }
    .width('100%')
    .layoutWeight(1)
    .barHeight(0)
    .barMode(BarMode.Fixed)
    .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
    .animationMode(AnimationMode.CONTENT_FIRST)
    .animationDuration(180)
    .animationCurve(Curve.EaseOut)
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

  /** 模糊底图用小尺寸封面，借助 B 站图片缩略参数降低下载与解码开销。 */
  private coverThumb(url: string): string {
    return url.startsWith('http') ? url + '@480w_270h_1c.webp' : url;
  }

  /** 卡片侧带过来的封面：detail 数据回来前播放区/底图直接垫它，入场期不出"加载中"占位。 */
  private entryCoverUrl(): string {
    return this.entryCoverSource.length > 0 ? this.entryCoverSource : this.detail.cover;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 详情内容只淡入淡出，绝不跟 hero 一起缩放。
      Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
        .hitTestBehavior(HitTestMode.None)
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
              // 卡片原封面持续垫在 Surface 上，直到 PlayerView 同时收到 playing 与官方首帧事件。
              videoCover: this.entryCoverUrl(),
              ownerName: this.detail.upName,
              ownerFace: this.detail.upFace,
              liked: this.liked,
              coined: this.coinCountByMe > 0,
              favorited: this.favorited,
              externalDanmakuOn: this.danmakuOn,
              danmakuFixedHeight: this.danmakuCanvasHeight(),
              onDanmakuEngineReady: (engine: PlayerDanmakuEngine) => {
                this.dmEngineRef = engine;
                this.syncDanmakuViewport();
              },
              localDanmakuText: this.localDanmakuText,
              localDanmakuToken: this.localDanmakuToken,
              compactMode: !this.playerFullscreen && !this.playerEnded && this.visiblePlayerHeight() < 176,
               onBack: () => {
                 this.goBack();
               },
              onFullscreenChange: (fullscreen: boolean) => {
                if (fullscreen) {
                  this.playerFullscreenRestoreHeight = this.visiblePlayerHeight();
                  this.playerFullscreenExitVisual = false;
                  this.playerFullscreenExitHeight = 0;
                  this.playerFullscreenExitTop = 0;
                  this.playerFullscreen = true;
                } else {
                  this.finishPlayerFullscreenExit();
                }
                // 全屏时评论回复 Sheet 应随评论区一起隐藏，不能叠在视频画面上。
                if (fullscreen) this.closeReplyThread();
              },
              onFullscreenExitStart: () => {
                this.beginPlayerFullscreenExit();
              },
               onPlayingChange: (playing: boolean) => {
                 this.onPlayerPlayingChange(playing);
               },
               onFirstFrameShown: () => {
                 this.startupCoverVisible = false;
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
              endRecList: this.endRecList,
              upFollowing: this.following,
              disliked: this.disliked,
              onFollow: () => {
                this.actionFollow();
              },
              onDislike: () => {
                this.actionDislike();
              },
              onEndRecOpen: (item: VideoItem) => {
                this.onPlayerEndRecOpen(item);
              },
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
              moreSheetHeight: this.moreSheetHeightValue(),
            })
          }

          // 该节点不随 playUrl 的到达而替换，持续覆盖 XComponent 创建/prepare 阶段的空 Surface。
          if (this.entryCoverUrl().length > 0) {
            Image(this.entryCoverUrl())
              .id('video-detail-startup-cover')
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .opacity(this.startupCoverVisible ? 1 : 0)
              .animation({ duration: 160, curve: Curve.EaseOut })
              .hitTestBehavior(HitTestMode.None)
          }

          if (this.playUrl.length === 0 && this.playbackAddressFailed) {
            // 请求期间保持纯封面；仅当播放地址完整请求流程最终失败后才提示。
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor('#52000000')
              .hitTestBehavior(HitTestMode.None)
            Column() {
              Text('获取播放地址失败')
                .fontSize(12)
                .fontColor('#FFFFFF')
            }
          }
        }
        .width('100%')
        .height(this.playerFullscreen ?
          (this.playerFullscreenExitVisual ? this.playerFullscreenExitHeight : '100%') :
          this.visiblePlayerHeight())
        .clip(true)
        .backgroundColor('#000000')

        // 信息区
        if (!this.playerFullscreen || this.playerFullscreenExitVisual) {
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
      .padding({ top: this.playerFullscreen ?
        (this.playerFullscreenExitVisual ? this.playerFullscreenExitTop : 0) :
        Immersive.statusBarHeight() })

      // 视频上方状态栏固定纯黑，避免封面倒影干扰。
      if (!this.playerFullscreen || this.playerFullscreenExitVisual) {
        Column()
        .width('100%')
        .height(Immersive.statusBarHeight())
        .backgroundColor('#000000')
        .hitTestBehavior(HitTestMode.None)

      }

      if (this.coinSheetOpen) {
        CoinSheetView({
          coinCountByMe: this.coinCountByMe,
          choice: this.coinChoice,
          withLike: this.coinWithLike,
          busy: this.actionBusy,
          contentWidth: Math.min(322, Math.max(280, this.screenWidthVp - 24)),
          onChoiceChange: (n: number) => {
            this.coinChoice = n;
          },
          onWithLikeChange: (c: boolean) => {
            this.coinWithLike = c;
          },
          onConfirm: () => {
            this.submitCoin();
          },
          onClose: () => {
            if (!this.actionBusy) this.coinSheetOpen = false;
          },
        })
      }
      if (this.favPickOpen) {
        FavPickSheetView({
          loading: this.favPickLoading,
          folders: this.favPickFolders,
          checked: this.favPickChecked,
          onToggle: (id: number) => {
            this.toggleFavPick(id);
          },
          onConfirm: () => {
            this.saveFavPick().catch(() => {
            });
          },
          onClose: () => {
            this.favPickOpen = false;
          },
        })
      }
      }
      .width('100%')
      // 整卡转场期间保持目标页整屏布局，只由外层容器负责裁剪和缩放，避免内容重排。
      .height(this.wholeCardAnimating && this.screenHeightVp > 0 ? this.screenHeightVp : '100%')
      .opacity(this.entryContentOpacity)

      if (this.entryFromWholeCard && this.wholeCardSnapshot !== null) {
        Image(this.wholeCardSnapshot)
          .width('100%')
          .height(this.wholeCardSnapshotHeight)
          .position({ x: 0, y: 0 })
          .objectFit(ImageFit.Fill)
          .opacity(this.wholeCardSnapshotOpacity)
          .syncLoad(true)
          .hitTestBehavior(HitTestMode.None)
          .zIndex(10)
      }

      if (this.heroVisible && this.heroSource.length > 0) {
        Image(this.heroSource)
          .width(this.heroWidth)
          .height(this.heroHeight)
          .position({ x: this.heroX, y: this.heroY })
          .objectFit(ImageFit.Cover)
          .borderRadius(this.heroRadius)
          .opacity(this.heroOpacity)
          .clip(true)
          .hitTestBehavior(HitTestMode.None)
      }

      if (this.replyThreadOpen) {
        Stack() {
          this.VideoThreadSheet()
        }
        .width('100%')
        .height(this.replySheetHeight())
        // 自定义面板必须显式锚到播放器底边。只设置高度时，部分真机的 Stack
        // 会把它贴到窗口顶端，表现为“回复栏飞到最上面”。
        .position({ x: 0, y: this.replySheetTop() })
        .borderRadius({ topLeft: 18, topRight: 18 })
        .clip(true)
        .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
        .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: -4 })
        .zIndex(20)
        .transition(TransitionEffect.move(TransitionEdge.BOTTOM)
          .combine(TransitionEffect.opacity(0.98))
          .animation({ duration: 140, curve: Curve.EaseOut }))
      }
    }
    .scale({ x: this.wholeCardScale, y: this.wholeCardScale })
    .translate({ x: this.wholeCardTranslateX, y: this.wholeCardTranslateY })
    .width('100%')
    .height(this.wholeCardAnimating && this.wholeCardClipHeight > 0 ? this.wholeCardClipHeight : '100%')
    .borderRadius(this.wholeCardAnimating ? this.wholeCardRadius : 0)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
    .clip(this.wholeCardAnimating)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      if (this.wholeCardAnimating) return;
      const height: number = Number.parseFloat(String(newValue.height));
      if (Number.isFinite(height) && height > 0 && Math.abs(height - this.pageHeightVp) > 0.5) {
        this.pageHeightVp = height;
      }
      this.refreshScreenSize();
    })
  }
}
