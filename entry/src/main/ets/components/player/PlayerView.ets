import { VideoReportDialog } from '../VideoReportDialog';
import { PlayerQualityPreference } from '../../common/PlayerQualityPreference';
import { AVVolumePanel } from '@kit.AudioKit';
import { SystemMediaVolume } from './SystemMediaVolume';
import { PlayerChapterBar } from './PlayerChapterBar';
import { chapterTitleAt } from './PlayerChapterSupport';
/**
 * 播放器组件：AVPlayer + XComponent 渲染 + Canvas 弹幕引擎 + 手势控制
 */
import { RequestEpoch } from '../../common/RequestEpoch';
import { media } from '@kit.MediaKit';
import { PiPWindow as pictureInPicture } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { avSession } from '@kit.AVSessionKit';
import { PlayerAvSessionHelper } from './PlayerAvSessionHelper';
import { PlayerSubtitleController } from './PlayerSubtitleController';
import { PlayerSeekController } from './PlayerSeekController';
import { PlayerSpeedController } from './PlayerSpeedController';
import { PlayerGestureController } from './PlayerGestureController';
import { PlayerPlaybackConfig } from './PlayerPlaybackConfig';
import { playerPanelTitle } from './PlayerSheetTheme';
import { PlayerSideSettingsDrawer } from './PlayerSideSettingsDrawer';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { ActionResult, BiliApi, DanmakuItem, DmFilterRule, VideoChapter } from '../../api/BiliApi';
import { SponsorBlockApi, SponsorBlockResult, SponsorBlockUserInfo } from '../../api/SponsorBlockApi';
import { UserStore } from '../../services/auth/UserStore';
import { AppTheme, DanmakuSettings } from '../../common/AppTheme';
import { Haptic } from '../../common/Haptic';
import { Immersive } from '../../common/Immersive';
import { formatDuration, formatCount } from '../../common/Utils';
import { PlayerSponsorController, SponsorNoticeUi } from './PlayerSponsorController';
import { PlayerDanmakuClock } from './PlayerDanmakuClock';
import { PlayUrlInfo, SubtitleCue, SubtitleTrack, VideoItem, VideoQualityOption } from '../../model/Models';
import { Constants } from '../../common/Constants';
import { BasicDataSource } from '../../common/BasicDataSource';
import { PlayerGestureOverlay, PlayerScrubController } from './PlayerGestureOverlay';
import { PlayerFullscreenHeader } from './PlayerFullscreenHeader';
import { CONTROLS_GRADIENT_COLORS, DM_SEGMENT_SECONDS } from './PlayerDanmakuSupport';
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
import { HttpClient } from '../../services/network/HttpClient';
import { VideoDownloadService } from '../../services/media/VideoDownloadService';

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
  /** 官方 startRenderFrame 已到达；必须再与 playing 同时成立，才撤掉起播封面。 */
  private firstRenderReady: boolean = false;
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
  @State subtitleLoading: boolean = false;
  @State dmFilterRulesCount: number = 0;
  @State dmFilterLoading: boolean = false;
  @State dmFilterDraft: string = '';
  @State dmFilterType: number = 0;
  @State dmListCount: number = 0;
  @State chapters: Array<VideoChapter> = [];
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
  @State holdSpeedActive: boolean = false;
  // 横滑预览时间下沉到 PlayerGestureOverlay 自持（scrubCtl 注入写回），
  // 父结构体不再随手势采样频率全量重渲染。这里只留非响应式镜像供手势结束时的 seekTo 读取落点。
  private gestureScrubValue: number = -1;
  private scrubCtl: PlayerScrubController = new PlayerScrubController();
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
  private player: media.AVPlayer | null = null;
  private audioPlayer: media.AVPlayer | null = null;
  private audioPrepared: boolean = false;
  private videoReportDialog: CustomDialogController | null = null;
  private pipController: pictureInPicture.PiPController | null = null;
  private pipActive: boolean = false;
  private pipStarting: boolean = false;
  private pipRestoring: boolean = false;
  private pipGeneration: number = 0;
  private xcController: XComponentController = new XComponentController();
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private dmEngine: PlayerDanmakuEngine = new PlayerDanmakuEngine(this.ctx);
  private dmInteraction: PlayerDanmakuInteractionController = new PlayerDanmakuInteractionController(this.dmEngine);
  private dmClock: PlayerDanmakuClock = new PlayerDanmakuClock({
    isPlaying: (): boolean => this.playing,
    isDanmakuOn: (): boolean => this.danmakuOn,
    getFrameRate: (): number => this.dmFrameRate,
    getEngine: (): PlayerDanmakuEngine => this.dmEngine,
    clearPinned: (): void => {
      this.dmPinnedVisible = false;
      this.dmPinnedText = '';
    },
  });
  private hideTimer: number = -1;
  private sourceIndex: number = 0;
  private retryingSource: boolean = false;
  private runtimeSources: Array<string> = [];
  private runtimeAudioSources: Array<string> = [];
  private audioSourceIndex: number = 0;
  private lastAudioSyncAtMs: number = -1;
  private audioDriftSamples: number = 0;
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
    muteImmediately: (): void => this.muteImmediately(),
    restoreUserVolume: (): void => this.restoreUserVolume(),
    isFirstFrameMuteArmed: (): boolean => this.firstFrameMuteArmed,
    toast: (message: string): void => this.toast(message),
    getBvid: (): string => this.bvid,
    getCid: (): number => this.cid,
  });
  private subtitleCtl: PlayerSubtitleController | null = null;
  private avSessionHelper: PlayerAvSessionHelper | null = null;
  private dmListSource: BasicDataSource<DanmakuItem> = new BasicDataSource<DanmakuItem>();
  private dmFilterRuleSource: BasicDataSource<DmFilterRule> = new BasicDataSource<DmFilterRule>();
  private runtimeQualityOptions: Array<VideoQualityOption> = [];
  private resumeAfterPrepare: number = -1;
  private shouldPlayAfterPrepare: boolean = true;
  // seek 采用“并发请求获胜”的串行状态机，由 PlayerSeekController 管理音视频双轨 seek 合并。
  private seekCtl: PlayerSeekController | null = null;
  private speedCtl: PlayerSpeedController | null = null;
  private gestureCtl: PlayerGestureController | null = null;
  private onlineRequest: number = 0;
  private surfaceId: string = '';
  // 组件销毁后置位：所有跨 await 的换源/重建流程在 initPlayer 前据此放弃，避免泄漏无人释放的 AVPlayer。
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
  private volumeRestoreTimer: number = -1;
  /** 音画对齐：音频等待视频播放头推进并定位到同一时刻后再 play。 */
  private audioStartPending: boolean = false;
  /** 音轨首播先对齐到视频播放头；等待本次 seekDone 后才允许出声。 */
  private audioGateSeekPending: boolean = false;
  /** 音轨门控 seek 的目标与看门狗；回调丢失时也必须恢复声音，不能永久静音。 */
  private audioGateSeekTargetMs: number = -1;
  private audioGateTimer: number = -1;
  // 起播静音至首帧：play 时双轨音量置 0，首个 timeUpdate>50ms（首帧已上屏）恢复用户音量，
  // seek 恢复时还会校验 timeUpdate 已落到目标附近，避免旧位置回调提前放声。
  private firstFrameMuteArmed: boolean = false;
  private firstFrameMuteTimer: number = -1;
  private firstFrameMuteTargetMs: number = -1;
  /** 慢 seek 时用预览帧/封面挡住 Surface，直到新位置开始推进。 */
  @State seekRecoveryCoverVisible: boolean = false;
  private seekRecoveryActive: boolean = false;
  private fullscreenExitPending: boolean = false;
  private fullscreenExitAnimationStarted: boolean = false;
  private fullscreenExitCancel: (() => void) | null = null;
  // AVPlayer 创建本身是异步的：代次使离页/换源前发起的 createAVPlayer 结果失效并立即释放。
  private playerCreateGeneration: number = 0;
  private sourceRequests: RequestEpoch = new RequestEpoch();
  private playerCreating: boolean = false;
  /** 后台音乐模式：视频轨暂停，独立 DASH 音轨继续播放。 */
  private backgroundAudioOnly: boolean = false;
  /** 从后台音乐模式回到前台时，等待双轨 seek 完成并恢复视频。 */
  private backgroundVideoResumePending: boolean = false;
  /** 同一次 seek 超时最多重建一次，避免故障源形成释放/重建/重新下载死循环。 */
  private seekRecoveryAttempts: number = 0;
  // 已加载弹幕对应的 cid，避免 aboutToAppear 与换源触发的并发/重复加载。
  private dmLoadedCid: number = -1;
  // 弹幕分段加载状态（0 基段号）；分段首段失败时 dmSegFallback 置位，整体回退 XML 整段接口。
  private dmSegLoaded: Set<number> = new Set<number>();
  private dmSegLoading: Set<number> = new Set<number>();
  private dmSegFallback: boolean = false;
  /** 首帧后才发的增强请求是否已发出（换源时重置，让新 cid 同样排到新首帧之后）。 */
  private deferredLoadsDone: boolean = false;
  private deferredLoadTimer: number = -1;

  aboutToAppear(): void {
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
    this.downloadBusy = VideoDownloadService.isActive();
    this.downloadProgress = VideoDownloadService.currentProgress();
    this.restoreDanmakuSettings();
    this.onDanmakuEngineReady(this.dmEngine);
    this.showControls = false;
    this.endScreenOpen = false;
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    AppStorage.setOrCreate<number>('videoFullscreenExitRequest', 0);
    if (this.seekCtl === null) {
      this.seekCtl = new PlayerSeekController(
        (): media.AVPlayer | null => this.player,
        (): media.AVPlayer | null => this.audioPlayer,
        (): boolean => this.prepared,
        (): boolean => this.audioPrepared,
        (targetMs: number, resumePlaying: boolean): void => {
          this.preparePlayersForSeek(targetMs, resumePlaying);
          this.dmClock.stop(false);
        },
        (on: boolean): void => {
          this.buffering = on;
          if (on) this.seekRecoveryCoverVisible = true;
        },
        (resume: boolean, targetMs: number): void => {
          this.seekRecoveryAttempts = 0;
          const video: media.AVPlayer | null = this.player;
          if (resume && video !== null && this.prepared) {
            try {
              // seek 后恢复播放同样静音等目标帧：新位置开始推进前不放声。
              const actualTargetMs: number = video.currentTime >= 0 ? video.currentTime : targetMs;
              this.armFirstFrameMute(actualTargetMs, 1800);
              if (video.state !== 'playing') video.play();
              // 两轨已经在暂停态对齐，直接成对启动；再次门控 seek 会让音频落后视频一个定位耗时。
              const audio: media.AVPlayer | null = this.audioPlayer;
              if (audio !== null && this.audioPrepared) audio.play();
            } catch (e) {
            }
          } else {
            this.seekRecoveryActive = false;
            this.seekRecoveryCoverVisible = false;
            this.restoreUserVolume();
          }
          // seek 完成：解锁进度回写，让 timeUpdate 接管进度显示。
          this.seekLocked = false;
          // 播放中的 seek 要等新位置首个 timeUpdate 再撤遮罩/缓冲；暂停态可直接显示定位帧。
          if (!resume) this.buffering = false;
        },
        (video: media.AVPlayer | null, targetMs: number): void => {
          if (video !== null) this.recoverPlayersAfterSeekStall(video, targetMs);
        },
      );
    }

    if (this.speedCtl === null) {
      this.speedCtl = new PlayerSpeedController(
        (rate: number): void => {
          this.applyTemporarySpeed(rate);
        },
        (active: boolean): void => {
          this.holdSpeedActive = active;
        },
      );
    }
    
    if (this.gestureCtl === null) {
      this.gestureCtl = new PlayerGestureController(
        (value: number): void => {
          this.gestureScrubValue = value;
          this.scrubCtl.show(value);
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
if (this.runtimeSources.length === 0) {
      this.runtimeSources = this.videoUrls.length > 0 ? this.videoUrls : (this.videoUrl.length > 0 ? [this.videoUrl] : []);
      this.runtimeAudioSources = this.audioUrls;
      this.runtimeQualityOptions = this.qualityOptions;
      this.activeQuality = this.currentQuality;
    }
    this.danmakuOn = this.externalDanmakuOn;
    this.dmEngine.enabled = this.danmakuOn;
    Immersive.setKeepScreenOn(false);
    this.ensureAVSession();
    if (this.initialSeekSeconds > 0) {
      this.resumeAfterPrepare = this.initialSeekSeconds;
      this.shouldPlayAfterPrepare = true;
      this.curTime = this.initialSeekSeconds;
      this.playheadSec = this.initialSeekSeconds;
    }
    this.loadDanmaku();
    // 增强请求（空降/章节/拖动预览/在看人数）延到首帧后，别和首帧抢带宽；
    // 重新出现时按旧行为重取一次，避免使用上一次会话的陈旧数据。
    this.deferredLoadsDone = false;
    this.armDeferredLoads();
    this.loadGestureLevels();
    // 被其他 NavDestination 覆盖后 AVPlayer 已释放；返回时在原进度重建并保持暂停。
    if (this.player === null && this.surfaceId.length > 0) {
      this.shouldPlayAfterPrepare = false;
      this.buffering = true;
      this.initPlayer();
    }
  }

  onQualityOptionsChanged(): void {
    if (this.qualityOptions.length > 0) this.runtimeQualityOptions = this.qualityOptions;
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
    this.syncPictureInPicture();
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

  private async startPictureInPicture(): Promise<void> {
    if (this.pipStarting || this.pipActive || this.destroyed) return;
    if (!this.prepared || this.player === null || this.surfaceId.length === 0) {
      this.toast('请等待视频加载后再开启小窗');
      return;
    }
    const generation: number = ++this.pipGeneration;
    this.pipStarting = true;
    try {
      if (!pictureInPicture.isPiPEnabled()) {
        this.toast('当前设备不支持小窗播放');
        return;
      }
      this.closeSettingPanels();
      let controller: pictureInPicture.PiPController | null = this.pipController;
      if (controller === null) {
        controller = await pictureInPicture.create({
          context: this.getUIContext().getHostContext() as common.UIAbilityContext,
          componentController: this.xcController,
          navigationId: 'bili_main_navigation',
          templateType: pictureInPicture.PiPTemplateType.VIDEO_PLAY,
          contentWidth: this.realVideoWidth > 0 ? this.realVideoWidth : 16,
          contentHeight: this.realVideoHeight > 0 ? this.realVideoHeight : 9,
        });
        if (generation !== this.pipGeneration || this.destroyed) return;
        this.pipController = controller;
        controller.setAutoStartEnabled(false);
        controller.on('stateChange', (state: pictureInPicture.PiPState): void => {
          if (this.pipController !== controller || this.destroyed) return;
          if (state === pictureInPicture.PiPState.ABOUT_TO_START || state === pictureInPicture.PiPState.STARTED) {
            this.pipActive = true;
            this.pipRestoring = false;
            this.syncPictureInPicture();
          } else if (state === pictureInPicture.PiPState.ABOUT_TO_RESTORE) {
            this.pipRestoring = true;
          } else if (state === pictureInPicture.PiPState.STOPPED || state === pictureInPicture.PiPState.ERROR) {
            this.pipActive = false;
            this.pipStarting = false;
            if (!this.appInBackground) this.pipRestoring = false;
            if (!this.pipRestoring) this.onAppBackgroundChanged();
          }
        });
        controller.on('controlEvent', (event: pictureInPicture.ControlEventParam): void => {
          if (this.pipController !== controller || this.destroyed) return;
          if (event.controlType === pictureInPicture.PiPControlType.VIDEO_PLAY_PAUSE && event.status !== undefined) {
            const play: boolean = event.status === pictureInPicture.PiPControlStatus.PLAY;
            if (play !== this.playing) this.togglePlay();
            this.syncPictureInPicture();
          }
        });
      }
      await controller.startPiP();
      if (generation !== this.pipGeneration || this.destroyed) {
        // release 可能先于 startPiP 完成；完成后再次停止，避免孤立系统窗口。
        await controller.stopPiP().catch(() => {});
        return;
      }
      this.syncPictureInPicture();
    } catch (e) {
      if (generation === this.pipGeneration && !this.destroyed) {
        this.pipActive = false;
        this.toast('小窗启动失败，请检查系统画中画权限后重试');
      }
    } finally {
      if (generation === this.pipGeneration) {
        this.pipStarting = false;
        if (!this.destroyed && this.appInBackground && !this.pipActive) this.onAppBackgroundChanged();
      }
    }
  }

  private syncPictureInPicture(): void {
    if (this.pipController === null) return;
    try {
      this.pipController.updatePiPControlStatus(pictureInPicture.PiPControlType.VIDEO_PLAY_PAUSE,
        this.playing ? pictureInPicture.PiPControlStatus.PLAY : pictureInPicture.PiPControlStatus.PAUSE);
      if (this.realVideoWidth > 0 && this.realVideoHeight > 0) {
        this.pipController.updateContentSize(this.realVideoWidth, this.realVideoHeight);
      }
    } catch (_) {}
  }

  private releasePictureInPicture(): void {
    ++this.pipGeneration;
    const controller: pictureInPicture.PiPController | null = this.pipController;
    this.pipController = null;
    this.pipActive = false;
    this.pipStarting = false;
    this.pipRestoring = false;
    if (controller === null) return;
    try {
      controller.off('stateChange');
      controller.off('controlEvent');
      controller.setAutoStartEnabled(false);
      controller.stopPiP().catch(() => {});
    } catch (_) {}
  }

  onAppBackgroundChanged(): void {
    if (this.destroyed) return;
    if (this.appInBackground) {
      // 画中画异步启动期间也可能先收到后台通知，必须保留双轨播放。
      if (this.pipActive || this.pipStarting || this.pipRestoring) return;
      if (this.backgroundPlaybackEnabled) this.enterBackgroundAudioOnly();
      else if (this.playing) this.togglePlay();
    } else {
      this.pipRestoring = false;
      this.leaveBackgroundAudioOnly();
    }
  }

  private setBackgroundPlayback(next: boolean): void {
    AppStorage.setOrCreate<boolean>('backgroundPlaybackEnabled', next);
    AppTheme.persistBackgroundPlayback(next);
  }

  private enterBackgroundAudioOnly(): void {
    const video: media.AVPlayer | null = this.player;
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (!this.playing || video === null || !this.prepared || audio === null || !this.audioPrepared) return;
    this.backgroundAudioOnly = true;
    this.backgroundVideoResumePending = false;
    this.audioStartPending = false;
    this.cancelAudioGate();
    this.disarmFirstFrameMute();
    try {
      video.pause();
      audio.play();
      this.dmClock.pause();
      Immersive.setKeepScreenOn(false);
      this.updateAVSessionPlaybackState();
      if (DEBUG) {
        hilog.info(0x0000, 'BiliPlayback', 'background.audioOnly.enter position=%{public}d', audio.currentTime);
      }
    } catch (e) {
      this.backgroundAudioOnly = false;
      if (DEBUG) {
        hilog.error(0x0000, 'BiliPlayback', 'background.audioOnly.enter.error %{public}s', String(e));
      }
    }
  }

  private leaveBackgroundAudioOnly(): void {
    if (!this.backgroundAudioOnly) return;
    const video: media.AVPlayer | null = this.player;
    const audio: media.AVPlayer | null = this.audioPlayer;
    const resume: boolean = this.playing;
    const targetMs: number = audio !== null ? audio.currentTime : Math.floor(this.playheadSec * 1000);
    this.backgroundAudioOnly = false;
    this.backgroundVideoResumePending = resume;
    if (video === null || !this.prepared) {
      this.backgroundVideoResumePending = false;
      return;
    }
    const targetSec: number = Math.max(0, targetMs / 1000);
    this.playheadSec = targetSec;
    this.curTime = targetSec;
    this.onProgress(targetSec);
    this.lastAudioSyncAtMs = -1;
    this.seekLocked = true;
    // 让统一 seek 状态机暂停并校准双轨；播放中的会话在 seekDone 后恢复视频与音频。
    this.playing = false;
    this.seekCtl?.request(targetMs, true, resume);
    if (!resume) this.updateAVSessionPlaybackState();
    if (DEBUG) {
      hilog.info(0x0000, 'BiliPlayback',
        'background.audioOnly.leave position=%{public}d resume=%{public}s', targetMs, String(resume));
    }
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
    if (ctl.loading && index === ctl.index) return;
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
    if (ctl.loading && index === ctl.index) return;
    ctl.changeSubtitle(index);
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
    const request: number = this.sourceRequests.next();
    this.qualityLoading = false;
    this.releaseSeekPreview();
    this.invalidatePlayerCreation();
    this.seekCtl?.cancel();
    this.backgroundAudioOnly = false;
    this.backgroundVideoResumePending = false;
    this.audioStartPending = false;
    this.cancelAudioGate();
    this.cancelFirstFrameMute(false);
    this.seekRecoveryActive = false;
    this.seekRecoveryCoverVisible = false;
    const oldPlayer: media.AVPlayer | null = this.player;
    const oldAudioPlayer: media.AVPlayer | null = this.audioPlayer;
    this.player = null;
    this.audioPlayer = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.playing = false;
    this.firstFrameShown = false;
    this.firstRenderReady = false;
    this.buffering = true;
    this.errorText = '';
    this.curTime = 0;
    this.playheadSec = 0;
    this.duration = 0;
    this.sourceIndex = 0;
    this.audioSourceIndex = 0;
    this.resumeAfterPrepare = -1;
    this.shouldPlayAfterPrepare = true;
    this.runtimeSources = this.videoUrls.length > 0 ? this.videoUrls : (this.videoUrl.length > 0 ? [this.videoUrl] : []);
    this.runtimeAudioSources = this.audioUrls;
    this.runtimeQualityOptions = this.qualityOptions;
    this.activeQuality = this.currentQuality;
    this.subtitleText = '';
    this.subtitleCtl?.reset();
    // 换源立即作废旧视频的空降片段与章节：若等新首帧后的异步加载返回才清，
    // 窗口期内新视频命中旧片段时间区间会误自动跳段、进度条短暂显示旧章节。
    this.sponsorCtl.invalidateForSourceChange();
    this.chapters = [];
    this.dmClock.stop(true);
    this.dmEngine.list = [];
    this.dmEngine.cursor = 0;
    this.seekLocked = false;
    this.endScreenOpen = false;
    this.onPlayingChange(false);
    if (oldPlayer !== null) {
      try {
        await oldPlayer.release();
      } catch (e) {
      }
    }
    if (oldAudioPlayer !== null) {
      try {
        await oldAudioPlayer.release();
      } catch (e) {
      }
    }
    // await 期间组件可能已销毁（release 已执行），此时再 initPlayer 会泄漏无人释放的 AVPlayer。
    if (this.destroyed || !this.sourceRequests.isCurrent(request)) return;
    this.dmLoadedCid = -1;
    this.loadDanmaku();
    // 换源后这些增强请求都属于新 cid，但同样要排在新首帧之后。
    this.deferredLoadsDone = false;
    this.armDeferredLoads();
    await this.initPlayer();
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
    this.sourceRequests.invalidate();
    this.invalidatePlayerCreation();
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    this.endHoldSpeed();
    this.sponsorCtl.clearNoticeTimer();
    this.resumeAfterPrepare = this.playheadSec;
    this.shouldPlayAfterPrepare = false;
    if (this.seekCtl !== null) this.seekCtl.seekResumePlaying = false;
    this.muteImmediately();
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

  onPlaybackStopRequested(): void {
    // 导航转场开始即静音并暂停；真正离开组件时再释放，返回后才能从原进度重建。
    const video: media.AVPlayer | null = this.player;
    const audio: media.AVPlayer | null = this.audioPlayer;
    this.shouldPlayAfterPrepare = false;
    if (this.seekCtl !== null) this.seekCtl.seekResumePlaying = false;
    this.muteImmediately();
    // 取消首帧门控，避免暂停期间的 seekDone 再把音频轨单独放出来。
    this.audioStartPending = false;
    this.cancelAudioGate();
    this.cancelFirstFrameMute(false);
    this.seekRecoveryActive = false;
    this.seekRecoveryCoverVisible = false;
    try {
      if (video !== null && this.prepared) video.pause();
      if (audio !== null && this.audioPrepared) audio.pause();
    } catch (e) {
      // 状态切换边界可能已由系统暂停。
    }
    this.playing = false;
    this.showControls = true;
    this.dmClock.pause();
    this.onPlayingChange(false);
    // pause 完成后恢复音量；播放器仍保持暂停，返回点击继续时声音正常。
    if (this.volumeRestoreTimer >= 0) clearTimeout(this.volumeRestoreTimer);
    this.volumeRestoreTimer = setTimeout(() => {
      this.volumeRestoreTimer = -1;
      if (this.destroyed) return;
      try {
        const restoreVolume: number = this.sponsorCtl.isMuted() ? 0 : 1;
        if (this.player === video && video !== null && this.prepared) video.setVolume(restoreVolume);
        if (this.audioPlayer === audio && audio !== null && this.audioPrepared) audio.setVolume(restoreVolume);
      } catch (e) {
      }
    }, 100);
  }

  private muteImmediately(): void {
    try {
      if (this.player !== null && this.prepared) this.player.setVolume(0);
      if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setVolume(0);
    } catch (e) {
      // 播放器正处于切源/释放边界时无需重复处理。
    }
  }

  private restoreUserVolume(): void {
    try {
      const restoreVolume: number = this.sponsorCtl.isMuted() ? 0 : 1;
      if (this.player !== null && this.prepared) this.player.setVolume(restoreVolume);
      if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setVolume(restoreVolume);
    } catch (e) {
      // 播放器正处于切源/释放边界时无需重复处理。
    }
  }

  /** 新 seek 接管播放器前清掉旧的首帧/音轨门控；旧回调不得恢复声音或误判完成。 */
  private preparePlayersForSeek(targetMs: number, resumePlaying: boolean): void {
    this.cancelFirstFrameMute(false);
    this.cancelAudioGate();
    this.audioDriftSamples = 0;
    this.audioStartPending = false;
    this.seekRecoveryActive = resumePlaying;
    this.seekRecoveryCoverVisible = false;
    // 快进按钮通常没有目标预览帧；旧拖动残留帧不能被拿来遮住本次 seek。
    if (this.seekPreviewSeconds < 0 || Math.abs(this.seekPreviewSeconds * 1000 - targetMs) > 1500) {
      this.seekPreviewFrame = null;
    }
    if (resumePlaying) this.muteImmediately();
    if (DEBUG) {
      hilog.info(0x0000, 'BiliPlayback',
        'seek.dispatch target=%{public}d resume=%{public}s', targetMs, String(resumePlaying));
    }
  }

  /** 起播/恢复播放前调用：双轨静音并等目标附近的首个 timeUpdate，超时后安全恢复。 */
  private armFirstFrameMute(targetMs: number = -1, fallbackMs: number = 900): void {
    if (this.firstFrameMuteTimer >= 0) clearTimeout(this.firstFrameMuteTimer);
    this.firstFrameMuteArmed = true;
    this.firstFrameMuteTargetMs = targetMs;
    this.muteImmediately();
    this.firstFrameMuteTimer = setTimeout(() => {
      this.firstFrameMuteTimer = -1;
      this.disarmFirstFrameMute();
    }, fallbackMs);
  }

  private cancelFirstFrameMute(restore: boolean): void {
    if (this.firstFrameMuteTimer >= 0) {
      clearTimeout(this.firstFrameMuteTimer);
      this.firstFrameMuteTimer = -1;
    }
    this.firstFrameMuteArmed = false;
    this.firstFrameMuteTargetMs = -1;
    if (restore) this.restoreUserVolume();
  }

  /** 过滤 seek 前排队的旧 timeUpdate；关键帧定位允许与请求位置存在一个 GOP 的偏差。 */
  private canReleaseFrameMute(timeMs: number): boolean {
    if (!this.firstFrameMuteArmed) return false;
    if (this.firstFrameMuteTargetMs < 0) return timeMs > 50;
    return Math.abs(timeMs - this.firstFrameMuteTargetMs) <= 1200;
  }

  /** 首帧已上屏（或兜底超时）：恢复用户手势音量。未武装时不写音量，避免与离页临时静音互踩。 */
  private disarmFirstFrameMute(): void {
    if (!this.firstFrameMuteArmed) return;
    this.cancelFirstFrameMute(true);
    if (this.seekRecoveryActive) {
      this.seekRecoveryActive = false;
      this.seekRecoveryCoverVisible = false;
      this.buffering = false;
      if (this.playing) this.dmClock.start();
    }
  }

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

  async loadVideoChapters(): Promise<void> {
    const aid: number = this.aid;
    const bvid: string = this.bvid;
    const cid: number = this.cid;
    try {
      const chapters: Array<VideoChapter> = await BiliApi.getVideoChapters(aid, bvid, cid);
      if (this.destroyed || this.aid !== aid || this.bvid !== bvid || this.cid !== cid) return;
      this.chapters = chapters;
    } catch (e) {
      // 章节请求失败时保留普通进度条，不影响播放。
    }
  }

  async loadDanmaku(): Promise<void> {
    // 同一 cid 不重复加载；先占位再 await 的写法同时挡住 aboutToAppear 与换源触发的并发加载。
    const cid: number = this.cid;
    if (this.dmLoadedCid === cid) return;
    this.dmLoadedCid = cid;
    this.dmSegLoaded.clear();
    this.dmSegLoading.clear();
    this.dmSegFallback = false;
    this.dmSegLoading.add(0);
    try {
      // 优先 protobuf 分段接口（每 6 分钟一段）；首段失败才回退 XML 整段。
      const first: Array<DanmakuItem> | null = await BiliApi.getDanmakuSeg(cid, this.aid, 1);
      if (this.destroyed || this.dmLoadedCid !== cid) return;
      if (first === null) {
        this.dmSegFallback = true;
        const list: Array<DanmakuItem> = await BiliApi.getDanmaku(cid);
        if (this.destroyed || this.dmLoadedCid !== cid) return;
        list.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time);
        this.dmEngine.lastPlayerTime = this.playheadSec;
        this.dmEngine.setList(list);
        return;
      }
      this.dmSegLoaded.add(0);
      this.mergeDanmakuSegment(first);
      // 首屏并行预取第 2 段；时长未知时不限制段数，空段兜底。
      const total: number = this.danmakuSegmentTotal();
      if (total !== 1) {
        this.ensureDanmakuSegment(1);
      }
    } catch (e) {
      // 失败后允许下一次进入/换源重新请求，而不是把 cid 永久标记为已加载。
      if (!this.destroyed && this.dmLoadedCid === cid) this.dmLoadedCid = -1;
    } finally {
      this.dmSegLoading.delete(0);
    }
  }

  /** 弹幕分段总数：时长未知时返回 0，表示不限制段数（靠空段响应兜底）。 */
  private danmakuSegmentTotal(): number {
    const d: number = this.videoDuration > 0 ? this.videoDuration : this.duration;
    return d > 0 ? Math.ceil(d / DM_SEGMENT_SECONDS) : 0;
  }

  /** 分段弹幕合入全局有序列表；游标重定位到播放头之后，避免重放已喷出的弹幕。 */
  private mergeDanmakuSegment(items: Array<DanmakuItem>): void {
    this.dmEngine.lastPlayerTime = this.playheadSec;
    this.dmEngine.appendSorted(items);
    if (DEBUG) hilog.info(0x0000, 'BiliPlayback',
      'danmaku.segment cid=%{public}d added=%{public}d total=%{public}d',
      this.cid, items.length, this.dmEngine.list.length);
  }

  /** 拉取指定分段（0 基）；已加载/加载中自动去重，失败不标记，播放头再次经过时重试。 */
  private ensureDanmakuSegment(index: number): void {
    if (this.dmSegFallback || this.cid <= 0 || index < 0) return;
    const total: number = this.danmakuSegmentTotal();
    if (total > 0 && index >= total) return;
    if (this.dmSegLoaded.has(index) || this.dmSegLoading.has(index)) return;
    this.dmSegLoading.add(index);
    const cid: number = this.cid;
    BiliApi.getDanmakuSeg(cid, this.aid, index + 1)
      .then((items: Array<DanmakuItem> | null) => {
        this.dmSegLoading.delete(index);
        if (this.destroyed || this.dmLoadedCid !== cid) return;
        if (items === null) return;
        this.dmSegLoaded.add(index);
        this.mergeDanmakuSegment(items);
      })
      .catch(() => {
        this.dmSegLoading.delete(index);
      });
  }

  /** 播放头推进时的分段预取：进入新段或逼近段尾（提前 30 秒）时拉取下一段。 */
  private prefetchDanmakuSegments(now: number): void {
    if (this.dmSegFallback || this.cid <= 0 || this.dmLoadedCid !== this.cid) return;
    const current: number = Math.floor(now / DM_SEGMENT_SECONDS);
    this.ensureDanmakuSegment(current);
    if (now + 30 >= (current + 1) * DM_SEGMENT_SECONDS) {
      this.ensureDanmakuSegment(current + 1);
    }
  }

  // XComponent 就绪后初始化播放器
  onSurfaceReady(): void {
    this.surfaceId = this.xcController.getXComponentSurfaceId();
    this.initPlayer();
  }

  /** AVPlayer 进入 playing 不等于 Surface 已有画面；两项都满足后才交叉淡出封面。 */
  private revealFirstFrameIfReady(): void {
    if (!this.firstFrameShown && this.playing && this.firstRenderReady) {
      this.firstFrameShown = true;
      this.onFirstFrameShown();
      // 首帧已经出画，增强请求现在才允许占用带宽。
      this.scheduleDeferredLoads();
    }
  }

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
    this.loadVideoChapters();
    this.seekPreviewCtl.preload(this.aid, this.bvid, this.cid);
    this.loadOnlineTotal();
  }

  async initPlayer(): Promise<void> {
    if (this.destroyed || this.player !== null || this.playerCreating) {
      return;
    }
    const generation: number = ++this.playerCreateGeneration;
    this.playerCreating = true;
    try {
      const p: media.AVPlayer = await media.createAVPlayer();
      if (this.destroyed || generation !== this.playerCreateGeneration) {
        try {
          await p.release();
        } catch (e) {
        }
        return;
      }
      this.player = p;
      this.playerCreating = false;
      // 官方状态机模式：先挂监听再 setMediaSource，initialized 后再 prepare
      p.on('stateChange', (state: media.AVPlayerState) => {
        if (this.player !== p) return;
        if (state === 'initialized') {
          p.surfaceId = this.surfaceId;
          p.prepare();
        } else if (state === 'prepared') {
          this.prepared = true;
          this.errorText = '';
          this.applyVideoScaleType();
          this.reportVideoSize(p);
          try {
            p.setPlaybackRate(this.playbackRate);
            p.setVolume(this.sponsorCtl.isMuted() ? 0 : 1);
          } catch (e) {
            // 某些视频解码器不支持非常用倍速，保持 1x 即可。
          }
          this.tryStartPreparedPlayers();
        } else if (state === 'playing') {
          this.backgroundVideoResumePending = false;
          this.resumeTransitionActive = false;
          this.playing = true;
          this.revealFirstFrameIfReady();
          this.onPlayingChange(true);
          this.scheduleControlsHide();
          this.dmClock.start();
          this.buffering = false;
          this.ensureAVSession();
          this.updateAVSessionPlaybackState();
          Immersive.setKeepScreenOn(true);
        } else if (state === 'paused' && (this.backgroundAudioOnly || this.backgroundVideoResumePending)) {
          // 后台音乐模式只暂停视频轨；逻辑播放态和 AVSession 仍由音频轨维持。
          this.dmClock.pause();
          Immersive.setKeepScreenOn(false);
        } else if (state === 'paused' && ((this.seekCtl?.seekInFlight ?? false) || this.seekRecoveryActive)) {
          // seek 内部暂停只是解码状态切换，不能把逻辑播放态、系统媒体会话和控制栏改成“用户暂停”。
          this.dmClock.pause();
        } else if (state === 'paused' || state === 'completed') {
          this.resumeTransitionActive = false;
          this.playing = false;
          this.showControls = true;
          if (this.hideTimer >= 0) {
            clearTimeout(this.hideTimer);
            this.hideTimer = -1;
          }
          this.onPlayingChange(false);
          this.dmClock.pause();
          this.updateAVSessionPlaybackState();
          Immersive.setKeepScreenOn(false);
            if (state === 'completed') {
            if (this.playMode === 2) {
              // 单集循环：从头自动重播，不出现结束画面。
              this.endReplay();
            } else {
              // 自然播完：在播放区弹出「推荐/重播/分享」结束画面（覆盖整个视频播放区，不切全屏）。
              this.clearSeekPreviewInteraction();
              this.endScreenOpen = true;
              this.onEnded();
            }
          }
        }
      });
      // 官方首帧事件：stateChange('playing') 只表示播放器状态，不能证明 Surface 已经出画。
      p.on('startRenderFrame', () => {
        if (this.player !== p) return;
        this.firstRenderReady = true;
        this.revealFirstFrameIfReady();
        this.tryStartGatedAudio();
      });
      p.on('playbackRateDone', (rate: number) => {
        if (this.player !== p || !DEBUG) return;
        hilog.info(0x0000, 'BiliPlayback', 'video.rate.done rate=%{public}s position=%{public}d',
          String(rate), p.currentTime);
      });
      p.onMetricsEvent((events: Array<media.AVMetricsEvent>) => {
        if (this.player !== p || !DEBUG) return;
        for (let i: number = 0; i < events.length; i++) {
          // 仅记事件类型和播放位置，不输出地址、鉴权参数或完整事件载荷。
          hilog.info(0x0000, 'BiliPlayback', 'video.metric type=%{public}d position=%{public}d',
            events[i].event, events[i].playbackPosition);
        }
      });
      p.on('error', (err: BusinessError) => {
        this.handlePlayerError(p, err.message);
      });
      p.on('seekDone', (position: number) => {
        this.onVideoSeekDone(p, position);
      });
      p.on('timeUpdate', (t: number) => {
        if (this.player !== p || this.seekLocked) return;
        // 起播/seek 静音恢复点：seek 后必须等播放头落到目标附近，不能让旧位置回调提前放声。
        if (this.canReleaseFrameMute(t)) this.disarmFirstFrameMute();
        // AVPlayer 上报毫秒，播放器 UI/弹幕内部统一使用秒。
        const nextTime: number = t / 1000;
        if (this.dmEngine.lastPlayerTime > 0 && (nextTime < this.dmEngine.lastPlayerTime - 0.5 || nextTime > this.dmEngine.lastPlayerTime + 2.5)) {
          this.resetDanmakuAt(nextTime);
        }
        this.dmEngine.lastPlayerTime = nextTime;
        this.playheadSec = nextTime;
        // 音画对齐：视频播放头开始推进后，将音频先定位到同一时间点再启动。
        if (this.audioStartPending && nextTime > 0.05) {
          this.tryStartGatedAudio();
        }
        // seek 锁定时 AVPlayer 仍会上报 seek 前的位置，忽略这些旧回写，让进度条钉在目标值。
        if (!this.seekLocked && Math.floor(nextTime) !== Math.floor(this.curTime)) this.curTime = nextTime;
        const systemPlaybackBucket: number = Math.floor(nextTime / 15);
        if (systemPlaybackBucket !== this.lastSystemPlaybackBucket) {
          this.lastSystemPlaybackBucket = systemPlaybackBucket;
          this.updateAVSessionPlaybackState();
        }
        if (this.timerFireAt > 0 && Date.now() >= this.timerFireAt) {
          this.timerFireAt = 0;
          this.timerMinutes = 0;
          this.pauseForTimer();
        }
        this.onProgress(nextTime);
        this.updateSubtitle(nextTime);
        this.spawnDanmaku(nextTime);
        // 弹幕分段预取：进入新段或逼近段尾时拉取下一段（XML 兜底模式下为空操作）。
        this.prefetchDanmakuSegments(nextTime);
        if (this.sponsorCtl.maybeSkipSponsor(nextTime)) return;
        this.checkAudioSync(t);
      });
      p.on('durationUpdate', (d: number) => {
        this.duration = d / 1000;
        this.updateAVSessionMetadata();
      });
      let bufferingAudioPause: Promise<void> | null = null;
      let bufferGeneration: number = 0;
      let speedBufferTimer: number = -1;
      const pauseForBuffer = (): void => {
        // seek 的短暂缓冲由延迟提示管理，快速定位不闪 loading。
        if ((this.seekCtl?.seekInFlight ?? true) === false) this.buffering = true;
        this.dmClock.pause();
        const audio: media.AVPlayer | null = this.audioPlayer;
        if (audio !== null && this.audioPrepared && this.playing &&
          !(this.seekCtl?.seekInFlight ?? true) && bufferingAudioPause === null) {
          this.cancelAudioGate();
          audio.setVolume(0);
          bufferingAudioPause = audio.state === 'playing' ? audio.pause().catch(() => {}) : Promise.resolve();
        }
      };
      p.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
        if (this.player !== p || this.backgroundAudioOnly) return;
        if (infoType === media.BufferingInfoType.BUFFERING_START) {
          bufferGeneration++;
          // 切速时短暂重新排帧不立即暂停音轨；真正持续的缓冲最多延迟 180ms 处理。
          if (Date.now() < this.speedTransitionUntilMs) {
            if (speedBufferTimer < 0) {
              speedBufferTimer = setTimeout(() => {
                speedBufferTimer = -1;
                if (this.player === p && !this.backgroundAudioOnly) pauseForBuffer();
              }, 180);
            }
          } else {
            pauseForBuffer();
          }
        } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
          if (speedBufferTimer >= 0) {
            clearTimeout(speedBufferTimer);
            speedBufferTimer = -1;
          }
          const completedBuffer: number = bufferGeneration;
          const paused: Promise<void> | null = bufferingAudioPause;
          bufferingAudioPause = null;
          if (paused !== null) {
            paused.then(() => {
              if (this.player !== p || completedBuffer !== bufferGeneration || !this.playing ||
                this.backgroundAudioOnly || this.seekLocked || this.buffering) return;
              this.gateAudioStart();
              this.tryStartGatedAudio();
            });
          }
          // seek 尚未完成音轨对齐时不能提前隐藏 loading 或恢复弹幕时钟。
          if ((this.seekCtl?.seekInFlight ?? true) === false && !this.seekRecoveryActive) {
            this.buffering = false;
            this.dmClock.start();
          }
        }
      });
      p.on('videoSizeChange', (width: number, height: number) => {
        if (this.player !== p || height <= 0 || width <= 0) return;
        this.realVideoWidth = width;
        this.realVideoHeight = height;
        this.syncPictureInPicture();
        this.onVideoSizeChange(width, height);
      });
      const sourceUrl: string = this.currentSourceUrl();
      if (sourceUrl.length === 0) {
        this.errorText = '无法播放：播放地址为空';
        await p.release();
        this.player = null;
        return;
      }
      const source: media.MediaSource = media.createMediaSourceWithUrl(sourceUrl, this.playbackHeaders());
      // 音轨初始化不再 await：音/视频两条握手并行，起播耗时从“串行之和”降为“较慢一路”。
      // tryStartPreparedPlayers 会等到两条轨都 prepared 才开播，并行不会引入竞态。
      if (this.runtimeAudioSources.length > 0) {
        this.initAudioPlayer(generation).catch(() => {
          // initAudioPlayer 内部已把 setMediaSource 失败收敛到 handleAudioPlayerError；
          // 这里只兜底清理残留引用，防止 tryStartPreparedPlayers 因音轨未就绪而永久等待。
          // generation 已变说明有新一轮重建在途，动它的引用反而会破坏新初始化。
          if (this.destroyed || generation !== this.playerCreateGeneration || this.retryingSource) return;
          if (this.audioPlayer !== null && !this.audioPrepared && this.errorText.length === 0) {
            this.audioPlayer = null;
            this.tryStartPreparedPlayers();
          }
        });
      }
      if (this.destroyed || generation !== this.playerCreateGeneration || this.player !== p) return;
      await p.setMediaSource(source, this.videoPlaybackStrategy(this.resumeAfterPrepare <= 0 && this.initialSeekSeconds <= 0));
    } catch (e) {
      if (generation === this.playerCreateGeneration) this.playerCreating = false;
      if (this.destroyed || generation !== this.playerCreateGeneration) return;
      const msg: string = (e as Error)?.message ?? JSON.stringify(e);
      const failedPlayer: media.AVPlayer | null = this.player;
      if (failedPlayer !== null && this.sourceIndex + 1 < this.sourceCount()) {
        await this.handlePlayerError(failedPlayer, msg);
        return;
      }
      this.errorText = '无法播放：' + msg.substring(0, 120);
    }
  }

  private sourceCount(): number {
    return this.runtimeSources.length;
  }

  private currentSourceUrl(): string {
    return PlayerPlaybackConfig.sourceUrl(this.runtimeSources, this.sourceIndex);
  }

  private currentAudioSourceUrl(): string {
    return PlayerPlaybackConfig.sourceUrl(this.runtimeAudioSources, this.audioSourceIndex);
  }

  private videoPlaybackStrategy(showFirstFrame: boolean = true): media.PlaybackStrategy {
    return PlayerPlaybackConfig.videoStrategy(showFirstFrame);
  }

  private audioPlaybackStrategy(): media.PlaybackStrategy {
    return PlayerPlaybackConfig.audioStrategy();
  }

  private playbackHeaders(): Record<string, string> {
    return PlayerPlaybackConfig.playbackHeaders();
  }

  private async initAudioPlayer(generation: number): Promise<void> {
    if (this.audioPlayer !== null || this.runtimeAudioSources.length === 0) return;
    const sourceUrl: string = this.currentAudioSourceUrl();
    if (sourceUrl.length === 0) return;
    const audio: media.AVPlayer = await media.createAVPlayer();
    if (this.destroyed || generation !== this.playerCreateGeneration || this.player === null) {
      try {
        await audio.release();
      } catch (e) {
      }
      return;
    }
    this.audioPlayer = audio;
    this.audioPrepared = false;
    audio.on('stateChange', (state: media.AVPlayerState) => {
      if (this.audioPlayer !== audio) return;
      if (state === 'initialized') {
        audio.prepare();
      } else if (state === 'prepared') {
        this.audioPrepared = true;
        try {
          audio.setPlaybackRate(this.playbackRate);
          audio.setVolume(this.sponsorCtl.isMuted() ? 0 : 1);
        } catch (e) {
          // 倍速不被音频解码器支持时，设置入口会统一回退到 1x。
        }
        this.tryStartPreparedPlayers();
      } else if (state === 'completed' && this.backgroundAudioOnly) {
        this.playing = false;
        this.showControls = true;
        this.onPlayingChange(false);
        this.updateAVSessionPlaybackState();
        this.clearSeekPreviewInteraction();
        this.endScreenOpen = true;
        this.onEnded();
      }
    });
    audio.on('playbackRateDone', (rate: number) => {
      if (this.audioPlayer !== audio || !DEBUG) return;
      hilog.info(0x0000, 'BiliPlayback', 'audio.rate.done rate=%{public}s position=%{public}d',
        String(rate), audio.currentTime);
    });
    audio.on('error', (err: BusinessError) => {
      this.handleAudioPlayerError(audio, err.message);
    });
    audio.on('seekDone', (position: number) => {
      // 用户 seek 与首帧音频对齐共用 AVPlayer 的 seekDone。连续定位时，旧门控的
      // 回调可能晚于新一轮双轨 seek；在途 seek 必须优先消费回调，避免音轨永久暂停。
      if (this.seekCtl?.seekInFlight ?? false) {
        this.onAudioSeekDone(audio, position);
        return;
      }
      if (this.audioPlayer === audio && this.audioGateSeekPending) {
        // 只消费门控自己发出的 seek；用户 seek 的回调交给 PlayerSeekController。
        if (this.audioGateSeekTargetMs < 0 || Math.abs(position - this.audioGateSeekTargetMs) > 500) return;
        this.finishGatedAudioStart(audio);
        return;
      }
      this.onAudioSeekDone(audio, position);
    });
    audio.on('timeUpdate', (timeMs: number) => {
      if (this.audioPlayer !== audio || !this.backgroundAudioOnly) return;
      const nextTime: number = timeMs / 1000;
      this.playheadSec = nextTime;
      if (Math.floor(nextTime) !== Math.floor(this.curTime)) this.curTime = nextTime;
      this.onProgress(nextTime);
      const systemPlaybackBucket: number = Math.floor(nextTime / 15);
      if (systemPlaybackBucket !== this.lastSystemPlaybackBucket) {
        this.lastSystemPlaybackBucket = systemPlaybackBucket;
        this.updateAVSessionPlaybackState();
      }
      if (this.timerFireAt > 0 && Date.now() >= this.timerFireAt) {
        this.timerFireAt = 0;
        this.timerMinutes = 0;
        this.pauseForTimer();
      }
      // 后台听视频时视频轨已暂停，SponsorBlock 的跳段/静音只能由音频轨进度回调驱动；
      // skip 触发的 seekTo 走双轨定位，与前台行为一致。
      this.sponsorCtl.maybeSkipSponsor(nextTime);
    });
    try {
      const source: media.MediaSource = media.createMediaSourceWithUrl(sourceUrl, this.playbackHeaders());
      await audio.setMediaSource(source, this.audioPlaybackStrategy());
    } catch (e) {
      // setMediaSource 失败可能只走 rejection 不发 error 事件；必须收敛到统一兜底，
      // 否则 audioPlayer 残留且 audioPrepared 恒为 false，tryStartPreparedPlayers 永久等待。
      await this.handleAudioPlayerError(audio, '音轨资源加载失败');
    }
  }

  private speedTransitionUntilMs: number = 0;
  private audioSyncRate: number = -1;
  private audioSyncPlayer: media.AVPlayer | null = null;

  private resetAudioSyncRate(): void {
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (audio !== null && audio === this.audioSyncPlayer && this.audioSyncRate >= 0 && this.audioPrepared) {
      try { audio.setPlaybackRate(this.playbackRate); } catch (e) {}
    }
    this.audioSyncRate = -1;
    this.audioSyncPlayer = null;
  }

  private checkAudioSync(videoTimeMs: number): void {
    // 两轨倍速切换异步生效；稳定期间不依据瞬时钟差再次切速。
    if (Date.now() < this.speedTransitionUntilMs) {
      this.audioDriftSamples = 0;
      return;
    }
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (this.holdSpeedActive) {
      // 临时倍速由手势控制器接管，不能在 timeUpdate 中改回设置页倍速。
      this.audioSyncRate = -1;
      this.audioSyncPlayer = null;
      this.audioDriftSamples = 0;
      return;
    }
    if (!this.playing || this.backgroundAudioOnly || this.buffering || this.firstFrameMuteArmed ||
      this.audioStartPending || this.audioGateSeekPending || this.seekLocked ||
      (this.seekCtl?.seekInFlight ?? true) || audio === null || !this.audioPrepared || audio.state !== 'playing') {
      this.audioDriftSamples = 0;
      this.resetAudioSyncRate();
      return;
    }
    const driftMs: number = audio.currentTime - (this.player?.currentTime ?? videoTimeMs);
    if (Math.abs(driftMs) <= 100) {
      this.audioDriftSamples = 0;
      this.resetAudioSyncRate();
      return;
    }
    // 350ms 才开始调整，回到 100ms 内停止，避免时钟回调抖动导致来回切速。
    if (Math.abs(driftMs) <= 350 && this.audioSyncRate < 0) {
      this.audioDriftSamples = 0;
      return;
    }
    this.audioDriftSamples++;
    const nowMs: number = Date.now();
    if (this.audioDriftSamples < 3 || nowMs - this.lastAudioSyncAtMs < 3000) return;
    this.audioDriftSamples = 0;
    // 连续播放期间不再静音、pause 或 seek；以最多 3% 的速度差逐步收敛。
    const rate: number = Math.max(0.125, Math.min(8, this.playbackRate * (driftMs > 0 ? 0.97 : 1.03)));
    this.lastAudioSyncAtMs = nowMs;
    if (this.audioSyncPlayer === audio && Math.abs(this.audioSyncRate - rate) < 0.001) return;
    try {
      audio.setPlaybackRate(rate);
      this.audioSyncPlayer = audio;
      this.audioSyncRate = rate;
    } catch (e) {
      // 设备不支持微调时保留连续播放，不能退回循环暂停/定位。
      this.resetAudioSyncRate();
    }
  }

  private invalidatePlayerCreation(): void {
    this.playerCreateGeneration++;
    this.playerCreating = false;
  }

  private tryStartPreparedPlayers(): void {
    const video: media.AVPlayer | null = this.player;
    if (video === null || !this.prepared) return;
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (audio !== null && !this.audioPrepared) return;
    // 清除可能残留的上一次起播静音（重建/换源路径会重新武装）。
    this.disarmFirstFrameMute();
    if (this.resumeAfterPrepare > 0) {
      const resumeAt: number = this.resumeAfterPrepare;
      const resumePlaying: boolean = this.shouldPlayAfterPrepare;
      const recoveringSeek: boolean = this.seekRecoveryAttempts > 0;
      this.resumeAfterPrepare = -1;
      this.shouldPlayAfterPrepare = false;
      if (this.seekCtl !== null) this.seekCtl.seekResumePlaying = resumePlaying;
      // 重建/切清晰度后也走同一串行 seek，不能在 seekDone 前让两条轨道各自起播。
      // seek 超时重建后的这一次定位必须保留重试计数，否则会重新进入无限重建循环。
      this.seekTo(resumeAt, !recoveringSeek, !recoveringSeek);
      return;
    }
    this.resumeAfterPrepare = -1;
    if (this.shouldPlayAfterPrepare) {
      // 起播先静音，首个 timeUpdate（首帧上屏）后放声，避免先闻其声后见画面。
      this.armFirstFrameMute();
      video.play();
      // 音频不随视频同时 play：等视频首帧上屏后再启动，避免先闻其声。
      this.gateAudioStart();
    }
  }

  /** 起播时先等待视频播放头推进，禁止超时后绕过画面门控单独播放音频。 */
  private gateAudioStart(): void {
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (audio === null || !this.audioPrepared) return;
    this.cancelAudioGate();
    this.audioStartPending = true;
  }

  /** 视频已开始推进：先把尚未播放的 DASH 音轨定位到当前视频时间，再在 seekDone 后启动。 */
  private tryStartGatedAudio(): void {
    if (!this.audioStartPending || this.audioGateSeekPending || !this.playing) return;
    const video: media.AVPlayer | null = this.player;
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (video === null || !this.prepared || audio === null || !this.audioPrepared) return;
    const targetMs: number = Math.max(0, video.currentTime);
    if (Math.abs(audio.currentTime - targetMs) > 80) {
      this.alignGatedAudio(video, audio);
      return;
    }
    this.finishGatedAudioStart(audio);
  }

  private audioGateGeneration: number = 0;

  /** 自动恢复只暂停、定位音轨；用户拖动仍由双轨 seek 状态机处理。 */
  private async alignGatedAudio(video: media.AVPlayer, audio: media.AVPlayer): Promise<void> {
    const generation: number = this.audioGateGeneration;
    this.audioGateSeekPending = true;
    try {
      audio.setVolume(0);
      if (audio.state === 'playing') await audio.pause();
      if (generation !== this.audioGateGeneration || this.player !== video || this.audioPlayer !== audio ||
        !this.playing || this.seekLocked || this.backgroundAudioOnly) return;
      this.audioGateSeekTargetMs = Math.max(0, video.currentTime);
      audio.seek(this.audioGateSeekTargetMs);
      this.audioGateTimer = setTimeout(() => {
        this.audioGateTimer = -1;
        if (generation !== this.audioGateGeneration || this.audioPlayer !== audio || !this.audioGateSeekPending) return;
        if (Math.abs(audio.currentTime - this.audioGateSeekTargetMs) <= 500) {
          this.finishGatedAudioStart(audio);
        } else {
          this.cancelAudioGate();
          this.handleAudioPlayerError(audio, '音轨定位超时');
        }
      }, 1500);
    } catch (e) {
      if (generation !== this.audioGateGeneration || this.audioPlayer !== audio) return;
      this.cancelAudioGate();
      this.handleAudioPlayerError(audio, '音轨同步失败');
    }
  }

  private finishGatedAudioStart(audio: media.AVPlayer): void {
    if (this.audioGateTimer >= 0) {
      clearTimeout(this.audioGateTimer);
      this.audioGateTimer = -1;
    }
    this.audioGateSeekPending = false;
    this.audioGateSeekTargetMs = -1;
    this.audioStartPending = false;
    if (this.audioPlayer !== audio || !this.audioPrepared || !this.playing) return;
    try {
      this.restoreUserVolume();
      audio.play();
    } catch (e) {
    }
  }

  private cancelAudioGate(): void {
    this.resetAudioSyncRate();
    this.audioGateGeneration++;
    if (this.audioGateTimer >= 0) {
      clearTimeout(this.audioGateTimer);
      this.audioGateTimer = -1;
    }
    this.audioGateSeekPending = false;
    this.audioGateSeekTargetMs = -1;
    this.audioStartPending = false;
  }

  async changeQuality(qn: number): Promise<void> {
    if (this.destroyed) return;
    if (this.qualityLoading) return;
    if (qn === this.activeQuality) {
      PlayerQualityPreference.remember(qn);
      this.closeSettingPanels();
      return;
    }
    const request: number = this.sourceRequests.next();
    const sourceVersion: number = this.sourceVersion;
    const cid: number = this.cid;
    this.qualityLoading = true;
    try {
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(this.aid, this.bvid, this.cid, qn, this.epId);
      if (this.destroyed || !this.sourceRequests.isCurrent(request) ||
        sourceVersion !== this.sourceVersion || cid !== this.cid) return;
      if (info === null || info.urls.length === 0) {
        this.errorText = '该清晰度暂时不可用';
        return;
      }
      PlayerQualityPreference.remember(qn);
      this.previewPlayback = info.isPreview;
      const oldPlayer: media.AVPlayer | null = this.player;
      const oldAudioPlayer: media.AVPlayer | null = this.audioPlayer;
      this.invalidatePlayerCreation();
      this.seekCtl?.cancel();
      this.cancelAudioGate();
      this.cancelFirstFrameMute(false);
      this.seekRecoveryActive = false;
      this.seekRecoveryCoverVisible = false;
      this.resumeAfterPrepare = this.playheadSec;
      this.shouldPlayAfterPrepare = this.playing;
      this.runtimeSources = info.urls;
      this.runtimeAudioSources = info.audioUrls;
      if (info.qualities.length > 0) this.runtimeQualityOptions = info.qualities;
      this.activeQuality = info.quality;
      this.sourceIndex = 0;
      this.audioSourceIndex = 0;
      this.player = null;
      this.audioPlayer = null;
      this.audioPrepared = false;
      this.prepared = false;
      this.playing = false;
      // 换清晰度重建播放后 surface 短暂空白：封面重新垫底，首帧上屏后再淡出。
      this.firstFrameShown = false;
      this.firstRenderReady = false;
      this.buffering = true;
      this.closeSettingPanels();
      this.dmClock.stop(false);
      if (oldPlayer !== null) {
        try {
          await oldPlayer.release();
        } catch (e) {
          // 错误状态播放器可能已经由系统释放。
        }
      }
      if (oldAudioPlayer !== null) {
        try {
          await oldAudioPlayer.release();
        } catch (e) {
          // 错误状态音频播放器可能已经由系统释放。
        }
      }
      // await 期间组件可能已销毁，此时重建播放器会泄漏。
      if (this.destroyed || !this.sourceRequests.isCurrent(request) ||
        sourceVersion !== this.sourceVersion || cid !== this.cid) return;
      await this.initPlayer();
    } catch (e) {
      if (!this.destroyed && this.sourceRequests.isCurrent(request)) this.errorText = '切换清晰度失败，请重试';
    } finally {
      // 同步抛错（如签名异常）也必须复位，否则 qualityLoading 永远卡 true。
      if (!this.destroyed && this.sourceRequests.isCurrent(request)) this.qualityLoading = false;
    }
  }

  setPlaybackSpeed(rate: number): void {
    this.audioSyncRate = -1;
    this.audioSyncPlayer = null;
    this.audioDriftSamples = 0;
    this.lastAudioSyncAtMs = Date.now();
    this.speedTransitionUntilMs = this.lastAudioSyncAtMs + 1500;
    this.playbackRate = rate;
    this.dmEngine.setPlaybackRate(rate);
    this.closeSettingPanels();
    const p: media.AVPlayer | null = this.player;
    if (p !== null && this.prepared) {
      try {
        p.setPlaybackRate(rate);
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setPlaybackRate(rate);
      } catch (e) {
        this.playbackRate = 1.0;
        this.dmEngine.setPlaybackRate(1.0);
        p.setPlaybackRate(1.0);
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setPlaybackRate(1.0);
      }
    }
  }

  private applyTemporarySpeed(rate: number): void {
    // 直接覆盖微调速率，不能先恢复旧倍速再设置目标倍速，造成一次手势两次重配。
    this.audioSyncRate = -1;
    this.audioSyncPlayer = null;
    this.audioDriftSamples = 0;
    this.lastAudioSyncAtMs = Date.now();
    this.speedTransitionUntilMs = this.lastAudioSyncAtMs + 1500;
    let videoApplied: boolean = false;
    let audioApplied: boolean = false;
    try {
      if (this.player !== null && this.prepared) {
        this.player.setPlaybackRate(rate);
        videoApplied = true;
      }
    } catch (e) {
      if (DEBUG) {
        hilog.error(0x0000, 'BiliPlayback',
          'holdSpeed.video.failed rate=%{public}s', String(rate));
      }
    }
    try {
      if (this.audioPlayer !== null && this.audioPrepared) {
        this.audioPlayer.setPlaybackRate(rate);
        audioApplied = true;
      }
    } catch (e) {
      if (DEBUG) {
        hilog.error(0x0000, 'BiliPlayback',
          'holdSpeed.audio.failed rate=%{public}s', String(rate));
      }
    }
    if (DEBUG) {
      hilog.info(0x0000, 'BiliPlayback',
        'holdSpeed.apply rate=%{public}s video=%{public}s audio=%{public}s',
        String(rate), videoApplied ? 'true' : 'false', audioApplied ? 'true' : 'false');
    }
    // 弹幕设置速度保持不变，仅让滚动位移跟随视频当前实际倍速。
    if (videoApplied) this.dmEngine.setPlaybackRate(rate);
  }

  private beginHoldSpeed(): void {
    if (this.holdEnabled === false) return;
    this.dmInteraction.cancelPending();
    if (!this.playing || !this.prepared || this.holdSpeedActive) return;
    Haptic.seek();
    this.speedCtl?.beginHold(this.playbackRate);
  }

  private endHoldSpeed(): void {
    // 长按快进松手还原正常倍速：落定震动（与按下的轻震呼应）；页面销毁等被动路径同样安全。
    if (this.holdSpeedActive) Haptic.release();
    this.speedCtl?.endHold();
  }

  private loadGestureLevels(): void {
    this.gestureCtl?.loadInitials();
  }

  private applyGestureVolume(value: number): void {
    try {
      this.systemVolumeLevel = this.systemVolume.levelForPercent(value);
    } catch (e) {}
  }

  private loadOnlineTotal(): void {
    const request: number = ++this.onlineRequest;
    const cid: number = this.cid;
    BiliApi.getOnlineTotal(this.aid, this.bvid, cid).then((total: string) => {
      if (!this.destroyed && request === this.onlineRequest && this.cid === cid) {
        this.onlineTotal = total;
        this.onOnlineCount(total);
      }
    }).catch(() => {
      if (!this.destroyed && request === this.onlineRequest) {
        this.onlineTotal = '';
        this.onOnlineCount('');
      }
    });
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
    this.seekPreviewCtl.request(seconds, this.aid, this.bvid, this.cid, this.currentSourceUrl(),
      this.playbackHeaders(),
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
    this.closeSeekPreview();
  }

  private releaseSeekPreview(): void {
    this.sliderDragging = false;
    this.gestureScrubValue = -1;
    this.scrubCtl.show(-1);
    this.seekPreviewSeconds = -1;
    this.seekPreviewCtl.release();
  }


  private handleDoubleTap(): void {
    if (this.doubleTapEnabled === false) return;
    this.dmInteraction.cancelPending();
    if (!this.prepared || this.player === null || this.endScreenOpen) return;
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

  /** 当前 CDN 失败时自动释放播放器并切换 durl.backup_url。 */
  async handlePlayerError(failedPlayer: media.AVPlayer, message: string): Promise<void> {
    if (this.player !== failedPlayer || this.retryingSource) {
      return;
    }
    if (this.sourceIndex + 1 >= this.sourceCount()) {
      // 备用线路已用尽：复位播放状态并释放仍挂在错误态的播放器，避免卡 loading。
      this.errorText = '播放出错：' + message;
      this.buffering = false;
      this.release();
      return;
    }
    this.retryingSource = true;
    this.invalidatePlayerCreation();
    this.seekCtl?.cancel();
    this.cancelAudioGate();
    this.cancelFirstFrameMute(false);
    this.seekRecoveryActive = false;
    this.seekRecoveryCoverVisible = false;
    this.resumeAfterPrepare = this.playheadSec;
    this.shouldPlayAfterPrepare = this.playing;
    this.player = null;
    const failedAudio: media.AVPlayer | null = this.audioPlayer;
    this.audioPlayer = null;
    this.audioPrepared = false;
    this.prepared = false;
    this.playing = false;
    this.firstFrameShown = false;
    this.firstRenderReady = false;
    this.buffering = false;
    this.errorText = '当前线路不可用，正在切换备用 CDN…';
    try {
      await failedPlayer.release();
    } catch (e) {
      // 错误状态的播放器可能已被系统释放，继续切线即可。
    }
    if (failedAudio !== null) {
      try {
        await failedAudio.release();
      } catch (e) {
        // 音频播放器可能也已进入错误态。
      }
    }
    // await 期间组件可能已销毁，放弃重建并复位重试标志。
    if (this.destroyed) {
      this.retryingSource = false;
      return;
    }
    this.sourceIndex++;
    this.retryingSource = false;
    await this.initPlayer();
  }

  private async handleAudioPlayerError(failedAudio: media.AVPlayer, message: string): Promise<void> {
    if (this.audioPlayer !== failedAudio || this.retryingSource) return;
    if (this.audioSourceIndex + 1 >= this.runtimeAudioSources.length) {
      this.errorText = '音频播放出错：' + message.substring(0, 100);
      return;
    }
    this.retryingSource = true;
    this.invalidatePlayerCreation();
    this.seekCtl?.cancel();
    this.cancelAudioGate();
    this.cancelFirstFrameMute(false);
    this.seekRecoveryActive = false;
    this.seekRecoveryCoverVisible = false;
    this.resumeAfterPrepare = this.playheadSec;
    this.shouldPlayAfterPrepare = this.playing;
    const video: media.AVPlayer | null = this.player;
    this.player = null;
    this.audioPlayer = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.playing = false;
    this.firstFrameShown = false;
    this.firstRenderReady = false;
    this.buffering = true;
    try {
      await failedAudio.release();
    } catch (e) {
      // ignore
    }
    if (video !== null) {
      try {
        await video.release();
      } catch (e) {
        // ignore
      }
    }
    // await 期间组件可能已销毁，放弃重建并复位重试标志。
    if (this.destroyed) {
      this.retryingSource = false;
      return;
    }
    this.audioSourceIndex++;
    this.retryingSource = false;
    await this.initPlayer();
  }

  togglePlay(): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) {
      return;
    }
    if (this.playing) {
      if (this.seekCtl !== null) this.seekCtl.seekResumePlaying = false;
      this.seekRecoveryActive = false;
      this.audioStartPending = false;
      this.cancelAudioGate();
      this.cancelFirstFrameMute(true);
      try {
        if (!this.backgroundAudioOnly) p.pause();
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.pause();
        // AVPlayer 状态回调可能滞后一帧以上；点击后立即刷新按钮，回调再做最终校准。
        this.playing = false;
        this.showControls = true;
        this.onPlayingChange(false);
        if (this.backgroundAudioOnly) this.updateAVSessionPlaybackState();
      } catch (e) {
        // 底层状态不允许暂停时保持原 UI，等待 stateChange 校准。
      }
    } else {
      if (this.appInBackground && !this.backgroundPlaybackEnabled && !this.pipActive && !this.pipStarting) return;
      if (this.appInBackground && !this.pipActive && !this.pipStarting &&
        this.audioPlayer !== null && this.audioPrepared) {
        try {
          this.backgroundAudioOnly = true;
          this.audioPlayer.play();
          this.playing = true;
          this.onPlayingChange(true);
          this.updateAVSessionPlaybackState();
        } catch (e) {
          this.backgroundAudioOnly = false;
        }
        return;
      }
      // 用户主动点击继续时先通知外层恢复完整播放器高度；首播/切清晰度不会误触发。
      this.resumeTransitionActive = this.compactMode && !this.fullscreen;
      this.onResumeRequest();
      try {
        // 恢复播放同样先静音等首帧（pause 期间画面虽在，但 resume 后首个解码帧仍可能滞后于声音）。
        this.armFirstFrameMute(Math.max(0, p.currentTime), 1200);
        p.play();
        // 音频等视频首帧上屏后再启动（同一节奏，避免先闻其声）。
        this.gateAudioStart();
        this.playing = true;
        this.onPlayingChange(true);
        this.scheduleControlsHide();
      } catch (e) {
        this.resumeTransitionActive = false;
      }
    }
  }

  /** 结束画面「重播」：从头开始再播一遍（seek 0 并恢复播放）。 */
  endReplay(): void {
    this.clearSeekPreviewInteraction();
    this.endScreenOpen = false;
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) return;
    this.resumeTransitionActive = this.compactMode && !this.fullscreen;
    this.onResumeRequest();
    try {
      this.sponsorCtl.resetForReplay();
      this.resetDanmakuAt(0);
      this.playheadSec = 0;
      this.curTime = 0;
      this.lastAudioSyncAtMs = -1;
      // resetDanmakuAt 已把游标同步到开头；保留已加载列表，避免单集循环/手动重播后
      // dmLoadedCid 仍命中去重逻辑、却因为列表被清空而整轮都没有弹幕。
      // seek 恢复播放：seek 到 0 后由 onSeekDone 回调自动 play。
      this.seekLocked = true;
      this.seekCtl?.request(0, true, true);
      this.showControls = false;
    } catch (e) {
      this.resumeTransitionActive = false;
    }
  }

  /** 结束画面关闭：回到剧终画面（保留控制层）。 */
  closeEndScreen(): void {
    this.endScreenOpen = false;
    this.showControls = true;
  }

  seekTo(positionSec: number, precise: boolean = true, resetRecoveryAttempts: boolean = true): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) return;
    const clampedRaw: number = Math.max(0, Math.min(this.duration > 0 ? this.duration : positionSec, positionSec));
    // 用户把手势/滑块拖到最末尾时，停在结尾前 0.5s，避免精确 seek 到末帧被 AVPlayer 当作
    // "自然播完"而触发自动连播切到下一视频；真正自然播完仍走 completed → onEnded 连线。
    const clamped: number = this.duration > 0 && clampedRaw >= this.duration ?
      Math.max(0, this.duration - 0.5) : clampedRaw;
    // Slider 会产生小数秒，四舍五入到最近毫秒，避免最终落点被额外向前截断。
    const targetMs: number = Math.round(clamped * 1000);
    this.resetDanmakuAt(clamped);
    this.playheadSec = clamped;
    this.curTime = clamped;
    this.onProgress(clamped);
    this.updateSubtitle(clamped);
    this.updateAVSessionPlaybackState();
    this.lastAudioSyncAtMs = -1;
    // seek 期间 AVPlayer 的 timeUpdate 仍会上报旧位置，若直接写回 curTime 会让进度条
    // 从目标值弹回旧位置再跳过去（视觉上"抖动"）。用 seek 锁让进度显示钉住目标值，
    // 等 seekDone 解锁后再跟随正常 timeUpdate。
    this.seekLocked = true;
    if (resetRecoveryAttempts) this.seekRecoveryAttempts = 0;
    this.seekCtl?.request(targetMs, precise, this.playing);
  }

  onVideoSeekDone(video: media.AVPlayer, position: number): void {
    this.seekCtl?.onVideoSeekDone(video, position);
  }

  onAudioSeekDone(audio: media.AVPlayer, position: number): void {
    this.seekCtl?.onAudioSeekDone(audio, position);
  }

  private async recoverPlayersAfterSeekStall(stalledVideo: media.AVPlayer, targetMs: number): Promise<void> {
    if (this.player !== stalledVideo) return;
    const resume: boolean = this.seekCtl?.seekResumePlaying ?? false;
    if (this.seekRecoveryAttempts >= 1) {
      this.seekCtl?.cancel();
      this.cancelAudioGate();
      this.cancelFirstFrameMute(true);
      this.seekRecoveryActive = false;
      this.seekRecoveryCoverVisible = false;
      this.seekLocked = false;
      this.buffering = false;
      try {
        if (resume && this.prepared) {
          if (stalledVideo.state !== 'playing') stalledVideo.play();
          this.gateAudioStart();
        }
      } catch (e) {
        this.errorText = '定位失败，请重试';
      }
      // 本次恢复链已经结束；下一次用户主动定位应重新获得一次恢复机会。
      this.seekRecoveryAttempts = 0;
      return;
    }
    this.seekRecoveryAttempts++;
    this.seekCtl?.cancel();
    this.cancelAudioGate();
    this.cancelFirstFrameMute(false);
    this.seekRecoveryActive = false;
    this.seekRecoveryCoverVisible = false;
    this.seekLocked = false;
    this.invalidatePlayerCreation();
    const stalledAudio: media.AVPlayer | null = this.audioPlayer;
    this.player = null;
    this.audioPlayer = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.playing = false;
    this.firstFrameShown = false;
    this.firstRenderReady = false;
    this.resumeAfterPrepare = Math.max(0, targetMs / 1000);
    this.shouldPlayAfterPrepare = resume;
    this.buffering = true;
    try {
      await stalledVideo.release();
    } catch (e) {
    }
    if (stalledAudio !== null) {
      try {
        await stalledAudio.release();
      } catch (e) {
      }
    }
    if (this.destroyed) return;
    await this.initPlayer();
  }

  toggleFullscreen(): void {
    if (this.fullscreen) {
      this.exitFullscreen();
    } else {
      this.fullscreen = true;
      this.dmEngine.fullscreen = true;
      this.restartDmLoopForViewport();
      AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', true);
      this.applyVideoScaleType();
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
    this.applyVideoScaleType();
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
  }

  applyVideoScaleType(): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) {
      return;
    }
    // 所有模式都完整等比显示：不拉伸，也不为了填满屏幕裁掉画面上下或左右内容。
    p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
  }

  private reportVideoSize(p: media.AVPlayer): void {
    // AVPlayer 在 prepared 后可读真实视频宽高。接口里的 dimension 有时缺失或只到上一个分 P，
    // 这里把解码结果回传给详情页，让播放器容器按真实画幅重新算高度，避免上下被裁。
    if (this.player !== p || p.width <= 0 || p.height <= 0) {
      return;
    }
    this.realVideoWidth = p.width;
    this.realVideoHeight = p.height;
    this.onVideoSizeChange(p.width, p.height);
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
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, () => {
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
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) return;
    try {
      if (!this.backgroundAudioOnly) p.pause();
      if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.pause();
      this.playing = false;
      this.showControls = true;
      this.onPlayingChange(false);
      if (this.backgroundAudioOnly) this.updateAVSessionPlaybackState();
    } catch (e) {
    }
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

  /** 下载只选择音画一体的 MP4 档位；1080P+ 依赖 DASH 混流，不能伪装成可直接播放的单文件。 */
  private downloadQualityOptions(): Array<VideoQualityOption> {
    const result: Array<VideoQualityOption> = [];
    for (let i: number = 0; i < this.runtimeQualityOptions.length; i++) {
      const option: VideoQualityOption = this.runtimeQualityOptions[i];
      if (option.available && option.qn > 0 && option.qn <= 80 &&
        result.findIndex((item: VideoQualityOption): boolean => item.qn === option.qn) < 0) {
        result.push(option);
      }
    }
    return result;
  }

  private downloadQualityValue(): number {
    const options: Array<VideoQualityOption> = this.downloadQualityOptions();
    if (this.downloadQuality > 0 &&
      options.some((option: VideoQualityOption): boolean => option.qn === this.downloadQuality)) {
      return this.downloadQuality;
    }
    if (this.activeQuality > 0 && this.activeQuality <= 80 &&
      options.some((option: VideoQualityOption): boolean => option.qn === this.activeQuality)) {
      return this.activeQuality;
    }
    return options.length > 0 ? options[0].qn : 64;
  }

  private downloadQualityText(): string {
    const qn: number = this.downloadQualityValue();
    const options: Array<VideoQualityOption> = this.downloadQualityOptions();
    for (let i: number = 0; i < options.length; i++) {
      if (options[i].qn === qn) return options[i].label;
    }
    return qn === 80 ? '1080P' : (qn === 64 ? '720P' : String(qn));
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
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: '下载画质（最高 1080P MP4）',
        buttons: buttons,
      }).then((result) => {
        const index: number = Number(result.index);
        if (index >= 0 && index < options.length) this.downloadQuality = options[index].qn;
      });
    } catch (e) {
      this.toast('无法打开画质选择');
    }
  }

  private safeDownloadName(value: string): string {
    const invalid: string = "\\/:*?\"'`<>|{}[]";
    let result: string = '';
    for (let i: number = 0; i < value.length; i++) {
      const ch: string = value.charAt(i);
      result += invalid.indexOf(ch) >= 0 ? '_' : ch;
    }
    const trimmed: string = result.trim();
    const safe: string = trimmed.length > 0 ? trimmed : 'BiliHarmony视频';
    return safe.substring(0, Math.min(96, safe.length));
  }

  private promptDownloadType(): void {
    if (this.downloadBusy || VideoDownloadService.isActive()) {
      this.toast('已有下载任务正在进行');
      return;
    }
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: '选择下载格式',
        buttons: [
          { text: '下载视频（MP4）', color: this.isDark ? '#E6E6E6' : '#18191C' },
          { text: '只下载音频（M4A）', color: this.isDark ? '#E6E6E6' : '#18191C' },
        ],
      }).then((result) => {
        const index: number = Number(result.index);
        if (index === 0 || index === 1) {
          this.startMediaDownload(index === 1).catch(() => {
          });
        }
      });
    } catch (e) {
      this.toast('无法打开下载格式选择');
    }
  }

  private async startMediaDownload(audioOnly: boolean): Promise<void> {
    if (this.epId > 0) {
      this.toast('番剧下载暂未开放');
      return;
    }
    if (this.downloadBusy || VideoDownloadService.isActive()) {
      this.toast('已有下载任务正在进行');
      return;
    }
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined || this.cid <= 0 || (this.aid <= 0 && this.bvid.length === 0)) {
      this.toast('当前视频信息不完整，无法下载');
      return;
    }
    this.downloadBusy = true;
    this.downloadProgress = -1;
    try {
      const requestedQuality: number = this.downloadQualityValue();
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(this.aid, this.bvid, this.cid, requestedQuality);
      if (info === null) throw new Error('暂时无法获取下载地址');
      const sourceUrls: Array<string> = audioOnly ? info.downloadAudioUrls : info.urls;
      if (audioOnly && sourceUrls.length === 0) {
        throw new Error('当前视频没有可下载的独立音轨');
      }
      if (!audioOnly && (sourceUrls.length === 0 || info.isDash)) {
        throw new Error('该画质只有 DASH 分离流，暂时无法直接保存为单个 MP4');
      }
      if (!audioOnly) {
        const mp4Source: boolean = info.format.startsWith('mp4') ||
          sourceUrls.some((url: string): boolean => url.split('?')[0].toLowerCase().endsWith('.mp4'));
        if (!mp4Source) throw new Error('该视频仅提供旧版分段格式，暂时无法保存为单个 MP4');
      }
      this.downloadQuality = info.quality;
      let baseName: string = this.videoTitle;
      if (this.videoPartTitle.trim().length > 0 && this.videoPartTitle.trim() !== this.videoTitle.trim()) {
        baseName += ' - ' + this.videoPartTitle.trim();
      }
      const identity: string = this.bvid.length > 0 ? this.bvid : 'av' + String(this.aid);
      const extension: string = audioOnly ? '.m4a' : '.mp4';
      const formatTag: string = audioOnly ? '音频' : this.downloadQualityText();
      const fileName: string = this.safeDownloadName(baseName + ' [' + identity + '] [' + formatTag + ']') + extension;
      this.showMoreMenu = false;
      this.showSideDrawer = false;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [fileName];
      options.fileSuffixChoices = [audioOnly ? '音频文件|.m4a' : '视频文件|.mp4'];
      const targets: Array<string> = await documentPicker.save(options);
      if (targets.length === 0) return;
      this.downloadBusy = true;
      this.downloadProgress = -1;
      this.toast(audioOnly ? '音频已开始下载，可在通知栏查看进度' : '视频已开始下载，可在通知栏查看进度');
      const refererId: string = this.bvid.length > 0 ? this.bvid : 'av' + String(this.aid);
      await VideoDownloadService.downloadToUri(context, sourceUrls, targets[0], fileName,
        HttpClient.getDownloadHeaders('https://www.bilibili.com/video/' + refererId),
        (received: number, total: number): void => {
          if (!this.destroyed) {
            this.downloadBusy = true;
            this.downloadProgress = total > 0 ? Math.max(0, Math.min(100,
              Math.floor(received * 100 / total))) : -1;
          }
        });
      if (!this.destroyed) this.toast(audioOnly ? '音频已保存到所选位置' : '视频已保存到所选位置');
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      // 文件选择器取消属于正常操作，不显示成网络失败。
      if (!this.destroyed && error.code !== 13900042) {
        const message: string = error.message ?? String(e);
        this.toast(message.length > 0 ? message : '下载失败，请稍后重试');
      }
    } finally {
      if (!this.destroyed) {
        this.downloadBusy = VideoDownloadService.isActive();
        this.downloadProgress = VideoDownloadService.currentProgress();
      }
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
    this.releasePictureInPicture();
    this.invalidatePlayerCreation();
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.seekCtl?.cancel();
    this.releaseSeekPreview();
    if (this.volumeRestoreTimer >= 0) {
      clearTimeout(this.volumeRestoreTimer);
      this.volumeRestoreTimer = -1;
    }
    this.audioStartPending = false;
    this.cancelAudioGate();
    this.backgroundAudioOnly = false;
    this.backgroundVideoResumePending = false;
    if (this.fullscreenExitCancel !== null) {
      this.fullscreenExitCancel();
      this.fullscreenExitCancel = null;
    }
    this.fullscreenExitPending = false;
    this.fullscreenExitAnimationStarted = false;
    this.cancelFirstFrameMute(false);
    this.seekRecoveryActive = false;
    this.seekRecoveryCoverVisible = false;
    this.audioStartPending = false;
    this.dmClock.stop(true);
    this.dmClock.release();
    this.dmEngine.clearCaches();
    Immersive.setKeepScreenOn(false);
    this.deactivateAVSession();
    const p: media.AVPlayer | null = this.player;
    if (p !== null) {
      this.player = null;
      // release 返回 Promise，同步 try/catch 捕获不到异步 rejection，需显式 catch。
      p.release().catch(() => {
        // 释放失败无需兜底，组件已脱离该播放器。
      });
    }
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (audio !== null) {
      this.audioPlayer = null;
      audio.release().catch(() => {
        // 同上。
      });
    }
    this.audioPrepared = false;
    this.prepared = false;
    this.playing = false;
    this.firstRenderReady = false;
  }

  // ===== 弹幕引擎 =====

  spawnDanmaku(now: number): void {
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
    AppTheme.persistDanmakuSettings(s);
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
          .animation({ duration: 200, curve: Curve.EaseOut })
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
          .fontSize(15)
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
              progress: this.progressDisplayTime(),
              duration: this.duration,
              chapters: this.chapters,
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
              playing: this.playing,
              danmakuOn: this.danmakuOn,
              sponsorEnabled: this.sponsorSkipEnabled,
              chapters: this.chapters,
              sponsorSegments: this.visibleSponsorSegments(),
              progress: this.progressDisplayTime(),
              duration: this.duration,
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
      onBackgroundPlaybackChange: (next: boolean) => this.setBackgroundPlayback(next),
      onPictureInPicture: () => { this.startPictureInPicture(); },
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
