/**
 * 播放器组件：AVPlayer + XComponent 渲染 + Canvas 弹幕引擎 + 手势控制
 */
import { media } from '@kit.MediaKit';
import { avSession } from '@kit.AVSessionKit';
import { PlayerAvSessionHelper } from './PlayerAvSessionHelper';
import { PlayerSubtitleController } from './PlayerSubtitleController';
import { PlayerSeekController } from './PlayerSeekController';
import { PlayerSpeedController } from './PlayerSpeedController';
import { PlayerMenuItem, PlayerSponsorItem } from './PlayerMenuItems';
import { PlayerToggleItem } from './PlayerMenuItems';
import { PlayerGestureController } from './PlayerGestureController';
import { PlayerPlaybackConfig } from './PlayerPlaybackConfig';
import { DanmakuListPanel } from './DanmakuListPanel';
import { DmFilterPanel } from './DmFilterPanel';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ActionResult, BiliApi, DanmakuItem, DmFilterRule, SponsorSegment, VideoChapter } from '../api/BiliApi';
import { UserStore } from '../common/UserStore';
import { AppTheme } from '../common/AppTheme';
import { Immersive } from '../common/Immersive';
import { formatDuration } from '../common/Utils';
import { PlayUrlInfo, SubtitleCue, SubtitleTrack, VideoQualityOption } from '../model/Models';
import { Constants } from '../common/Constants';
import { BasicDataSource } from '../common/BasicDataSource';
import { PlayerProgressBar } from './PlayerProgressBar';
import { PlayerSettingsPanel } from './PlayerSettingsPanel';
import { PlayerGestureOverlay } from './PlayerGestureOverlay';
import { PlayerFullscreenHeader } from './PlayerFullscreenHeader';
import { CONTROLS_GRADIENT_COLORS, DM_SEGMENT_SECONDS } from './PlayerDanmakuSupport';
import { PlayerDanmakuEngine } from './PlayerDanmakuEngine';
import { PlayerBottomControls } from './PlayerBottomControls';
import { PlayerPlaybackIndicator } from './PlayerPlaybackIndicator';

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
  /** 视频时长（秒，业务页详情数据）：弹幕分段数预估用；0 表示未知，由播放器 durationUpdate 兜底。 */
  @Prop videoDuration: number = 0;
  @Prop videoTitle: string = '';
  @Prop videoCover: string = '';
  @Prop ownerName: string = '';
  @Prop ownerFace: string = '';
  @Prop liked: boolean = false;
  @Prop coined: boolean = false;
  @Prop favorited: boolean = false;
  @Prop @Watch('onExternalDanmakuChanged') externalDanmakuOn: boolean = true;
  @Prop localDanmakuText: string = '';
  @Prop @Watch('onLocalDanmakuRequested') localDanmakuToken: number = 0;
  @Prop @Watch('onCompactModeChanged') compactMode: boolean = false;
  onBack: () => void = () => {};
  onFullscreenChange: (fullscreen: boolean) => void = () => {};
  onPlayingChange: (playing: boolean) => void = () => {};
  onResumeRequest: () => void = () => {};
  onDanmakuChange: (enabled: boolean) => void = () => {};
  /** 横屏底栏弹幕输入：草稿与发送由业务页（VideoDetail）持有 */
  @Prop dmDraft: string = '';
  @Prop dmSending: boolean = false;
  onDmDraftChange: (value: string) => void = () => {};
  onDmSend: () => void = () => {};
  onProgress: (seconds: number) => void = () => {};
  onEnded: () => void = () => {};
  onLike: () => void = () => {};
  onCoin: () => void = () => {};
  onFavorite: () => void = () => {};
  onShare: () => void = () => {};
  @State playing: boolean = false;
  @State prepared: boolean = false;
  @State errorText: string = '';
  @State curTime: number = 0;
  @State duration: number = 0;
  @State danmakuOn: boolean = true;
  @State fullscreen: boolean = false;
  // 进入播放页直接展示纯画面；用户点画面或暂停时再唤出控制层。
  @State showControls: boolean = false;
  @State buffering: boolean = false;
  @State showMoreMenu: boolean = false;      // 竖屏：底部 Sheet 设置面板
  @State showSideDrawer: boolean = false;    // 横屏：右侧抽屉设置面板
  @State moreSheetPage: string = 'menu';     // Sheet/抽屉共用的子页状态
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
  @State playbackRate: number = 1.0;
  @State dmOpacity: number = 0.85;
  @State dmSpeed: number = 1.0;
  // 默认 1.3 对齐 B 站弹幕观感；设置面板可在 0.7~1.8 间调节。
  @State dmFontScale: number = 1.3;
  @State dmDensity: number = 18;
  @State blockScrollDm: boolean = false;
  @State blockTopDm: boolean = false;
  @State blockBottomDm: boolean = false;
  @State blockColorDm: boolean = false;
  @State holdSpeedActive: boolean = false;
  @State gestureSeekPreview: number = -1;
  @State gestureAdjustKind: string = '';
  @State gestureAdjustPercent: number = -1;
  @State doubleTapFeedbackVisible: boolean = false;
  @State doubleTapFeedbackPlaying: boolean = false;
  @State doubleTapFeedbackScale: number = 0.78;
  @State doubleTapFeedbackOpacity: number = 0;
  @State resumeTransitionActive: boolean = false;
  @State onlineTotal: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('videoFullscreenExitRequest') @Watch('onFullscreenExitRequested') fullscreenExitRequest: number = 0;
  @StorageProp('videoSeekRequestToken') @Watch('onExternalSeekRequested') seekRequestToken: number = 0;
  @StorageProp('videoPlaybackStopRequest') @Watch('onPlaybackStopRequested') stopRequest: number = 0;
  @StorageLink('sponsorSkipEnabled') sponsorSkipEnabled: boolean = true;
  /** 播完自动连播下一集（UGC 合集）；关闭后播完停在剧终画面，由用户手动选择。 */
  @StorageLink('autoContinuePlay') autoContinuePlay: boolean = true;
  private player: media.AVPlayer | null = null;
  private audioPlayer: media.AVPlayer | null = null;
  private audioPrepared: boolean = false;
  private xcController: XComponentController = new XComponentController();
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private dmEngine: PlayerDanmakuEngine = new PlayerDanmakuEngine(this.ctx);
  private dmTick: number = -1;
  /** 弹幕视口尺寸高频回调合并：pending 尺寸 + 尾随一次应用。 */
  private dmResizeTimer: number = -1;
  private dmPendingW: number = 0;
  private dmPendingH: number = 0;
  private hideTimer: number = -1;
  private sourceIndex: number = 0;
  private retryingSource: boolean = false;
  private runtimeSources: Array<string> = [];
  private runtimeAudioSources: Array<string> = [];
  private audioSourceIndex: number = 0;
  private lastAudioSyncBucket: number = -1;
  private sponsorSegments: Array<SponsorSegment> = [];
  private lastSponsorUuid: string = '';
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
  // 拖动进度条期间滑块以拖动值为准，避免 timeUpdate 回写 curTime 把滑块拽回。
  @State sliderDragging: boolean = false;
  @State sliderDragValue: number = 0;
  private volumeRestoreTimer: number = -1;
  private fullscreenExitTimer: number = -1;
  private doubleTapFeedbackTimer: number = -1;
  // AVPlayer 创建本身是异步的：代次使离页/换源前发起的 createAVPlayer 结果失效并立即释放。
  private playerCreateGeneration: number = 0;
  private playerCreating: boolean = false;
  // 已加载弹幕对应的 cid，避免 aboutToAppear 与换源触发的并发/重复加载。
  private dmLoadedCid: number = -1;
  // 弹幕分段加载状态（0 基段号）；分段首段失败时 dmSegFallback 置位，整体回退 XML 整段接口。
  private dmSegLoaded: Set<number> = new Set<number>();
  private dmSegLoading: Set<number> = new Set<number>();
  private dmSegFallback: boolean = false;

  aboutToAppear(): void {
    // 被其他 NavDestination 覆盖时 aboutToDisappear 已置位；返回同一实例需恢复。
    this.destroyed = false;
    this.showControls = false;
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    AppStorage.setOrCreate<number>('videoFullscreenExitRequest', 0);
    if (this.seekCtl === null) {
      this.seekCtl = new PlayerSeekController(
        (): media.AVPlayer | null => this.player,
        (): media.AVPlayer | null => this.audioPlayer,
        (): boolean => this.prepared,
        (): boolean => this.audioPrepared,
        (): void => {
          this.stopDmLoop(false);
        },
        (on: boolean): void => {
          this.buffering = on;
        },
        (resume: boolean): void => {
          const video: media.AVPlayer | null = this.player;
          if (resume && video !== null && this.prepared) {
            try {
              if (!this.playing) video.play();
              if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.play();
            } catch (e) {
            }
          }
          this.buffering = false;
          if (this.playing) this.startDmLoop();
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
          this.gestureSeekPreview = value;
        },
        (value: number): void => {
          if (this.gestureSeekPreview >= 0 && value === -1) {
            this.seekTo(this.gestureSeekPreview, true);
            this.gestureSeekPreview = -1;
          }
        },
        (kind: string, percent: number): void => {
          this.gestureAdjustKind = kind === 'brightness' ? '亮度' : (kind === 'volume' ? '音量' : '');
          this.gestureAdjustPercent = percent;
        },
        (value: number): void => {
          this.applyGestureVolume(value);
        },
        (value: number): void => {
          this.applyGestureVolume(value);
        },
        (value: number): void => {
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
    this.loadSponsorSegments();
    this.loadVideoChapters();
    this.loadOnlineTotal();
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
    if (item.id <= 0) {
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
        BiliApi.reportDanmaku(this.cid, item.id, reasonValues[pick])
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
    this.moreSheetPage = 'danmakuList';
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
    this.moreSheetPage = 'dmFilter';
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
    this.invalidatePlayerCreation();
    const oldPlayer: media.AVPlayer | null = this.player;
    const oldAudioPlayer: media.AVPlayer | null = this.audioPlayer;
    this.player = null;
    this.audioPlayer = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.playing = false;
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
    this.stopDmLoop(true);
    this.dmEngine.list = [];
    this.dmEngine.cursor = 0;
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
    if (this.destroyed) {
      this.buffering = false;
      return;
    }
    this.dmLoadedCid = -1;
    this.loadDanmaku();
    this.loadSponsorSegments();
    this.loadVideoChapters();
    this.loadOnlineTotal();
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
    if (this.dmResizeTimer >= 0) {
      clearTimeout(this.dmResizeTimer);
      this.dmResizeTimer = -1;
    }
    this.invalidatePlayerCreation();
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    this.endHoldSpeed();
    this.resumeAfterPrepare = this.playheadSec;
    this.shouldPlayAfterPrepare = false;
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
    this.muteImmediately();
    try {
      if (video !== null && this.prepared) video.pause();
      if (audio !== null && this.audioPrepared) audio.pause();
    } catch (e) {
      // 状态切换边界可能已由系统暂停。
    }
    this.playing = false;
    this.showControls = true;
    this.pauseDmLoop();
    this.onPlayingChange(false);
    // pause 完成后恢复音量；播放器仍保持暂停，返回点击继续时声音正常。
    if (this.volumeRestoreTimer >= 0) clearTimeout(this.volumeRestoreTimer);
    this.volumeRestoreTimer = setTimeout(() => {
      this.volumeRestoreTimer = -1;
      if (this.destroyed) return;
      try {
        const restoreVolume: number = (this.gestureCtl?.gestureVolume ?? 100) / 100;
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

  async loadSponsorSegments(): Promise<void> {
    const bvid: string = this.bvid;
    const cid: number = this.cid;
    try {
      const segments: Array<SponsorSegment> = await BiliApi.getSponsorSegments(bvid, cid);
      if (this.destroyed || this.bvid !== bvid || this.cid !== cid) return;
      this.sponsorSegments = segments;
      this.lastSponsorUuid = '';
    } catch (e) {
      // 空降数据是增强能力，请求失败不能影响播放器主流程。
    }
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

  maybeSkipSponsor(now: number): boolean {
    if (!this.sponsorSkipEnabled || this.sponsorSegments.length === 0) return false;
    for (let i: number = 0; i < this.sponsorSegments.length; i++) {
      const segment: SponsorSegment = this.sponsorSegments[i];
      if (now >= segment.start && now < segment.end - 0.08 && this.lastSponsorUuid !== segment.uuid) {
        this.lastSponsorUuid = segment.uuid;
        this.seekTo(segment.end + 0.05, true);
        this.toast(segment.category === 'sponsor' ? '已跳过赞助广告' : '已跳过推广片段');
        return true;
      }
    }
    return false;
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
          try {
            p.setPlaybackRate(this.playbackRate);
            p.setVolume((this.gestureCtl?.gestureVolume ?? 100) / 100);
          } catch (e) {
            // 某些视频解码器不支持非常用倍速，保持 1x 即可。
          }
          this.tryStartPreparedPlayers();
        } else if (state === 'playing') {
          this.resumeTransitionActive = false;
          this.playing = true;
          this.onPlayingChange(true);
          this.scheduleControlsHide();
          this.startDmLoop();
          this.buffering = false;
          this.ensureAVSession();
          this.updateAVSessionPlaybackState();
          Immersive.setKeepScreenOn(true);
        } else if (state === 'paused' || state === 'completed') {
          this.resumeTransitionActive = false;
          this.playing = false;
          this.showControls = true;
          if (this.hideTimer >= 0) {
            clearTimeout(this.hideTimer);
            this.hideTimer = -1;
          }
          this.onPlayingChange(false);
          this.pauseDmLoop();
          this.updateAVSessionPlaybackState();
          Immersive.setKeepScreenOn(false);
          if (state === 'completed') {
            this.onEnded();
          }
        }
      });
      p.on('error', (err: BusinessError) => {
        this.handlePlayerError(p, err.message);
      });
      p.on('seekDone', (position: number) => {
        this.onVideoSeekDone(p);
      });
      p.on('timeUpdate', (t: number) => {
        if (this.player !== p) return;
        // AVPlayer 上报毫秒，播放器 UI/弹幕内部统一使用秒。
        const nextTime: number = t / 1000;
        if (this.dmEngine.lastPlayerTime > 0 && (nextTime < this.dmEngine.lastPlayerTime - 0.5 || nextTime > this.dmEngine.lastPlayerTime + 2.5)) {
          this.resetDanmakuAt(nextTime);
        }
        this.dmEngine.lastPlayerTime = nextTime;
        this.playheadSec = nextTime;
        // 控制层只需秒级刷新，避免 250ms 一次的 @State 写入驱动整棵控制子树重建。
        if (Math.floor(nextTime) !== Math.floor(this.curTime)) this.curTime = nextTime;
        this.onProgress(nextTime);
        this.updateSubtitle(nextTime);
        this.spawnDanmaku(nextTime);
        // 弹幕分段预取：进入新段或逼近段尾时拉取下一段（XML 兜底模式下为空操作）。
        this.prefetchDanmakuSegments(nextTime);
        if (this.maybeSkipSponsor(nextTime)) return;
        const audio: media.AVPlayer | null = this.audioPlayer;
        // 双 DASH 轨只在明显失步时兜底校时；原先每 5 秒、220ms 阈值会制造周期性顿挫。
        const syncBucket: number = Math.floor(nextTime / 30);
        if ((this.seekCtl?.seekInFlight ?? true) === false && audio !== null && this.audioPrepared && syncBucket !== this.lastAudioSyncBucket &&
          Math.abs(audio.currentTime - t) > 900) {
          this.lastAudioSyncBucket = syncBucket;
          audio.seek(t, media.SeekMode.SEEK_CLOSEST);
        }
      });
      p.on('durationUpdate', (d: number) => {
        this.duration = d / 1000;
        this.updateAVSessionMetadata();
      });
      p.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
        if (infoType === media.BufferingInfoType.BUFFERING_START) {
          // seek 的短暂缓冲由延迟提示管理，快速定位不闪 loading。
          if ((this.seekCtl?.seekInFlight ?? true) === false) this.buffering = true;
          this.pauseDmLoop();
        } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
          // seek 尚未完成音轨对齐时不能提前隐藏 loading 或恢复弹幕时钟。
          if ((this.seekCtl?.seekInFlight ?? true) === false) {
            this.buffering = false;
            this.startDmLoop();
          }
        }
      });
      const sourceUrl: string = this.currentSourceUrl();
      if (sourceUrl.length === 0) {
        this.errorText = '无法播放：播放地址为空';
        await p.release();
        this.player = null;
        return;
      }
      const source: media.MediaSource = media.createMediaSourceWithUrl(sourceUrl, this.playbackHeaders());
      if (this.runtimeAudioSources.length > 0) await this.initAudioPlayer(generation);
      if (this.destroyed || generation !== this.playerCreateGeneration || this.player !== p) return;
      await p.setMediaSource(source, this.videoPlaybackStrategy());
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

  private videoPlaybackStrategy(): media.PlaybackStrategy {
    return PlayerPlaybackConfig.videoStrategy();
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
          audio.setVolume((this.gestureCtl?.gestureVolume ?? 100) / 100);
        } catch (e) {
          // 倍速不被音频解码器支持时，设置入口会统一回退到 1x。
        }
        this.tryStartPreparedPlayers();
      }
    });
    audio.on('error', (err: BusinessError) => {
      this.handleAudioPlayerError(audio, err.message);
    });
    audio.on('seekDone', (position: number) => {
      this.onAudioSeekDone(audio, position);
    });
    const source: media.MediaSource = media.createMediaSourceWithUrl(sourceUrl, this.playbackHeaders());
    await audio.setMediaSource(source, this.audioPlaybackStrategy());
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
    if (this.resumeAfterPrepare > 0) {
      const resumeAt: number = this.resumeAfterPrepare;
      const resumePlaying: boolean = this.shouldPlayAfterPrepare;
      this.resumeAfterPrepare = -1;
      this.shouldPlayAfterPrepare = false;
      if (this.seekCtl !== null) this.seekCtl.seekResumePlaying = resumePlaying;
      // 重建/切清晰度后也走同一串行 seek，不能在 seekDone 前让两条轨道各自起播。
      this.seekTo(resumeAt, true);
      return;
    }
    this.resumeAfterPrepare = -1;
    if (this.shouldPlayAfterPrepare) {
      video.play();
      if (audio !== null) audio.play();
    }
  }

  async changeQuality(qn: number): Promise<void> {
    if (this.qualityLoading || qn === this.activeQuality) {
      this.closeSettingPanels();
      return;
    }
    this.qualityLoading = true;
    try {
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(this.aid, this.bvid, this.cid, qn);
      if (info === null || info.urls.length === 0) {
        this.errorText = '该清晰度暂时不可用';
        return;
      }
      const oldPlayer: media.AVPlayer | null = this.player;
      const oldAudioPlayer: media.AVPlayer | null = this.audioPlayer;
      this.invalidatePlayerCreation();
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
      this.buffering = true;
      this.closeSettingPanels();
      this.stopDmLoop(false);
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
      if (this.destroyed) {
        this.buffering = false;
        return;
      }
      await this.initPlayer();
    } finally {
      // 同步抛错（如签名异常）也必须复位，否则 qualityLoading 永远卡 true。
      this.qualityLoading = false;
    }
  }

  setPlaybackSpeed(rate: number): void {
    this.playbackRate = rate;
    this.closeSettingPanels();
    const p: media.AVPlayer | null = this.player;
    if (p !== null && this.prepared) {
      try {
        p.setPlaybackRate(rate);
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setPlaybackRate(rate);
      } catch (e) {
        this.playbackRate = 1.0;
        p.setPlaybackRate(1.0);
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setPlaybackRate(1.0);
      }
    }
  }

  private applyTemporarySpeed(rate: number): void {
    try {
      if (this.player !== null && this.prepared) this.player.setPlaybackRate(rate);
      if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setPlaybackRate(rate);
    } catch (e) {
      // 个别解码器不支持 2x 时保持原速。
    }
  }

  private beginHoldSpeed(): void {
    if (!this.playing || !this.prepared || this.holdSpeedActive) return;
    this.speedCtl?.beginHold(this.playbackRate);
  }

  private endHoldSpeed(): void {
    this.speedCtl?.endHold();
  }

  private loadGestureLevels(): void {
    this.gestureCtl?.loadInitials();
  }

  private applyGestureVolume(value: number): void {
    const normalized: number = Math.max(0, Math.min(1, value / 100));
    try {
      if (this.player !== null && this.prepared) this.player.setVolume(normalized);
      if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.setVolume(normalized);
    } catch (e) {
    }
  }

  private loadOnlineTotal(): void {
    const request: number = ++this.onlineRequest;
    const cid: number = this.cid;
    BiliApi.getOnlineTotal(this.aid, this.bvid, cid).then((total: string) => {
      if (!this.destroyed && request === this.onlineRequest && this.cid === cid) this.onlineTotal = total;
    }).catch(() => {
      if (!this.destroyed && request === this.onlineRequest) this.onlineTotal = '';
    });
  }

  private beginPlayerPan(event: GestureEvent): void {
    const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : this.dmEngine.width / 2;
    this.gestureCtl?.beginPan(x, this.dmEngine.width, this.playheadSec, this.duration);
  }

  private updatePlayerPan(event: GestureEvent): void {
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
    const preview: number = this.gestureSeekPreview;
    ctl.endPan();
    if (preview >= 0) {
      this.seekTo(preview, true);
      this.gestureSeekPreview = -1;
    }
    this.gestureAdjustKind = '';
    this.gestureAdjustPercent = -1;
    if (this.playing) this.scheduleControlsHide();
  }

  private progressDisplayTime(): number {
    if (this.sliderDragging) return this.sliderDragValue;
    if (this.gestureSeekPreview >= 0) return this.gestureSeekPreview;
    return this.duration > 0 ? this.curTime : 0;
  }


  private handleDoubleTap(): void {
    if (!this.prepared || this.player === null) return;
    const willPlay: boolean = !this.playing;
    this.doubleTapFeedbackPlaying = willPlay;
    this.doubleTapFeedbackVisible = true;
    this.doubleTapFeedbackScale = 0.78;
    this.doubleTapFeedbackOpacity = 0;
    if (this.doubleTapFeedbackTimer >= 0) clearTimeout(this.doubleTapFeedbackTimer);
    this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
      this.doubleTapFeedbackScale = 1;
      this.doubleTapFeedbackOpacity = 1;
    });
    this.togglePlay();
    this.doubleTapFeedbackTimer = setTimeout(() => {
      this.doubleTapFeedbackTimer = -1;
      this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseIn }, () => {
        this.doubleTapFeedbackScale = 1.08;
        this.doubleTapFeedbackOpacity = 0;
      });
      setTimeout(() => {
        if (!this.destroyed) this.doubleTapFeedbackVisible = false;
      }, 170);
    }, 420);
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
    this.resumeAfterPrepare = this.playheadSec;
    this.shouldPlayAfterPrepare = this.playing;
    this.player = null;
    const failedAudio: media.AVPlayer | null = this.audioPlayer;
    this.audioPlayer = null;
    this.audioPrepared = false;
    this.prepared = false;
    this.playing = false;
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
    this.resumeAfterPrepare = this.playheadSec;
    this.shouldPlayAfterPrepare = this.playing;
    const video: media.AVPlayer | null = this.player;
    this.player = null;
    this.audioPlayer = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.playing = false;
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
      try {
        p.pause();
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.pause();
        // AVPlayer 状态回调可能滞后一帧以上；点击后立即刷新按钮，回调再做最终校准。
        this.playing = false;
        this.showControls = true;
        this.onPlayingChange(false);
      } catch (e) {
        // 底层状态不允许暂停时保持原 UI，等待 stateChange 校准。
      }
    } else {
      // 用户主动点击继续时先通知外层恢复完整播放器高度；首播/切清晰度不会误触发。
      this.resumeTransitionActive = this.compactMode && !this.fullscreen;
      this.onResumeRequest();
      try {
        p.play();
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.play();
        this.playing = true;
        this.onPlayingChange(true);
        this.scheduleControlsHide();
      } catch (e) {
        this.resumeTransitionActive = false;
      }
    }
  }

  seekTo(positionSec: number, precise: boolean = false): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) return;
    const clamped: number = Math.max(0, Math.min(this.duration > 0 ? this.duration : positionSec, positionSec));
    const targetMs: number = Math.floor(clamped * 1000);
    this.resetDanmakuAt(clamped);
    this.playheadSec = clamped;
    this.curTime = clamped;
    this.onProgress(clamped);
    this.updateSubtitle(clamped);
    this.updateAVSessionPlaybackState();
    this.lastAudioSyncBucket = -1;
    this.seekCtl?.request(targetMs, precise, this.playing);
  }

  onVideoSeekDone(video: media.AVPlayer): void {
    this.seekCtl?.onVideoSeekDone(video);
  }

  onAudioSeekDone(audio: media.AVPlayer, position: number): void {
    this.seekCtl?.onAudioSeekDone(audio, position);
  }

  private async recoverPlayersAfterSeekStall(stalledVideo: media.AVPlayer, targetMs: number): Promise<void> {
    if (this.player !== stalledVideo) return;
    const resume: boolean = this.seekCtl?.seekResumePlaying ?? false;
    this.seekCtl?.cancel();
    this.invalidatePlayerCreation();
    const stalledAudio: media.AVPlayer | null = this.audioPlayer;
    this.player = null;
    this.audioPlayer = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.playing = false;
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
      Immersive.setFullscreen(true);
    }
  }

  exitFullscreen(): void {
    if (!this.fullscreen) {
      return;
    }
    this.fullscreen = false;
    this.dmEngine.fullscreen = false;
    this.showSideDrawer = false;
    this.restartDmLoopForViewport();
    this.applyVideoScaleType();
    // 先恢复竖屏，待窗口尺寸稳定后再恢复详情布局，避免短暂套用横屏宽度。
    // 在过渡结束前继续标记为全屏，使连续的返回手势也不会误把视频页弹出。
    Immersive.setFullscreen(false);
    if (this.fullscreenExitTimer >= 0) clearTimeout(this.fullscreenExitTimer);
    this.fullscreenExitTimer = setTimeout(() => {
      this.fullscreenExitTimer = -1;
      if (this.destroyed) return;
      this.onFullscreenChange(false);
      AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    }, 240);
  }

  applyVideoScaleType(): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) {
      return;
    }
    // 所有模式都完整等比显示：不拉伸，也不为了填满屏幕裁掉画面上下或左右内容。
    p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
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
  }

  /** 设置面板开关：竖屏弹底部 Sheet，横屏弹右侧抽屉；再点一次收起。 */
  private toggleMoreMenu(): void {
    if (this.fullscreen) {
      const next: boolean = !this.showSideDrawer;
      this.closeSettingPanels();
      this.showSideDrawer = next;
      if (next) this.moreSheetPage = 'menu';
    } else {
      const next: boolean = !this.showMoreMenu;
      this.closeSettingPanels();
      this.showMoreMenu = next;
      if (next) this.moreSheetPage = 'menu';
    }
  }

  /** 打开指定设置子页：竖屏走底部 Sheet，横屏走右侧抽屉。 */
  private openSettingsPage(page: string): void {
    this.closeSettingPanels();
    this.moreSheetPage = page;
    if (this.fullscreen) {
      this.showSideDrawer = true;
    } else {
      this.showMoreMenu = true;
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
    this.invalidatePlayerCreation();
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.seekCtl?.cancel();
    if (this.volumeRestoreTimer >= 0) {
      clearTimeout(this.volumeRestoreTimer);
      this.volumeRestoreTimer = -1;
    }
    if (this.fullscreenExitTimer >= 0) {
      clearTimeout(this.fullscreenExitTimer);
      this.fullscreenExitTimer = -1;
    }
    if (this.doubleTapFeedbackTimer >= 0) {
      clearTimeout(this.doubleTapFeedbackTimer);
      this.doubleTapFeedbackTimer = -1;
    }
    this.stopDmLoop(true);
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
  }

  // ===== 弹幕引擎 =====

  spawnDanmaku(now: number): void {
    this.dmEngine.spawn(now);
    if (this.dmEngine.active.length > 0) this.startDmLoop();
  }

  /** 统一绘制入口：画布上已经没有活动弹幕时顺带停掉定时器。 */
  private renderDanmakuFrame(advance: boolean = true): void {
    this.dmEngine.drawFrame(advance);
    if (this.dmEngine.active.length === 0) this.stopDmLoop(false);
  }

  startDmLoop(): void {
    if (this.dmTick >= 0 || !this.danmakuOn || this.dmEngine.active.length === 0) {
      return;
    }
    this.dmEngine.lastDrawMs = Date.now();
    this.dmTick = setInterval(() => {
      if (this.playing && this.danmakuOn && this.dmEngine.active.length > 0) {
        this.renderDanmakuFrame();
      }
    // 仅在存在活动弹幕时运行：普通 30fps、全屏 40fps，兼顾连续性与功耗。
    }, this.fullscreen ? 25 : 33);
  }

  private onDanmakuAreaChange(newV: Area): void {
    // onAreaChange 在横屏/竖屏/缩放/迷你态切换期间高频触发，逐次全量重排弹幕
    // 会瞬间拉满 CPU 并掉帧。这里把「应用新尺寸」合并到定时器尾：16ms 内只应用最后一次，
    // 期间渲染循环仍在按旧视口画，视觉无感。
    const newW: number = newV.width as number;
    const newH: number = newV.height as number;
    this.dmPendingW = newW;
    this.dmPendingH = newH;
    if (this.dmResizeTimer < 0) {
      this.dmResizeTimer = setTimeout(() => {
        this.dmResizeTimer = -1;
        if (this.destroyed) return;
        this.dmEngine.setViewport(this.dmPendingW, this.dmPendingH);
        // 渲染循环运行中由下一帧自然重绘；暂停/缓冲时无循环，
        // Canvas 可能已被尺寸变化清空，补一帧避免白屏。
        if (this.dmTick < 0 && this.dmEngine.active.length > 0) {
          this.dmEngine.drawFrame(false);
        }
      }, 16);
    }
  }

  /** 暂停/缓冲时只停时钟，保留已上屏弹幕；恢复播放后从当前帧继续推进。 */
  private pauseDmLoop(): void {
    if (this.dmTick >= 0) {
      clearInterval(this.dmTick);
      this.dmTick = -1;
    }
    this.dmEngine.lastDrawMs = 0;
  }

  stopDmLoop(clearActive: boolean): void {
    if (this.dmTick >= 0) {
      clearInterval(this.dmTick);
      this.dmTick = -1;
    }
    this.dmEngine.lastDrawMs = 0;
    if (clearActive) {
      this.dmEngine.clearActive();
    } else {
      this.dmEngine.clearCanvas();
    }
  }

  toggleDanmaku(): void {
    this.setDanmakuEnabled(!this.danmakuOn, true);
  }

  private setDanmakuEnabled(enabled: boolean, notify: boolean): void {
    if (this.danmakuOn === enabled) return;
    this.danmakuOn = enabled;
    this.dmEngine.enabled = enabled;
    if (!enabled) {
      this.stopDmLoop(true);
    } else {
      // 重新开启时从当前播放位置继续，不补画已经错过的一大批弹幕。
      this.dmEngine.syncCursor(this.playheadSec - 0.08);
      this.spawnDanmaku(this.playheadSec);
    }
    if (notify) this.onDanmakuChange(enabled);
  }

  restartDmLoopForViewport(): void {
    const shouldRestart: boolean = this.dmTick >= 0;
    this.stopDmLoop(false);
    this.dmEngine.clearCaches();
    // 横竖屏字号和轨道数不同，切换时立即重排，避免旋转后沿用旧坐标产生抽搐。
    this.setDmFontScale(this.dmFontScale);
    if (shouldRestart || (this.playing && this.dmEngine.active.length > 0)) this.startDmLoop();
  }

  resetDanmakuAt(time: number): void {
    this.stopDmLoop(true);
    this.dmEngine.resetAt(time);
  }

  setDmOpacity(value: number): void {
    this.dmOpacity = value;
    this.dmEngine.opacity = value;
  }

  setDmSpeed(value: number): void {
    this.dmEngine.setSpeed(value);
  }

  setDmFontScale(value: number): void {
    this.dmEngine.setFontScale(value);
  }

  setDmDensity(value: number): void {
    this.dmEngine.setDensity(value);
  }

  applyDmFilters(): void {
    this.dmEngine.blockScrollDm = this.blockScrollDm;
    this.dmEngine.blockTopDm = this.blockTopDm;
    this.dmEngine.blockBottomDm = this.blockBottomDm;
    this.dmEngine.blockColorDm = this.blockColorDm;
    this.dmEngine.applyFilters();
    if (this.dmEngine.active.length === 0) this.stopDmLoop(false);
  }

  syncDanmakuCursor(time: number): void {
    this.dmEngine.syncCursor(time);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 视频画面
      XComponent({
        id: 'playerSurface',
        type: XComponentType.SURFACE,
        controller: this.xcController,
      })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.onSurfaceReady();
        })

      // 弹幕层
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .visibility(this.danmakuOn ? Visibility.Visible : Visibility.Hidden)
        .onReady(() => {})
        .onAreaChange((oldV: Area, newV: Area) => {
          this.onDanmakuAreaChange(newV);
        })

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
        onlineTotal: this.onlineTotal,
        compactMode: this.compactMode,
        showControls: this.showControls,
        fullscreen: this.fullscreen,
        holdSpeedActive: this.holdSpeedActive,
        gestureSeekPreview: this.gestureSeekPreview,
        gestureAdjustKind: this.gestureAdjustKind,
        gestureAdjustPercent: this.gestureAdjustPercent,
        panStartTime: this.gestureCtl?.panStartTime ?? 0,
        duration: this.duration,
        doubleTapVisible: this.doubleTapFeedbackVisible,
        doubleTapPlaying: this.doubleTapFeedbackPlaying,
        doubleTapScale: this.doubleTapFeedbackScale,
        doubleTapOpacity: this.doubleTapFeedbackOpacity,
      })
      // 控件层
      if ((this.showControls || (!this.playing && this.compactMode && !this.fullscreen)) && this.errorText.length === 0) {
        Column() {
          if (this.compactMode && !this.fullscreen) {
            if (!this.playing) {
              // 参考官方客户端暂停最小化蒙版：深色横幅，返回/立即播放/更多三段布局。
              Stack({ alignContent: Alignment.Center }) {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor('#A30B0C10')
                Row() {
                  this.IconButton($r('app.media.ic_back'), 24, 42, 42, '#F2FFFFFF', false, () => {
                    this.onBack();
                  })
                  Blank()
                  Row({ space: 9 }) {
                    Image($r('app.media.ic_video_replay'))
                      .width(31)
                      .height(31)
                      .renderMode(ImageRenderMode.Template)
                      .fillColor('#F2FFFFFF')
                    Text('立即播放')
                      .fontSize(18)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#F2FFFFFF')
                  }
                  .height(48)
                  .padding({ left: 8, right: 8 })
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => {
                    this.togglePlay();
                  })
                  Blank()
                  this.IconButton($r('app.media.ic_more'), 22, 42, 42, '#F2FFFFFF', false, () => {
                    this.toggleMoreMenu();
                  })
                }
                .width('100%')
                .height('100%')
                .padding({ left: 6, right: 6 })
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .height('100%')
            } else {
              // 播放中的收起态保留单行进度控制。
              Column() {
                Blank()
                Row({ space: 7 }) {
                  this.IconButton($r('app.media.ic_pause'), 16, 36, 36, '#FFFFFF', true, () => {
                    this.togglePlay();
                  })
                  Text(formatDuration(this.progressDisplayTime()))
                    .fontSize(10)
                    .fontColor(this.sheetTitleColor())
                  this.ProgressSlider(true)
                  this.IconButton($r('app.media.ic_fullscreen'), 20, 36, 36, '#FFFFFF', false, () => {
                    this.toggleFullscreen();
                  })
                }
                .width('100%')
                .height(44)
                .padding({ left: 8, right: 8, bottom: 4 })
              }
              .width('100%')
              .height('100%')
            }
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
                onBack: () => this.exitFullscreen(),
                onLike: () => this.onLike(),
                onCoin: () => this.onCoin(),
                onFavorite: () => this.onFavorite(),
                onShare: () => this.onShare(),
              })
            } else {
              // 竖屏右上角 ⋮：清晰度/倍速/空降/分段/弹幕设置全部收纳在这里，
              // 底栏只保留 播放-进度-全屏，减少对画面内容的遮挡。
              Row() {
                Blank()
                this.IconButton($r('app.media.ic_more'), 20, 36, 36, '#FFFFFF', false, () => {
                  this.toggleMoreMenu();
                })
              }
              .width('100%')
              .padding({ top: 6, right: 4 })
            }
            Blank()
            PlayerBottomControls({
              fullscreen: this.fullscreen,
              playing: this.playing,
              danmakuOn: this.danmakuOn,
              sponsorEnabled: this.sponsorSkipEnabled,
              chapters: this.chapters,
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
                this.sponsorSkipEnabled = !this.sponsorSkipEnabled;
                AppTheme.persistSponsorSkip(this.sponsorSkipEnabled);
                this.toast(this.sponsorSkipEnabled ? '广告空降已开启' : '广告空降已关闭');
              },
              onChapter: () => this.openSettingsPage('chapters'),
              onQuality: () => this.openSettingsPage('quality'),
              onSpeed: () => this.openSettingsPage('speed'),
              onFullscreen: () => this.toggleFullscreen(),
              onProgressChange: (value: number, mode: SliderChangeMode) => this.onProgressSliderChange(value, mode),
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

      // 横屏设置抽屉：从右侧滑入，点左侧空白收起；竖屏设置走 bindSheet（见下方 showMoreMenu）。
      if (this.fullscreen && this.showSideDrawer && this.errorText.length === 0) {
        this.SideSettingsDrawer()
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor('#000000')
    .bindSheet($$this.showMoreMenu, this.MoreMenuSheetContent(), {
      height: 600,
      dragBar: false,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: this.isDark ? '#18191C' : '#FFFFFF',
    })
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2 })
          .onAction(() => this.handleDoubleTap()),
        TapGesture({ count: 1 })
          .onAction((event: GestureEvent) => this.handleCanvasTap(event)),
        LongPressGesture({ repeat: false })
          .onAction(() => this.beginHoldSpeed())
          .onActionEnd(() => this.endHoldSpeed()),
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 12 })
          .onActionStart((event: GestureEvent) => this.beginPlayerPan(event))
          .onActionUpdate((event: GestureEvent) => this.updatePlayerPan(event))
          .onActionEnd(() => this.endPlayerPan())
          .onActionCancel(() => this.endPlayerPan())
      )
    )
  }

  /** 单击播放画面：命中的弹幕优先弹举报，否则照常切换控件。 */
  private handleCanvasTap(event: GestureEvent): void {
    const finger: FingerInfo | undefined = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    const x: number = finger !== undefined ? finger.localX : -1;
    const y: number = finger !== undefined ? finger.localY : -1;
    if (x >= 0 && y >= 0) {
      const hit: DanmakuItem | null = this.dmEngine.hitTest(x, y);
      if (hit !== null && hit.id > 0) {
        this.promptReportDanmaku(hit);
        return;
      }
    }
    this.toggleControls();
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

  /** 播放进度条：compact 为收起态 InSet 样式，否则为底部控制条 OutSet 样式。 */
  @Builder
  ProgressSlider(compact: boolean) {
    PlayerProgressBar({
      value: this.progressDisplayTime(),
      duration: this.duration,
      compact: compact,
      chapters: this.chapters,
      onChange: (value: number, mode: SliderChangeMode) => this.onProgressSliderChange(value, mode),
    })
  }

  private onProgressSliderChange(value: number, mode: SliderChangeMode): void {
    // 拖动期间滑块以拖动值为准，避免 timeUpdate 回写 curTime 把滑块拽回；仍在 End/Click 才 seek。
    if (mode === SliderChangeMode.Begin) {
      this.sliderDragging = true;
      this.sliderDragValue = value;
    } else if (mode === SliderChangeMode.Moving) {
      this.sliderDragValue = value;
    } else {
      this.sliderDragging = false;
      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
        this.seekTo(value, true);
      }
    }
  }

  /** 横屏右侧设置抽屉：复用「更多功能」Sheet 的菜单与子页内容，点左侧空白收起。 */
  @Builder
  SideSettingsDrawer() {
    Row() {
      Blank()
        .layoutWeight(1)
        .height('100%')
        .onClick(() => {
          this.showSideDrawer = false;
          this.moreSheetPage = 'menu';
        })
      Column() {
        this.MoreMenuSheetContent()
      }
      .width(320)
      .height('100%')
      .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
      .shadow({ radius: 24, color: '#40000000', offsetX: -6, offsetY: 0 })
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 320 }))
        .animation({ duration: 220, curve: Curve.EaseOut }),
      TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 320 }))
        .animation({ duration: 160, curve: Curve.EaseIn })))
  }

  /** 竖屏 ⋮ 更多菜单：清晰度/倍速/弹幕设置/分段/空降收纳项。 */
  private sheetTitleColor(): string {
    return this.isDark ? '#FFFFFF' : '#18191C';
  }

  private sheetSubColor(): string {
    return this.isDark ? '#B3FFFFFF' : '#5A5F66';
  }

  private sheetRowBg(): string {
    return this.isDark ? '#26272B' : '#F5F7F9';
  }

  /** 更多功能 Sheet 内嵌管理页：复用 PlayerSettingsPanel 的内容与回调，但去掉播放器内弹层的半透明灰底。 */
  @Builder
  EmbeddedSettingsPanel(which: number) {
    PlayerSettingsPanel({
      which: which,
      fullscreen: this.fullscreen,
      embedded: true,
      accent: this.accent,
      dmOpacity: this.dmOpacity,
      dmSpeed: this.dmSpeed,
      dmFontScale: this.dmFontScale,
      dmDensity: this.dmDensity,
      blockScrollDm: this.blockScrollDm,
      blockTopDm: this.blockTopDm,
      blockBottomDm: this.blockBottomDm,
      blockColorDm: this.blockColorDm,
      qualityOptions: this.runtimeQualityOptions,
      activeQuality: this.activeQuality,
      chapters: this.chapters,
      currentTime: this.curTime,
      playbackRate: this.playbackRate,
      subtitles: this.subtitles,
      subtitleIndex: this.subtitleIndex,
      subtitleOn: this.subtitleOn,
      onSubtitleChange: (index: number) => this.changeSubtitle(index),
      onResetDanmaku: () => {
        this.setDmOpacity(0.85);
        this.setDmSpeed(1);
        this.setDmFontScale(1.3);
        this.setDmDensity(18);
        this.blockScrollDm = false;
        this.blockTopDm = false;
        this.blockBottomDm = false;
        this.blockColorDm = false;
        this.applyDmFilters();
      },
      onDmOpacityChange: (value: number) => this.setDmOpacity(value),
      onDmSpeedChange: (value: number) => this.setDmSpeed(value),
      onDmFontScaleChange: (value: number) => this.setDmFontScale(value),
      onDmDensityChange: (value: number) => this.setDmDensity(value),
      onToggleDmBlock: (kind: string) => {
        if (kind === 'scroll') this.blockScrollDm = !this.blockScrollDm;
        else if (kind === 'top') this.blockTopDm = !this.blockTopDm;
        else if (kind === 'bottom') this.blockBottomDm = !this.blockBottomDm;
        else this.blockColorDm = !this.blockColorDm;
        this.applyDmFilters();
      },
      onQualityChange: (qn: number) => this.changeQuality(qn),
      onChapterChange: (seconds: number) => {
        this.seekTo(seconds, true);
        this.closeSettingPanels();
      },
      onSpeedChange: (rate: number) => this.setPlaybackSpeed(rate),
    })
  }

  @Builder
  MoreMenuSheetContent() {
    Column({ space: 4 }) {
      if (this.moreSheetPage !== 'menu') {
        Row({ space: 8 }) {
          Image($r('app.media.ic_back'))
            .width(24)
            .height(24)
            .renderMode(ImageRenderMode.Template)
            .fillColor(this.isDark ? '#FFFFFF' : '#18191C')
          Text('返回')
            .fontSize(15)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Blank()
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 10 })
        .onClick(() => {
          this.moreSheetPage = 'menu';
        })
        Column() {
          if (this.moreSheetPage === 'quality') this.EmbeddedSettingsPanel(1)
          else if (this.moreSheetPage === 'speed') this.EmbeddedSettingsPanel(3)
          else if (this.moreSheetPage === 'dm') this.EmbeddedSettingsPanel(0)
          else if (this.moreSheetPage === 'chapters') this.EmbeddedSettingsPanel(2)
          else if (this.moreSheetPage === 'subtitle') this.EmbeddedSettingsPanel(4)
          else if (this.moreSheetPage === 'danmakuList') DanmakuListPanel({
            source: this.dmListSource,
            count: this.dmListCount,
            embedded: true,
            onSeek: (seconds: number): void => {
              this.seekTo(seconds, true);
            },
            onReport: (item: DanmakuItem): void => {
              this.promptReportDanmaku(item);
            },
            onClose: (): void => {
              this.showMoreMenu = false;
              this.showSideDrawer = false;
            },
          })
          else if (this.moreSheetPage === 'dmFilter') DmFilterPanel({
            source: this.dmFilterRuleSource,
            loading: this.dmFilterLoading,
            filterType: this.dmFilterType,
            draft: this.dmFilterDraft,
            rulesCount: this.dmFilterRulesCount,
            embedded: true,
            onTypeChange: (type: number): void => {
              this.dmFilterType = type;
            },
            onDraftChange: (draft: string): void => {
              this.dmFilterDraft = draft;
            },
            onAdd: (): void => {
              this.submitDmFilterRule().catch(() => {
              });
            },
            onDelete: (id: number): void => {
              this.deleteDmFilterRule(id).catch(() => {
              });
            },
          })
        }
        .layoutWeight(1)
      } else {
        Row() {
          Text('更多功能')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Blank()
          Text('点击空白处关闭')
            .fontSize(11)
            .fontColor(this.isDark ? '#C8C8CC' : '#9499A0')
          Image($r('app.media.ic_close'))
            .width(22)
            .height(22)
            .renderMode(ImageRenderMode.Template)
            .fillColor(this.isDark ? '#FFFFFF' : '#18191C')
            .margin({ left: 8 })
            .onClick(() => {
              this.toggleMoreMenu();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 10 })

        PlayerMenuItem({
          icon: $r('app.media.ic_play'),
          label: '清晰度',
          value: this.qualityLoading ? '切换中…' : this.qualityLabel(),
          onTap: (): void => {
            this.moreSheetPage = 'quality';
          },
        })
        PlayerMenuItem({
          icon: $r('app.media.ic_video_replay'),
          label: '倍速',
          value: this.playbackRate === 1 ? '1.0x' : this.playbackRate.toFixed(this.playbackRate % 1 === 0 ? 0 : 2) + 'x',
          onTap: (): void => {
            this.moreSheetPage = 'speed';
          },
        })
        PlayerMenuItem({
          icon: $r('app.media.ic_danmaku_settings'),
          label: '弹幕设置',
          value: '',
          onTap: (): void => {
            this.moreSheetPage = 'dm';
          },
        })
        PlayerMenuItem({
          icon: $r('app.media.ic_danmaku_on'),
          label: '弹幕列表',
          value: this.dmEngine.list.length > 0 ? String(this.dmEngine.list.length) + ' 条' : '',
          onTap: (): void => {
            this.openDanmakuList();
          },
        })
        PlayerMenuItem({
          icon: $r('app.media.ic_filter'),
          label: '屏蔽管理',
          value: '',
          onTap: (): void => {
            this.openDanmakuFilter();
          },
        })
        if (this.chapters.length > 0) {
          PlayerMenuItem({
            icon: $r('app.media.ic_sort'),
            label: '分段视频',
            value: String(this.chapters.length) + ' 段',
            onTap: (): void => {
              this.moreSheetPage = 'chapters';
            },
          })
        }
        if (this.subtitles.length > 0) {
          PlayerMenuItem({
            icon: $r('app.media.ic_comment'),
            label: 'CC字幕',
            value: this.subtitleOn ? this.subtitleLabel() : '关闭',
            onTap: (): void => {
              this.moreSheetPage = 'subtitle';
            },
          })
        }
        PlayerToggleItem({
          icon: $r('app.media.ic_video_replay'),
          label: '自动连播',
          isOn: this.autoContinuePlay,
          onChange: (next: boolean): void => {
            this.autoContinuePlay = next;
            AppTheme.persistAutoContinue(next);
          },
        })
        PlayerSponsorItem({
          sponsorOn: this.sponsorSkipEnabled,
          onToggle: (current: boolean): void => {
            this.sponsorSkipEnabled = !current;
            AppTheme.persistSponsorSkip(this.sponsorSkipEnabled);
            this.toast(this.sponsorSkipEnabled ? '广告空降已开启' : '广告空降已关闭');
          },
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
