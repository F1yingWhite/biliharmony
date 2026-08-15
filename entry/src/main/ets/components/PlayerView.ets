/**
 * 播放器组件：AVPlayer + XComponent 渲染 + Canvas 弹幕引擎 + 手势控制
 */
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { BiliApi, DanmakuItem, SponsorSegment, VideoChapter } from '../api/BiliApi';
import { Immersive } from '../common/Immersive';
import { formatDuration } from '../common/Utils';
import { PlayUrlInfo, VideoQualityOption } from '../model/Models';
import { Constants } from '../common/Constants';
import { PlayerProgressBar } from './PlayerProgressBar';
import { PlayerSettingsPanel } from './PlayerSettingsPanel';
import { PlayerGestureOverlay } from './PlayerGestureOverlay';
import { PlayerFullscreenHeader } from './PlayerFullscreenHeader';
import { ActiveDm, colorHex, CONTROLS_GRADIENT_COLORS } from './PlayerDanmakuSupport';
import { PlayerBottomControls } from './PlayerBottomControls';
import { PlayerPlaybackIndicator } from './PlayerPlaybackIndicator';

@Component
export struct PlayerView {
  @Prop videoUrl: string = '';
  @Prop videoUrls: Array<string> = [];
  @Prop audioUrls: Array<string> = [];
  @Prop @Watch('onQualityOptionsChanged') qualityOptions: Array<VideoQualityOption> = [];
  @Prop currentQuality: number = 0;
  @Prop @Watch('onSourceVersionChanged') sourceVersion: number = 0;
  @Prop aid: number = 0;
  @Prop bvid: string = '';
  @Prop cid: number = 0;
  @Prop videoTitle: string = '';
  @Prop ownerName: string = '';
  @Prop ownerFace: string = '';
  @Prop liked: boolean = false;
  @Prop coined: boolean = false;
  @Prop favorited: boolean = false;
  @Prop @Watch('onExternalDanmakuChanged') externalDanmakuOn: boolean = true;
  @Prop localDanmakuText: string = '';
  @Prop @Watch('onLocalDanmakuRequested') localDanmakuToken: number = 0;
  @Prop @Watch('onCompactModeChanged') compactMode: boolean = false;
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
  @State showDmSettings: boolean = false;
  @State showMoreMenu: boolean = false;
  @State showQualitySettings: boolean = false;
  @State showSpeedSettings: boolean = false;
  @State showChapterSettings: boolean = false;
  @State chapters: Array<VideoChapter> = [];
  @State activeQuality: number = 0;
  @State qualityLoading: boolean = false;
  @State playbackRate: number = 1.0;
  @State dmOpacity: number = 0.85;
  @State dmSpeed: number = 1.0;
  // 当前 1.0 在手机上仍明显小于 B 站默认观感，默认整体放大 1.3 倍。
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
  @StorageProp('videoFullscreenExitRequest') @Watch('onFullscreenExitRequested') fullscreenExitRequest: number = 0;
  @StorageProp('videoSeekRequestToken') @Watch('onExternalSeekRequested') seekRequestToken: number = 0;
  @StorageProp('videoPlaybackStopRequest') @Watch('onPlaybackStopRequested') stopRequest: number = 0;
  @StorageLink('sponsorSkipEnabled') sponsorSkipEnabled: boolean = true;
  private player: media.AVPlayer | null = null;
  private audioPlayer: media.AVPlayer | null = null;
  private audioPrepared: boolean = false;
  private xcController: XComponentController = new XComponentController();
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private dmList: Array<DanmakuItem> = [];
  private active: Array<ActiveDm> = [];
  private dmTick: number = -1;
  private dmLastDrawMs: number = 0;
  private dmLastPlayerTime: number = 0;
  private dmCursor: number = 0;
  private nextScrollLane: number = 0;
  private nextTopLane: number = 0;
  private nextBottomLane: number = 0;
  private canvasW: number = 1;
  private canvasH: number = 1;
  private lastSpawnTime: number = -1;
  private hideTimer: number = -1;
  private textWidthCache: Map<string, number> = new Map<string, number>();
  private colorCache: Map<number, string> = new Map<number, string>();
  private sourceIndex: number = 0;
  private retryingSource: boolean = false;
  private runtimeSources: Array<string> = [];
  private runtimeAudioSources: Array<string> = [];
  private audioSourceIndex: number = 0;
  private lastAudioSyncBucket: number = -1;
  private sponsorSegments: Array<SponsorSegment> = [];
  private lastSponsorUuid: string = '';
  private runtimeQualityOptions: Array<VideoQualityOption> = [];
  private resumeAfterPrepare: number = -1;
  private shouldPlayAfterPrepare: boolean = true;
  // seek 采用“末次请求获胜”的串行状态机，避免视频/音频两个 DASH 播放器堆积并发 seek。
  private seekDispatchTimer: number = -1;
  private seekSpinnerTimer: number = -1;
  private seekWatchdogTimer: number = -1;
  private pendingSeekMs: number = -1;
  private pendingSeekPrecise: boolean = false;
  private activeSeekMs: number = -1;
  private activeAudioSeekMs: number = -1;
  private seekInFlight: boolean = false;
  private videoSeekDone: boolean = false;
  private audioSeekDone: boolean = false;
  private seekResumePlaying: boolean = false;
  private holdPreviousRate: number = 1.0;
  private panStartTime: number = 0;
  private panGestureActive: boolean = false;
  private panMode: string = '';
  private panStartX: number = 0;
  private panStartBrightness: number = 0.5;
  private panStartVolume: number = 100;
  private gestureBrightness: number = 0.5;
  private gestureVolume: number = 100;
  private lastGestureApplyMs: number = 0;
  private onlineRequest: number = 0;
  private surfaceId: string = '';
  // 组件销毁后置位：所有跨 await 的换源/重建流程在 initPlayer 前据此放弃，避免泄漏无人释放的 AVPlayer。
  private destroyed: boolean = false;
  // 高精度播放头（秒）：弹幕引擎与恢复定位使用；@State curTime 只做秒级 UI 刷新。
  private playheadSec: number = 0;
  // 拖动进度条期间滑块以拖动值为准，避免 timeUpdate 回写 curTime 把滑块拽回。
  private sliderDragging: boolean = false;
  private sliderDragValue: number = 0;
  private volumeRestoreTimer: number = -1;
  private fullscreenExitTimer: number = -1;
  private doubleTapFeedbackTimer: number = -1;
  // AVPlayer 创建本身是异步的：代次使离页/换源前发起的 createAVPlayer 结果失效并立即释放。
  private playerCreateGeneration: number = 0;
  private playerCreating: boolean = false;
  // 已加载弹幕对应的 cid，避免 aboutToAppear 与换源触发的并发/重复加载。
  private dmLoadedCid: number = -1;
  // drawFrame 双缓冲，避免每帧分配 keep 数组。
  private activeBack: Array<ActiveDm> = [];

  aboutToAppear(): void {
    // 被其他 NavDestination 覆盖时 aboutToDisappear 已置位；返回同一实例需恢复。
    this.destroyed = false;
    this.showControls = false;
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    AppStorage.setOrCreate<number>('videoFullscreenExitRequest', 0);
    if (this.runtimeSources.length === 0) {
      this.runtimeSources = this.videoUrls.length > 0 ? this.videoUrls : (this.videoUrl.length > 0 ? [this.videoUrl] : []);
      this.runtimeAudioSources = this.audioUrls;
      this.runtimeQualityOptions = this.qualityOptions;
      this.activeQuality = this.currentQuality;
    }
    this.danmakuOn = this.externalDanmakuOn;
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
    this.stopDmLoop(true);
    this.dmList = [];
    this.active = [];
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
    // dmList 按 time 有序（二分查找依赖），本地弹幕也必须落在有序位置而非游标处。
    let low: number = 0;
    let high: number = this.dmList.length;
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.dmList[middle].time <= item.time) low = middle + 1;
      else high = middle;
    }
    this.dmList.splice(low, 0, item);
    if (low < this.dmCursor) this.dmCursor++;
    this.spawnDanmaku(this.playheadSec);
  }

  onCompactModeChanged(): void {
    if (!this.compactMode || this.fullscreen) return;
    // 收起播放器时底部抽屉没有足够空间，避免其越出视频框。
    this.closeSettingPanels();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
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
    this.stopDmLoop(false);
    this.onPlayingChange(false);
    // pause 完成后恢复音量；播放器仍保持暂停，返回点击继续时声音正常。
    if (this.volumeRestoreTimer >= 0) clearTimeout(this.volumeRestoreTimer);
    this.volumeRestoreTimer = setTimeout(() => {
      this.volumeRestoreTimer = -1;
      if (this.destroyed) return;
      try {
        const restoreVolume: number = this.gestureVolume / 100;
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
        promptAction.showToast({ message: segment.category === 'sponsor' ? '已跳过赞助广告' : '已跳过推广片段' });
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
    try {
      const list: Array<DanmakuItem> = await BiliApi.getDanmaku(cid);
      if (this.destroyed || this.dmLoadedCid !== cid) return;
      list.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time);
      this.dmList = list;
      this.syncDanmakuCursor(this.playheadSec);
      this.lastSpawnTime = -1;
    } catch (e) {
      // 失败后允许下一次进入/换源重新请求，而不是把 cid 永久标记为已加载。
      if (!this.destroyed && this.dmLoadedCid === cid) this.dmLoadedCid = -1;
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
            p.setVolume(this.gestureVolume / 100);
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
        } else if (state === 'paused' || state === 'completed') {
          this.resumeTransitionActive = false;
          this.playing = false;
          this.showControls = true;
          if (this.hideTimer >= 0) {
            clearTimeout(this.hideTimer);
            this.hideTimer = -1;
          }
          this.onPlayingChange(false);
          this.stopDmLoop(false);
        }
      });
      p.on('error', (err: BusinessError) => {
        this.handlePlayerError(p, err.message);
      });
      p.on('seekDone', (position: number) => {
        this.onVideoSeekDone(p, position);
      });
      p.on('timeUpdate', (t: number) => {
        if (this.player !== p) return;
        // AVPlayer 上报毫秒，播放器 UI/弹幕内部统一使用秒。
        const nextTime: number = t / 1000;
        if (this.dmLastPlayerTime > 0 && (nextTime < this.dmLastPlayerTime - 0.5 || nextTime > this.dmLastPlayerTime + 2.5)) {
          this.resetDanmakuAt(nextTime);
        }
        this.dmLastPlayerTime = nextTime;
        this.playheadSec = nextTime;
        // 控制层只需秒级刷新，避免 250ms 一次的 @State 写入驱动整棵控制子树重建。
        if (Math.floor(nextTime) !== Math.floor(this.curTime)) this.curTime = nextTime;
        this.onProgress(nextTime);
        this.spawnDanmaku(nextTime);
        if (this.maybeSkipSponsor(nextTime)) return;
        const audio: media.AVPlayer | null = this.audioPlayer;
        // 双 DASH 轨只在明显失步时兜底校时；原先每 5 秒、220ms 阈值会制造周期性顿挫。
        const syncBucket: number = Math.floor(nextTime / 30);
        if (!this.seekInFlight && audio !== null && this.audioPrepared && syncBucket !== this.lastAudioSyncBucket &&
          Math.abs(audio.currentTime - t) > 900) {
          this.lastAudioSyncBucket = syncBucket;
          audio.seek(t, media.SeekMode.SEEK_CLOSEST);
        }
      });
      p.on('durationUpdate', (d: number) => {
        this.duration = d / 1000;
      });
      p.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
        if (infoType === media.BufferingInfoType.BUFFERING_START) {
          // seek 的短暂缓冲由延迟提示管理，快速定位不闪 loading。
          if (!this.seekInFlight) this.buffering = true;
          this.stopDmLoop(false);
        } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
          // seek 尚未完成音轨对齐时不能提前隐藏 loading 或恢复弹幕时钟。
          if (!this.seekInFlight) {
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
    return this.runtimeSources[Math.min(this.sourceIndex, Math.max(0, this.runtimeSources.length - 1))] ?? '';
  }

  private currentAudioSourceUrl(): string {
    return this.runtimeAudioSources[Math.min(this.audioSourceIndex,
      Math.max(0, this.runtimeAudioSources.length - 1))] ?? '';
  }

  /** 快速出首帧、卡顿后留足续播水位，同时限制前向缓存避免高码率视频占用过多内存。 */
  private videoPlaybackStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: 15,
      preferredBufferDurationForPlaying: 1,
      thresholdForAutoQuickPlay: 3,
      showFirstFrameOnPrepare: true,
    };
  }

  private audioPlaybackStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: 20,
      preferredBufferDurationForPlaying: 0.6,
      thresholdForAutoQuickPlay: 2.6,
    };
  }

  /** PiliPlus 同样在底层播放器统一设置 PC UA + bilibili Referer。 */
  private playbackHeaders(): Record<string, string> {
    return {
      'User-Agent': Constants.browserUa,
      'Referer': 'https://www.bilibili.com/',
    };
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
          audio.setVolume(this.gestureVolume / 100);
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
      this.seekResumePlaying = resumePlaying;
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
      this.showQualitySettings = false;
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
      this.showQualitySettings = false;
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
    this.showSpeedSettings = false;
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
    this.holdPreviousRate = this.playbackRate;
    this.holdSpeedActive = true;
    this.applyTemporarySpeed(2.0);
  }

  private endHoldSpeed(): void {
    if (!this.holdSpeedActive) return;
    this.holdSpeedActive = false;
    this.applyTemporarySpeed(this.holdPreviousRate);
  }

  private beginHorizontalSeek(): void {
    if (this.duration <= 0) return;
    this.panStartTime = this.playheadSec;
    this.panGestureActive = false;
    this.gestureSeekPreview = -1;
  }

  private loadGestureLevels(): void {
    const brightness: number = Immersive.windowBrightness();
    if (brightness >= 0) this.gestureBrightness = brightness;
    // AVPlayer 没有启用 APP_INDIVIDUAL 模式，应用音量百分比既不控制实际声音，
    // 还可能读回旧版本遗留的 0。播放器本地增益以字段默认值 100% 起步即可。
  }

  private applyGestureVolume(value: number): void {
    const normalized: number = Math.max(0, Math.min(1, value / 100));
    try {
      // AVPlayer 默认不属于 APP_INDIVIDUAL 音量模式，setAppVolumePercentage
      // 在部分设备上只会返回成功但不改变声音；直接设置当前视频/音频轨才可靠。
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
    this.beginHorizontalSeek();
    this.panMode = '';
    this.gestureAdjustKind = '';
    this.gestureAdjustPercent = -1;
    this.panStartX = event.fingerList.length > 0 ? event.fingerList[0].localX : this.canvasW / 2;
    const brightness: number = Immersive.windowBrightness();
    if (brightness >= 0) this.gestureBrightness = brightness;
    this.panStartBrightness = this.gestureBrightness;
    this.panStartVolume = this.gestureVolume;
  }

  private updatePlayerPan(event: GestureEvent): void {
    const absX: number = Math.abs(event.offsetX);
    const absY: number = Math.abs(event.offsetY);
    if (this.panMode.length === 0) {
      if (Math.max(absX, absY) < 12) return;
      if (absX > absY * 1.15) this.panMode = 'seek';
      else if (absY > absX * 1.15) this.panMode = this.panStartX < this.canvasW / 2 ? 'brightness' : 'volume';
      else return;
    }
    if (this.panMode === 'seek') {
      this.updateHorizontalSeek(event.offsetX);
      return;
    }
    const travel: number = Math.max(180, this.canvasH * 0.72);
    const now: number = Date.now();
    if (this.panMode === 'brightness') {
      const value: number = Math.max(0.02, Math.min(1, this.panStartBrightness - event.offsetY / travel));
      this.gestureBrightness = value;
      this.gestureAdjustKind = '亮度';
      this.gestureAdjustPercent = Math.round(value * 100);
      if (now - this.lastGestureApplyMs >= 16) Immersive.setWindowBrightness(value);
    } else {
      const value: number = Math.max(0, Math.min(100, this.panStartVolume - event.offsetY * 100 / travel));
      this.gestureVolume = value;
      this.gestureAdjustKind = '音量';
      this.gestureAdjustPercent = Math.round(value);
      this.applyGestureVolume(value);
    }
    if (now - this.lastGestureApplyMs >= 16) this.lastGestureApplyMs = now;
  }

  private endPlayerPan(): void {
    if (this.panMode === 'seek') this.endHorizontalSeek();
    else {
      this.panGestureActive = false;
      this.gestureSeekPreview = -1;
    }
    this.panMode = '';
    this.gestureAdjustKind = '';
    this.gestureAdjustPercent = -1;
  }

  private updateHorizontalSeek(offsetX: number): void {
    if (this.duration <= 0 || Math.abs(offsetX) < 12) return;
    this.panGestureActive = true;
    // 横滑期间主动展示底部进度条，并用预览值驱动滑块；松手后才真正 seek。
    this.showControls = true;
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    // 长视频提高单次拖动跨度，短视频保持精细；最终只在松手时 seek 一次。
    const secondsPerVp: number = Math.max(0.10, Math.min(0.60, this.duration / 1800));
    this.gestureSeekPreview = Math.max(0, Math.min(this.duration, this.panStartTime + offsetX * secondsPerVp));
  }

  private endHorizontalSeek(): void {
    if (this.panGestureActive && this.gestureSeekPreview >= 0) {
      this.seekTo(this.gestureSeekPreview, true);
    }
    this.panGestureActive = false;
    this.gestureSeekPreview = -1;
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
    animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
      this.doubleTapFeedbackScale = 1;
      this.doubleTapFeedbackOpacity = 1;
    });
    this.togglePlay();
    this.doubleTapFeedbackTimer = setTimeout(() => {
      this.doubleTapFeedbackTimer = -1;
      animateTo({ duration: 160, curve: Curve.EaseIn }, () => {
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
      p.pause();
      if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.pause();
    } else {
      // 用户主动点击继续时先通知外层恢复完整播放器高度；首播/切清晰度不会误触发。
      this.resumeTransitionActive = this.compactMode && !this.fullscreen;
      this.onResumeRequest();
      try {
        p.play();
        if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.play();
      } catch (e) {
        this.resumeTransitionActive = false;
      }
    }
  }

  seekTo(positionSec: number, precise: boolean = false): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) {
      return;
    }
    const clamped: number = Math.max(0, Math.min(this.duration > 0 ? this.duration : positionSec, positionSec));
    const targetMs: number = Math.floor(clamped * 1000);
    this.resetDanmakuAt(clamped);
    this.playheadSec = clamped;
    this.curTime = clamped;
    this.onProgress(clamped);
    this.pendingSeekMs = targetMs;
    this.pendingSeekPrecise = precise;
    this.seekResumePlaying = this.seekResumePlaying || this.playing;
    this.lastAudioSyncBucket = -1;
    if (this.seekInFlight) return;
    if (this.seekDispatchTimer >= 0) clearTimeout(this.seekDispatchTimer);
    // 合并短时间内连续点击/滑动，只让底层解码器处理最后一次目标。
    this.seekDispatchTimer = setTimeout(() => {
      this.seekDispatchTimer = -1;
      this.dispatchPendingSeek();
    }, 90);
  }

  private dispatchPendingSeek(): void {
    const video: media.AVPlayer | null = this.player;
    if (video === null || !this.prepared || this.pendingSeekMs < 0) return;
    const targetMs: number = this.pendingSeekMs;
    const precise: boolean = this.pendingSeekPrecise;
    this.pendingSeekMs = -1;
    this.activeSeekMs = targetMs;
    this.activeAudioSeekMs = -1;
    this.videoSeekDone = false;
    this.audioSeekDone = this.audioPlayer === null || !this.audioPrepared;
    this.seekInFlight = true;
    const mode: media.SeekMode = precise ? media.SeekMode.SEEK_CLOSEST :
      (targetMs < video.currentTime ? media.SeekMode.SEEK_NEXT_SYNC : media.SeekMode.SEEK_PREV_SYNC);
    this.stopDmLoop(false);
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (audio !== null && this.audioPrepared) {
      try {
        audio.pause();
        this.activeAudioSeekMs = targetMs;
        this.audioSeekDone = false;
        // 经过请求合并后，每次事务只并行提交一组音视频 seek，降低最终定位延迟。
        audio.seek(targetMs, mode);
      } catch (e) {
        this.audioSeekDone = true;
      }
    }
    try {
      video.seek(targetMs, mode);
    } catch (e) {
      this.seekInFlight = false;
      this.recoverPlayersAfterSeekStall(video, targetMs);
      return;
    }
    if (this.seekSpinnerTimer >= 0) clearTimeout(this.seekSpinnerTimer);
    this.seekSpinnerTimer = setTimeout(() => {
      this.seekSpinnerTimer = -1;
      if (this.seekInFlight && this.player === video) this.buffering = true;
    }, 180);
    this.armSeekWatchdog(video, targetMs);
  }

  private onVideoSeekDone(video: media.AVPlayer, position: number): void {
    if (this.player !== video || !this.seekInFlight) return;
    this.videoSeekDone = true;
    this.finishSeek();
  }

  private onAudioSeekDone(audio: media.AVPlayer, position: number): void {
    if (this.audioPlayer !== audio || !this.seekInFlight || this.activeAudioSeekMs < 0) return;
    // 丢弃其他周期校时产生的旧回调，避免错误地提前结束当前 seek。
    if (Math.abs(position - this.activeAudioSeekMs) > 8000) return;
    this.audioSeekDone = true;
    this.finishSeek();
  }

  private finishSeek(): void {
    if (!this.seekInFlight || !this.videoSeekDone || !this.audioSeekDone) return;
    this.clearSeekWatchdog();
    this.clearSeekSpinner();
    this.seekInFlight = false;
    this.activeSeekMs = -1;
    this.activeAudioSeekMs = -1;
    if (this.pendingSeekMs >= 0) {
      this.dispatchPendingSeek();
      return;
    }
    const video: media.AVPlayer | null = this.player;
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (this.seekResumePlaying && video !== null && this.prepared) {
      try {
        if (!this.playing) video.play();
        if (audio !== null && this.audioPrepared) audio.play();
      } catch (e) {
      }
    }
    this.seekResumePlaying = false;
    this.buffering = false;
    if (this.playing) this.startDmLoop();
  }

  private armSeekWatchdog(video: media.AVPlayer, targetMs: number): void {
    this.clearSeekWatchdog();
    this.seekWatchdogTimer = setTimeout(() => {
      this.seekWatchdogTimer = -1;
      if (this.player === video && this.seekInFlight) {
        const latestTarget: number = this.pendingSeekMs >= 0 ? this.pendingSeekMs : targetMs;
        this.pendingSeekMs = -1;
        this.recoverPlayersAfterSeekStall(video, latestTarget);
      }
    }, 4000);
  }

  private clearSeekWatchdog(): void {
    if (this.seekWatchdogTimer >= 0) {
      clearTimeout(this.seekWatchdogTimer);
      this.seekWatchdogTimer = -1;
    }
  }

  private clearSeekSpinner(): void {
    if (this.seekSpinnerTimer >= 0) {
      clearTimeout(this.seekSpinnerTimer);
      this.seekSpinnerTimer = -1;
    }
  }

  private async recoverPlayersAfterSeekStall(stalledVideo: media.AVPlayer, targetMs: number): Promise<void> {
    if (this.player !== stalledVideo) return;
    this.invalidatePlayerCreation();
    const stalledAudio: media.AVPlayer | null = this.audioPlayer;
    this.player = null;
    this.audioPlayer = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.playing = false;
    this.seekInFlight = false;
    this.videoSeekDone = false;
    this.audioSeekDone = false;
    this.resumeAfterPrepare = Math.max(0, targetMs / 1000);
    this.shouldPlayAfterPrepare = this.seekResumePlaying;
    this.seekResumePlaying = false;
    this.buffering = true;
    this.clearSeekSpinner();
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
    // 看门狗触发后组件可能已销毁，避免重建出无人释放的播放器。
    if (this.destroyed) return;
    await this.initPlayer();
  }

  toggleFullscreen(): void {
    if (this.fullscreen) {
      this.exitFullscreen();
    } else {
      this.fullscreen = true;
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
    this.showDmSettings = false;
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
    if (this.showDmSettings || this.showQualitySettings || this.showSpeedSettings || this.showChapterSettings ||
      this.showMoreMenu) {
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
    this.showDmSettings = false;
    this.showQualitySettings = false;
    this.showSpeedSettings = false;
    this.showChapterSettings = false;
    this.showMoreMenu = false;
  }

  /** 竖屏右上角 ⋮ 菜单开关；与其余设置面板互斥。 */
  private toggleMoreMenu(): void {
    const next: boolean = !this.showMoreMenu;
    this.closeSettingPanels();
    this.showMoreMenu = next;
  }

  /** 底部设置面板互斥开关：打开目标面板时关掉其余三个，再点一次则全部收起。 */
  private exclusiveToggle(which: string): void {
    const next: boolean = !(which === 'dm' ? this.showDmSettings : which === 'quality' ? this.showQualitySettings :
      which === 'speed' ? this.showSpeedSettings : this.showChapterSettings);
    this.closeSettingPanels();
    if (which === 'dm') this.showDmSettings = next;
    else if (which === 'quality') this.showQualitySettings = next;
    else if (which === 'speed') this.showSpeedSettings = next;
    else this.showChapterSettings = next;
  }

  private scheduleControlsHide(): void {
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (this.playing && !this.showDmSettings && !this.showQualitySettings &&
        !this.showSpeedSettings && !this.showChapterSettings && !this.showMoreMenu) {
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
    if (this.seekDispatchTimer >= 0) {
      clearTimeout(this.seekDispatchTimer);
      this.seekDispatchTimer = -1;
    }
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
    this.clearSeekWatchdog();
    this.clearSeekSpinner();
    this.pendingSeekMs = -1;
    this.seekInFlight = false;
    this.seekResumePlaying = false;
    this.stopDmLoop(true);
    this.textWidthCache.clear();
    this.colorCache.clear();
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
    if (!this.danmakuOn || this.dmList.length === 0) {
      return;
    }
    // 数量同时受用户密度、实际轨道数和 Canvas 性能上限约束。
    const maxActive: number = this.maxActiveDanmaku();
    const spawnBudget: number = this.fullscreen ? 8 : 5;
    let spawned: number = 0;
    while (this.dmCursor < this.dmList.length && this.dmList[this.dmCursor].time <= now + 0.1 && spawned < spawnBudget) {
      const item: DanmakuItem = this.dmList[this.dmCursor];
      this.dmCursor++;
      spawned++;
      const isTop: boolean = item.mode === 5;
      const isBottom: boolean = item.mode === 4;
      const isScroll: boolean = !isTop && !isBottom;
      if ((isScroll && this.blockScrollDm) || (isTop && this.blockTopDm) ||
        (isBottom && this.blockBottomDm) || (this.blockColorDm && item.color !== 16777215)) {
        continue;
      }
      if (this.active.length >= maxActive) {
        continue;
      }
      const renderText: string = item.text.length > 80 ? item.text.substring(0, 79) + '…' : item.text;
      const textW: number = this.measureText(renderText);
      const renderColor: string = this.dmColor(item.color);
      if (item.mode === 4 || item.mode === 5) {
        // 固定弹幕：顶部/底部居中，停留 4 秒
        const fixedLane: number = this.allocFixedLane(item.mode);
        if (fixedLane < 0) continue;
        this.active.push(new ActiveDm(item, -1, fixedLane, 0, now + 4, true, now, textW, renderText, renderColor));
      } else {
        // 所有弹幕保持近似相同的过屏时间；长文本虽然速度更快，但分轨时会预判追尾。
        const spawnX: number = this.canvasW + Math.max(10, this.dmFontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / Math.max(0.5, this.dmSpeed);
        const speed: number = (spawnX + textW) / travelSeconds;
        const lane: number = this.allocLane(spawnX, speed);
        if (lane < 0) continue;
        this.active.push(new ActiveDm(item, spawnX, lane, speed, 0, false, now, textW, renderText, renderColor));
      }
    }
    if (this.active.length > 0) this.startDmLoop();
  }

  private dmLineHeight(): number {
    // 旧实现固定加 10，字号越大空隙越夸张；现在只保留 3vp 防描边相碰。
    return this.dmFontSize() + 3;
  }

  private dmLaneCount(): number {
    // 弹幕只覆盖画面上方约 86%，给进度条/字幕留出底部安全区。
    const usableHeight: number = Math.max(this.dmLineHeight(), this.canvasH * 0.86);
    return Math.max(1, Math.floor(usableHeight / this.dmLineHeight()));
  }

  private maxActiveDanmaku(): number {
    const byDensity: number = this.fullscreen ? this.dmDensity * 2 : this.dmDensity;
    const byLane: number = this.dmLaneCount() * 4;
    return Math.max(3, Math.min(this.fullscreen ? 48 : 28, byDensity, byLane));
  }

  private laneSafeForScroll(lane: number, spawnX: number, newSpeed: number): boolean {
    const minimumGap: number = Math.max(18, this.dmFontSize() * 0.62);
    for (let i: number = 0; i < this.active.length; i++) {
      const current: ActiveDm = this.active[i];
      if (current.lane !== lane) continue;
      // 固定弹幕仍占据同一条视觉轨道，滚动弹幕不能从它下面穿过。
      if (current.isFixed) return false;
      const currentTail: number = current.x + current.textWidth;
      if (currentTail + minimumGap > spawnX) return false;
      if (newSpeed > current.speed + 0.01) {
        const catchSeconds: number = (spawnX - currentTail - minimumGap) / (newSpeed - current.speed);
        const currentExitSeconds: number = Math.max(0, (currentTail + minimumGap) / Math.max(1, current.speed));
        if (catchSeconds < currentExitSeconds) return false;
      }
    }
    return true;
  }

  allocLane(spawnX: number, speed: number): number {
    const laneCount: number = this.dmLaneCount();
    for (let offset: number = 0; offset < laneCount; offset++) {
      const lane: number = (this.nextScrollLane + offset) % laneCount;
      if (this.laneSafeForScroll(lane, spawnX, speed)) {
        this.nextScrollLane = (lane + 1) % laneCount;
        return lane;
      }
    }
    return -1;
  }

  allocFixedLane(mode: number): number {
    const laneCount: number = this.dmLaneCount();
    const candidateCount: number = Math.max(1, Math.min(3, laneCount));
    const start: number = mode === 5 ? this.nextTopLane : this.nextBottomLane;
    for (let offset: number = 0; offset < candidateCount; offset++) {
      const relative: number = (start + offset) % candidateCount;
      const lane: number = mode === 5 ? relative : laneCount - 1 - relative;
      let available: boolean = true;
      for (let i: number = 0; i < this.active.length; i++) {
        // 顶部、底部和滚动弹幕共用视觉轨道，彻底避免模式间互相覆盖。
        if (this.active[i].lane === lane) {
          available = false;
          break;
        }
      }
      if (available) {
        if (mode === 5) this.nextTopLane = (relative + 1) % candidateCount;
        else this.nextBottomLane = (relative + 1) % candidateCount;
        return lane;
      }
    }
    return -1;
  }

  measureText(text: string): number {
    const size: number = this.dmFontSize();
    const key: string = String(Math.round(size * 10)) + ':' + text;
    const cached: number | undefined = this.textWidthCache.get(key);
    if (cached !== undefined) return cached;
    this.ctx.font = '600 ' + size + 'px sans-serif';
    const w: number = this.ctx.measureText(text).width;
    const result: number = Math.max(20, w);
    if (this.textWidthCache.size > 512) {
      // 整体清空会造成短时间内大量重复测量；改为淘汰最早插入的一半（Map 迭代序即插入序）。
      let evict: number = 256;
      for (const oldest of this.textWidthCache.keys()) {
        if (evict <= 0) break;
        this.textWidthCache.delete(oldest);
        evict--;
      }
    }
    this.textWidthCache.set(key, result);
    return result;
  }

  dmColor(color: number): string {
    const cached: string | undefined = this.colorCache.get(color);
    if (cached !== undefined) return cached;
    const result: string = colorHex(color);
    this.colorCache.set(color, result);
    return result;
  }

  drawFrame(advance: boolean = true): void {
    this.ctx.clearRect(0, 0, this.canvasW, this.canvasH);
    const now: number = this.playheadSec;
    const fontSize: number = this.dmFontSize();
    const laneH: number = this.dmLineHeight();
    // 双缓冲原地复用，避免每帧分配 keep 数组带来的 GC 压力。
    const keep: Array<ActiveDm> = this.activeBack;
    keep.length = 0;
    const drawMs: number = Date.now();
    const deltaSec: number = advance ?
      (this.dmLastDrawMs > 0 ? Math.min(0.12, Math.max(0.012, (drawMs - this.dmLastDrawMs) / 1000)) : 0.033) : 0;
    if (advance) this.dmLastDrawMs = drawMs;
    this.ctx.globalAlpha = this.dmOpacity;
    this.ctx.font = '600 ' + fontSize + 'px sans-serif';
    this.ctx.strokeStyle = '#B3000000';
    this.ctx.lineWidth = this.fullscreen ? 2.5 : 2;
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (dm.isFixed) {
        if (now > dm.fixedUntil) {
          continue;
        }
        this.ctx.fillStyle = dm.renderColor;
        const x: number = (this.canvasW - dm.textWidth) / 2;
        const y: number = dm.lane * laneH + fontSize;
        this.ctx.strokeText(dm.renderText, x, y);
        this.ctx.fillText(dm.renderText, x, y);
        keep.push(dm);
      } else {
        dm.x -= dm.speed * deltaSec;
        if (dm.x + dm.textWidth < -10) {
          continue;
        }
        this.ctx.fillStyle = dm.renderColor;
        const y: number = dm.lane * laneH + fontSize;
        this.ctx.strokeText(dm.renderText, dm.x, y);
        this.ctx.fillText(dm.renderText, dm.x, y);
        keep.push(dm);
      }
    }
    this.ctx.globalAlpha = 1;
    this.activeBack = this.active;
    this.active = keep;
    if (this.active.length === 0) this.stopDmLoop(false);
  }

  startDmLoop(): void {
    if (this.dmTick >= 0 || !this.danmakuOn || this.active.length === 0) {
      return;
    }
    this.dmLastDrawMs = Date.now();
    this.dmTick = setInterval(() => {
      if (this.playing && this.danmakuOn && this.active.length > 0) {
        this.drawFrame();
      }
    // 仅在存在活动弹幕时运行：普通 30fps、全屏 40fps，兼顾连续性与功耗。
    }, this.fullscreen ? 25 : 33);
  }

  private onDanmakuAreaChange(newV: Area): void {
    const newW: number = newV.width as number;
    const newH: number = newV.height as number;
    if (Math.abs(newW - this.canvasW) < 0.5 && Math.abs(newH - this.canvasH) < 0.5) return;
    this.canvasW = Math.max(1, newW);
    this.canvasH = Math.max(1, newH);

    // Canvas 改尺寸会清空后备缓冲；同步重绘可避免收放播放器时出现闪空抽搐。
    const maxLane: number = this.dmLaneCount();
    const keep: Array<ActiveDm> = [];
    for (let i: number = 0; i < this.active.length; i++) {
      if (this.active[i].lane < maxLane) keep.push(this.active[i]);
    }
    this.active = keep;
    this.drawFrame(false);
  }

  stopDmLoop(clearActive: boolean): void {
    if (this.dmTick >= 0) {
      clearInterval(this.dmTick);
      this.dmTick = -1;
    }
    this.dmLastDrawMs = 0;
    if (clearActive) {
      this.active = [];
      this.nextScrollLane = 0;
      this.nextTopLane = 0;
      this.nextBottomLane = 0;
    }
    this.ctx.clearRect(0, 0, this.canvasW, this.canvasH);
  }

  toggleDanmaku(): void {
    this.setDanmakuEnabled(!this.danmakuOn, true);
  }

  private setDanmakuEnabled(enabled: boolean, notify: boolean): void {
    if (this.danmakuOn === enabled) return;
    this.danmakuOn = enabled;
    if (!enabled) {
      this.stopDmLoop(true);
    } else {
      // 重新开启时从当前播放位置继续，不补画已经错过的一大批弹幕。
      while (this.dmCursor < this.dmList.length && this.dmList[this.dmCursor].time < this.playheadSec - 0.2) {
        this.dmCursor++;
      }
      this.spawnDanmaku(this.playheadSec);
    }
    if (notify) this.onDanmakuChange(enabled);
  }

  restartDmLoopForViewport(): void {
    const shouldRestart: boolean = this.dmTick >= 0;
    this.stopDmLoop(false);
    this.textWidthCache.clear();
    // 横竖屏字号和轨道数不同，切换时立即重排，避免旋转后沿用旧坐标产生抽搐。
    this.setDmFontScale(this.dmFontScale);
    if (shouldRestart || (this.playing && this.active.length > 0)) this.startDmLoop();
  }

  resetDanmakuAt(time: number): void {
    this.stopDmLoop(true);
    this.syncDanmakuCursor(time);
    this.dmLastPlayerTime = time;
  }

  setDmSpeed(value: number): void {
    this.dmSpeed = value;
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (!dm.isFixed) {
        const spawnInset: number = Math.max(10, this.dmFontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / Math.max(0.5, value);
        dm.speed = (this.canvasW + spawnInset + dm.textWidth) / travelSeconds;
      }
    }
  }

  setDmFontScale(value: number): void {
    this.dmFontScale = value;
    this.textWidthCache.clear();
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      dm.textWidth = this.measureText(dm.renderText);
      if (!dm.isFixed) {
        const spawnInset: number = Math.max(10, this.dmFontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / Math.max(0.5, this.dmSpeed);
        dm.speed = (this.canvasW + spawnInset + dm.textWidth) / travelSeconds;
      }
    }
    const laneCount: number = this.dmLaneCount();
    this.active = this.active.filter((dm: ActiveDm) => dm.lane < laneCount);
    this.drawFrame(false);
  }

  setDmDensity(value: number): void {
    this.dmDensity = Math.round(value);
    const maxActive: number = this.maxActiveDanmaku();
    if (this.active.length > maxActive) this.active = this.active.slice(0, maxActive);
  }

  applyDmFilters(): void {
    const keep: Array<ActiveDm> = [];
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      const isTop: boolean = dm.item.mode === 5;
      const isBottom: boolean = dm.item.mode === 4;
      const isScroll: boolean = !isTop && !isBottom;
      if ((isScroll && this.blockScrollDm) || (isTop && this.blockTopDm) ||
        (isBottom && this.blockBottomDm) || (this.blockColorDm && dm.item.color !== 16777215)) continue;
      keep.push(dm);
    }
    this.active = keep;
    if (this.active.length === 0) this.stopDmLoop(false);
  }

  syncDanmakuCursor(time: number): void {
    let low: number = 0;
    let high: number = this.dmList.length;
    const threshold: number = Math.max(0, time - 0.12);
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.dmList[middle].time < threshold) low = middle + 1;
      else high = middle;
    }
    this.dmCursor = low;
  }

  /** 默认字号进一步增大；行高单独由 dmLineHeight 控制，不再用大间距假装字号。 */
  private dmFontSize(): number {
    return (this.fullscreen ? 46 : 36) * this.dmFontScale;
  }

  /** 收起且暂停时只保留提示文字，不在当前画面上再叠一层深色控制渐变。 */
  private controlsGradientColors(): Array<[ResourceColor, number]> {
    if (this.compactMode && !this.fullscreen && !this.playing) {
      return [['#00000000', 0.0], ['#00000000', 1.0]];
    }
    return CONTROLS_GRADIENT_COLORS;
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

      // 错误遮罩
      if (this.errorText.length > 0) {
        Column({ space: 8 }) {
          Text('⚠')
            .fontSize(30)
            .fontColor('#FFFFFF')
          Text(this.errorText)
            .fontSize(13)
            .fontColor('#FFFFFF')
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
        panStartTime: this.panStartTime,
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
            Blank()
            // 收起态无论播放或暂停都只使用左下角播放键，不再在画面中央重复放入口。
            Row({ space: 7 }) {
              this.IconButton(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'), 16, 36, 36, '#FFFFFF', true,
                () => {
                  this.togglePlay();
                })
              Text(formatDuration(this.progressDisplayTime()))
                .fontSize(10)
                .fontColor('#FFFFFF')
              this.ProgressSlider(true)
              this.IconButton($r('app.media.ic_fullscreen'), 20, 36, 36, '#FFFFFF', false, () => {
                this.toggleFullscreen();
              })
            }
            .width('100%')
            .height(44)
            .padding({ left: 8, right: 8, bottom: 4 })
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
              showQualitySettings: this.showQualitySettings,
              showChapterSettings: this.showChapterSettings,
              showSpeedSettings: this.showSpeedSettings,
              dmDraft: this.dmDraft,
              dmSending: this.dmSending,
              onPlay: () => this.togglePlay(),
              onDanmaku: () => this.toggleDanmaku(),
              onDanmakuSettings: () => this.exclusiveToggle('dm'),
              onSponsor: () => {
                this.sponsorSkipEnabled = !this.sponsorSkipEnabled;
                promptAction.showToast({ message: this.sponsorSkipEnabled ? '广告空降已开启' : '广告空降已关闭' });
              },
              onChapter: () => this.exclusiveToggle('chapter'),
              onQuality: () => this.exclusiveToggle('quality'),
              onSpeed: () => this.exclusiveToggle('speed'),
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
          colors: this.controlsGradientColors(),
        })
      }

      // 竖屏 ⋮ 更多菜单：浮在播放器右上角，透明区域不拦截画面点击。
      if (this.showControls && this.showMoreMenu && !this.fullscreen && this.errorText.length === 0) {
        this.MoreMenuPanel()
      }

      if (this.showControls && this.showDmSettings && this.errorText.length === 0) {
        this.SettingsPanelHost(0)
      }

      if (this.showControls && this.showQualitySettings && this.errorText.length === 0) {
        this.SettingsPanelHost(1)
      }

      if (this.showControls && this.showChapterSettings && this.errorText.length === 0) {
        this.SettingsPanelHost(2)
      }

      if (this.showControls && this.showSpeedSettings && this.errorText.length === 0) {
        this.SettingsPanelHost(3)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor('#000000')
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2 })
          .onAction(() => this.handleDoubleTap()),
        TapGesture({ count: 1 })
          .onAction(() => this.toggleControls()),
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
        this.seekTo(value);
      }
    }
  }

  /** 设置面板状态编排留在播放器；具体视觉与选项列表由独立组件负责。 */
  @Builder
  SettingsPanelHost(which: number) {    PlayerSettingsPanel({
      which: which,
      fullscreen: this.fullscreen,
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
      onResetDanmaku: () => {
        this.dmOpacity = 0.85;
        this.setDmSpeed(1);
        this.setDmFontScale(1.3);
        this.setDmDensity(18);
        this.blockScrollDm = false;
        this.blockTopDm = false;
        this.blockBottomDm = false;
        this.blockColorDm = false;
        this.applyDmFilters();
      },
      onDmOpacityChange: (value: number) => this.dmOpacity = value,
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
        this.showChapterSettings = false;
      },
      onSpeedChange: (rate: number) => this.setPlaybackSpeed(rate),
    })
  }

  /** 竖屏 ⋮ 更多菜单：清晰度/倍速/弹幕设置/分段/空降收纳项。 */
  @Builder
  MoreMenuPanel() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 2 }) {
        this.MoreMenuItem('清晰度', this.qualityLoading ? '切换中…' : this.qualityLabel(),
          () => this.exclusiveToggle('quality'))
        this.MoreMenuItem('倍速',
          this.playbackRate === 1 ? '1.0x' : this.playbackRate.toFixed(this.playbackRate % 1 === 0 ? 0 : 2) + 'x',
          () => this.exclusiveToggle('speed'))
        this.MoreMenuItem('弹幕设置', '', () => this.exclusiveToggle('dm'))
        if (this.chapters.length > 0) {
          this.MoreMenuItem('分段视频', String(this.chapters.length) + ' 段', () => this.exclusiveToggle('chapter'))
        }
        this.MoreMenuItem('广告空降', this.sponsorSkipEnabled ? '已开启' : '已关闭', () => {
          this.sponsorSkipEnabled = !this.sponsorSkipEnabled;
          promptAction.showToast({ message: this.sponsorSkipEnabled ? '广告空降已开启' : '广告空降已关闭' });
        })
      }
      .width(164)
      .padding({ top: 5, bottom: 5 })
      .backgroundColor('#F21D1E22')
      .borderRadius(10)
      .margin({ top: 48, right: 8 })
    }
    .width('100%')
    .height('100%')
    // 空白区域不拦截画面点击（透出到底层播放/隐藏控制层手势），菜单项自身可点。
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  MoreMenuItem(label: string, value: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#FFFFFF')
      Blank()
      if (value.length > 0) {
        Text(value)
          .fontSize(12)
          .fontColor('#B3FFFFFF')
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .onClick(() => onTap())
  }

}
