import { PlayerPlaybackSession } from './PlayerPlaybackSession';
import { PlayerPlaybackConfig } from './PlayerPlaybackConfig';
import { PlayerQualityPreference } from '../../common/PlayerQualityPreference';
import { PlayerPlaybackSource, PlayerPlaybackState, PlayerPlaybackEvent, PlayerPlaybackPolicy } from './PlayerPlaybackState';
import { MotionTokens } from '../../common/MotionTokens';
import { VideoReportDialog } from '../VideoReportDialog';
import { AVVolumePanel } from '@kit.AudioKit';
import { SystemMediaVolume } from './SystemMediaVolume';
import { PlayerChapterBar } from './PlayerChapterBar';
import { chapterTitleAt } from './PlayerChapterSupport';
/**
 * 播放器组件：AVPlayer + XComponent 渲染 + Canvas 弹幕引擎 + 手势控制
 */
import { PlayerPictureInPicture, PlayerVideoSize } from './PlayerPictureInPicture';
import { PlayerAuxiliaryController } from './PlayerAuxiliaryController';
import { PlayerMediaExportController, PlayerMediaExportSnapshot, PlayerDownloadUi } from './PlayerMediaExportController';
import { MediaExportFormat } from '../../services/media/MediaExportFormat';
import { image } from '@kit.ImageKit';
import { avSession } from '@kit.AVSessionKit';
import { PlayerAvSessionHelper } from './PlayerAvSessionHelper';
import { PlayerSubtitleController } from './PlayerSubtitleController';
import { PlayerGestureController } from './PlayerGestureController';
import { playerPanelTitle } from './PlayerSheetTheme';
import { PlayerSideSettingsDrawer } from './PlayerSideSettingsDrawer';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ActionResult, BiliApi, DanmakuItem, DmFilterRule, HotPoint, VideoChapter } from '../../api/BiliApi';
import { SponsorBlockApi, SponsorBlockResult, SponsorBlockUserInfo } from '../../api/SponsorBlockApi';
import { UserStore } from '../../services/auth/UserStore';
import { AppTheme, DanmakuSettings } from '../../common/AppTheme';
import { Haptic } from '../../common/Haptic';
import { Immersive } from '../../common/Immersive';
import { formatDuration, formatCount } from '../../common/Utils';
import { PlayerSponsorController, SponsorNoticeUi } from './PlayerSponsorController';
import { PlayerDanmakuClock } from './PlayerDanmakuClock';
import { SubtitleTrack, VideoItem, VideoQualityOption } from '../../model/Models';
import { BasicDataSource } from '../../common/BasicDataSource';
import { PlayerGestureOverlay, PlayerScrubController } from './PlayerGestureOverlay';
import { PlayerFullscreenHeader } from './PlayerFullscreenHeader';
import { CONTROLS_GRADIENT_COLORS } from './PlayerDanmakuSupport';
import { PlayerDanmakuEngine } from './PlayerDanmakuEngine';
import { PlayerBottomControls } from './PlayerBottomControls';
import { PlayerGestureSurface } from './PlayerGestureSurface';
import { PlayerEndScreen } from './PlayerEndScreen';
import { PlayerSeekPreviewController } from './PlayerSeekPreviewController';
import { PlayerSettingsContent } from './PlayerSettingsContent';
import { PlayerCompactControls } from './PlayerCompactControls';
import { DanmakuPinResult, PlayerDanmakuInteractionController } from './PlayerDanmakuInteractionController';
import { PlayerDanmakuAction } from './PlayerDanmakuAction';
import { SponsorBlockCategory, SponsorBlockMode, SponsorBlockSegment, SponsorBlockStore,
  sponsorBlockSupportedActions } from '../../common/SponsorBlock';
import { SponsorBlockNotice } from './SponsorBlockNotice';
import { VideoDownloadService } from '../../services/media/VideoDownloadService';
import { ContinueWatchingStore } from '../../common/ContinueWatchingStore';

/**
 * 非首帧关键请求的延后窗口：空降片段 / 章节 / 拖动预览 / 在看人数都属于增强能力，
 * 首帧前发出去只会和播放地址、封面抢带宽与解码。首帧事件先到就提前发。
 */
const DEFERRED_LOAD_DELAY_MS: number = 1200;

/** showDialog 按钮的声明类型（promptAction 的 Button 命名空间类型不便直接引用）。 */
interface ReportButtonItem {
  text: string;
  color: string;
}
@Component
export struct PlayerView {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  @Prop videoUrl: string = '';
  @Prop videoUrls: Array<string> = [];
  @Prop audioUrls: Array<string> = [];
  @Prop @Watch('onQualityOptionsChanged') qualityOptions: Array<VideoQualityOption> = [];
  @Prop @Watch('onSubtitlesChanged') subtitles: Array<SubtitleTrack> = [];
  @Prop currentQuality: number = 0;
  @Prop @Watch('onSourceVersionChanged') sourceVersion: number = 0;
  /** 初始续播位置（秒）；首帧 prepared 后自动 seek 到该位置。 */
  @Prop initialSeekSeconds: number = 0;
  @Prop aid: number = 0;
  @Prop bvid: string = '';
  @Prop cid: number = 0;
  @Prop epId: number = 0;
  @Prop previewPlayback: boolean = false;
  /** 视频时长（秒，业务页详情数据）：弹幕分段数预估用；0 表示未知，由播放器 durationUpdate 兜底。 */
  @Prop videoDuration: number = 0;
  @Prop videoTitle: string = '';
  @Prop videoPartTitle: string = '';
  @Prop videoCover: string = '';
  @Prop ownerName: string = '';
  @Prop ownerFace: string = '';
  @Prop liked: boolean = false;
  @Prop coined: boolean = false;
  @Prop favorited: boolean = false;
  @Prop @Watch('onExternalDanmakuChanged') externalDanmakuOn: boolean = true;
  /** 弹幕画布固定高度（展开态播放区高/全屏高）：收起/展开动画期画布节点尺寸恒定，只有外层裁剪窗口收缩，
   *  Canvas 后备缓冲不被逐帧 resize，避免清缓冲造成的弹幕闪烁。 */
  @Prop danmakuFixedHeight: number = 0;
  /** 弹幕引擎就绪（或已绑定外部画布）后回调，外部据此直接驱动视口尺寸。 */
  onDanmakuEngineReady: (engine: PlayerDanmakuEngine) => void = (engine: PlayerDanmakuEngine) => {
  };
  @Prop localDanmakuText: string = '';
  @Prop @Watch('onLocalDanmakuRequested') localDanmakuToken: number = 0;
  @Prop @Watch('onCompactModeChanged') compactMode: boolean = false;
  onBack: () => void = () => {};
  onHome: () => void = () => {};
  /** AVPlayer 回报的真实画幅：全屏时判断竖屏视频保持竖屏。 */
  private realVideoWidth: number = 0;
  private realVideoHeight: number = 0;
  /** 当前全屏是否为竖屏全屏（竖屏视频）：决定顶栏让出状态栏高度。 */
  private fullscreenPortrait: boolean = false;
  onFullscreenChange: (fullscreen: boolean) => void = () => {};
  /** 系统开始转回竖屏：父页只启动外层裁剪窗口的缩放，此时不改逻辑全屏和弹幕视口。 */
  onFullscreenExitStart: () => void = () => {};
  onPlayingChange: (playing: boolean) => void = () => {};
  /** playing 与 startRenderFrame 均到达后通知父页，父页据此撤掉跨 XComponent 创建期的稳定封面。 */
  onFirstFrameShown: () => void = () => {};
  onResumeRequest: () => void = () => {};
  onDanmakuChange: (enabled: boolean) => void = () => {};
  /** 全视频空降标签（如「商业推广」）：交给页面显示在标题前，避免长期盖住画面。 */
  onSponsorFullLabel: (label: string, color: string) => void = () => {};
  /** AVPlayer 解码后的真实视频尺寸，详情页据此重算高度，避免竖屏长视频被裁切。 */
  onVideoSizeChange: (width: number, height: number) => void = () => {};
  /** 横屏底栏弹幕输入：草稿与发送由业务页（VideoDetail）持有 */
  @Prop dmDraft: string = '';
  @Prop dmSending: boolean = false;
  onDmDraftChange: (value: string) => void = () => {};
  onDmSend: () => void = () => {};
  onProgress: (seconds: number) => void = () => {};
  /** 在线观看人数变化上报：详情页把"X人正在看"显示在信息行（竖屏播放器不再悬浮）。 */
  onOnlineCount: (value: string) => void = () => {};
  onEnded: () => void = () => {};
  onLike: () => void = () => {};
  onCoin: () => void = () => {};
  onFavorite: () => void = () => {};
  onShare: () => void = () => {};
  onWatchLater: () => void = () => {};
  /** 播完后「立即播放」下一段（由业务页替换为推荐视频/下一集）。 */
  onEndPlayNow: () => void = () => {};
  // 播完推荐卡数据（推荐列表第一条的排布）
  @Prop endRecTitle: string = '';
  @Prop endRecCover: string = '';
  @Prop endRecUpName: string = '';
  @Prop endRecPlayText: string = '';
  @Prop endRecDuration: number = 0;
  @Prop endRecToken: number = 0;
  /** 横屏结束画面推荐列表（首条与"立即播放"同目标：合集下一集或相关推荐第一条）。 */
  @Prop endRecList: Array<VideoItem> = [];
  /** 当前 UP 的关注状态（横屏结束画面"+ 关注"胶囊）。 */
  @Prop upFollowing: boolean = false;
  /** 当前点踩状态（横屏结束画面图标高亮）。 */
  @Prop disliked: boolean = false;
  onFollow: () => void = () => {};
  onDislike: () => void = () => {};
  /** 播完后点击推荐卡：打开对应稿件（业务页替换当前页）。 */
  onEndRecOpen: (item: VideoItem) => void = () => {};
  /** 播完结束画面是否可见（由 onEnded 置位，播放新源时复位）。 */
  @State endScreenOpen: boolean = false;
  @State playing: boolean = false;
  @State prepared: boolean = false;
  /** 首个播放帧是否已可见（playing + startRenderFrame）：之前播放区垫封面，避免空 surface 黑屏。 */
  @State firstFrameShown: boolean = false;
  @State errorText: string = '';
  @State curTime: number = 0;
  @State duration: number = 0;
  @State danmakuOn: boolean = true;
  /** 被点击停住的弹幕（操作条：点赞/复制/举报）。null 表示无选中。 */
  @State dmPinnedText: string = '';
  @State dmPinnedVisible: boolean = false;
  /** 气泡锚点（vp）：定位在弹幕上方/下方。 */
  @State dmPinBubbleX: number = 0;
  @State dmPinBubbleY: number = 0;
  /** 气泡尺寸（供 clamp 复用）。 */
  @State dmPinBubbleW: number = 100;
  @State dmPinBubbleH: number = 34;
  @State fullscreen: boolean = false;
  // 进入播放页直接展示纯画面；用户点画面或暂停时再唤出控制层。
  @State showControls: boolean = false;
  @State buffering: boolean = false;
  @State showMoreMenu: boolean = false;      // 竖屏：底部 Sheet 设置面板
  @State showSideDrawer: boolean = false;    // 横屏：播放器栈顶右侧抽屉设置面板
  @State moreSheetPage: string = 'menu';     // Sheet/抽屉共用的子页状态
  private settingsOpenedDirectly: boolean = false;
  /** 竖屏 ⋮ 面板高度（vp）：业务页传“默认评论区”高度，0 表示用内置兜底。 */
  @Prop moreSheetHeight: number = 0;
  @State playMode: number = 0;               // 播放模式：0 自动连播 1 列表循环 2 单集循环
  @State mirrorOn: boolean = false;          // 镜像翻转（画面水平翻转）
  @State timerMinutes: number = 0;           // 定时关闭分钟数（0 关闭）
  @StorageLink('videoQualityPref') qualityPref: number = 0;  // 画质偏好：0 自动 1 高码率 2 高清高码 3 智能省流
  private timerFireAt: number = 0;
  @State subtitleOn: boolean = false;
  @State subtitleIndex: number = -1;
  @State subtitleText: string = '';
  @StorageProp('subtitleScale') @Watch('onSubtitleScaleChanged') subtitleScale: number = 1.0;
  @State subtitleLoading: boolean = false;
  @State dmFilterRulesCount: number = 0;
  @State dmFilterLoading: boolean = false;
  @State dmFilterDraft: string = '';
  @State dmFilterType: number = 0;
  @State dmListCount: number = 0;
  @State chapters: Array<VideoChapter> = [];
  @State hotPoints: Array<HotPoint> = [];
  /** 每个源只做一次片头跳过判断（番剧）。 */
  private pgcSkipTried: boolean = false;
  @State activeQuality: number = 0;
  @State qualityLoading: boolean = false;
  @State downloadBusy: boolean = false;
  @State downloadProgress: number = -1;
  @State downloadQuality: number = 0;
  @State playbackRate: number = 1.0;
  @State dmOpacity: number = 0.85;
  @State dmFrameRate: number = 60;
  @State dmSpeed: number = 1.0;
  // 默认 1.0：1.3 时行高过大、同屏轨道只有 4 条左右，密度明显低于 B 站；设置面板可在 0.7~1.8 间调节。
  @State dmFontScale: number = 1.0;
  @State dmSpacing: number = 1.0;
  @State dmDensity: number = 22;
  /** 智能云屏蔽等级 0-10（weight 低于等级的不喷出，0 关闭）。 */
  @State dmBlockLevel: number = 0;
  @State blockScrollDm: boolean = false;
  @State blockTopDm: boolean = false;
  @State blockBottomDm: boolean = false;
  @State blockColorDm: boolean = false;
  @State dmMerge: boolean = false;
  @State dmMergeCount: boolean = true;
  @State holdSpeedActive: boolean = false;
  // 横滑预览时间下沉到 PlayerGestureOverlay 自持（scrubCtl 注入写回），
  // 父结构体不再随手势采样频率全量重渲染。这里只留非响应式镜像供手势结束时的 seekTo 读取落点。
  private gestureScrubValue: number = -1;
  private scrubCtl: PlayerScrubController = new PlayerScrubController();
  // 底部进度条/章节条的「待落点」通道：横滑期间与结束后保持预览位置（条跟手），
  // seek 完成后清零回落到真实播放进度。与 scrubCtl 分开：叠层预览卡要在手势结束时立即消失。
  private seekTargetCtl: PlayerScrubController = new PlayerScrubController();
  @State systemVolumeLevel: number = 0;
  private systemVolume: SystemMediaVolume = new SystemMediaVolume();
  @State gestureAdjustKind: string = '';
  @State gestureAdjustPercent: number = -1;
  @State resumeTransitionActive: boolean = false;
  @State onlineTotal: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('videoFullscreenExitRequest') @Watch('onFullscreenExitRequested') fullscreenExitRequest: number = 0;
  @StorageProp('videoSeekRequestToken') @Watch('onExternalSeekRequested') seekRequestToken: number = 0;
  @StorageProp('videoPlaybackStopRequest') @Watch('onPlaybackStopRequested') stopRequest: number = 0;
  @StorageProp('playerDoubleTapEnabled') doubleTapEnabled: boolean = true;
  @StorageProp('playerPanEnabled') panEnabled: boolean = true;
  @StorageProp('playerHoldEnabled') holdEnabled: boolean = true;
  @StorageProp('backgroundPlaybackEnabled') backgroundPlaybackEnabled: boolean = false;
  @StorageProp('appInBackground') @Watch('onAppBackgroundChanged') appInBackground: boolean = false;
  @StorageLink('sponsorSkipEnabled') sponsorSkipEnabled: boolean = true;
  /** 播完自动连播下一集（UGC 合集）；关闭后播完停在剧终画面，由用户手动选择。 */
  @StorageLink('autoContinuePlay') autoContinuePlay: boolean = true;
  private videoReportDialog: CustomDialogController | null = null;
  private pictureInPicture: PlayerPictureInPicture = new PlayerPictureInPicture({
    isDestroyed: (): boolean => this.destroyed,
    isReady: (): boolean => this.playback.ready && this.playback.hasSurface,
    isInBackground: (): boolean => this.appInBackground,
    isPlaying: (): boolean => this.playing,
    getContext: (): common.UIAbilityContext => this.getUIContext().getHostContext() as common.UIAbilityContext,
    getComponentController: (): XComponentController => this.xcController,
    getVideoSize: (): PlayerVideoSize => ({ width: this.realVideoWidth, height: this.realVideoHeight }),
    closePanels: (): void => this.closeSettingPanels(),
    togglePlay: (): void => this.togglePlay(),
    onPlaybackPolicyChanged: (): void => this.onAppBackgroundChanged(),
    toast: (message: string): void => this.toast(message),
  });
  private exportMenuGeneration: number = 0;
  private mediaExport: PlayerMediaExportController = new PlayerMediaExportController({
    getContext: (): common.UIAbilityContext | undefined =>
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined,
    snapshot: (): PlayerMediaExportSnapshot => ({
      aid: this.aid, bvid: this.bvid, cid: this.cid, epId: this.epId,
      title: this.videoTitle, partTitle: this.videoPartTitle, cover: this.videoCover,
      duration: this.duration, playhead: this.playheadSec, quality: this.downloadQualityValue(),
      qualityOptions: this.downloadQualityOptions(),
      subtitle: this.subtitleIndex >= 0 && this.subtitleIndex < this.subtitles.length ?
        this.subtitles[this.subtitleIndex] : null,
    }),
    isDestroyed: (): boolean => this.destroyed,
    closePanels: (): void => this.closeSettingPanels(),
    toast: (message: string): void => this.toast(message),
    publishDownload: (state: PlayerDownloadUi): void => {
      this.downloadBusy = state.busy;
      this.downloadProgress = state.progress;
      if (state.quality > 0) this.downloadQuality = state.quality;
    },
  }, (seconds: number): Promise<image.PixelMap | null> => this.seekPreviewCtl.captureAt(seconds));
  private xcController: XComponentController = new XComponentController();
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private dmEngine: PlayerDanmakuEngine = new PlayerDanmakuEngine(this.ctx);
  private dmInteraction: PlayerDanmakuInteractionController = new PlayerDanmakuInteractionController(this.dmEngine);
  private dmClock: PlayerDanmakuClock = new PlayerDanmakuClock({
    isPlaying: (): boolean => this.playing,
    isDanmakuOn: (): boolean => this.danmakuOn && !this.appInBackground,
    getFrameRate: (): number => this.dmFrameRate,
    getEngine: (): PlayerDanmakuEngine => this.dmEngine,
    clearPinned: (): void => {
      this.dmPinnedVisible = false;
      this.dmPinnedText = '';
    },
  });
  private hideTimer: number = -1;
  /** 每 15 秒同步一次系统媒体进度。 */
  private lastSystemPlaybackBucket: number = -1;
  @State sponsorSegments: Array<SponsorBlockSegment> = [];
  @State sponsorCategories: Array<SponsorBlockCategory> = SponsorBlockStore.categories();
  @State sponsorNoticeVisible: boolean = false;
  @State sponsorNoticeTitle: string = '';
  @State sponsorNoticeDetail: string = '';
  @State sponsorNoticeColor: string = '#00D400';
  @State sponsorNoticeManual: boolean = false;
  @State sponsorNoticeCanUndo: boolean = false;
  @State sponsorNoticeCanVote: boolean = false;
  @State sponsorDraftStart: number = -1;
  @State sponsorDraftEnd: number = -1;
  @State sponsorDraftCategory: string = 'sponsor';
  @State sponsorDraftAction: string = 'skip';
  @State sponsorSubmitting: boolean = false;
  @State sponsorUserLoading: boolean = false;
  @State sponsorUserName: string = '';
  @State sponsorUserStats: string = '';
  @State sponsorWarningReason: string = '';
  @StorageProp('sponsorBlockSettingsRevision') @Watch('onSponsorSettingsChanged') sponsorSettingsRevision: number = 0;
  /** 空降运行时域（片段命中/跳段/静音/提示卡/投票）抽到 PlayerSponsorController。 */
  private sponsorCtl: PlayerSponsorController = new PlayerSponsorController({
    isDestroyed: (): boolean => this.destroyed,
    getSegments: (): Array<SponsorBlockSegment> => this.sponsorSegments,
    setSegments: (segments: Array<SponsorBlockSegment>): void => {
      this.sponsorSegments = segments;
    },
    getSponsorSkipEnabled: (): boolean => this.sponsorSkipEnabled,
    getPlayhead: (): number => this.playheadSec,
    applyNotice: (ui: SponsorNoticeUi | null): void => {
      if (ui === null) {
        this.sponsorNoticeVisible = false;
        this.sponsorNoticeManual = false;
        this.sponsorNoticeCanUndo = false;
        return;
      }
      this.sponsorNoticeTitle = ui.title;
      this.sponsorNoticeDetail = ui.detail;
      this.sponsorNoticeColor = ui.color;
      this.sponsorNoticeManual = ui.manual;
      this.sponsorNoticeCanUndo = ui.canUndo;
      this.sponsorNoticeCanVote = ui.canVote;
      this.sponsorNoticeVisible = true;
    },
    onFullLabel: (label: string, color: string): void => this.onSponsorFullLabel(label, color),
    seekTo: (seconds: number, precise: boolean): void => this.seekTo(seconds, precise),
    muteImmediately: (): void => this.playback.mute(),
    restoreUserVolume: (): void => this.playback.restoreVolume(),
    isFirstFrameMuteArmed: (): boolean => this.playback.isFrameMuted,
    toast: (message: string): void => this.toast(message),
    getBvid: (): string => this.bvid,
    getCid: (): number => this.cid,
  });
  private subtitleCtl: PlayerSubtitleController | null = null;
  private avSessionHelper: PlayerAvSessionHelper | null = null;
  private dmListSource: BasicDataSource<DanmakuItem> = new BasicDataSource<DanmakuItem>();
  private dmFilterRuleSource: BasicDataSource<DmFilterRule> = new BasicDataSource<DmFilterRule>();
  private runtimeQualityOptions: Array<VideoQualityOption> = [];
  private gestureCtl: PlayerGestureController | null = null;
  // UI 异步回调的生命周期；原生双轨生命周期由 PlayerPlaybackSession 管理。
  private destroyed: boolean = false;
  // 高精度播放头（秒）：弹幕引擎与恢复定位使用；@State curTime 只做秒级 UI 刷新。
  private playheadSec: number = 0;
  // seek 目标锁：seek 发起后到 seekDone 前，忽略 AVPlayer 上报的旧位置回写，
  // 避免进度条从目标值弹回（快速拖动/双击快进时最明显）。
  private seekLocked: boolean = false;
  // 拖动进度条期间滑块以拖动值为准，避免 timeUpdate 回写 curTime 把滑块拽回。
  @State sliderDragging: boolean = false;
  @State sliderDragValue: number = 0;
  @State seekPreviewFrame: image.PixelMap | null = null;
  private seekPreviewSeconds: number = -1;
  @State seekPreviewSprite: string = '';
  @State seekPreviewSpriteCell: number = -1;
  @State seekPreviewSpriteXLen: number = 10;
  @State seekPreviewSpriteYLen: number = 10;
  private seekPreviewCtl: PlayerSeekPreviewController = new PlayerSeekPreviewController();
  /** 慢 seek 时用预览帧/封面挡住 Surface，直到新位置开始推进。 */
  @State seekRecoveryCoverVisible: boolean = false;
  private fullscreenExitPending: boolean = false;
  private fullscreenExitAnimationStarted: boolean = false;
  private fullscreenExitCancel: (() => void) | null = null;
  private playbackSourceGeneration: number = 0;
  private playback: PlayerPlaybackSession = new PlayerPlaybackSession({
    policy: (): PlayerPlaybackPolicy => ({ background: this.appInBackground, allowBackground: this.backgroundPlaybackEnabled,
      pipKeepsAlive: this.pictureInPicture.keepsPlaybackAlive(), pipVisible: this.pictureInPicture.isVisibleOrStarting(),
      muted: this.sponsorCtl.isMuted() }),
    state: (state: PlayerPlaybackState): void => {
      this.playing = state.playing;
      this.prepared = state.prepared;
      this.firstFrameShown = state.firstFrameShown;
      this.errorText = state.errorText;
      this.playheadSec = state.position;
      if (state.seekLocked || Math.floor(this.curTime) !== Math.floor(state.position)) this.curTime = state.position;
      this.duration = state.duration;
      this.buffering = state.buffering;
      this.seekLocked = state.seekLocked;
      this.seekRecoveryCoverVisible = state.seekRecoveryCoverVisible;
      this.qualityLoading = state.qualityLoading;
      this.activeQuality = state.activeQuality;
      this.runtimeQualityOptions = state.qualities;
      this.previewPlayback = state.preview;
      this.playbackRate = state.playbackRate;
      this.holdSpeedActive = state.holdSpeedActive;
    },
    event: (event: PlayerPlaybackEvent): void => this.onPlaybackEvent(event),
    progress: (seconds: number, background: boolean): boolean => this.onPlaybackProgress(seconds, background),
  });

  private playbackSource(): PlayerPlaybackSource {
    const source: PlayerPlaybackSource = new PlayerPlaybackSource();
    source.aid = this.aid; source.bvid = this.bvid; source.cid = this.cid; source.epId = this.epId;
    source.version = this.sourceVersion;
    source.urls = this.videoUrls.length > 0 ? this.videoUrls : (this.videoUrl.length > 0 ? [this.videoUrl] : []);
    source.audioUrls = this.audioUrls;
    source.qualities = this.qualityOptions;
    source.quality = this.currentQuality;
    source.initialSeek = this.initialSeekSeconds;
    source.preview = this.previewPlayback;
    return source;
  }

  private onPlaybackEvent(event: PlayerPlaybackEvent): void {
    switch (event.kind) {
      case 'clock.start': this.dmClock.start(); break;
      case 'clock.pause': this.dmClock.pause(); break;
      case 'clock.stop': this.dmClock.stop(false); break;
      case 'rate': this.dmEngine.setPlaybackRate(event.value); break;
      case 'started':
        this.resumeTransitionActive = false;
        this.applyPgcSkipIntroOnce();
        this.onPlayingChange(true);
        this.scheduleControlsHide();
        this.ensureAVSession();
        this.updateAVSessionPlaybackState();
        Immersive.setKeepScreenOn(true);
        break;
      case 'playing':
        this.onPlayingChange(true);
        this.scheduleControlsHide();
        this.updateAVSessionPlaybackState();
        break;
      case 'paused':
        this.resumeTransitionActive = false;
        this.showControls = true;
        if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
        this.hideTimer = -1;
        this.onPlayingChange(false);
        this.updateAVSessionPlaybackState();
        Immersive.setKeepScreenOn(false);
        break;
      case 'firstFrame': this.onFirstFrameShown(); this.scheduleDeferredLoads(); break;
      case 'ended':
        if (this.playMode === 2 && event.value === 0) this.endReplay();
        else { this.clearSeekPreviewInteraction(); this.endScreenOpen = true; this.onEnded(); }
        break;
      case 'seek':
        this.resetDanmakuAt(event.value);
        this.onProgress(event.value);
        this.updateSubtitle(event.value);
        this.updateAVSessionPlaybackState();
        break;
      case 'seek.dispatch':
        if (this.seekPreviewSeconds < 0 || Math.abs(this.seekPreviewSeconds * 1000 - event.value) > 1500) this.seekPreviewFrame = null;
        break;
      case 'seek.finished': this.seekTargetCtl.show(-1); break;
      case 'foregroundSeek': this.onProgress(event.value); this.updateAVSessionPlaybackState(); break;
      case 'backgroundAudio': Immersive.setKeepScreenOn(false); this.updateAVSessionPlaybackState(); break;
      case 'resume': this.resumeTransitionActive = this.compactMode && !this.fullscreen; this.onResumeRequest(); break;
      case 'closePanels': this.closeSettingPanels(); break;
      case 'duration': this.updateAVSessionMetadata(); break;
      case 'size':
        this.realVideoWidth = event.value;
        this.realVideoHeight = event.second;
        this.pictureInPicture.sync();
        this.onVideoSizeChange(event.value, event.second);
        break;
      case 'source': this.onPlayingChange(false); break;
      case 'fatal': this.release(); break;
    }
  }

  private onPlaybackProgress(seconds: number, background: boolean): boolean {
    this.playheadSec = seconds;
    if (!background) {
      if (this.dmEngine.lastPlayerTime > 0 &&
        (seconds < this.dmEngine.lastPlayerTime - 0.5 || seconds > this.dmEngine.lastPlayerTime + 2.5)) this.resetDanmakuAt(seconds);
      this.dmEngine.lastPlayerTime = seconds;
    }
    const bucket: number = Math.floor(seconds / 15);
    if (bucket !== this.lastSystemPlaybackBucket && seconds > 0.05) {
      this.lastSystemPlaybackBucket = bucket;
      this.updateAVSessionPlaybackState();
      if (!background) this.reportContinueWatching(seconds);
    }
    if (this.timerFireAt > 0 && Date.now() >= this.timerFireAt) {
      this.timerFireAt = 0;
      this.timerMinutes = 0;
      this.pauseForTimer();
    }
    this.onProgress(seconds);
    if (!background) {
      this.updateSubtitle(seconds);
      this.spawnDanmaku(seconds);
      this.auxiliary.prefetch(seconds);
    }
    return this.sponsorCtl.maybeSkipSponsor(seconds);
  }

  private auxiliary: PlayerAuxiliaryController = new PlayerAuxiliaryController({
    isDestroyed: (): boolean => this.destroyed,
    duration: (): number => this.videoDuration > 0 ? this.videoDuration : this.duration,
    danmaku: (items: Array<DanmakuItem>, replace: boolean): void => {
      this.dmEngine.lastPlayerTime = this.playheadSec;
      if (replace) this.dmEngine.setList(items);
      else this.dmEngine.appendSorted(items);
    },
    heatPoints: (items: Array<HotPoint>): void => { this.hotPoints = items; },
    chapters: (items: Array<VideoChapter>): void => { this.chapters = items; },
    online: (value: string): void => { this.onlineTotal = value; this.onOnlineCount(value); },
  });
  private deferredLoadsDone: boolean = false;
  private deferredLoadTimer: number = -1;

  aboutToAppear(): void {
    PersistentStorage.persistProp<number>('subtitleScale', 1.0);
    PersistentStorage.persistProp<number>('pgcSkipIntroSeconds', 0);
    const persistedScale: number = AppStorage.get<number>('subtitleScale') ?? 1.0;
    if (persistedScale > 0) this.subtitleScale = persistedScale;
    // 被其他 NavDestination 覆盖时 aboutToDisappear 已置位；返回同一实例时恢复。
    this.destroyed = false;
    try { this.systemVolumeLevel = this.systemVolume.level(); } catch (e) {}
    this.systemVolume.start((percent: number) => {
      if (this.destroyed) return;
      try { this.systemVolumeLevel = this.systemVolume.level(); } catch (e) {}
      if (!this.destroyed && this.gestureAdjustKind === '音量') this.gestureAdjustPercent = percent;
    });
    this.fullscreen = false;
    this.fullscreenPortrait = false;
    this.fullscreenExitPending = false;
    this.fullscreenExitAnimationStarted = false;
    this.dmEngine.fullscreen = false;
    Immersive.setFullscreen(false);
    this.sponsorCategories = SponsorBlockStore.categories();
    this.mediaExport.syncDownload();
    this.restoreDanmakuSettings();
    this.onDanmakuEngineReady(this.dmEngine);
    this.showControls = false;
    this.endScreenOpen = false;
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    AppStorage.setOrCreate<number>('videoFullscreenExitRequest', 0);
    if (this.gestureCtl === null) {
      this.gestureCtl = new PlayerGestureController(
        (value: number): void => {
          this.gestureScrubValue = value;
          this.scrubCtl.show(value);
          this.seekTargetCtl.show(value);
          if (value >= 0) this.requestSeekPreview(value);
        },
        (value: number): void => {
          if (this.gestureScrubValue >= 0 && value === -1) {
            const preview: number = this.gestureScrubValue;
            Haptic.seek();
            // 横滑快进/后退按预览值精确落点，不能退回约 5 秒一档的关键帧。
            this.seekTo(preview);
            this.gestureScrubValue = -1;
            this.scrubCtl.show(-1);
            this.closeSeekPreview();
          }
        },
        (kind: string, percent: number): void => {
          this.gestureAdjustKind = kind === 'brightness' ? '亮度' : (kind === 'volume' ? '音量' : '');
          this.gestureAdjustPercent = kind === 'volume' ? this.systemVolume.percent() : percent;
        },
        (value: number): void => {},
        (value: number): void => {
          this.applyGestureVolume(value);
        },
        (value: number): void => {
          // 预览值即最终值：记录后新视频（窗口重置为跟随系统）的亮度手势从该值起跳，而不是默认 50%。
          AppTheme.saveLastBrightness(value);
        },
        (value: number): void => {
          Immersive.setWindowBrightness(value);
        },
      );
    }
    this.playback.activate(this.playbackSource());
    this.danmakuOn = this.externalDanmakuOn;
    this.dmEngine.enabled = this.danmakuOn;
    Immersive.setKeepScreenOn(false);
    this.ensureAVSession();
    this.loadDanmaku();
    // 增强请求（空降/章节/拖动预览/在看人数）延到首帧后，别和首帧抢带宽；
    // 重新出现时按旧行为重取一次，避免使用上一次会话的陈旧数据。
    this.deferredLoadsDone = false;
    this.armDeferredLoads();
    this.loadGestureLevels();
  }

  onQualityOptionsChanged(): void {
    this.playback.updateQualities(this.qualityOptions);
  }

  onSponsorSettingsChanged(): void {
    this.sponsorCategories = SponsorBlockStore.categories();
    this.sponsorCtl.refreshFullLabel();
  }

  private ensureAVSession(): void {
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) return;
    if (this.avSessionHelper === null) {
      this.avSessionHelper = new PlayerAvSessionHelper(context);
    }
    this.avSessionHelper.ensure(
      (): void => {
        if (this.playing === false) this.togglePlay();
      },
      (): void => {
        if (this.playing) this.togglePlay();
      },
      (timeMs: number): void => {
        this.seekTo(timeMs / 1000, true);
      },
      this.avSessionMetadata(),
      this.avSessionPlaybackState(),
    ).catch(() => {
    });
  }

  private avSessionMetadata(): avSession.AVMetadata {
    return {
      assetId: this.bvid.length > 0 ? this.bvid : String(this.aid),
      title: this.videoTitle,
      artist: this.ownerName,
      mediaImage: this.videoCover.length > 0 ? this.videoCover : this.ownerFace,
      duration: this.duration > 0 ? Math.floor(this.duration * 1000) : undefined,
    };
  }

  private avSessionPlaybackState(): avSession.AVPlaybackState {
    return {
      state: this.playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
        avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: this.playbackRate,
      position: {
        elapsedTime: Math.floor(this.curTime * 1000),
        updateTime: Date.now(),
      },
    };
  }

  private updateAVSessionMetadata(): void {
    const helper: PlayerAvSessionHelper | null = this.avSessionHelper;
    if (helper === null) return;
    helper.setMetadata(this.avSessionMetadata());
  }

  private updateAVSessionPlaybackState(): void {
    this.pictureInPicture.sync();
    const helper: PlayerAvSessionHelper | null = this.avSessionHelper;
    if (helper === null) return;
    helper.setPlaybackState(this.avSessionPlaybackState());
  }

  private deactivateAVSession(): void {
    const helper: PlayerAvSessionHelper | null = this.avSessionHelper;
    if (helper !== null) {
      helper.release();
      this.avSessionHelper = null;
    }
  }

  private reportCurrentVideo(): void {
    if (!UserStore.isLogin) { this.toast('请先登录后再举报'); return; }
    if (this.aid <= 0) { this.toast('当前视频不支持举报'); return; }
    this.closeSettingPanels();
    this.videoReportDialog?.close();
    this.videoReportDialog = new CustomDialogController({
      builder: VideoReportDialog({ aid: this.aid, title: this.videoTitle }),
      autoCancel: false,
      customStyle: true,
    });
    this.videoReportDialog.open();
  }

  onAppBackgroundChanged(): void {
    if (this.destroyed) return;
    if (!this.appInBackground && this.pictureInPicture.keepsPlaybackAlive()) this.pictureInPicture.release();
    this.playback.onBackgroundChanged();
    if (!this.appInBackground) this.restoreForegroundDanmaku();
  }

  private restoreForegroundDanmaku(): void {
    // 后台期间 DisplaySync 可能被系统挂起，但 running 仍为 true。
    // 重新绑定前台帧回调，并从当前进度开始，避免旧弹幕停在画布上或集中补发。
    this.dmClock.release();
    this.resetDanmakuAt(this.playheadSec);
    if (this.playing && !this.seekLocked) this.spawnDanmaku(this.playheadSec);
  }

  private setBackgroundPlayback(next: boolean): void {
    AppStorage.setOrCreate<boolean>('backgroundPlaybackEnabled', next);
    AppTheme.persistBackgroundPlayback(next);
  }

  onSubtitlesChanged(): void {
    if (this.subtitleCtl === null) {
      this.subtitleCtl = new PlayerSubtitleController(() => this.syncSubtitleState());
    }
    this.subtitleCtl.setTracks(this.subtitles, this.playheadSec);
  }

  private subtitleLabel(): string {
    if (this.subtitleCtl === null) return '关闭';
    return this.subtitleCtl.label();
  }

  private updateSubtitle(timeSec: number): void {
    this.subtitleCtl?.update(timeSec);
  }

  private changeSubtitle(index: number): void {
    const ctl: PlayerSubtitleController | null = this.subtitleCtl;
    if (ctl === null) return;
    ctl.changeSubtitle(index);
    this.closeSettingPanels();
  }

  /** ⋮ 弹层 CC 字幕纯开关：开 = 选当前/第一条可用轨道，关 = -1。不关弹层面板。 */
  private toggleSubtitle(next: boolean): void {
    const ctl: PlayerSubtitleController | null = this.subtitleCtl;
    if (ctl === null) return;
    if (this.subtitles.length === 0) {
      this.toast('当前视频无 CC 字幕');
      return;
    }
    const index: number = next ? (this.subtitleIndex >= 0 ? this.subtitleIndex : 0) : -1;
    ctl.changeSubtitle(index);
  }

  private onSubtitleScaleChanged(): void {
    // @StorageProp 自动更新渲染；持久化由 PersistentStorage 完成。
  }

  private syncSubtitleState(): void {
    const ctl: PlayerSubtitleController | null = this.subtitleCtl;
    if (ctl === null) return;
    this.subtitleOn = ctl.enabled;
    this.subtitleIndex = ctl.index;
    this.subtitleText = ctl.text;
    this.subtitleLoading = ctl.loading;
  }


  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 播放器销毁或窗口异常时忽略提示，避免二次崩溃。
    }
  }

  /** 弹幕举报：长按列表弹出原因选择。 */
  private promptReportDanmaku(item: DanmakuItem): void {
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再举报弹幕');
      return;
    }
    if (item.idStr.length === 0) {
      this.toast('该弹幕来自兼容协议，暂不支持举报');
      return;
    }
    const reasons: Array<string> = ['违法违规', '色情内容', '低俗内容', '人身攻击', '垃圾广告', '引战引流量', '其他'];
    // showDialog 的按钮不支持 action 回调：本地 interface 承载文案与颜色，结果经 then 的 index 回读。
    const buttons: Array<ReportButtonItem> = [];
    for (let i: number = 0; i < reasons.length; i++) {
      buttons.push({ text: reasons[i], color: this.isDark ? '#CCFFFFFF' : '#18191C' });
    }
    buttons.push({ text: '取消', color: '#9499A0' });
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '举报弹幕',
        message: '「' + item.text.substring(0, Math.min(24, item.text.length)) + (item.text.length > 24 ? '…' : '') + '」',
        buttons: buttons,
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        // 0..6 对应原因；最后一个按钮为「取消」
        if (pick < 0 || pick >= reasons.length) {
          return;
        }
        const reasonValues: Array<number> = [1, 2, 3, 5, 6, 7, 10];
        BiliApi.reportDanmaku(this.cid, item.idStr, reasonValues[pick])
          .then((r: ActionResult) => {
            this.toast(r.ok ? '已提交举报，感谢反馈' : r.message);
          })
          .catch(() => {
            this.toast('举报失败，请稍后重试');
          });
      });
    } catch (e) {
      // 播放器销毁或窗口异常时忽略。
    }
  }

  private rebuildDmListSource(): void {
    // 面板只展示已加载弹幕的前 300 条，避免一次重排上万行。
    this.dmListSource.reset(this.dmEngine.list.slice(0, 300));
    this.dmListCount = this.dmListSource.totalCount();
  }

  /** 弹幕列表：切到「更多功能」Sheet 内嵌子页，不再从播放器上弹层。 */
  private openDanmakuList(): void {
    this.rebuildDmListSource();
    this.openSheetPage('danmakuList');
  }

  private async loadDmFilterRules(): Promise<void> {
    if (this.dmFilterLoading) return;
    this.dmFilterLoading = true;
    try {
      const rules: Array<DmFilterRule> = await BiliApi.getDanmakuFilter();
      this.dmFilterRuleSource.reset(rules);
      this.dmFilterRulesCount = this.dmFilterRuleSource.totalCount();
    } catch (e) {
      this.dmFilterRuleSource.reset([]);
      this.dmFilterRulesCount = 0;
    } finally {
      this.dmFilterLoading = false;
    }
  }

  /** 屏蔽管理：切到「更多功能」Sheet 内嵌子页，不再从播放器上弹层。 */
  private openDanmakuFilter(): void {
    this.dmFilterDraft = '';
    this.dmFilterType = 0;
    this.openSheetPage('dmFilter');
    this.loadDmFilterRules().catch(() => {
    });
  }

  private dmFilterTypeLabel(type: number): string {
    if (type === 0) return '关键词';
    if (type === 1) return '正则';
    return '用户';
  }

  private async submitDmFilterRule(): Promise<void> {
    if (this.dmFilterDraft.trim().length === 0) {
      this.toast('请输入屏蔽内容');
      return;
    }
    const result: ActionResult = await BiliApi.addDanmakuFilter(this.dmFilterType, this.dmFilterDraft);
    if (result.ok) {
      this.toast('已添加');
      this.dmFilterDraft = '';
      this.loadDmFilterRules().catch(() => {
      });
    } else {
      this.toast(result.message);
    }
  }

  private async deleteDmFilterRule(id: number): Promise<void> {
    const result: ActionResult = await BiliApi.delDanmakuFilter([id]);
    if (result.ok) {
      this.toast('已删除');
      this.loadDmFilterRules().catch(() => {
      });
    } else {
      this.toast(result.message);
    }
  }

  async onSourceVersionChanged(): Promise<void> {
    if (this.destroyed) return;
    const generation: number = ++this.playbackSourceGeneration;
    ++this.exportMenuGeneration;
    this.mediaExport.invalidate();
    this.auxiliary.invalidate();
    this.auxiliary.bind({ aid: this.aid, bvid: this.bvid, cid: this.cid });
    this.pgcSkipTried = false;
    this.hotPoints = [];
    this.onlineTotal = '';
    this.lastSystemPlaybackBucket = -1;
    this.onOnlineCount('');
    this.mediaExport.syncDownload();
    this.releaseSeekPreview();
    this.subtitleText = '';
    this.subtitleCtl?.reset();
    this.sponsorCtl.invalidateForSourceChange();
    this.chapters = [];
    this.dmClock.stop(true);
    this.dmEngine.list = [];
    this.dmEngine.cursor = 0;
    this.seekTargetCtl.show(-1);
    this.endScreenOpen = false;
    await this.playback.replaceSource(this.playbackSource());
    if (this.destroyed || generation !== this.playbackSourceGeneration) return;
    this.loadDanmaku();
    this.deferredLoadsDone = false;
    this.armDeferredLoads();
  }

  onExternalDanmakuChanged(): void {
    this.setDanmakuEnabled(this.externalDanmakuOn, false);
  }

  onLocalDanmakuRequested(): void {
    const text: string = this.localDanmakuText.trim();
    if (text.length === 0) return;
    const item: DanmakuItem = new DanmakuItem(this.playheadSec, 1, 0xFFFFFF, text);
    this.dmEngine.insertLocal(item);
    this.spawnDanmaku(this.playheadSec);
  }

  onCompactModeChanged(): void {
    if (!this.compactMode || this.fullscreen) return;
    // 收起播放器时底部抽屉没有足够空间，避免其越出视频框。
    this.closeSettingPanels();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.videoReportDialog?.close();
    this.videoReportDialog = null;
    this.cancelDeferredLoadTimer();
    this.systemVolume.stop();
    ++this.playbackSourceGeneration;
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    this.endHoldSpeed();
    this.sponsorCtl.clearNoticeTimer();
    this.playback.deactivate();
    this.release();
    Immersive.restoreWindowBrightness();
    // 销毁阶段写 @State 无效且高风险，只做资源清理；父组件通知保留但隔离异常。
    try {
      this.onPlayingChange(false);
    } catch (e) {
      // 父组件可能已先行销毁。
    }
    Immersive.setFullscreen(false);
  }

  onFullscreenExitRequested(): void {
    if (this.fullscreen) {
      this.exitFullscreen();
    }
  }

  onExternalSeekRequested(): void {
    const seconds: number = AppStorage.get<number>('videoSeekRequestSeconds') ?? -1;
    if (seconds >= 0) this.seekTo(seconds, true);
  }

  onPlaybackStopRequested(): void { this.playback.stopForNavigation(); }

  private changeSponsorMode(category: string, mode: number): void {
    SponsorBlockStore.setMode(category, mode);
    this.sponsorCategories = SponsorBlockStore.categories();
    this.sponsorCtl.refreshFullLabel();
  }

  private markSponsorStart(): void {
    this.sponsorDraftStart = Math.max(0, this.playheadSec);
    if (this.sponsorDraftAction === 'poi') this.sponsorDraftEnd = this.sponsorDraftStart;
  }

  private markSponsorEnd(): void {
    this.sponsorDraftEnd = Math.max(0, this.playheadSec);
    if (this.sponsorDraftStart < 0) this.sponsorDraftStart = 0;
  }

  private changeSponsorDraftCategory(category: string): void {
    this.sponsorDraftCategory = category;
    const actions: Array<string> = sponsorBlockSupportedActions(category);
    if (actions.indexOf(this.sponsorDraftAction) < 0) this.sponsorDraftAction = actions[0];
    if (this.sponsorDraftAction === 'poi') this.sponsorDraftEnd = this.sponsorDraftStart;
    if (this.sponsorDraftAction === 'full') {
      this.sponsorDraftStart = 0;
      this.sponsorDraftEnd = 0;
    }
  }

  private changeSponsorDraftAction(action: string): void {
    this.sponsorDraftAction = action;
    if (action === 'poi') this.sponsorDraftEnd = this.sponsorDraftStart;
    if (action === 'full') {
      this.sponsorDraftStart = 0;
      this.sponsorDraftEnd = 0;
    }
  }

  private clearSponsorDraft(): void {
    this.sponsorDraftStart = -1;
    this.sponsorDraftEnd = -1;
    this.sponsorDraftCategory = 'sponsor';
    this.sponsorDraftAction = 'skip';
  }

  private previewSponsorDraft(): void {
    if (this.sponsorDraftStart < 0) return;
    this.seekTo(this.sponsorDraftStart, true);
    this.closeSettingPanels();
  }

  private seekSponsorSegment(segment: SponsorBlockSegment): void {
    this.sponsorCtl.markHandled(segment);
    this.seekTo(segment.start, true);
    this.closeSettingPanels();
  }

  private async submitSponsorDraft(): Promise<void> {
    if (this.sponsorSubmitting) return;
    const actions: Array<string> = sponsorBlockSupportedActions(this.sponsorDraftCategory);
    if (actions.indexOf(this.sponsorDraftAction) < 0) {
      this.toast('该分类不支持所选动作');
      return;
    }
    let start: number = this.sponsorDraftStart;
    let end: number = this.sponsorDraftEnd;
    if (this.sponsorDraftAction === 'full') {
      start = 0;
      end = 0;
    } else if (this.sponsorDraftAction === 'poi') {
      end = start;
    } else if (start < 0 || end <= start) {
      this.toast('结束时间必须晚于开始时间');
      return;
    }
    if (start < 0 || (this.duration > 0 && (start > this.duration || end > this.duration + 0.5))) {
      this.toast('片段时间超出视频范围');
      return;
    }
    const segment: SponsorBlockSegment = new SponsorBlockSegment();
    segment.start = start;
    segment.end = end;
    segment.cid = String(this.cid);
    segment.category = this.sponsorDraftCategory;
    segment.actionType = this.sponsorDraftAction;
    segment.videoDuration = this.duration;
    this.sponsorSubmitting = true;
    try {
      const result: SponsorBlockResult = await SponsorBlockApi.submit(this.bvid, this.cid, this.duration, [segment]);
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      if (result.uuids.length > 0) segment.uuid = result.uuids[0];
      this.sponsorSegments = this.sponsorSegments.concat([segment]);
      this.sponsorSegments.sort((a: SponsorBlockSegment, b: SponsorBlockSegment) => a.start - b.start);
      this.sponsorCtl.refreshFullLabel();
      this.clearSponsorDraft();
      this.toast(result.message);
      this.loadSponsorUserInfo(true).catch(() => {});
    } catch (e) {
      this.toast('提交失败，请稍后重试');
    } finally {
      this.sponsorSubmitting = false;
    }
  }

  private async loadSponsorUserInfo(ignoreCache: boolean = false): Promise<void> {
    if (this.sponsorUserLoading) return;
    this.sponsorUserLoading = true;
    try {
      const info: SponsorBlockUserInfo | null = await SponsorBlockApi.getUserInfo(ignoreCache);
      if (this.destroyed || info === null) return;
      this.sponsorUserName = info.userName;
      this.sponsorUserStats = String(info.segmentCount) + ' 个投稿 · ' + String(info.viewCount) +
        ' 次帮助 · 节省 ' + info.minutesSaved.toFixed(1) + ' 分钟' + (info.vip ? ' · VIP' : '');
      this.sponsorWarningReason = info.warnings > 0 ? info.warningReason : '';
    } finally {
      this.sponsorUserLoading = false;
    }
  }

  private async saveSponsorUsername(): Promise<void> {
    const name: string = this.sponsorUserName.trim();
    if (name.length > 64) {
      this.toast('昵称不能超过 64 个字符');
      return;
    }
    const result: SponsorBlockResult = await SponsorBlockApi.setUsername(name);
    this.toast(result.message);
    if (result.ok) this.loadSponsorUserInfo(true).catch(() => {});
  }

  private async acknowledgeSponsorWarning(): Promise<void> {
    const result: SponsorBlockResult = await SponsorBlockApi.acknowledgeWarning();
    this.toast(result.message);
    if (result.ok) this.sponsorWarningReason = '';
  }

  private setSponsorEnabled(next: boolean): void {
    this.sponsorSkipEnabled = next;
    AppTheme.persistSponsorSkip(next);
    if (!next) {
      this.sponsorCtl.deactivate();
    }
    this.toast(next ? '空降助手已开启' : '空降助手已关闭');
  }

  private visibleSponsorSegments(): Array<SponsorBlockSegment> {
    const result: Array<SponsorBlockSegment> = [];
    for (let i: number = 0; i < this.sponsorSegments.length; i++) {
      if (SponsorBlockStore.modeFor(this.sponsorSegments[i].category) !== SponsorBlockMode.DISABLED) {
        result.push(this.sponsorSegments[i]);
      }
    }
    return result;
  }

  /** 服务卡片「继续观看」数据上报（内部 15 秒节流；失败静默）。 */
  private reportContinueWatching(positionSec: number): void {
    if (this.videoTitle.length === 0) return;
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) return;
    ContinueWatchingStore.report(context, this.bvid, this.aid, this.videoTitle, this.videoCover,
      positionSec, this.duration, this.cid, this.epId).catch(() => {
    });
  }

  /**
   * 番剧跳过片头：仅 PGC（epId>0）生效；每次起播尝试一次，且仅在自然接近片头位置时跳。
   * 用户手动拖动/续播到中段时不会回跳。
   */
  private applyPgcSkipIntroOnce(): void {
    if (this.epId <= 0 || this.pgcSkipTried) return;
    this.pgcSkipTried = true;
    const seconds: number = AppStorage.get<number>('pgcSkipIntroSeconds') ?? 0;
    if (seconds <= 0) return;
    if (this.playheadSec > 30 || this.playheadSec >= seconds) return;
    this.seekTo(seconds, true);
    this.toast('已跳过片头');
  }

  async loadDanmaku(): Promise<void> {
    this.auxiliary.bind({ aid: this.aid, bvid: this.bvid, cid: this.cid });
    await this.auxiliary.loadDanmaku();
  }

  // XComponent 的 Surface 标识是 UI 唯一传给播放会话的原生句柄。
  onSurfaceReady(): void { this.playback.setSurface(this.xcController.getXComponentSurfaceId()); }

  /** 排定增强请求：首帧事件或 DEFERRED_LOAD_DELAY_MS 兜底，谁先到谁触发。 */
  private armDeferredLoads(): void {
    if (this.deferredLoadsDone || this.deferredLoadTimer >= 0) return;
    this.deferredLoadTimer = setTimeout(() => {
      this.deferredLoadTimer = -1;
      if (this.destroyed) return;
      this.scheduleDeferredLoads();
    }, DEFERRED_LOAD_DELAY_MS);
  }

  private cancelDeferredLoadTimer(): void {
    if (this.deferredLoadTimer >= 0) {
      clearTimeout(this.deferredLoadTimer);
      this.deferredLoadTimer = -1;
    }
  }

  /** 一次发出全部增强请求；重复调用无副作用。 */
  private scheduleDeferredLoads(): void {
    if (this.deferredLoadsDone || this.destroyed) return;
    this.deferredLoadsDone = true;
    this.cancelDeferredLoadTimer();
    this.sponsorCtl.loadSponsorSegments();
    this.auxiliary.loadChapters();
    this.auxiliary.loadHeatPoints();
    this.seekPreviewCtl.preload(this.aid, this.bvid, this.cid);
    this.auxiliary.loadOnline();
  }

  async changeQuality(qn: number): Promise<void> { await this.playback.changeQuality(qn); }

  setPlaybackSpeed(rate: number): void {
    this.closeSettingPanels();
    this.playback.setSpeed(rate);
  }

  private beginHoldSpeed(): void {
    if (this.holdEnabled === false) return;
    this.dmInteraction.cancelPending();
    if (!this.playing || !this.prepared || this.holdSpeedActive) return;
    Haptic.seek();
    this.playback.beginHold();
  }

  private endHoldSpeed(): void {
    // 长按快进松手还原正常倍速：落定震动（与按下的轻震呼应）；页面销毁等被动路径同样安全。
    if (this.holdSpeedActive) Haptic.release();
    this.playback.endHold();
  }

  private loadGestureLevels(): void {
    this.gestureCtl?.loadInitials();
  }

  private applyGestureVolume(value: number): void {
    try {
      this.systemVolumeLevel = this.systemVolume.levelForPercent(value);
    } catch (e) {}
  }

  private beginPlayerPan(event: GestureEvent): void {
    if (this.panEnabled === false) return;
    if (this.endScreenOpen) return;
    // 滑动手势判定后不再视为点弹幕。
    this.dmInteraction.cancelPending();
    const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : this.dmEngine.width / 2;
    const volume: number = this.systemVolume.percent();
    if (this.gestureCtl !== null && volume >= 0) this.gestureCtl.gestureVolume = volume;
    this.gestureCtl?.beginPan(x, this.dmEngine.width, this.playheadSec, this.duration);
  }

  private updatePlayerPan(event: GestureEvent): void {
    if (this.panEnabled === false) return;
    this.gestureCtl?.updatePan(event.offsetX, event.offsetY, this.dmEngine.width, this.duration);
    if (this.gestureCtl?.panMode === 'seek') {
      this.showControls = true;
      if (this.hideTimer >= 0) {
        clearTimeout(this.hideTimer);
        this.hideTimer = -1;
      }
    }
  }

  private endPlayerPan(): void {
    const ctl: PlayerGestureController | null = this.gestureCtl;
    if (ctl === null) return;
    // PlayerGestureController.endPan 会通过 onSeek 唯一提交本次目标；这里不再重复 seek。
    ctl.endPan();
    this.closeSeekPreview();
    this.gestureAdjustKind = '';
    this.gestureAdjustPercent = -1;
    if (this.playing) this.scheduleControlsHide();
  }

  private progressDisplayTime(): number {
    if (this.sliderDragging) return this.sliderDragValue;
    return this.duration > 0 ? this.curTime : 0;
  }

  private passiveProgressWidth(): string {
    if (this.duration <= 0) return '0%';
    const percent: number = Math.max(0, Math.min(100, this.curTime * 100 / this.duration));
    return percent.toFixed(2) + '%';
  }

  /** 连续拖动只解码最新位置，避免网络取帧任务排队拖慢播放器。 */
  private requestSeekPreview(seconds: number): void {
    if (seconds < 0 || this.destroyed) return;
    this.seekPreviewSeconds = seconds;
    this.seekPreviewCtl.request(seconds, this.aid, this.bvid, this.cid, this.playback.sourceUrl,
      PlayerPlaybackConfig.playbackHeaders(),
      (url: string, cell: number, xLen: number, yLen: number): void => {
        this.seekPreviewSprite = url;
        this.seekPreviewSpriteCell = cell;
        this.seekPreviewSpriteXLen = xLen;
        this.seekPreviewSpriteYLen = yLen;
      },
      (frame: image.PixelMap | null): void => {
        this.seekPreviewFrame = frame;
      });
  }

  private closeSeekPreview(): void {
    this.seekPreviewCtl.close();
  }

  private finishProgressPreviewInteraction(): void {
    this.sliderDragging = false;
    this.closeSeekPreview();
  }

  private clearSeekPreviewInteraction(): void {
    this.sliderDragging = false;
    this.gestureScrubValue = -1;
    this.scrubCtl.show(-1);
    this.seekTargetCtl.show(-1);
    this.closeSeekPreview();
  }

  private releaseSeekPreview(): void {
    this.sliderDragging = false;
    this.gestureScrubValue = -1;
    this.scrubCtl.show(-1);
    this.seekTargetCtl.show(-1);
    this.seekPreviewSeconds = -1;
    this.seekPreviewCtl.release();
  }


  private handleDoubleTap(): void {
    if (this.doubleTapEnabled === false) return;
    this.dmInteraction.cancelPending();
    if (!this.prepared || this.endScreenOpen) return;
    // 双击只切换播放/暂停，不再在屏幕中央弹图标；播放键状态由左下角按钮直接反映。
    this.togglePlay();
  }

  @Builder
  PlayerGestureArea() {
    PlayerGestureSurface({
      onSingleTap: (event: GestureEvent) => this.handleCanvasTap(event),
      onDoubleTap: () => this.handleDoubleTap(),
      onPanStart: (event: GestureEvent) => this.beginPlayerPan(event),
      onPanUpdate: (event: GestureEvent) => this.updatePlayerPan(event),
      onPanEnd: () => this.endPlayerPan(),
      onLongPressStart: () => this.beginHoldSpeed(),
      onLongPressEnd: () => this.endHoldSpeed(),
      onTouchDown: (x: number, y: number) => {
        this.dmInteraction.rememberTouch(x, y, this.dmPinnedVisible);
      },
    })
  }

  qualityLabel(): string {
    for (let i: number = 0; i < this.runtimeQualityOptions.length; i++) {
      if (this.runtimeQualityOptions[i].qn === this.activeQuality) return this.runtimeQualityOptions[i].label;
    }
    return this.activeQuality > 0 ? String(this.activeQuality) : '清晰度';
  }

  togglePlay(): void { this.playback.toggle(); }

  /** UI 的结束画面与空降状态由页面重置，双轨重播走同一 seek 状态机。 */
  endReplay(): void {
    this.clearSeekPreviewInteraction();
    this.endScreenOpen = false;
    if (!this.prepared) return;
    this.sponsorCtl.resetForReplay();
    this.playback.replay();
    this.showControls = false;
  }

  /** 结束画面关闭：回到剧终画面（保留控制层）。 */
  closeEndScreen(): void {
    this.endScreenOpen = false;
    this.showControls = true;
  }

  seekTo(positionSec: number, precise: boolean = true): void { this.playback.seekTo(positionSec, precise); }

  toggleFullscreen(): void {
    if (this.fullscreen) {
      this.exitFullscreen();
    } else {
      this.fullscreen = true;
      this.dmEngine.fullscreen = true;
      this.restartDmLoopForViewport();
      AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', true);
      // 先让详情页播放器占满窗口，再旋转；整个过程中不会重新创建 AVPlayer。
      this.onFullscreenChange(true);
      // 竖屏视频全屏保持竖屏：转横屏只会让画面瘦成中间一条，体验更差。
      this.fullscreenPortrait = this.realVideoHeight > this.realVideoWidth && this.realVideoWidth > 0;
      Immersive.setFullscreen(true, this.fullscreenPortrait);
    }
  }

  /** 播放器内所有“返回”的唯一入口：全屏只退全屏，嵌入态才退详情页。 */
  private handlePlayerBack(): void {
    if (this.fullscreen) {
      this.exitFullscreen();
      return;
    }
    this.onBack();
  }

  exitFullscreen(): void {
    if (!this.fullscreen || this.fullscreenExitPending) {
      return;
    }
    this.showSideDrawer = false;
    this.showControls = false;
    this.fullscreenExitPending = true;
    this.fullscreenExitAnimationStarted = false;
    // 系统开始旋转的同一时刻收起播放器；DID_ROTATE 仅做状态收尾，不再串成两段动画。
    this.fullscreenExitCancel = Immersive.duringPortraitRotation(
      (): void => this.startFullscreenExitAnimation(),
      (): void => this.finishFullscreenExit());
    Immersive.setFullscreen(false);
  }

  private startFullscreenExitAnimation(): void {
    if (!this.fullscreenExitPending || this.fullscreenExitAnimationStarted || this.destroyed) return;
    this.fullscreenExitAnimationStarted = true;
    // WILL_ROTATE 时仅收缩父页的裁剪窗口。内部 Surface、Canvas 和弹幕引擎仍按全屏尺寸
    // 跟随系统旋转，否则会在横屏尺寸尚未稳定时被提前重排成竖屏轨道。
    this.onFullscreenExitStart();
  }

  private finishFullscreenExit(): void {
    if (!this.fullscreenExitPending) return;
    if (!this.fullscreenExitAnimationStarted) this.startFullscreenExitAnimation();
    this.fullscreenExitPending = false;
    this.fullscreenExitAnimationStarted = false;
    this.fullscreenExitCancel = null;
    if (this.destroyed) return;
    // DID_ROTATE 后窗口已经是最终竖屏尺寸，此时再一次性切换真实布局与弹幕视口。
    this.fullscreen = false;
    this.fullscreenPortrait = false;
    this.dmEngine.fullscreen = false;
    this.onFullscreenChange(false);
    this.restartDmLoopForViewport();
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
  }

  toggleControls(): void {
    if (this.showMoreMenu || this.showSideDrawer) {
      this.closeSettingPanels();
      return;
    }
    this.showControls = !this.showControls;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
    }
    if (this.showControls) {
      this.scheduleControlsHide();
    }
  }

  private closeSettingPanels(): void {
    this.showMoreMenu = false;
    this.showSideDrawer = false;
    this.settingsOpenedDirectly = false;
  }

  /** 切换更多菜单/抽屉内页：push/pop 式过渡（子页从右滑入，menu 向左滑出）。 */
  private openSheetPage(page: string): void {
    if (page === this.moreSheetPage) return;
    if (page === 'sponsor') this.loadSponsorUserInfo(false).catch(() => {});
    if (this.moreSheetPage === 'menu' && page !== 'menu') {
      this.settingsOpenedDirectly = false;
    }
    this.getUIContext().animateTo({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut }, () => {
      this.moreSheetPage = page;
    });
  }

  /** 设置面板开关：竖屏弹底部 Sheet，横屏弹右侧抽屉；再点一次收起。 */
  private toggleMoreMenu(): void {
    if (this.fullscreen) {
      const next: boolean = !this.showSideDrawer;
      this.closeSettingPanels();
      this.showSideDrawer = next;
      this.settingsOpenedDirectly = false;
      if (next) this.openSheetPage('menu');
    } else {
      const next: boolean = !this.showMoreMenu;
      this.closeSettingPanels();
      this.showMoreMenu = next;
      this.settingsOpenedDirectly = false;
      if (next) this.openSheetPage('menu');
    }
  }

  /** 打开指定设置子页：竖屏走底部 Sheet，横屏走右侧抽屉。 */
  private openSettingsPage(page: string): void {
    this.closeSettingPanels();
    this.settingsOpenedDirectly = true;
    this.moreSheetPage = page;
    if (this.fullscreen) {
      this.showSideDrawer = true;
    } else {
      this.showMoreMenu = true;
    }
  }

  private backFromSettingsPage(): void {
    if (this.fullscreen && this.settingsOpenedDirectly) {
      this.showSideDrawer = false;
      this.moreSheetPage = 'menu';
      this.settingsOpenedDirectly = false;
      return;
    }
    this.openSheetPage('menu');
  }

  private pauseForTimer(): void {
    if (!this.prepared) return;
    this.playback.pause();
    this.toast('定时关闭，播放已暂停');
  }

  private onTimerChanged(minutes: number): void {
    this.timerMinutes = minutes;
    if (minutes > 0) {
      this.timerFireAt = Date.now() + minutes * 60000;
      this.toast('定时关闭：' + minutes + ' 分钟后暂停');
    } else {
      this.timerFireAt = 0;
      this.toast('定时关闭已取消');
    }
  }

  private onPlayModeChanged(mode: number): void {
    this.playMode = mode;
    if (mode !== 2) {
      this.autoContinuePlay = true;
    }
  }

  private copyShareLink(): void {
    const url: string = 'https://www.bilibili.com/video/' + this.bvid;
    const text: string = (this.videoTitle + ' ' + url).trim();
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast('链接已复制');
    }).catch((): void => {
      this.toast('复制失败');
    });
  }

  private downloadQualityOptions(): Array<VideoQualityOption> {
    return MediaExportFormat.qualities(this.runtimeQualityOptions);
  }

  private downloadQualityValue(): number {
    return MediaExportFormat.qualityValue(this.runtimeQualityOptions, this.downloadQuality, this.activeQuality);
  }

  private downloadQualityText(): string {
    return MediaExportFormat.qualityText(this.downloadQualityOptions(), this.downloadQualityValue());
  }

  private chooseDownloadQuality(): void {
    if (this.downloadBusy || VideoDownloadService.isActive()) {
      this.toast('已有下载任务正在进行');
      return;
    }
    const options: Array<VideoQualityOption> = this.downloadQualityOptions();
    if (options.length === 0) {
      this.toast('当前视频暂无可下载的 MP4 画质');
      return;
    }
    const buttons: [ReportButtonItem, ReportButtonItem?, ReportButtonItem?, ReportButtonItem?,
      ReportButtonItem?, ReportButtonItem?] = [
      { text: options[0].label, color: this.isDark ? '#E6E6E6' : '#18191C' },
    ];
    for (let i: number = 1; i < options.length && i < 6; i++) {
      buttons.push({ text: options[i].label, color: this.isDark ? '#E6E6E6' : '#18191C' });
    }
    const generation: number = ++this.exportMenuGeneration;
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: '下载画质（最高 1080P MP4）',
        buttons: buttons,
      }).then((result) => {
        if (this.destroyed || generation !== this.exportMenuGeneration) return;
        const index: number = Number(result.index);
        if (index >= 0 && index < options.length) this.downloadQuality = options[index].qn;
      }).catch(() => {});
    } catch (e) {
      this.toast('无法打开画质选择');
    }
  }

  private promptDownloadType(): void {
    const dark: boolean = this.isDark;
    const option: string = dark ? '#E6E6E6' : '#18191C';
    const generation: number = ++this.exportMenuGeneration;
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: '选择下载内容',
        buttons: [
          { text: '缓存到下载中心 · 视频', color: option },
          { text: '缓存到下载中心 · 音频', color: option },
          { text: '导出视频（MP4）', color: option },
          { text: '导出音频（M4A）', color: option },
          { text: '弹幕 / 字幕 / 封面…', color: option },
        ],
      }).then((result) => {
        if (this.destroyed || generation !== this.exportMenuGeneration) return;
        const index: number = Number(result.index);
        if (index === 0) {
          this.mediaExport.enqueueCenterDownload(false).catch(() => {
          });
        } else if (index === 1) {
          this.mediaExport.enqueueCenterDownload(true).catch(() => {
          });
        } else if (index === 2) {
          this.mediaExport.startMediaDownload(false).catch(() => {
          });
        } else if (index === 3) {
          this.mediaExport.startMediaDownload(true).catch(() => {
          });
        } else if (index === 4) {
          this.promptMediaExportMenu();
        }
      }).catch(() => {});
    } catch (e) {
      this.toast('无法打开下载格式选择');
    }
  }

  /** 二级菜单：弹幕/字幕/封面（showActionMenu 最多 6 个按钮）。 */
  private promptMediaExportMenu(): void {
    const dark: boolean = this.isDark;
    const option: string = dark ? '#E6E6E6' : '#18191C';
    const generation: number = ++this.exportMenuGeneration;
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: '导出内容',
        buttons: [
          { text: '下载弹幕（XML）', color: option },
          { text: '下载字幕（SRT）', color: option },
          { text: '下载封面（图片）', color: option },
        ],
      }).then((result) => {
        if (this.destroyed || generation !== this.exportMenuGeneration) return;
        const index: number = Number(result.index);
        if (index === 0) {
          this.mediaExport.exportDanmaku().catch(() => {
          });
        } else if (index === 1) {
          this.mediaExport.exportSubtitle().catch(() => {
          });
        } else if (index === 2) {
          this.mediaExport.exportCover().catch(() => {
          });
        }
      }).catch(() => {});
    } catch (e) {
      this.toast('无法打开导出菜单');
    }
  }

  private scheduleControlsHide(): void {
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (this.playing && !this.showMoreMenu && !this.showSideDrawer) {
        this.showControls = false;
      }
    }, 3000);
  }

  release(): void {
    ++this.exportMenuGeneration;
    this.mediaExport.invalidate();
    this.auxiliary.invalidate();
    this.pictureInPicture.release();
    this.playback.release();
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = -1;
    this.releaseSeekPreview();
    if (this.fullscreenExitCancel !== null) this.fullscreenExitCancel();
    this.fullscreenExitCancel = null;
    this.fullscreenExitPending = false;
    this.fullscreenExitAnimationStarted = false;
    this.dmClock.stop(true);
    this.dmClock.release();
    this.dmEngine.clearCaches();
    Immersive.setKeepScreenOn(false);
    this.deactivateAVSession();
  }

  // ===== 弹幕引擎 =====

  spawnDanmaku(now: number): void {
    if (this.appInBackground) return;
    this.dmEngine.spawn(now);
    if (this.dmEngine.active.length > 0) this.dmClock.start();
  }

  toggleDanmaku(): void {
    this.setDanmakuEnabled(!this.danmakuOn, true);
  }

  private setDanmakuEnabled(enabled: boolean, notify: boolean): void {
    if (this.danmakuOn === enabled) return;
    this.danmakuOn = enabled;
    this.dmEngine.enabled = enabled;
    if (!enabled) {
      this.dmClock.stop(true);
    } else {
      // 重新开启时从当前播放位置继续，不补画已经错过的一大批弹幕。
      this.dmEngine.syncCursor(this.playheadSec - 0.08);
      this.spawnDanmaku(this.playheadSec);
    }
    if (notify) this.onDanmakuChange(enabled);
    this.persistDanmaku();
  }

  restartDmLoopForViewport(): void {
    const shouldRestart: boolean = this.dmClock.isRunning();
    this.dmClock.stop(false);
    this.dmEngine.clearCaches();
    // 横竖屏字号和轨道数不同，切换时立即重排，避免旋转后沿用旧坐标产生抽搐。
    this.setDmFontScale(this.dmFontScale);
    if (shouldRestart || (this.playing && this.dmEngine.active.length > 0)) this.dmClock.start();
  }

  resetDanmakuAt(time: number): void {
    this.dmClock.stop(true);
    this.dmEngine.resetAt(time);
  }

  /** 持久化设置恢复：透明度/速度/字号/密度/屏蔽全量还原到状态与引擎（开关由 VideoDetail 恢复后经 externalDanmakuOn 下发）。
   *  引擎在首次绘制前尚为空白，直接赋字段即可，不走 setter 避免触发落盘。 */
  private restoreDanmakuSettings(): void {
    const s: DanmakuSettings = AppTheme.loadDanmakuSettings();
    this.dmFrameRate = s.frameRate;
    this.dmOpacity = s.opacity;
    this.dmSpeed = s.speed;
    this.dmFontScale = s.fontScale;
    this.dmSpacing = s.spacing;
    this.dmDensity = s.density;
    this.dmBlockLevel = s.blockLevel;
    this.blockScrollDm = s.blockScroll;
    this.blockTopDm = s.blockTop;
    this.blockBottomDm = s.blockBottom;
    this.blockColorDm = s.blockColor;
    this.dmMerge = s.mergeDuplicates;
    this.dmMergeCount = s.mergeShowCount;
    this.dmEngine.opacity = s.opacity;
    this.dmEngine.speed = s.speed;
    this.dmEngine.fontScale = s.fontScale;
    this.dmEngine.spacing = s.spacing;
    this.dmEngine.density = s.density;
    this.dmEngine.minWeight = s.blockLevel;
    this.dmEngine.blockScrollDm = s.blockScroll;
    this.dmEngine.blockTopDm = s.blockTop;
    this.dmEngine.blockBottomDm = s.blockBottom;
    this.dmEngine.blockColorDm = s.blockColor;
    this.dmEngine.mergeDuplicates = s.mergeDuplicates;
    this.dmEngine.showMergeCount = s.mergeShowCount;
  }

  /** 当前弹幕设置全量快照落盘（存储层内部 flush 防抖，滑条高频触发安全）。 */
  private persistDanmaku(): void {
    const s: DanmakuSettings = new DanmakuSettings();
    s.enabled = this.danmakuOn;
    s.frameRate = this.dmFrameRate;
    s.opacity = this.dmOpacity;
    s.speed = this.dmSpeed;
    s.fontScale = this.dmFontScale;
    s.spacing = this.dmSpacing;
    s.density = this.dmDensity;
    s.blockLevel = this.dmBlockLevel;
    s.blockScroll = this.blockScrollDm;
    s.blockTop = this.blockTopDm;
    s.blockBottom = this.blockBottomDm;
    s.blockColor = this.blockColorDm;
    s.mergeDuplicates = this.dmMerge;
    s.mergeShowCount = this.dmMergeCount;
    AppTheme.persistDanmakuSettings(s);
  }

  /** 重复弹幕合并开关：切换后重载弹幕以重新聚类（列表已被合并/展开过，无法原地逆变换）。 */
  setDmMerge(on: boolean): void {
    this.dmMerge = on;
    this.dmEngine.mergeDuplicates = on;
    this.persistDanmaku();
    this.loadDanmaku();
  }

  setDmMergeCount(on: boolean): void {
    this.dmMergeCount = on;
    this.dmEngine.showMergeCount = on;
    this.persistDanmaku();
    if (on) this.loadDanmaku();
  }

  setDmOpacity(value: number): void {
    this.dmOpacity = value;
    this.dmEngine.opacity = value;
    this.persistDanmaku();
  }

  setDmFrameRate(value: number): void {
    this.dmFrameRate = Math.max(24, Math.min(120, Math.round(value)));
    this.dmClock.frameRateChanged();
    this.persistDanmaku();
  }

  setDmSpeed(value: number): void {
    // @State 必须与引擎同步回写，否则滑条显示值不跟随拖动、下次重渲染弹回默认。
    this.dmSpeed = value;
    this.dmEngine.setSpeed(value);
    this.persistDanmaku();
  }

  setDmFontScale(value: number): void {
    this.dmFontScale = value;
    this.dmEngine.setFontScale(value);
    this.persistDanmaku();
  }

  setDmSpacing(value: number): void {
    this.dmSpacing = Math.max(0.5, Math.min(2, value));
    this.dmEngine.setSpacing(this.dmSpacing);
    this.persistDanmaku();
  }

  setDmDensity(value: number): void {
    this.dmDensity = value;
    this.dmEngine.setDensity(value);
    this.persistDanmaku();
  }

  setDmBlockLevel(value: number): void {
    this.dmBlockLevel = Math.round(value);
    this.dmEngine.minWeight = this.dmBlockLevel;
    this.applyDmFilters();
  }

  applyDmFilters(): void {
    this.dmEngine.blockScrollDm = this.blockScrollDm;
    this.dmEngine.blockTopDm = this.blockTopDm;
    this.dmEngine.blockBottomDm = this.blockBottomDm;
    this.dmEngine.blockColorDm = this.blockColorDm;
    this.dmEngine.minWeight = this.dmBlockLevel;
    this.dmEngine.applyFilters();
    if (this.dmEngine.active.length === 0) this.dmClock.stop(false);
    this.persistDanmaku();
  }

  private resetDanmakuSettings(): void {
    const defaults: DanmakuSettings = new DanmakuSettings();
    this.setDmOpacity(defaults.opacity);
    this.setDmFrameRate(defaults.frameRate);
    this.setDmSpeed(defaults.speed);
    this.setDmFontScale(defaults.fontScale);
    this.setDmSpacing(defaults.spacing);
    this.setDmDensity(defaults.density);
    this.setDmBlockLevel(defaults.blockLevel);
    this.blockScrollDm = defaults.blockScroll;
    this.blockTopDm = defaults.blockTop;
    this.blockBottomDm = defaults.blockBottom;
    this.blockColorDm = defaults.blockColor;
    this.dmMerge = defaults.mergeDuplicates;
    this.dmMergeCount = defaults.mergeShowCount;
    this.applyDmFilters();
  }

  private toggleDmBlock(kind: string): void {
    if (kind === 'scroll') this.blockScrollDm = !this.blockScrollDm;
    else if (kind === 'top') this.blockTopDm = !this.blockTopDm;
    else if (kind === 'bottom') this.blockBottomDm = !this.blockBottomDm;
    else this.blockColorDm = !this.blockColorDm;
    this.applyDmFilters();
  }

  syncDanmakuCursor(time: number): void {
    this.dmEngine.syncCursor(time);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      AVVolumePanel({ volumeLevel: this.systemVolumeLevel })
      // 视频画面（外层 Stack 承载镜像翻转：XComponent 自身不支持 transform 属性）
      Stack() {
        XComponent({
          id: 'playerSurface',
          type: XComponentType.SURFACE,
          controller: this.xcController,
        })
          .id('qa_player_surface')
          .width('100%')
          .height('100%')
          .onLoad(() => {
            this.onSurfaceReady();
          })
      }
      .width('100%')
      .height('100%')
      .rotate({ angleY: this.mirrorOn ? 180 : 0 })

      // 起播缓冲封面：垫在 surface 之上、弹幕之下，首帧上屏（'playing'）后淡出；
      // 换源/换清晰度后重新垫起，缓冲期看到的是封面而不是黑屏。
      if (this.videoCover.length > 0) {
        Image(this.videoCover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
          .opacity(this.firstFrameShown ? 0 : 1)
          .animation({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut })
      }

      // seek 超过 180ms 时，仅复用本次拖动已经解出的目标预览帧；没有预览则保留
      // Surface 的上一帧并显示加载环，不能跳回与当前时间无关的视频封面。
      if (this.seekRecoveryCoverVisible && this.seekPreviewFrame !== null) {
        Image(this.seekPreviewFrame)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
      }

      // 弹幕层：位于视频画面与控件层之间（层级顺序 视频 < 弹幕 < 其他组件），
      // 控制条/弹幕输入/气泡/字幕始终浮在弹幕之上。画布节点高度恒定为 danmakuFixedHeight，
      // 收起/展开动画期只有本包裹层裁剪窗口收缩，Canvas 后备缓冲不被逐帧 resize，
      // 避免清缓冲造成的弹幕闪烁。
      Stack({ alignContent: Alignment.TopStart }) {
        Canvas(this.ctx)
          .id('qa_player_danmaku_canvas')
          .width('100%')
          .height(this.danmakuFixedHeight > 0 ? this.danmakuFixedHeight : '100%')
          .hitTestBehavior(HitTestMode.None)
          // onReady 也在 Canvas 尺寸变化、缓冲清空后触发；暂停时需补画保留的静止弹幕。
          .onReady(() => this.dmClock.redraw())
      }
      .id('qa_player_danmaku_viewport')
      .width('100%')
      .height('100%')
      .clip(true)
      .hitTestBehavior(HitTestMode.None)
      .visibility(this.externalDanmakuOn ? Visibility.Visible : Visibility.Hidden)

      // 控件隐藏时整屏命中；控件显示时只由中间空白区挂载，避免覆盖顶栏和底栏。
      if (!this.showControls) {
        this.PlayerGestureArea()
      }

      // 弹幕交互气泡：点击弹幕停住后，在弹幕上方/下方显示一个黑色半透明小气泡
      // （点赞/复制/举报三个线性图标，无文字，弹幕本身保持原大小和位置）。
      if (this.dmPinnedVisible) {
        Row({ space: 0 }) {
          PlayerDanmakuAction({ icon: $r('app.media.ic_like'), onTap: () => this.dmLike() })
          PlayerDanmakuAction({ icon: $r('app.media.ic_copy'), onTap: () => this.dmCopy() })
          PlayerDanmakuAction({ icon: $r('app.media.ic_report_flag'), onTap: () => this.dmReport() })
        }
        .width(this.dmPinBubbleW)
        .height(this.dmPinBubbleH)
        .padding({ left: 4, right: 4, top: 2, bottom: 2 })
        .borderRadius(17)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
        .border({ width: 0.5, color: '#33FFFFFF' })
        .shadow({ radius: 8, color: '#33000000', offsetY: 2 })
        .align(Alignment.TopStart)
        .position({ x: this.dmPinBubbleX, y: this.dmPinBubbleY })
        .zIndex(60)
      }

      // CC 字幕层：底部黑底白字，开关与轨道选择见设置面板/更多菜单。
      if (this.subtitleOn && this.subtitleText.length > 0) {
        Text(this.subtitleText)
          .fontSize(Math.max(12, Math.min(30, Math.round(15 * this.subtitleScale))))
          .fontColor(this.sheetTitleColor())
          .backgroundColor('#66000000')
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(4)
          .margin({ bottom: 96 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .align(Alignment.Bottom)
      }

      if (this.previewPlayback && this.errorText.length === 0) {
        Text('试看 · 完整内容需相应观看权限')
          .fontSize(11).fontColor('#FFFFFF').backgroundColor('#99000000')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(6)
          .align(Alignment.TopEnd).margin({ top: 42, right: 12 })
          .hitTestBehavior(HitTestMode.None)
      }

      // 错误遮罩
      if (this.errorText.length > 0) {
        Column({ space: 8 }) {
          Text('⚠')
            .fontSize(30)
            .fontColor(this.sheetTitleColor())
          Text(this.errorText)
            .fontSize(13)
            .fontColor(this.sheetTitleColor())
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
      }

      // 缓冲提示
      if (this.buffering) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color('#FFFFFF')
      }

      PlayerGestureOverlay({
        chapterTitle: chapterTitleAt(this.chapters, this.progressDisplayTime(), this.duration),
        onlineTotal: this.onlineTotal,
        compactMode: this.compactMode,
        showControls: this.showControls,
        fullscreen: this.fullscreen,
        holdSpeedActive: this.holdSpeedActive,
        chapters: this.chapters,
        scrubCtl: this.scrubCtl,
        sliderSeekPreview: this.sliderDragging ? this.sliderDragValue : -1,
        seekPreviewFrame: this.seekPreviewFrame,
        seekPreviewCover: this.videoCover,
        seekPreviewSprite: this.seekPreviewSprite,
        seekPreviewSpriteCell: this.seekPreviewSpriteCell,
        seekPreviewSpriteXLen: this.seekPreviewSpriteXLen,
        seekPreviewSpriteYLen: this.seekPreviewSpriteYLen,
        gestureAdjustKind: this.gestureAdjustKind,
        gestureAdjustPercent: this.gestureAdjustPercent,
        panStartTime: this.gestureCtl?.panStartTime ?? 0,
        duration: this.duration,
      })
      // 空降提示固定在右下角（旧实现无显式定位，被根 Stack 的 Center 对齐顶到画面中间遮挡内容）。
      if (this.sponsorNoticeVisible && !this.endScreenOpen) {
        Column() {
          SponsorBlockNotice({
            title: this.sponsorNoticeTitle,
            detail: this.sponsorNoticeDetail,
            color: this.sponsorNoticeColor,
            manual: this.sponsorNoticeManual,
            canUndo: this.sponsorNoticeCanUndo,
            canVote: this.sponsorNoticeCanVote,
            onPrimary: () => this.sponsorCtl.noticePrimary(),
            onVote: (type: number) => this.sponsorCtl.voteNotice(type),
            onClose: () => this.sponsorCtl.hideNotice(true),
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.End)
        .padding({ right: 10, bottom: this.fullscreen ? 88 : 48 })
        // 容器自身不参与命中测试，只有提示卡里的按钮可点（与 HeaderBackdrop 同款覆盖层语义）。
        .hitTestBehavior(HitTestMode.None)
        .zIndex(95)
      }
      // 竖屏收起控件后仍保留 1.5vp 的播放进度提示，紧贴画面底边且不响应触摸。
      if (!this.fullscreen && !this.showControls && this.duration > 0 &&
        this.errorText.length === 0 && !this.endScreenOpen) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Row()
            .width('100%')
            .height(1.5)
            .backgroundColor('#30FFFFFF')
          Row()
            .width(this.passiveProgressWidth())
            .height(1.5)
            .backgroundColor('#FFFB7299')
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .zIndex(80)
      }
      if (this.chapters.length > 0 && this.duration > 0 && !this.compactMode &&
        this.errorText.length === 0 && !this.endScreenOpen && !this.showMoreMenu && !this.showSideDrawer) {
        Row() {
          PlayerChapterBar({
            chapters: this.chapters, progress: this.progressDisplayTime(), duration: this.duration,
            scrubCtl: this.seekTargetCtl,
            controlsVisible: this.showControls, fullscreen: this.fullscreen,
            onSelect: (seconds: number) => {
              this.seekTo(seconds, true);
              this.showControls = true;
              this.scheduleControlsHide();
            },
            onOpen: () => this.openSettingsPage('chapters'),
          })
        }
        .width('100%')
        .position({ left: 0, bottom: this.showControls ? (this.fullscreen ? 88 : 42) : 0 })
        .zIndex(85)
      }
      // 控件层（播完结束画面为整幅蒙版，不再叠加控制条）
      if ((this.showControls || (!this.playing && this.compactMode && !this.fullscreen)) && this.errorText.length === 0 && !this.endScreenOpen) {
        Column() {
          if (this.compactMode && !this.fullscreen) {
            PlayerCompactControls({
              playing: this.playing,
              hotPoints: this.hotPoints,
              progress: this.progressDisplayTime(),
              duration: this.duration,
              chapters: this.chapters,
              scrubCtl: this.seekTargetCtl,
              sponsorSegments: this.visibleSponsorSegments(),
              titleColor: this.sheetTitleColor(),
              onBack: () => this.handlePlayerBack(),
              onHome: () => this.onHome(),
              onPlay: () => this.togglePlay(),
              onMore: () => this.toggleMoreMenu(),
              onFullscreen: () => this.toggleFullscreen(),
              onProgressChange: (value: number, mode: SliderChangeMode) => this.onProgressSliderChange(value, mode),
              onProgressInteractionEnd: () => this.finishProgressPreviewInteraction(),
            })
          } else {
            if (this.fullscreen) {
              PlayerFullscreenHeader({
                title: this.videoTitle,
                ownerName: this.ownerName,
                ownerFace: this.ownerFace,
                liked: this.liked,
                coined: this.coined,
                favorited: this.favorited,
                accent: this.accent,
                onBack: () => this.handlePlayerBack(),
              onHome: () => this.onHome(),
                onLike: () => this.onLike(),
                onCoin: () => this.onCoin(),
                onFavorite: () => this.onFavorite(),
                onShare: () => this.onShare(),
              })
              // 竖屏全屏时顶栏让出状态栏高度，避免融进状态栏区域难点难看。
              .padding({ top: this.fullscreenPortrait ? Immersive.statusBarHeight() : 0 })
            } else {
              // 竖屏顶栏：左上返回、右上 ⋮：清晰度/倍速/空降/分段/弹幕设置全部收纳在这里，
              // 底栏只保留 播放-进度-全屏，减少对画面内容的遮挡。
              Row() {
                this.IconButton($r('app.media.ic_back'), 20, 36, 36, '#FFFFFF', false, () => {
                  this.handlePlayerBack();
                })
                Image($r('app.media.ic_tab_home'))
                  .width(36).height(36).padding(8)
                  .renderMode(ImageRenderMode.Template).fillColor('#FFFFFF')
                  .accessibilityText('返回主页').id('player-home-entry')
                  .onClick(() => this.onHome())
                Blank()
                this.IconButton($r('app.media.ic_more'), 20, 36, 36, '#FFFFFF', false, () => {
                  this.toggleMoreMenu();
                })
              }
              .width('100%')
              .padding({ top: 6, left: 4, right: 4 })
            }
            Stack() {
              this.PlayerGestureArea()
            }
            .width('100%')
            .layoutWeight(1)
            PlayerBottomControls({
              fullscreen: this.fullscreen,
              hotPoints: this.hotPoints,
              playing: this.playing,
              danmakuOn: this.danmakuOn,
              sponsorEnabled: this.sponsorSkipEnabled,
              chapters: this.chapters,
              sponsorSegments: this.visibleSponsorSegments(),
              progress: this.progressDisplayTime(),
              duration: this.duration,
              scrubCtl: this.seekTargetCtl,
              qualityLoading: this.qualityLoading,
              qualityLabel: this.qualityLabel(),
              playbackRate: this.playbackRate,
              dmDraft: this.dmDraft,
              dmSending: this.dmSending,
              onPlay: () => this.togglePlay(),
              onDanmaku: () => this.toggleDanmaku(),
              onDanmakuSettings: () => this.openSettingsPage('dm'),
              onSponsor: () => {
                this.setSponsorEnabled(!this.sponsorSkipEnabled);
              },
              onChapter: () => this.openSettingsPage('chapters'),
              onQuality: () => this.openSettingsPage('quality'),
              onSpeed: () => this.openSettingsPage('speed'),
              onFullscreen: () => this.toggleFullscreen(),
              onProgressChange: (value: number, mode: SliderChangeMode) => this.onProgressSliderChange(value, mode),
              onProgressInteractionEnd: () => this.finishProgressPreviewInteraction(),
              onDmDraftChange: (value: string) => this.onDmDraftChange(value),
              onDmSend: () => this.onDmSend(),
            })
          }
        }
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: CONTROLS_GRADIENT_COLORS,
        })
      }

      // 播完结束画面：横屏全屏用官方多卡片版式；其余（竖屏/竖屏全屏/compact）用单卡版式
      if (this.endScreenOpen && !this.compactMode && this.errorText.length === 0) {
        PlayerEndScreen({
          landscape: this.fullscreen && !this.fullscreenPortrait,
          accent: this.accent,
          title: this.endRecTitle,
          cover: this.endRecCover,
          upName: this.ownerName,
          upFace: this.ownerFace,
          playText: this.endRecPlayText,
          duration: this.endRecDuration,
          recommendations: this.endRecList,
          following: this.upFollowing,
          liked: this.liked,
          disliked: this.disliked,
          coined: this.coined,
          favorited: this.favorited,
          onClose: () => this.closeEndScreen(),
          onBack: () => this.handlePlayerBack(),
              onHome: () => this.onHome(),
          onReplay: () => this.endReplay(),
          onPlayNow: () => {
            this.endScreenOpen = false;
            this.onEndPlayNow();
          },
          onFollow: () => this.onFollow(),
          onLike: () => this.onLike(),
          onDislike: () => this.onDislike(),
          onCoin: () => this.onCoin(),
          onFavorite: () => this.onFavorite(),
          onShare: () => {
            this.endScreenOpen = false;
            this.onShare();
          },
          onOpenRecommendation: (item: VideoItem) => {
            this.endScreenOpen = false;
            this.onEndRecOpen(item);
          },
        })
      }

      // 横屏旋转后窗口级 ContentCover 可能不会重新挂载；抽屉直接放在播放器栈顶，
      // 同样覆盖弹幕和控制条，并由左侧空白区域负责关闭。
      if (this.fullscreen && this.showSideDrawer) {
        this.SideDrawerCoverContent()
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor('#000000')
    .bindSheet($$this.showMoreMenu, this.MoreMenuSheetContent(), {
      height: this.moreSheetHeight > 0 ? this.moreSheetHeight : 760,
      dragBar: false,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: this.isDark ? '#18191C' : '#F5F6F7',
    })
  }

  /** 单击播放画面：命中的弹幕先"停住"并显示点赞/复制/举报操作条（B 站交互）；否则照常切控件。 */
  private handleCanvasTap(event: GestureEvent): void {
    if (this.endScreenOpen) return;
    const result: DanmakuPinResult = this.dmInteraction.handleTap(event, this.dmPinnedVisible);
    if (!result.handled) {
      this.toggleControls();
      return;
    }
    this.dmPinnedVisible = result.visible;
    this.dmPinnedText = result.text;
    if (!result.visible) {
      if (this.playing) this.scheduleControlsHide();
      return;
    }
    this.dmPinBubbleX = result.x;
    this.dmPinBubbleY = result.y;
    this.dmPinBubbleW = result.width;
    this.dmPinBubbleH = result.height;
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = -1;
    this.showControls = true;
  }

  /** 取消停住，恢复弹幕滚动。 */
  private unpinDanmaku(): void {
    this.dmInteraction.clearPin();
    this.dmPinnedVisible = false;
    this.dmPinnedText = '';
    if (this.playing) this.scheduleControlsHide();
  }

  /** 弹幕点赞：x/v2/dm/thumbup/add（dmid + cid）；XML 兜底协议无 dmid，只能本地反馈。 */
  private dmLike(): void {
    const request: Promise<string> = this.dmInteraction.like(this.cid);
    this.unpinDanmaku();
    request.then((message: string) => {
      if (message.length > 0) this.toast(message);
    });
  }

  /** 复制弹幕文本到系统剪贴板。 */
  private dmCopy(): void {
    const text: string = this.dmPinnedText;
    const request: Promise<string> = this.dmInteraction.copy(text);
    this.unpinDanmaku();
    request.then((message: string) => this.toast(message));
  }

  /** 弹幕举报：停住态下点"举报"进原因选择。 */
  private dmReport(): void {
    const item: DanmakuItem | null = this.dmInteraction.takeReportItem();
    this.unpinDanmaku();
    if (item !== null) this.promptReportDanmaku(item);
  }

  /** 圆形图标按钮：Stack 居中 Image，可选深色圆形底。 */
  @Builder
  IconButton(icon: Resource, iconSize: number, boxWidth: number, boxHeight: number, fill: ResourceColor,
    circleBg: boolean, onClick: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      if (circleBg) {
        Circle()
          .width(32)
          .height(32)
          .fill('#66000000')
      }
      Image(icon)
        .width(iconSize)
        .height(iconSize)
        .renderMode(ImageRenderMode.Template)
        .fillColor(fill)
    }
    .width(boxWidth)
    .height(boxHeight)
    .onClick(() => {
      onClick();
    })
  }

  private onProgressSliderChange(value: number, mode: SliderChangeMode): void {
    // 拖动期间滑块以拖动值为准，避免 timeUpdate 回写 curTime 把滑块拽回；仍在 End/Click 才 seek。
    if (mode === SliderChangeMode.Begin) {
      this.sliderDragging = true;
      this.sliderDragValue = value;
      this.requestSeekPreview(value);
    } else if (mode === SliderChangeMode.Moving) {
      this.sliderDragValue = value;
      this.requestSeekPreview(value);
    } else {
      this.finishProgressPreviewInteraction();
      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
        Haptic.seek();
        // Moving 阶段只更新预览；End/Click 仅提交一次精确 seek，避免落到前一关键帧。
        this.seekTo(value, true);
      }
    }
  }


  private sheetTitleColor(): string {
    return playerPanelTitle(this.isDark);
  }

  /** 横屏设置抽屉：从右侧滑入，点左侧空白收起。 */
  @Builder
  SideDrawerCoverContent() {
    PlayerSideSettingsDrawer({
      onClose: (): void => {
        this.showSideDrawer = false;
        this.moreSheetPage = 'menu';
        this.settingsOpenedDirectly = false;
      },
      content: (): void => {
        this.MoreMenuSheetContent()
      },
    })
    .zIndex(200)
  }

  @Builder
  MoreMenuSheetContent() {
    PlayerSettingsContent({
      page: this.moreSheetPage,
      fullscreen: this.fullscreen,
      isDark: this.isDark,
      accent: this.accent,
      playbackRate: this.playbackRate,
      playMode: this.playMode,
      qualityLabel: this.qualityLabel(),
      qualityLoading: this.qualityLoading,
      qualityPref: this.qualityPref,
      downloadQualityLabel: this.downloadQualityText(),
      downloadBusy: this.downloadBusy,
      downloadProgress: this.downloadProgress,
      mirrorOn: this.mirrorOn,
      timerMinutes: this.timerMinutes,
      sponsorOn: this.sponsorSkipEnabled,
      sponsorCategories: $sponsorCategories,
      sponsorSegments: $sponsorSegments,
      sponsorDraftStart: $sponsorDraftStart,
      sponsorDraftEnd: $sponsorDraftEnd,
      sponsorDraftCategory: $sponsorDraftCategory,
      sponsorDraftAction: $sponsorDraftAction,
      sponsorSubmitting: $sponsorSubmitting,
      sponsorUserLoading: $sponsorUserLoading,
      sponsorUserName: $sponsorUserName,
      sponsorUserStats: $sponsorUserStats,
      sponsorWarningReason: $sponsorWarningReason,
      subtitleOn: this.subtitleOn,
      subtitleScale: this.subtitleScale,
      backgroundPlaybackEnabled: this.backgroundPlaybackEnabled,
      subtitleIndex: this.subtitleIndex,
      subtitles: this.subtitles,
      chapters: this.chapters,
      currentTime: this.curTime,
      duration: this.duration,
      qualityOptions: this.runtimeQualityOptions,
      activeQuality: this.activeQuality,
      dmOpacity: this.dmOpacity,
      dmFrameRate: this.dmFrameRate,
      dmSpeed: this.dmSpeed,
      dmFontScale: this.dmFontScale,
      dmSpacing: this.dmSpacing,
      dmDensity: this.dmDensity,
      dmBlockLevel: this.dmBlockLevel,
      blockScrollDm: this.blockScrollDm,
      blockTopDm: this.blockTopDm,
      blockBottomDm: this.blockBottomDm,
      blockColorDm: this.blockColorDm,
      dmMerge: this.dmMerge,
      dmMergeCount: this.dmMergeCount,
      dmListCount: this.dmListCount,
      dmFilterLoading: this.dmFilterLoading,
      dmFilterType: this.dmFilterType,
      dmFilterDraft: this.dmFilterDraft,
      dmFilterRulesCount: this.dmFilterRulesCount,
      dmListSource: this.dmListSource,
      dmFilterRuleSource: this.dmFilterRuleSource,
      onBack: () => this.backFromSettingsPage(),
      onClose: () => {
        this.showMoreMenu = false;
        this.showSideDrawer = false;
      },
      onOpenPage: (page: string) => this.openSheetPage(page),
      onDmFilterOpen: () => this.openDanmakuFilter(),
      onSeek: (seconds: number) => this.seekTo(seconds, true),
      onReportDm: (item: DanmakuItem) => this.promptReportDanmaku(item),
      onFilterTypeChange: (type: number) => this.dmFilterType = type,
      onFilterDraftChange: (draft: string) => this.dmFilterDraft = draft,
      onFilterAdd: () => this.submitDmFilterRule().catch(() => {}),
      onFilterDelete: (id: number) => this.deleteDmFilterRule(id).catch(() => {}),
      onQualityPrefChange: (pref: number) => { PlayerQualityPreference.useMode(pref); },
      onDownloadQuality: () => this.chooseDownloadQuality(),
      onDownload: () => this.promptDownloadType(),
      onSubtitleChange: (index: number) => this.changeSubtitle(index),
      onResetDanmaku: () => this.resetDanmakuSettings(),
      onDmOpacityChange: (value: number) => this.setDmOpacity(value),
      onDmFrameRateChange: (value: number) => this.setDmFrameRate(value),
      onDmSpeedChange: (value: number) => this.setDmSpeed(value),
      onDmFontScaleChange: (value: number) => this.setDmFontScale(value),
      onDmSpacingChange: (value: number) => this.setDmSpacing(value),
      onDmDensityChange: (value: number) => this.setDmDensity(value),
      onDmBlockLevelChange: (value: number) => this.setDmBlockLevel(value),
      onToggleDmBlock: (kind: string) => this.toggleDmBlock(kind),
      onDmMergeChange: (next: boolean) => this.setDmMerge(next),
      onDmMergeCountChange: (next: boolean) => this.setDmMergeCount(next),
      onQualityChange: (qn: number) => this.changeQuality(qn),
      onChapterChange: (seconds: number) => {
        this.seekTo(seconds, true);
        this.closeSettingPanels();
      },
      onSpeedChange: (rate: number) => this.setPlaybackSpeed(rate),
      onPlayModeChange: (mode: number) => this.onPlayModeChanged(mode),
      onTimerChange: (minutes: number) => this.onTimerChanged(minutes),
      onMirrorChange: (next: boolean) => this.mirrorOn = next,
      onSubtitleToggle: (next: boolean) => this.toggleSubtitle(next),
      onSubtitleScaleChange: (scale: number) => {
        AppStorage.setOrCreate<number>('subtitleScale', scale);
      },
      onBackgroundPlaybackChange: (next: boolean) => this.setBackgroundPlayback(next),
      onPictureInPicture: () => { this.pictureInPicture.start(); },
      onReportVideo: () => this.reportCurrentVideo(),
      onSponsorToggle: (next: boolean) => {
        this.setSponsorEnabled(next);
      },
      onSponsorModeChange: (category: string, mode: number) => this.changeSponsorMode(category, mode),
      onSponsorRefresh: () => {
        this.sponsorCtl.loadSponsorSegments(true);
        this.loadSponsorUserInfo(true).catch(() => {});
      },
      onSponsorMarkStart: () => this.markSponsorStart(),
      onSponsorMarkEnd: () => this.markSponsorEnd(),
      onSponsorDraftStartChange: (value: number) => this.sponsorDraftStart = value,
      onSponsorDraftEndChange: (value: number) => this.sponsorDraftEnd = value,
      onSponsorDraftCategoryChange: (value: string) => this.changeSponsorDraftCategory(value),
      onSponsorDraftActionChange: (value: string) => this.changeSponsorDraftAction(value),
      onSponsorPreview: () => this.previewSponsorDraft(),
      onSponsorClear: () => this.clearSponsorDraft(),
      onSponsorSubmit: () => this.submitSponsorDraft().catch(() => {}),
      onSponsorSegmentSeek: (segment: SponsorBlockSegment) => this.seekSponsorSegment(segment),
      onSponsorSegmentVote: (segment: SponsorBlockSegment, type: number) => this.sponsorCtl.voteSegment(segment, type),
      onSponsorUserNameChange: (value: string) => this.sponsorUserName = value,
      onSponsorSaveUserName: () => this.saveSponsorUsername().catch(() => this.toast('昵称更新失败')),
      onSponsorAcknowledgeWarning: () => this.acknowledgeSponsorWarning().catch(() => this.toast('操作失败')),
      onShare: () => this.onShare(),
      onWatchLater: () => this.onWatchLater(),
      onCopyLink: () => this.copyShareLink(),
      onStub: (message: string) => this.toast(message),
    })
  }
}
