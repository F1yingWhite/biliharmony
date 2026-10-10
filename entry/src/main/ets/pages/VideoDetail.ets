import { VideoReportDialog } from '../components/VideoReportDialog';
import { LocalVideoFilter } from '../common/LocalVideoFilter';
/**
 * 视频详情页：沉浸式播放器 + 封面取色动态主题 + 简介/评论/相关。
 * 大区块已按职责拆到组件：评论 Tab（VideoReplyTab）、相关推荐行（RelatedVideoRow）、
 * 投币弹窗（CoinSheetView）、收藏夹多选（FavPickSheetView）、楼中楼面板（ReplyThreadPanel）。
 * hero 转场（VideoHeroTransitionController）与互动动作（VideoActionController）抽到
 * components/video/ 下的控制器：@State 留在本页，方法体经注入闭包访问页面状态。
 * 播放选择/心跳由 VideoPlaybackController 管理；推荐候选与分页由 VideoRecommendations 管理；
 * 收藏夹选择由 VideoFavoritePicker 发布快照，页面保留布局、导航和状态发布。
 */
import { PlaybackSelection } from '../services/media/PlaybackSourceCoordinator';
import { display, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { inputMethod } from '@kit.IMEKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Immersive } from '../common/Immersive';
import { Haptic } from '../common/Haptic';
import { AppNavStack, HERO_BG_SNAPSHOT_KEY, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  HERO_NAV_TRANSITION_FINISH_REQUEST_KEY, ImageViewerSrcRect, NAV_LOGIN, NAV_VIDEO_DETAIL, NAV_USER_SPACE,
  VideoDetailParam, UserSpaceParam, releasePixelMap, NAV_SEARCH } from '../common/AppRouter';
import { VideoDetail, VideoItem, ReplyItem, PlayUrlInfo, VideoPage, VideoQualityOption,
  BiliEmote, BiliEmotePackage, SubtitleTrack, UgcSeasonEpisode } from '../model/Models';
import { ActionResult, BiliApi, VideoTagInfo } from '../api/BiliApi';
import { PlayerView } from '../components/player/PlayerView';
import { AppTheme } from '../common/AppTheme';
import { PlayerDanmakuEngine } from '../components/player/PlayerDanmakuEngine';
import { LoadingView } from '../components/LoadingView';
import { UserStore } from '../services/auth/UserStore';
import { colorWithAlpha, formatCount, formatDate } from '../common/Utils';
import { PlayerCommandBus } from '../common/PlayerCommandBus';
import { VideoSystemQueue, VideoQueueTarget } from '../components/video/VideoSystemQueue';
import { AppRecoveryState, RecoveryViewState } from '../common/AppRecoveryState';
import { BasicDataSource } from '../common/BasicDataSource';
import { ReplyReactionHooks, runReplyDislike, runReplyLike } from '../common/ReplyMutation';
import { ReplyEmotePanel } from '../components/reply/ReplyEmotePanel';
import { ReplyThreadPanel } from '../components/reply/ReplyThreadPanel';
import { RepliesController } from '../components/reply/RepliesController';
import { MainRepliesState, ReplySubject, ThreadRepliesState, mergeUniqueReplies } from '../components/reply/ReplyState';
import { ReplyVoteCard } from '../model/reply/ReplyVoteModels';
import { ReplyShareController } from '../components/reply/ReplyShareController';
import { ReplySubmissionController, ReplySubmissionSnapshot } from '../components/reply/ReplySubmissionController';
import { DynDraftImage } from '../common/DynImagePreparer';
import { RelatedVideoRow } from '../components/video/VideoRelatedRow';
import { VideoReplyTab } from '../components/video/VideoReplyTab';
import { CoinSheetView } from '../components/video/CoinSheetView';
import { FavPickSheetView } from '../components/video/FavPickSheetView';
import { VideoActionItem } from '../components/video/VideoActionItem';
import { ReplyShareCard } from '../components/reply/ReplyShareCard';
import { safeToast } from '../common/Toast';
import { CommentLog } from '../common/CommentLog';
import { VideoDetailGeometry } from '../common/VideoDetailGeometry';
import { VideoInteractionLink } from '../model/video/VideoInteractionModels';
import { biliImageThumbnail } from '../common/ImageUrl';
import { VideoIntroSection } from '../components/video/VideoIntroSection';
import { VideoHeroTransitionController } from '../components/video/VideoHeroTransitionController';
import { VideoActionController } from '../components/video/VideoActionController';
import { VideoPlaybackController } from '../components/video/VideoPlaybackController';
import { VideoDanmakuSubmissionController } from '../components/video/VideoDanmakuSubmissionController';
import { VideoDetailController, VideoDetailMetadata, VideoDetailStatus } from '../components/video/VideoDetailController';
import { VideoAccountController, VideoAccountRelation, VideoEmoteStatus, VideoFollowStatus } from '../components/video/VideoAccountController';
import { RelatedVideoStatus, VideoRecommendations } from '../components/video/VideoRecommendations';
import { VideoFavoritePicker, VideoFavoritePickerState } from '../components/video/VideoFavoritePicker';

/** showDialog 按钮声明（promptAction 的 Button 类型不便直接引用）。 */
interface ReportButtonItem {
  text: string;
  color: string;
}

@Component
export struct VideoDetailPage {
  onHome: () => void = () => {};
  @State loading: boolean = true;
  @State errorText: string = '';
  @State detail: VideoDetail = new VideoDetail();
  @State playUrl: string = '';
  @State playUrls: Array<string> = [];
  @State playAudioUrls: Array<string> = [];
  @State playbackAddressFailed: boolean = false;
  @State playbackFailureText: string = '获取播放地址失败';
  @State previewPlayback: boolean = false;
  @State qualityOptions: Array<VideoQualityOption> = [];
  @State subtitleTracks: Array<SubtitleTrack> = [];
  @State currentQuality: number = 0;
  @State currentCid: number = 0;
  @State currentPageIndex: number = 0;
  @State pageSwitchingCid: number = 0;
  @State playerSourceVersion: number = 0;
  @State initialSeekSeconds: number = 0;
  /** 全视频空降标签（如「商业推广」）：播放器解析后回调，显示在标题前，不盖画面。 */
  @State sponsorFullLabel: string = '';
  @State sponsorFullColor: string = '#008A5C';
  @StorageProp('sponsorSkipEnabled') sponsorSkipEnabled: boolean = true;
  @State ugcCount: number = 0;
  @State ugcPanelOpen: boolean = false;
  /** 相关推荐行数（relatedSource 为普通属性，空态/尾 footer 需要响应式计数驱动）。 */
  @State relatedCount: number = 0;
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
  @State replyHasMore: boolean = true;
  @State replyLoading: boolean = false;
  @State replyLoadError: string = '';
  @State replyVoteCard: ReplyVoteCard | null = null;
  @State replyItemCount: number = 0;
  // 回复详情是视频页内的二级导航状态；放入 AppStorage 供 NavDestination
  // 的系统返回/侧滑回调优先关闭，避免直接把整个视频页弹出。
  @StorageLink('videoReplyThreadOpen') replyThreadOpen: boolean = false;
  @StorageLink('videoReplyThreadCloseRequest') @Watch('onReplyThreadCloseRequested') replyThreadCloseRequest: number = 0;
  @StorageLink('videoReplyComposerCloseRequest') @Watch('onReplyComposerCloseRequested')
  replyComposerCloseRequest: number = 0;
  @State replyThreadRoot: ReplyItem = new ReplyItem();
  @State threadHasMore: boolean = true;
  @State threadLoading: boolean = false;
  /** 当前输入栏回复所属的根评论；为 0 时发布一级评论。与详情面板是否打开相互独立。 */
  @State replyTargetRootRpid: number = 0;
  @State replyTargetRpid: number = 0;
  @State replyTargetName: string = '';
  /** 主评论输入栏与详情输入栏分别计数，避免两个已挂载编辑器同时抢焦点。 */
  @State replyFocusTick: number = 0;
  @State threadReplyFocusTick: number = 0;
  @State replyDraft: string = '';
  @State replyImages: Array<DynDraftImage> = [];
  @State replySending: boolean = false;
  private replySubmit: ReplySubmissionController = new ReplySubmissionController({
    isAlive: () => !this.destroyed,
    getTarget: () => ({ oid: this.detail.aid, type: 1, root: this.replyTargetRootRpid,
      parent: this.replyTargetRpid, scope: this.replyThreadOpen ? 'thread' : 'main', active: true }),
    getDraft: () => this.replyDraft,
    setImages: (images: Array<DynDraftImage>) => this.replyImages = images,
    setSending: (sending: boolean) => this.replySending = sending,
    toast: (message: string) => this.toast(message),
    onSuccess: (snapshot: ReplySubmissionSnapshot, reply: ReplyItem | null, clearDraft: boolean) => {
      this.applySubmittedReply(snapshot, reply, clearDraft);
    },
  });
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
  @State videoTags: Array<VideoTagInfo> = [];
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
  @State favoritePickerState: VideoFavoritePickerState = new VideoFavoritePickerState();
  private favoritePicker: VideoFavoritePicker = new VideoFavoritePicker({
    isDestroyed: (): boolean => this.destroyed,
    ensureLogin: (): boolean => this.ensureLogin(),
    getAid: (): number => this.detail.aid,
    isActionBusy: (): boolean => this.actionBusy,
    setActionBusy: (busy: boolean): void => { this.actionBusy = busy; },
    setFavorited: (favorited: boolean): void => { this.favorited = favorited; },
    toast: (message: string): void => this.toast(message),
    publish: (state: VideoFavoritePickerState): void => { this.favoritePickerState = state; },
  });
  @State @Watch('onPlayerGeomChanged') playerFullscreen: boolean = false;
  /** 退出全屏的视觉层：逻辑全屏保持到 DID_ROTATE，只让外层裁剪窗口边旋转边缩小。 */
  @State playerFullscreenExitVisual: boolean = false;
  @State playerFullscreenExitHeight: number = 0;
  @State playerFullscreenExitTop: number = 0;
  @State playerPlaying: boolean = false;
  /** 播放器上报的在线观看人数（"X人正在看"），展示在播放量信息行的时间后面。 */
  @State playerOnlineTotal: string = '';
  @State playerCollapse: number = 0;
  /** AVPlayer 解码后回传的真实视频尺寸；未拿到前先用接口 dimension 兜底。 */
  @State realVideoWidth: number = 0;
  @State realVideoHeight: number = 0;
  @State danmakuOn: boolean = true;
  @State danmakuDraft: string = '';
  @State danmakuSending: boolean = false;
  @State localDanmakuText: string = '';
  @State localDanmakuId: string = '';
  @State localDanmakuSeconds: number = 0;
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
  /**
   * 入场动画闸门与 hero 转场动画都在 VideoHeroTransitionController；@State 仍在本页，
   * 经下方闭包读写。转场键/动画时长/测量函数全部显式注入，数值与抽取前逐项一致。
   */
  private hero: VideoHeroTransitionController = new VideoHeroTransitionController(
    {
      snapshotKey: HERO_BG_SNAPSHOT_KEY,
      activeKey: HERO_NAV_TRANSITION_ACTIVE_KEY,
      durationKey: HERO_NAV_TRANSITION_DURATION_KEY,
      finishRequestKey: HERO_NAV_TRANSITION_FINISH_REQUEST_KEY,
    },
    {
      gateFallbackMs: 600,
      wholeCardExpandMs: 350,
      wholeCardContentMs: 100,
      wholeCardSnapshotFadeMs: 100,
      wholeCardSnapshotFadeDelayMs: 50,
      cardFlightMs: 320,
      cardContentMs: 190,
      cardContentDelayMs: 100,
      cardCoverRadius: 10,
      popDurationMs: 360,
      wholeCardCollapseMs: 350,
      exitSnapshotInMs: 50,
      exitSnapshotInDelayMs: 150,
      exitContentOutMs: 50,
      exitContentOutDelayMs: 200,
      cardExitContentMs: 170,
      cardExitFlightMs: 320,
      cardCornerVp: 6,
    },
    {
      setContentOpacity: (value: number): void => {
        this.entryContentOpacity = value;
      },
      setHeroVisible: (value: boolean): void => {
        this.heroVisible = value;
      },
      setHeroSource: (value: string): void => {
        this.heroSource = value;
      },
      setHeroX: (value: number): void => {
        this.heroX = value;
      },
      setHeroY: (value: number): void => {
        this.heroY = value;
      },
      setHeroWidth: (value: number): void => {
        this.heroWidth = value;
      },
      setHeroHeight: (value: number): void => {
        this.heroHeight = value;
      },
      setHeroRadius: (value: number): void => {
        this.heroRadius = value;
      },
      setHeroOpacity: (value: number): void => {
        this.heroOpacity = value;
      },
      setWholeCardAnimating: (value: boolean): void => {
        this.wholeCardAnimating = value;
      },
      getWholeCardSnapshot: (): image.PixelMap | null => this.wholeCardSnapshot,
      setWholeCardSnapshot: (value: image.PixelMap | null): void => {
        this.wholeCardSnapshot = value;
      },
      setWholeCardSnapshotOpacity: (value: number): void => {
        this.wholeCardSnapshotOpacity = value;
      },
      setWholeCardScale: (value: number): void => {
        this.wholeCardScale = value;
      },
      setWholeCardTranslateX: (value: number): void => {
        this.wholeCardTranslateX = value;
      },
      setWholeCardTranslateY: (value: number): void => {
        this.wholeCardTranslateY = value;
      },
      setWholeCardClipHeight: (value: number): void => {
        this.wholeCardClipHeight = value;
      },
      setWholeCardRadius: (value: number): void => {
        this.wholeCardRadius = value;
      },
      setWholeCardSnapshotHeight: (value: number): void => {
        this.wholeCardSnapshotHeight = value;
      },
      setFromWholeCard: (value: boolean): void => {
        this.entryFromWholeCard = value;
      },
      isFromWholeCard: (): boolean => this.entryFromWholeCard,
      setFromRect: (value: boolean): void => {
        this.entryFromRect = value;
      },
      isFromRect: (): boolean => this.entryFromRect,
      isEntranceArmed: (): boolean => this.entranceArmed,
      setEntranceArmed: (value: boolean): void => {
        this.entranceArmed = value;
      },
    },
    (): ImageViewerSrcRect | undefined => this.playerHeroRect(),
    (): string => this.entryCoverUrl(),
    (): number => this.screenWidthVp,
    (): number => this.screenHeightVp,
    (): ImageViewerSrcRect | undefined => this.param.cardRect,
    (): ImageViewerSrcRect | undefined => this.param.srcRect,
    (): boolean => this.param.mirrorHeroReturn === false,
    (): boolean => this.destroyed,
    (): boolean => this.closing,
    (): UIContext => this.getUIContext(),
    (callback: () => void, delayMs: number): void => {
      this.scheduleTimeout(callback, delayMs);
    },
  );
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
  private danmakuDraftVersion: number = 0;
  private danmakuSubmit: VideoDanmakuSubmissionController = new VideoDanmakuSubmissionController({
    isDestroyed: (): boolean => this.destroyed || this.closing,
    getTarget: () => ({ aid: this.detail.aid, bvid: this.detail.bvid,
      cid: this.currentCid, version: this.playerSourceVersion }),
    getProgress: (): number => this.videoProgressSeconds,
    getDraft: (): string => this.danmakuDraft,
    getDraftVersion: (): number => this.danmakuDraftVersion,
    setDraft: (value: string): void => { this.updateDanmakuDraft(value); },
    setSending: (value: boolean): void => { this.danmakuSending = value; },
    ensureLogin: (): boolean => this.ensureLogin(),
    showLocal: (message: string, seconds: number, id: string): void => {
      this.danmakuOn = true;
      this.localDanmakuText = message;
      this.localDanmakuId = id;
      this.localDanmakuSeconds = seconds;
      this.localDanmakuToken++;
    },
    toast: (message: string): void => this.toast(message),
  });
  private playback: VideoPlaybackController = new VideoPlaybackController({
    isDestroyed: (): boolean => this.destroyed,
    getDetail: (): VideoDetail => this.detail,
    getCurrentCid: (): number => this.currentCid,
    hasPlaybackUrls: (): boolean => this.playUrls.length > 0,
    getSwitchingCid: (): number => this.pageSwitchingCid,
    getResumeCid: (): number => this.param.resumePosition !== undefined ? (this.param.cid ?? 0) : 0,
    getResumePosition: (): number => this.param.resumePosition ?? 0,
    beginInitial: (cid: number): void => {
      this.playbackFailureText = '获取播放地址失败';
      this.resetPlaybackSize();
      this.currentCid = cid;
      this.currentPageIndex = 0;
    },
    publish: (info: PlayUrlInfo, cid: number, index: number, seekSeconds: number): void =>
      this.applyPlaybackSource(info, cid, index, seekSeconds),
    initialFailed: (message: string): void => {
      this.playbackAddressFailed = true;
      this.playbackFailureText = message;
    },
    initialSelected: (selection: PlaybackSelection): void => {
      CommentLog.info('resume', 'lastPlayTime=' + String(selection.info.lastPlayTime) +
        ' lastPlayCid=' + String(selection.info.lastPlayCid) + ' pickedCid=' + String(selection.cid) +
        ' seek=' + String(selection.resumeSeconds));
    },
    setSwitchingCid: (cid: number): void => { this.pageSwitchingCid = cid; },
    pageSwitched: (): void => {
      this.playerCollapseRaw = 0;
      this.playerCollapse = 0;
      this.playerEnded = false;
    },
    toast: (message: string): void => this.toast(message),
  });
  private detailLoader: VideoDetailController = new VideoDetailController({
    isAlive: () => !this.destroyed,
    waitEntrance: () => this.hero.waitEntranceGate(),
    publishStatus: (state: VideoDetailStatus) => {
      this.loading = state.loading;
      this.errorText = state.error;
    },
    publishMetadata: (state: VideoDetailMetadata) => {
      this.upFollowerCount = state.followers;
      this.upVideoCount = state.videos;
      this.videoTags = state.tags;
      this.pageTint = state.tint;
    },
    onLoaded: (detail: VideoDetail) => this.applyLoadedVideo(detail),
  });
  private accountContext: VideoAccountController = new VideoAccountController({
    isAlive: () => !this.destroyed,
    getRevision: () => ({ like: this.likeActionVersion, coin: this.coinActionVersion,
      favorite: this.favoriteActionVersion, follow: this.followActionVersion }),
    publishRelation: (state: VideoAccountRelation) => {
      // 控制器只发布已验证归属的读取结果；按钮版本仍由本地互动的写入推进。
      if (state.revision.like === this.likeActionVersion) {
        this.liked = state.value.liked;
        this.disliked = state.value.disliked;
      }
      if (state.revision.coin === this.coinActionVersion) this.coinCountByMe = state.value.coin;
      if (state.revision.favorite === this.favoriteActionVersion) this.favorited = state.value.favorite;
    },
    publishFollow: (state: VideoFollowStatus) => {
      if (state.revision !== this.followActionVersion) return;
      if (state.following !== null) this.following = state.following;
      this.followLoading = state.loading;
    },
    publishEmotes: (state: VideoEmoteStatus) => {
      this.emotePackages = state.packages;
      this.emoteLoading = state.loading;
      if (this.emotePackageIndex >= state.packages.length) this.emotePackageIndex = 0;
    },
  });
  private destroyed: boolean = false;
  private timers: Set<number> = new Set<number>();
  private replyLikeBusy: Set<number> = new Set<number>();
  private replyThreadAnimating: boolean = false;
  private likeActionVersion: number = 0;
  private coinActionVersion: number = 0;
  private favoriteActionVersion: number = 0;
  private followActionVersion: number = 0;
  /** 互动动作控制器：乐观更新与失败回滚都在这里；@State 仍在本页，经下方闭包读写。 */
  private actions: VideoActionController = new VideoActionController({
    isDestroyed: (): boolean => this.destroyed,
    ensureLogin: (): boolean => this.ensureLogin(),
    toast: (message: string): void => this.toast(message),
    isActionBusy: (): boolean => this.actionBusy,
    setActionBusy: (value: boolean): void => {
      this.actionBusy = value;
    },
    bumpLikeVersion: (): void => {
      this.likeActionVersion++;
    },
    bumpCoinVersion: (): void => {
      this.coinActionVersion++;
    },
    bumpFavoriteVersion: (): void => {
      this.favoriteActionVersion++;
    },
    getAid: (): number => this.detail.aid,
    getBvid: (): string => this.detail.bvid,
    getUpMid: (): number => this.detail.upMid,
    getLiked: (): boolean => this.liked,
    setLiked: (value: boolean): void => {
      this.likeActionVersion++;
      this.liked = value;
    },
    getDisliked: (): boolean => this.disliked,
    setDisliked: (value: boolean): void => {
      this.likeActionVersion++;
      this.disliked = value;
    },
    getLikeCount: (): number => this.likeCount,
    setLikeCount: (value: number): void => {
      this.likeCount = value;
    },
    getCoinCountByMe: (): number => this.coinCountByMe,
    setCoinCountByMe: (value: number): void => {
      this.coinActionVersion++;
      this.coinCountByMe = value;
    },
    getCoinCount: (): number => this.coinCount,
    setCoinCount: (value: number): void => {
      this.coinCount = value;
    },
    getCoinChoice: (): number => this.coinChoice,
    getCoinWithLike: (): boolean => this.coinWithLike,
    setCoinSheetOpen: (value: boolean): void => {
      this.coinSheetOpen = value;
    },
    getFavorited: (): boolean => this.favorited,
    setFavorited: (value: boolean): void => {
      this.favoriteActionVersion++;
      this.favorited = value;
    },
    getFavoriteCount: (): number => this.favoriteCount,
    setFavoriteCount: (value: number): void => {
      this.favoriteCount = value;
    },
    getFollowing: (): boolean => this.following,
    setFollowing: (value: boolean): void => {
      this.followActionVersion++;
      this.following = value;
    },
    getFollowLoading: (): boolean => this.followLoading,
    setFollowLoading: (value: boolean): void => {
      this.followLoading = value;
    },
    getAccent: (): string => this.accent,
    getUIContext: (): UIContext => this.getUIContext(),
  });
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
  // playerCollapse 的精确手势累计值；视觉态仅过滤不足半个 vp 的亚像素抖动。
  private playerCollapseRaw: number = 0;
  private recommendations: VideoRecommendations = new VideoRecommendations(
    (): boolean => this.destroyed, (): VideoDetail => this.detail,
    (status: RelatedVideoStatus): void => {
      this.relatedLoading = status.loading;
      this.relatedLoadError = status.error;
      this.relatedCount = status.count;
    });
  private ugcSource: BasicDataSource<UgcSeasonEpisode> = this.recommendations.episodes;
  /** 相关推荐懒加载数据源（无限追加必须虚拟化；AutoPlay 取相关第一条也从这里读）。 */
  private relatedSource: BasicDataSource<VideoItem> = this.recommendations.related;
  @State threadAllReplies: Array<ReplyItem> = [];
  private mainReplyComposerFocused: boolean = false;
  private threadReplyComposerFocused: boolean = false;
  /**
   * 评论编排控制器：列表与线程发布展示快照，分享导出独立拥有资源与取消会话。
   */
  private replies: RepliesController = new RepliesController({
    isDestroyed: () => this.destroyed,
    getSubject: (): ReplySubject => ({ oid: this.detail.aid, type: 1 }),
    publishMain: (state: MainRepliesState) => {
      this.replySortMode = state.sort;
      this.replyLoading = state.loading;
      this.replyItemCount = state.count;
      this.replyHasMore = state.hasMore;
      this.replyLikeVersion = state.version;
      this.replyLoadError = state.error;
      this.replyVoteCard = state.voteCard;
    },
    publishThread: (state: ThreadRepliesState) => {
      this.replyThreadRoot = state.root;
      this.threadAllReplies = state.replies;
      this.threadLoading = state.loading;
      this.threadHasMore = state.hasMore;
      this.replyLikeVersion = state.version;
    },
    onSortApplied: () => {
      this.hideReplyThread();
    },
  }, { clearOnSort: true, video: true }, new ReplyShareController({
    isDestroyed: () => this.destroyed,
    getSubject: (): ReplySubject => ({ oid: this.detail.aid, type: 1 }),
    toast: (message: string) => this.toast(message),
    getUIContext: () => this.getUIContext(),
    buildShareLink: (item: ReplyItem): string =>
      'https://www.bilibili.com/video/' + this.detail.bvid + '#reply' + String(item.rpid),
    renderShareCard: (): void => this.ReplyShareCardBuilder(),
    ensureShareContext: (_context: common.UIAbilityContext | undefined): boolean => true,
    onShareFailed: (item: ReplyItem, link: string, error: Object) => {
      CommentLog.error('share.reply.error', 'rpid=' + String(item.rpid) + ' error=' + CommentLog.errorText(error));
      this.copyTextToClipboard(link);
      this.toast('分享面板暂不可用，已复制评论链接');
    },
  }));

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
    if (!focused && !this.emotePanelOpen && !this.replySending &&
      this.replyDraft.trim().length === 0 && this.replyImages.length === 0) {
      this.replySubmit.reset();
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
    if (this.replyDraft.trim().length === 0 && this.replyImages.length === 0) {
      this.replySubmit.reset();
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
    this.replySubmit.reset();
    this.replies.cancelThread();
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

  private hideReplyThread(): void {
    if (this.replyThreadOpen) this.replySubmit.reset();
    this.replies.cancelThread();
    this.replyThreadOpen = false;
  }

  /** 楼中楼里删掉一条子回复：连同其子孙一起从页面回复源集合移除（面板内视图树由组件自维护）。 */
  private threadRemoveReply(target: ReplyItem): void {
    this.replies.removeThread(target.rpid, true);
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

  private currentPageTitle(): string {
    for (let i: number = 0; i < this.detail.pages.length; i++) {
      if (this.detail.pages[i].cid === this.currentCid) return this.detail.pages[i].part;
    }
    return '';
  }

  /** 播放中仅长屏/竖向画幅收缩；暂停后任何画幅都可收成继续播放横幅。 */
  private shouldCollapsePlayer(): boolean {
    // 起播缓冲时 playerPlaying 仍为 false，不能把它当成用户暂停；首个真实视频帧出现前
    // 保持播放区完整高度，避免用户滚动简介/评论时把封面和加载中的 Surface 压成横条。
    if (this.startupCoverVisible || this.playUrl.length === 0 || this.playbackAddressFailed) return false;
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

  /** 全屏状态变化时同步弹幕视口；竖屏收缩只裁剪画布，不改变画布自身尺寸。 */
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
    if (playing === false) this.playback.reportHeartbeat(this.videoProgressSeconds, this.playerPlaying, true);
  }

  private toast(message: string): void {
    safeToast(this.getUIContext(), message);
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
   * 收放量跟随手势逐帧写入；只过滤不足 0.5vp 的亚像素抖动。
   * 旧的 2% 行程量化在高视频区域会形成 6～10vp 台阶，视觉上只有约 15～30fps。
   */
  private setPlayerCollapse(raw: number): void {
    const maxCollapse: number = Math.max(0, this.playerHeight() - this.minPlayerHeight());
    const clamped: number = Math.max(0, Math.min(maxCollapse, raw));
    this.playerCollapseRaw = clamped;
    // 轻量阻尼曲线：收起开始响应更积极，接近终点逐渐减速；反向展开自然呈现先缓后快。
    // 曲线始终单调且端点准确，不使用补间动画，因此不会产生手指拖动延迟。
    const progress: number = maxCollapse > 0 ? clamped / maxCollapse : 0;
    let curved: number = maxCollapse * (progress + 0.12 * Math.sin(Math.PI * progress));
    if (clamped === 0) curved = 0;
    else if (clamped === maxCollapse) curved = maxCollapse;
    const threshold: number = 0.5;
    if (Math.abs(curved - this.playerCollapse) >= threshold ||
      (clamped === 0 && this.playerCollapse !== 0) ||
      (clamped === maxCollapse && this.playerCollapse !== maxCollapse)) {
      this.playerCollapse = curved;
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
    const restored: RecoveryViewState | undefined = AppRecoveryState.takeView(this.playbackRecoveryKey());
    if (restored !== undefined) {
      // Rebuild identity/progress only: old card rectangles and hero snapshots belong to the previous window.
      this.param = { bvid: this.param.bvid, aid: this.param.aid, title: this.param.title,
        epId: this.param.epId, cover: this.param.cover, cid: restored.cid ?? this.param.cid,
        resumePosition: restored.position ?? this.param.resumePosition,
        initiallyPaused: restored.playing !== true };
    }
    this.destroyed = false;
    this.replyLikeBusy = new Set<number>();
    this.replySubmit.reset();
    // NavDestination 返回时组件实例会复用；离场前的全屏状态不能污染竖屏布局。
    this.playerFullscreen = false;
    this.playerFullscreenExitVisual = false;
    this.playerFullscreenExitHeight = 0;
    this.playerFullscreenExitTop = 0;
    this.pendingVideoNavigation = null;
    this.pendingVideoReplace = false;
    // 上次离页时未完成的请求会因 destroyed 跳过 finally 写状态；返回页面时统一解锁。
    this.replySending = false;
    this.emoteLoading = false;
    this.actionBusy = false;
    this.favoritePicker.reset();
    this.followLoading = false;
    this.danmakuSending = false;
    this.danmakuSubmit.reset();
    this.pageSwitchingCid = 0;
    this.replyThreadOpen = false;
    // 弹幕总开关从持久化设置恢复（其余弹幕项由 PlayerView 自行恢复后经此页透传/回传）。
    this.danmakuOn = AppTheme.loadDanmakuSettings().enabled;
    this.bvid = this.param.bvid;
    this.aid = this.param.aid;
    this.entryCoverSource = this.param.cover ?? '';
    this.entryFromRect = false;
    this.entryFromWholeCard = false;
    // 页面复用（返回再进）时上一实例的整卡快照已不再渲染，先释放再置空（含 hero 可见层复位）。
    this.hero.resetForReuse();
    this.initStarted = false;
    this.closing = false;
    this.startupCoverVisible = true;
    this.refreshScreenSize();
    if (!this.hero.prepareWholeCardEntrance()) this.hero.prepareCardEntrance();
    // 请求与入场飞行并行：init 只把"写状态"挂在闸门上，动画期间不会重排整页。
    if (this.entryFromWholeCard || this.entryFromRect) this.hero.armEntranceGate();
    // 首次 VSync 后立即移动封面。
    if (this.entryFromWholeCard) this.hero.triggerWholeCardExpansion();
    else this.hero.triggerEntranceExpansion();
    this.startInit();
  }

  /** 播放区在窗口中的 hero 矩形（作为测量函数注入 VideoHeroTransitionController）。
   *  入场期详情尚未返回，天然稳定为 16:9。 */
  private playerHeroRect(): ImageViewerSrcRect | undefined {
    if (this.screenWidthVp <= 0) return undefined;
    return {
      x: 0,
      y: Immersive.statusBarHeight(),
      w: this.screenWidthVp,
      h: this.visiblePlayerHeight(),
    };
  }

  private startInit(): void {
    if (this.initStarted || this.destroyed) return;
    this.initStarted = true;
    this.init().catch(() => {
    });
  }

  onCloseRequested(): void {
    if (this.destroyed || this.closing) return;
    const destination: NavDestinationInfo | undefined = this.queryNavDestinationInfo();
    const target: number = AppStorage.get<number>('videoDetailCloseTargetIndex') ?? -1;
    if (destination === undefined || destination.index !== target) return;
    // Watch 会广播到栈内所有保活页面。先消费本次请求，避免 pop 后底页成为栈顶再响应。
    const handled: number = AppStorage.get<number>('videoDetailCloseHandled') ?? -1;
    if (handled === this.closeRequest) return;
    AppStorage.setOrCreate<number>('videoDetailCloseHandled', this.closeRequest);
    this.goBack();
  }

  /** 镜面退出（当前播放区封面收回源封面，详情正文独立淡出）的动画主体在
   *  VideoHeroTransitionController.runCloseTransition；这里只负责 closing 防重入。 */
  goBack(): void {
    if (this.closing) return;
    this.closing = true;
    this.hero.runCloseTransition();
  }

  aboutToDisappear(): void {
    this.danmakuSubmit.reset();
    this.actions.dispose();
    this.replySubmit.dispose();
    this.videoReportDialog?.close();
    this.videoReportDialog = null;
    this.hero.openEntranceGate();
    this.replies.dispose();
    this.destroyed = true;
    this.playback.invalidate();
    this.recommendations.dispose();
    this.favoritePicker.dispose();
    this.detailLoader.dispose();
    this.accountContext.dispose();
    this.playback.reportHeartbeat(this.videoProgressSeconds, this.playerPlaying, true);
    releasePixelMap(this.wholeCardSnapshot);
    this.wholeCardSnapshot = null;
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

  private upStatsText(): string {
    const followers: string = this.upFollowerCount >= 0 ? formatCount(this.upFollowerCount) : '--';
    const videos: string = this.upVideoCount >= 0 ? formatCount(this.upVideoCount) : '--';
    return followers + ' 粉丝  ' + videos + ' 视频';
  }

  private applyPlaybackSource(info: PlayUrlInfo, cid: number, index: number, seekSeconds: number): void {
    this.previewPlayback = info.isPreview;
    this.playUrl = info.url;
    this.playUrls = info.urls;
    this.playAudioUrls = info.audioUrls;
    this.qualityOptions = info.qualities;
    this.subtitleTracks = info.subtitles;
    this.currentQuality = info.quality;
    this.initialSeekSeconds = seekSeconds;
    this.videoProgressSeconds = Math.max(0, seekSeconds);
    this.playerPlaying = false;
    this.playback.resetHeartbeat();
    this.resetPlaybackSize();
    this.currentCid = cid;
    this.currentPageIndex = index;
    this.playbackAddressFailed = false;
    // 最后发布版本，播放器只读取同一次选择的完整属性。
    this.playerSourceVersion++;
    this.danmakuSubmit.reset();
  }

  async init(): Promise<void> {
    this.danmakuSubmit.reset();
    this.actions.reset();
    this.playback.invalidate();
    this.pageSwitchingCid = 0;
    this.playbackAddressFailed = false;
    this.descExpanded = false;
    this.descNeedsExpand = false;
    this.recommendations.reset();
    this.accountContext.reset();
    await this.detailLoader.load({ aid: this.aid, bvid: this.bvid, epId: this.param.epId ?? 0 });
  }

  /** 页面只衔接独立领域：基础资料提交后启动播放、推荐、评论及账号上下文。 */
  private applyLoadedVideo(detail: VideoDetail): void {
    this.detail = detail;
    this.likeCount = detail.like;
    this.coinCount = detail.coin;
    this.favoriteCount = detail.favorite;
    this.recommendations.setEpisodes(detail);
    this.ugcCount = this.ugcSource.totalCount();
    this.playback.loadInitial(detail).catch(() => {});
    this.recommendations.loadInitial(detail.aid, detail.bvid).catch(() => {});
    this.replies.load(true).catch(() => {});
    this.accountContext.activate(detail);
  }

  openEmotePanel(): void {
    if (!this.ensureLogin()) return;
    const opening: boolean = !this.emotePanelOpen;
    this.emotePanelOpen = opening;
    // @State 在当前事件完成后才刷新，直接使用 opening，避免这里读到切换前的旧值。
    this.syncReplyComposerActive(opening);
    if (opening) {
      this.accountContext.loadEmotes().catch(() => {});
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
    this.replySubmit.draftChanged();
    this.replyDraft += item.text;
  }

  onLoginVersionChanged(): void {
    if (this.destroyed) return;
    this.danmakuSubmit.reset();
    this.replyLikeBusy = new Set<number>();
    this.actions.reset();
    this.replySubmit.reset();
    this.replies.dispose();
    this.hideReplyThread();
    // 初次详情仍在等待时重发，使旧账号响应失效；已展示的视频只刷新账号资料。
    if (this.loading) this.init().catch(() => {});
    else {
      this.accountContext.refresh();
      this.replies.load(true).catch(() => {});
    }
  }

  private ensureLogin(): boolean {
    if (UserStore.isLogin) return true;
    this.toast('请先登录后再操作');
    AppNavStack.pushPathByName(NAV_LOGIN, null);
    return false;
  }

  private openUgcEpisode(ep: UgcSeasonEpisode): void {
    if (ep.aid <= 0 && ep.bvid.length === 0) return;
    if (ep.cid === this.currentCid && (ep.bvid === this.detail.bvid ||
      (ep.bvid.length === 0 && ep.aid === this.detail.aid))) return;
    const param: VideoDetailParam = { bvid: ep.bvid, aid: ep.aid, cid: ep.cid, resumePosition: 0, title: ep.title };
    this.navigateVideoDetail(param, true);
  }

  private systemQueueAsset(direction: number): string {
    return VideoSystemQueue.neighbor(this.detail, this.currentCid, direction)?.assetId ?? '';
  }

  private playbackRecoveryKey(): string {
    const epId: number = this.param.epId ?? 0;
    if (Number.isSafeInteger(epId) && epId > 0) return 'video:ep' + String(epId);
    return 'video:' + (this.param.bvid.length > 0 ? this.param.bvid : 'av' + String(this.param.aid));
  }

  private savePlaybackRecovery(): void {
    if (this.destroyed || this.currentCid <= 0 || this.loading || this.playbackAddressFailed ||
      !Number.isFinite(this.videoProgressSeconds)) return;
    AppRecoveryState.saveView(this.playbackRecoveryKey(),
      { cid: this.currentCid, position: Math.max(0, this.videoProgressSeconds), playing: this.playerPlaying });
  }

  private onPlaybackPlayingChange(playing: boolean, sourceVersion: number): void {
    if (this.destroyed || sourceVersion !== this.playerSourceVersion) return;
    this.onPlayerPlayingChange(playing);
    this.savePlaybackRecovery();
  }

  private onPlaybackProgress(seconds: number, sourceVersion: number): void {
    if (this.destroyed || sourceVersion !== this.playerSourceVersion || !Number.isFinite(seconds)) return;
    this.videoProgressSeconds = Math.max(0, seconds);
    this.savePlaybackRecovery();
    this.playback.reportHeartbeat(seconds, this.playerPlaying);
  }

  private playSystemNeighbor(direction: number): void {
    if (this.destroyed || this.closing || this.loading || this.pageSwitchingCid > 0) return;
    const target: VideoQueueTarget | undefined = VideoSystemQueue.neighbor(this.detail, this.currentCid, direction);
    if (target === undefined) return;
    if (target.pageIndex >= 0) {
      this.playback.switchPage(this.detail.pages[target.pageIndex], target.pageIndex).catch(() => {});
    } else {
      this.closing = true;
      this.navigateVideoDetail({ bvid: target.bvid, aid: target.aid, title: target.title,
        cid: target.cid, resumePosition: 0 }, true);
    }
  }

  private openInteractionVideo(target: VideoInteractionLink): void {
    if (target.aid <= 0 && target.bvid.length === 0 && target.epId <= 0) return;
    const param: VideoDetailParam = { bvid: target.bvid, aid: target.aid,
      epId: target.epId, title: target.title, cover: target.cover };
    this.pushVideoDetail(param);
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
    this.endRecList = this.recommendations.endList(this.detail, this.currentCid);
    // 播完：自动填入"推荐列表第一条"作为结束画面的推荐卡。
    // 优先合集下一集（合集里连续观看），否则用相关推荐第一条。
    const next: UgcSeasonEpisode | null = this.recommendations.nextEpisode(this.detail, this.currentCid);
    if (next !== null) {
      this.endRecTitle = next.title;
      this.endRecCover = next.cover;
      this.endRecUpName = this.detail.upName;
      this.endRecPlayText = '';
      this.endRecDuration = 0;
      this.endRecToken++;
      return;
    }
    const relatedList: Array<VideoItem> = this.relatedSource.getAll();
    if (relatedList.length > 0) {
      const related: VideoItem = relatedList[0];
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
    const next: UgcSeasonEpisode | null = this.recommendations.nextEpisode(this.detail, this.currentCid);
    if (next !== null) {
      this.openUgcEpisode(next);
      return;
    }
    const relatedForPlay: Array<VideoItem> = this.relatedSource.getAll();
    if (relatedForPlay.length > 0) {
      const related: VideoItem = relatedForPlay[0];
      if (related.aid > 0 || related.bvid.length > 0) {
        const param: VideoDetailParam = { bvid: related.bvid, aid: related.aid, title: related.title };
        // 用户主动点"立即播放"走入栈：返回回当前视频（播完好），而不是越过它。
        this.pushVideoDetail(param);
      }
    }
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
    this.replySubmit.reset();
    this.replyThreadAnimating = true;
    this.replies.beginThread(root, mergeUniqueReplies([], root.replies));
    this.replyTargetRootRpid = root.rpid;
    this.replyTargetRpid = root.rpid;
    this.replyTargetName = root.uname;
    // 面板立即升起，网络请求在面板内以 loading 状态完成，点击反馈不再等待首批接口。
    const loading: Promise<void> = this.replies.loadThread(true, false);
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
    this.replySubmit.reset();
    const latest: ReplyItem | null = this.findReplyItem(item.rpid);
    const root: ReplyItem = latest !== null ? latest : item;
    this.replies.updateThreadRoot(root);
    this.replyTargetRootRpid = root.rpid;
    this.replyTargetRpid = root.rpid;
    this.replyTargetName = root.uname;
    this.emotePanelOpen = false;
    this.replyFocusTick++;
    CommentLog.info('ui.reply.select', 'root=' + String(root.rpid) + ' target=' + String(root.rpid));
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
      replies: $threadAllReplies,
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
      onShare: (item: ReplyItem) => this.replies.sharing.share(item).catch(() => {}),
      focusTick: this.threadReplyFocusTick,
      focusId: 'video_thread_reply_composer_editor',
      onSelectReply: (item: ReplyItem) => {
        CommentLog.info('ui.thread.select', 'root=' + String(this.replyThreadRoot.rpid) +
          ' target=' + String(item.rpid));
        this.replySubmit.reset();
        this.replyTargetRpid = item.rpid;
        this.replyTargetName = item.uname;
        this.threadReplyFocusTick++;
      },
      onDeleted: (item: ReplyItem) => {
        this.threadRemoveReply(item);
      },
      onLoadMore: () => {
        this.replies.loadThread(false).catch(() => {
        });
      },
      onDraftChange: (value: string) => {
        this.replySubmit.draftChanged();
        this.replyDraft = value;
      },
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

  /** 发布响应可能不带表情字典，补齐本页已经加载的渲染资源。 */
  private decorateSentReply(item: ReplyItem): void {
    for (let i: number = 0; i < this.emotePackages.length; i++) {
      const emotes: Array<BiliEmote> = this.emotePackages[i].emotes;
      for (let j: number = 0; j < emotes.length; j++) {
        const emote: BiliEmote = emotes[j];
        if (emote.text.length > 0 && item.content.indexOf(emote.text) >= 0 &&
          !item.emotes.some((existing: BiliEmote) => existing.text === emote.text)) item.emotes.push(emote);
      }
    }
  }

  /** 楼中楼新增子回复后，同步主列表中的回复数与预览，避免关掉面板又看到旧状态。 */
  private insertSentThreadReply(item: ReplyItem): void {
    this.replies.addSentThread(item);
  }

  private insertSentInlineReply(item: ReplyItem, rootRpid: number): void {
    this.replies.addSentInline(item, rootRpid);
  }

  async sendReply(): Promise<void> {
    if (this.replyDraft.trim().length === 0 || this.replySending || !this.ensureLogin()) return;
    await this.replySubmit.send();
  }

  private applySubmittedReply(snapshot: ReplySubmissionSnapshot, sent: ReplyItem | null, clearDraft: boolean): void {
    if (clearDraft) this.replyDraft = '';
    if (sent !== null) this.decorateSentReply(sent);
    if (snapshot.root > 0 && snapshot.scope === 'thread') {
      if (clearDraft) {
        this.replyTargetRpid = this.replyThreadRoot.rpid;
        this.replyTargetName = this.replyThreadRoot.uname;
      }
      if (sent !== null) {
        this.insertSentThreadReply(sent);
        this.detail.reply++;
      } else {
        this.replies.thread.clearReplies();
        this.replies.resetThreadPaging();
        this.replies.loadThread(true).catch(() => {});
      }
    } else if (snapshot.root > 0) {
      if (clearDraft) {
        this.replyTargetRootRpid = 0;
        this.replyTargetRpid = 0;
        this.replyTargetName = '';
      }
      if (sent !== null) {
        this.insertSentInlineReply(sent, snapshot.root);
        this.detail.reply++;
      } else {
        this.replies.resetMainPaging();
        this.replies.load(true).catch(() => {});
      }
    } else if (sent !== null) {
      this.replies.addSentMain(sent);
      this.detail.reply++;
      this.scheduleTimeout(() => {
        if (this.detail.aid !== snapshot.oid || this.replyThreadOpen) return;
        try {
          this.replyScroller.scrollToIndex(0, true, ScrollAlign.START);
        } catch (e) {
        }
      }, 16);
    } else {
      this.replies.resetMainPaging();
      this.replies.load(true).catch(() => {});
    }
  }

  private updateDanmakuDraft(value: string): void {
    if (value !== this.danmakuDraft) this.danmakuDraftVersion++;
    this.danmakuDraft = value;
  }

  async sendVideoDanmaku(): Promise<void> {
    await this.danmakuSubmit.send();
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
    const list: Array<ReplyItem> = this.replies.source.getAll();
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].rpid === rpid) return list[i];
    }
    for (let i: number = 0; i < this.threadAllReplies.length; i++) {
      if (this.threadAllReplies[i].rpid === rpid) return this.threadAllReplies[i];
    }
    if (this.replyThreadRoot.rpid === rpid) return this.replyThreadRoot;
    return null;
  }

  /** 评论点赞：委托给共享实现 runReplyLike（登录检查/busy/乐观更新/失败回滚统一在一处）。 */
  async actionReplyLike(item: ReplyItem): Promise<void> {
    await runReplyLike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks(true));
  }

  /** 评论点踩：同理走共享实现（踩赞互斥逻辑在模块内）。 */
  async actionReplyDislike(item: ReplyItem): Promise<void> {
    await runReplyDislike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks(false));
  }

  private replyReactionHooks(isLike: boolean): ReplyReactionHooks {
    const current: () => boolean = this.replies.captureGuard();
    return {
      ensureLogin: () => {
        if (UserStore.isLogin) return true;
        this.toast('请先登录后再操作');
        AppNavStack.pushPathByName(NAV_LOGIN, null);
        return false;
      },
      toast: (message: string) => this.toast(message),
      isDestroyed: () => !current(),
      resolveOid: (it: ReplyItem) => it.oid > 0 ? it.oid : this.detail.aid,
      resolveType: (it: ReplyItem) => it.type > 0 ? it.type : 1,
      clearDislikeOnLike: true,
    };
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
      item: this.replies.sharing.shareItem(),
      upMid: this.detail.upMid,
      qr: this.replies.sharing.shareQr(),
      page: this.replies.sharing.sharePage(),
      linkLabel: this.replies.sharing.shareLink(),
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
      tags: this.videoTags,
      onTagTap: (tag: VideoTagInfo) => {
        AppStorage.setOrCreate<string>('searchPrefillKeyword', tag.name);
        PlayerCommandBus.stop();
        AppNavStack.pushPathByName(NAV_SEARCH, null);
      },
      currentCid: this.currentCid,
      pageSwitchingCid: this.pageSwitchingCid,
      ugcPanelOpen: this.ugcPanelOpen,
      ugcCount: this.ugcCount,
      sponsorTag: this.sponsorSkipEnabled ? this.sponsorFullLabel : '',
      sponsorTagColor: this.sponsorFullColor,
      relatedCount: this.relatedCount,
      relatedSource: this.relatedSource,
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
        this.actions.actionFollow();
      },
      onLike: () => this.actions.actionLike(),
      onTriple: () => this.actions.actionTriple(),
      onDislike: () => this.actions.actionDislike(),
      onCoin: () => this.openCoinSheet(),
      onFavorite: () => this.actions.actionFavorite(),
      onFavoritePick: () => this.favoritePicker.open(),
      onShare: () => this.actionShare(),
      onDescAreaChange: (width: Length) => this.updateDescOverflow(width),
      onToggleDescription: () => {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
          this.descExpanded = !this.descExpanded;
        });
      },
      onSwitchPage: (page: VideoPage, index: number) => this.playback.switchPage(page, index),
      onToggleUgc: () => {
        this.ugcPanelOpen = !this.ugcPanelOpen;
        if (this.ugcPanelOpen) {
          this.recommendations.setEpisodes(this.detail);
          this.ugcCount = this.ugcSource.totalCount();
        }
      },
      onOpenUgc: (episode: UgcSeasonEpisode) => this.openUgcEpisode(episode),
      onOpenRelated: (item: VideoItem) => this.openRelatedVideo(item),
      onReportRelated: (item: VideoItem) => this.reportRelated(item),
      onHideRelated: (item: VideoItem) => this.hideRelated(item),
      onLoadMoreRelated: () => this.recommendations.loadMore(),
      onScrollFrame: (offset: number, scroller: Scroller, state: ScrollState): number =>
        this.onContentScrollFrame(offset, scroller, state),
    })
  }

  private videoReportDialog: CustomDialogController | null = null;

  private reportRelated(item: VideoItem): void {
    if (!UserStore.isLogin) { this.toast('请先登录后再举报'); return; }
    if (item.aid <= 0) { this.toast('当前视频不支持举报'); return; }
    this.videoReportDialog?.close();
    this.videoReportDialog = new CustomDialogController({
      builder: VideoReportDialog({ aid: item.aid, title: item.title }),
      autoCancel: false,
      customStyle: true,
    });
    this.videoReportDialog.open();
  }

  /** ⋮ 菜单-不想看：移除该条相关推荐并提示。 */
  private hideRelated(item: VideoItem): void {
    this.recommendations.hide(item);
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
      if (index === 0) this.hideReplyThread();
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
              this.updateDanmakuDraft(value);
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
          voteCard: this.replyVoteCard,
          voteOid: this.detail.aid,
          draft: this.replyDraft,
          images: this.replyImages,
          allowImages: this.replyTargetRootRpid === 0,
          submission: this.replySubmit,
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
          source: this.replies.source,
          scroller: this.replyScroller,
          onSortChange: (mode: number) => {
            this.replies.changeReplySort(mode);
          },
          onLoadMore: (reset: boolean) => {
            this.replies.load(reset || (this.replyLoadError.length > 0 && this.replies.getRepliesRetryReset()));
          },
          onLike: (item: ReplyItem) => this.actionReplyLike(item),
          onDislike: (item: ReplyItem) => this.actionReplyDislike(item),
          onShare: (item: ReplyItem) => this.replies.sharing.share(item).catch(() => {}),
          onSelectReply: (item: ReplyItem) => this.selectReplyForComposer(item),
          onOpenThread: (item: ReplyItem) => this.openReplyThread(item),
          onDeleted: (item: ReplyItem) => {
            this.replies.removeMain(item.rpid);
            this.detail.reply = Math.max(0, this.detail.reply - 1);
          },
          onDraftChange: (value: string) => {
            this.replySubmit.draftChanged();
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
      if (targetIndex === 0) this.hideReplyThread();
    })
    .onChange((index: number) => {
      this.tab = index;
      this.visualTab = index;
      if (index === 0) this.hideReplyThread();
    })
    .divider({ strokeWidth: 0 })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .clip(true)
  }

  /** 卡片侧带过来的封面：detail 数据回来前播放区/底图直接垫它，入场期不出"加载中"占位。
   *  卡片没带封面时才回退详情封面，同样按 900w 出图，避免播放区拉一张原图。 */
  private entryCoverUrl(): string {
    return this.entryCoverSource.length > 0 ? this.entryCoverSource : biliImageThumbnail(this.detail.cover, 900);
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
              epId: this.detail.epId,
              previewPlayback: this.previewPlayback,
              videoDuration: this.currentPageDuration(),
              initiallyPaused: this.param.initiallyPaused ?? false,
              videoTitle: this.detail.title,
              videoPartTitle: this.currentPageTitle(),
              previousAssetId: this.systemQueueAsset(-1),
              nextAssetId: this.systemQueueAsset(1),
              onPlayPrevious: (): void => this.playSystemNeighbor(-1),
              onPlayNext: (): void => this.playSystemNeighbor(1),
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
              onSponsorFullLabel: (label: string, color: string) => {
                if (this.destroyed) return;
                this.sponsorFullLabel = label;
                this.sponsorFullColor = color;
              },
              localDanmakuText: this.localDanmakuText,
              localDanmakuId: this.localDanmakuId,
              localDanmakuSeconds: this.localDanmakuSeconds,
              localDanmakuToken: this.localDanmakuToken,
              compactMode: !this.playerFullscreen && !this.playerEnded && this.visiblePlayerHeight() < 176,
               onBack: () => {
                 this.goBack();
               },
              onHome: () => {
                if (this.closing) return;
                this.closing = true;
                this.onHome();
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
              onPlayingChange: (playing: boolean, sourceVersion: number) =>
                this.onPlaybackPlayingChange(playing, sourceVersion),
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
                this.updateDanmakuDraft(value);
              },
              onDmSend: () => {
                this.sendVideoDanmaku();
              },
              onProgress: (seconds: number, sourceVersion: number) =>
                this.onPlaybackProgress(seconds, sourceVersion),
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
                this.actions.actionFollow();
              },
              onDislike: () => {
                this.actions.actionDislike();
              },
              onEndRecOpen: (item: VideoItem) => {
                this.onPlayerEndRecOpen(item);
              },
              onInteractionVideo: (target: VideoInteractionLink) => this.openInteractionVideo(target),
              onLike: () => {
                this.actions.actionLike();
              },
              onCoin: () => {
                this.openCoinSheet();
              },
              onFavorite: () => {
                this.actions.actionFavorite();
              },
              onShare: () => {
                this.actionShare();
              },
              onWatchLater: () => this.actions.actionWatchLater(),
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
              Text(this.playbackFailureText)
                .fontSize(12)
                .fontColor('#FFFFFF')
                .textAlign(TextAlign.Center).padding({ left: 20, right: 20 })
              Button('重试播放').height(36).fontSize(12).fontColor('#FFFFFF')
                .backgroundColor('#66373C45').borderRadius(18).margin({ top: 10 })
                .onClick(() => {
                  this.playbackAddressFailed = false;
                  this.playback.loadInitial(this.detail);
                })
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
          // 所有内容状态共用面板背景，避免骨架卡片露在黑色衬底条上形成凸起。
          Column() {
            if (this.loading) {
              LoadingView({ skeleton: 'detail', loading: true })
            } else if (this.errorText.length > 0) {
              LoadingView({ skeleton: 'detail',
                loading: false,
                empty: false,
                errorText: this.errorText,
                onRetry: () => {
                  this.init();
                },
              })
            } else {
              this.DetailToolbar()
              this.DetailTabs()
            }
          }
          .width('100%')
          .layoutWeight(1)
          // 小圆角上沿：面板顶部与播放区底边齐平，圆角缝只露出上方黑色衬底条。
          .borderRadius({ topLeft: 12, topRight: 12 })
          .clip(true)
          .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
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
            this.actions.submitCoin();
          },
          onClose: () => {
            if (!this.actionBusy) this.coinSheetOpen = false;
          },
        })
      }
      if (this.favoritePickerState.open) {
        FavPickSheetView({
          loading: this.favoritePickerState.loading,
          saving: this.favoritePickerState.saving,
          folders: this.favoritePickerState.folders,
          checked: this.favoritePickerState.checked,
          onToggle: (id: number) => {
            this.favoritePicker.toggle(id);
          },
          onConfirm: () => {
            this.favoritePicker.save().catch(() => {
            });
          },
          onClose: () => {
            this.favoritePicker.setOpen(false);
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
