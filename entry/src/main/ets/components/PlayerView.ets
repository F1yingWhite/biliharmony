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

// 活跃弹幕（正在屏幕上运动/停留）
class ActiveDm {
  item: DanmakuItem;
  x: number;
  lane: number;
  speed: number;
  fixedUntil: number; // 固定弹幕消失时刻（视频秒）
  isFixed: boolean;
  born: number;
  textWidth: number;
  renderText: string;
  renderColor: string;

  constructor(item: DanmakuItem, x: number, lane: number, speed: number, fixedUntil: number, isFixed: boolean,
    born: number, textWidth: number, renderText: string, renderColor: string) {
    this.item = item;
    this.x = x;
    this.lane = lane;
    this.speed = speed;
    this.fixedUntil = fixedUntil;
    this.isFixed = isFixed;
    this.born = born;
    this.textWidth = textWidth;
    this.renderText = renderText;
    this.renderColor = renderColor;
  }
}

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
  @Prop @Watch('onExternalDanmakuChanged') externalDanmakuOn: boolean = true;
  @Prop localDanmakuText: string = '';
  @Prop @Watch('onLocalDanmakuRequested') localDanmakuToken: number = 0;
  @Prop @Watch('onCompactModeChanged') compactMode: boolean = false;
  onFullscreenChange: (fullscreen: boolean) => void = () => {};
  onPlayingChange: (playing: boolean) => void = () => {};
  onResumeRequest: () => void = () => {};
  onDanmakuChange: (enabled: boolean) => void = () => {};
  onProgress: (seconds: number) => void = () => {};
  onLike: () => void = () => {};
  onCoin: () => void = () => {};
  onShare: () => void = () => {};
  @State surfaceId: string = '';
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

  aboutToAppear(): void {
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
    this.loadDanmaku();
    this.loadSponsorSegments();
    this.loadVideoChapters();
    await this.initPlayer();
  }

  onExternalDanmakuChanged(): void {
    this.setDanmakuEnabled(this.externalDanmakuOn, false);
  }

  onLocalDanmakuRequested(): void {
    const text: string = this.localDanmakuText.trim();
    if (text.length === 0) return;
    const item: DanmakuItem = new DanmakuItem(this.curTime, 1, 0xFFFFFF, text);
    this.dmList.splice(this.dmCursor, 0, item);
    this.spawnDanmaku(this.curTime);
  }

  onCompactModeChanged(): void {
    if (!this.compactMode || this.fullscreen) return;
    // 收起播放器时底部抽屉没有足够空间，避免其越出视频框。
    this.showDmSettings = false;
    this.showQualitySettings = false;
    this.showSpeedSettings = false;
    this.showChapterSettings = false;
  }

  aboutToDisappear(): void {
    AppStorage.setOrCreate<boolean>('videoPlayerFullscreen', false);
    this.endHoldSpeed();
    this.gestureSeekPreview = -1;
    this.resumeAfterPrepare = this.curTime;
    this.shouldPlayAfterPrepare = false;
    this.muteImmediately();
    this.release();
    this.playing = false;
    this.showControls = true;
    this.onPlayingChange(false);
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
    setTimeout(() => {
      try {
        if (this.player === video && video !== null && this.prepared) video.setVolume(1);
        if (this.audioPlayer === audio && audio !== null && this.audioPrepared) audio.setVolume(1);
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
    this.sponsorSegments = await BiliApi.getSponsorSegments(this.bvid, this.cid);
    this.lastSponsorUuid = '';
  }

  async loadVideoChapters(): Promise<void> {
    this.chapters = await BiliApi.getVideoChapters(this.aid, this.bvid, this.cid);
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
    const list: Array<DanmakuItem> = await BiliApi.getDanmaku(this.cid);
    list.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time);
    this.dmList = list;
    this.syncDanmakuCursor(this.curTime);
    this.lastSpawnTime = -1;
  }

  // XComponent 就绪后初始化播放器
  onSurfaceReady(): void {
    this.surfaceId = this.xcController.getXComponentSurfaceId();
    this.initPlayer();
  }

  async initPlayer(): Promise<void> {
    if (this.player !== null) {
      return;
    }
    try {
      const p: media.AVPlayer = await media.createAVPlayer();
      this.player = p;
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
          } catch (e) {
            // 某些视频解码器不支持非常用倍速，保持 1x 即可。
          }
          this.tryStartPreparedPlayers();
        } else if (state === 'playing') {
          this.playing = true;
          this.onPlayingChange(true);
          this.scheduleControlsHide();
          this.startDmLoop();
          this.buffering = false;
        } else if (state === 'paused' || state === 'completed') {
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
        this.curTime = nextTime;
        this.onProgress(nextTime);
        this.spawnDanmaku(this.curTime);
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
      // PiliPlus 同样在底层播放器统一设置 PC UA + bilibili Referer。
      const source: media.MediaSource = media.createMediaSourceWithUrl(sourceUrl, {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
        'Referer': 'https://www.bilibili.com/',
      });
      if (this.runtimeAudioSources.length > 0) await this.initAudioPlayer();
      await p.setMediaSource(source, this.videoPlaybackStrategy());
    } catch (e) {
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

  private async initAudioPlayer(): Promise<void> {
    if (this.audioPlayer !== null || this.runtimeAudioSources.length === 0) return;
    const sourceUrl: string = this.currentAudioSourceUrl();
    if (sourceUrl.length === 0) return;
    const audio: media.AVPlayer = await media.createAVPlayer();
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
    const source: media.MediaSource = media.createMediaSourceWithUrl(sourceUrl, {
      'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
      'Referer': 'https://www.bilibili.com/',
    });
    await audio.setMediaSource(source, this.audioPlaybackStrategy());
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
    const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(this.aid, this.bvid, this.cid, qn);
    if (info === null || info.urls.length === 0) {
      this.qualityLoading = false;
      this.errorText = '该清晰度暂时不可用';
      return;
    }
    const oldPlayer: media.AVPlayer | null = this.player;
    const oldAudioPlayer: media.AVPlayer | null = this.audioPlayer;
    this.resumeAfterPrepare = this.curTime;
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
    this.qualityLoading = false;
    await this.initPlayer();
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
    this.panStartTime = this.curTime;
    this.panGestureActive = false;
    this.gestureSeekPreview = -1;
  }

  private updateHorizontalSeek(offsetX: number): void {
    if (this.duration <= 0 || Math.abs(offsetX) < 12) return;
    this.panGestureActive = true;
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
      this.errorText = '播放出错：' + message;
      return;
    }
    this.retryingSource = true;
    this.resumeAfterPrepare = this.curTime;
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
    this.resumeAfterPrepare = this.curTime;
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
      this.onResumeRequest();
      p.play();
      if (this.audioPlayer !== null && this.audioPrepared) this.audioPlayer.play();
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
    setTimeout(() => {
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
    if (this.showDmSettings || this.showQualitySettings || this.showSpeedSettings || this.showChapterSettings) {
      this.showDmSettings = false;
      this.showQualitySettings = false;
      this.showSpeedSettings = false;
      this.showChapterSettings = false;
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

  private scheduleControlsHide(): void {
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      if (this.playing && !this.showDmSettings && !this.showQualitySettings &&
        !this.showSpeedSettings && !this.showChapterSettings) {
        this.showControls = false;
      }
    }, 3000);
  }

  release(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    if (this.seekDispatchTimer >= 0) {
      clearTimeout(this.seekDispatchTimer);
      this.seekDispatchTimer = -1;
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
      try {
        p.release();
      } catch (e) {
        // ignore
      }
      this.player = null;
    }
    const audio: media.AVPlayer | null = this.audioPlayer;
    if (audio !== null) {
      try {
        audio.release();
      } catch (e) {
        // ignore
      }
      this.audioPlayer = null;
    }
    this.audioPrepared = false;
    this.prepared = false;
    this.playing = false;
  }

  // ===== 弹幕引擎 =====
  private dmLastTime: number = 0;

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
    if (this.textWidthCache.size > 512) this.textWidthCache.clear();
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
    const now: number = this.curTime;
    const fontSize: number = this.dmFontSize();
    const laneH: number = this.dmLineHeight();
    const keep: Array<ActiveDm> = [];
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
      while (this.dmCursor < this.dmList.length && this.dmList[this.dmCursor].time < this.curTime - 0.2) {
        this.dmCursor++;
      }
      this.spawnDanmaku(this.curTime);
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

      if (this.holdSpeedActive || this.gestureSeekPreview >= 0) {
        Row({ space: 7 }) {
          Text(this.holdSpeedActive ? '»' : (this.gestureSeekPreview >= this.panStartTime ? '››' : '‹‹'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text(this.holdSpeedActive ? '2× 快速播放' :
            formatDuration(this.gestureSeekPreview) + ' / ' + formatDuration(this.duration))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 14, right: 14, top: 9, bottom: 9 })
        .borderRadius(18)
        .backgroundColor('#A6000000')
        .backdropBlur(12)
        .hitTestBehavior(HitTestMode.None)
      }

      // 控件层
      if ((this.showControls || (!this.playing && this.compactMode && !this.fullscreen)) && this.errorText.length === 0) {
        Column() {
          if (this.compactMode && !this.fullscreen) {
            if (!this.playing) {
              // 暂停收起态保留视频画面，叠加整块蒙版与居中继续播放按钮。
              Stack({ alignContent: Alignment.Center }) {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor('#73000000')
                Column({ space: 5 }) {
                  Stack({ alignContent: Alignment.Center }) {
                    Circle()
                      .width(44)
                      .height(44)
                      .fill('#A6000000')
                      .stroke('#66FFFFFF')
                      .strokeWidth(0.5)
                    Image($r('app.media.ic_play'))
                      .width(22)
                      .height(22)
                      .fillColor('#FFFFFF')
                  }
                  .width(48)
                  .height(48)
                  Text('已暂停 · 点击继续')
                    .fontSize(10)
                    .fontColor('#D9FFFFFF')
                }
              }
              .width('100%')
              .height('100%')
              .onClick(() => {
                this.togglePlay();
              })
            } else {
              Blank()
              // 播放中的收起态使用单行控制，所有按钮都限制在视频框内。
              Row({ space: 7 }) {
              Stack({ alignContent: Alignment.Center }) {
                Circle()
                  .width(32)
                  .height(32)
                  .fill('#66000000')
                Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
                  .width(16)
                  .height(16)
                  .fillColor('#FFFFFF')
              }
              .width(36)
              .height(36)
              .onClick(() => {
                this.togglePlay();
              })
              Text(formatDuration(this.curTime))
                .fontSize(10)
                .fontColor('#FFFFFF')
              Slider({
                value: this.duration > 0 ? this.curTime : 0,
                min: 0,
                max: this.duration > 0 ? this.duration : 1,
                style: SliderStyle.InSet,
              })
                .layoutWeight(1)
                .height(28)
                .blockSize({ width: 10, height: 10 })
                .blockColor('#FFFFFF')
                .selectedColor('#FB7299')
                .trackColor('#55FFFFFF')
                .onChange((value: number, mode: SliderChangeMode) => {
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.seekTo(value);
                  }
                })
              Stack({ alignContent: Alignment.Center }) {
                Image($r('app.media.ic_fullscreen'))
                  .width(20)
                  .height(20)
                  .fillColor('#FFFFFF')
              }
              .width(36)
              .height(36)
              .onClick(() => {
                this.toggleFullscreen();
              })
              }
              .width('100%')
              .height(44)
              .padding({ left: 8, right: 8, bottom: 4 })
            }
          } else {
            if (this.fullscreen) {
              // 参考 B 站横屏控制层：顶部只保留身份信息与高频动作，避免画面上方完全空白。
              Row({ space: 10 }) {
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.ic_back'))
                    .width(24)
                    .height(24)
                    .fillColor('#FFFFFF')
                }
                .width(42)
                .height(42)
                .onClick(() => {
                  this.exitFullscreen();
                })
                if (this.ownerFace.length > 0) {
                  Image(this.ownerFace)
                    .width(30)
                    .height(30)
                    .borderRadius(15)
                    .objectFit(ImageFit.Cover)
                }
                Column({ space: 2 }) {
                  Text(this.videoTitle)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.ownerName)
                    .fontSize(11)
                    .fontColor('#B3FFFFFF')
                    .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Stack({ alignContent: Alignment.Center }) {
                  Image(this.liked ? $r('app.media.ic_like_fill') : $r('app.media.ic_like'))
                    .width(24)
                    .height(24)
                    .fillColor(this.liked ? this.accent : '#FFFFFF')
                }
                .width(42)
                .height(42)
                .onClick(() => {
                  this.onLike();
                })
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.bilix_icon_coin'))
                    .width(24)
                    .height(24)
                    .fillColor('#FFFFFF')
                }
                .width(42)
                .height(42)
                .onClick(() => {
                  this.onCoin();
                })
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.bilix_icon_share'))
                    .width(25)
                    .height(25)
                    .fillColor('#FFFFFF')
                }
                .width(42)
                .height(42)
                .onClick(() => {
                  this.onShare();
                })
              }
              .width('100%')
              .height(54)
              .padding({ left: 12, right: 18, top: 4 })
            }
            Blank()
            // 中央播放按钮
            if (!this.fullscreen) {
              Stack({ alignContent: Alignment.Center }) {
                Circle()
                  .width(52)
                  .height(52)
                  .fill('#73000000')
                  .stroke('#33FFFFFF')
                  .strokeWidth(0.5)
                  .backdropBlur(10)
                Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
                  .width(25)
                  .height(25)
                  .fillColor('#FFFFFF')
              }
              .width(52)
              .height(52)
              .onClick(() => {
                this.togglePlay();
              })
            }
            Blank()
            // 底部控制条
            Column({ space: 6 }) {
              Row({ space: 10 }) {
                Text(formatDuration(this.curTime))
                  .fontSize(11)
                  .fontColor('#FFFFFF')
                Slider({
                  value: this.duration > 0 ? this.curTime : 0,
                  min: 0,
                  max: this.duration > 0 ? this.duration : 1,
                  style: SliderStyle.OutSet,
                })
                  .layoutWeight(1)
                  .blockColor('#FFFFFF')
                  .selectedColor('#FB7299')
                  .trackColor('#33FFFFFF')
                  .onChange((value: number, mode: SliderChangeMode) => {
                    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                      this.seekTo(value);
                    }
                  })
                Text(formatDuration(this.duration))
                  .fontSize(11)
                  .fontColor('#FFFFFF')
              }
              .width('100%')
              Row({ space: 8 }) {
                if (this.fullscreen) {
                  Stack({ alignContent: Alignment.Center }) {
                    Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
                      .width(25)
                      .height(25)
                      .fillColor('#FFFFFF')
                  }
                  .width(38)
                  .height(34)
                  .onClick(() => {
                    this.togglePlay();
                  })
                }
                if (this.fullscreen) {
                  Stack({ alignContent: Alignment.Center }) {
                    Image(this.danmakuOn ? $r('app.media.ic_danmaku_on') : $r('app.media.ic_danmaku_off'))
                      .width(23)
                      .height(23)
                      .fillColor(this.danmakuOn ? '#FB7299' : '#99FFFFFF')
                  }
                  .width(36)
                  .height(32)
                  .onClick(() => {
                    this.toggleDanmaku();
                  })
                  Stack({ alignContent: Alignment.Center }) {
                    Image($r('app.media.ic_danmaku_settings'))
                      .width(21)
                      .height(21)
                      .fillColor('#FFFFFF')
                  }
                  .width(34)
                  .height(32)
                  .onClick(() => {
                    this.showDmSettings = !this.showDmSettings;
                    this.showQualitySettings = false;
                    this.showSpeedSettings = false;
                    this.showChapterSettings = false;
                  })
                }
                Text('空降')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.sponsorSkipEnabled ? '#FFFFFF' : '#99FFFFFF')
                  .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                  .borderRadius(14)
                  .backgroundColor(this.sponsorSkipEnabled ? '#B3FB7299' : '#26000000')
                  .onClick(() => {
                    this.sponsorSkipEnabled = !this.sponsorSkipEnabled;
                    promptAction.showToast({ message: this.sponsorSkipEnabled ? '广告空降已开启' : '广告空降已关闭' });
                  })
                if (this.chapters.length > 0) {
                  Text('章节')
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                    .borderRadius(14)
                    .backgroundColor(this.showChapterSettings ? '#66FFFFFF' : '#26000000')
                    .onClick(() => {
                      this.showChapterSettings = !this.showChapterSettings;
                      this.showQualitySettings = false;
                      this.showSpeedSettings = false;
                      this.showDmSettings = false;
                    })
                }
                Blank()
                Text(this.qualityLoading ? '切换中' : this.qualityLabel())
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF')
                  .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                  .borderRadius(this.fullscreen ? 0 : 14)
                  .backgroundColor(this.fullscreen ? '#00000000' :
                    (this.showQualitySettings ? '#66FFFFFF' : '#26000000'))
                  .onClick(() => {
                    this.showQualitySettings = !this.showQualitySettings;
                    this.showSpeedSettings = false;
                    this.showDmSettings = false;
                    this.showChapterSettings = false;
                  })
                Text(this.playbackRate === 1 ? '倍速' : this.playbackRate.toFixed(this.playbackRate % 1 === 0 ? 0 : 2) + 'x')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF')
                  .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                  .borderRadius(this.fullscreen ? 0 : 14)
                  .backgroundColor(this.fullscreen ? '#00000000' :
                    (this.showSpeedSettings ? '#66FFFFFF' : '#26000000'))
                  .onClick(() => {
                    this.showSpeedSettings = !this.showSpeedSettings;
                    this.showQualitySettings = false;
                    this.showDmSettings = false;
                    this.showChapterSettings = false;
                  })
                Stack({ alignContent: Alignment.Center }) {
                  Image(this.fullscreen ? $r('app.media.ic_fullscreen_exit') : $r('app.media.ic_fullscreen'))
                    .width(23)
                    .height(23)
                    .fillColor('#FFFFFF')
                }
                .width(36)
                .height(32)
                  .onClick(() => {
                    this.toggleFullscreen();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 12, right: 12, bottom: 8 })
          }
        }
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[this.isDarkGradientTop(), 0.0], ['#00000000', 0.35], [this.isDarkGradientTop(), 1.0]],
        })
      }

      if (this.showControls && this.fullscreen && this.showDmSettings && this.errorText.length === 0) {
        Column({ space: 2 }) {
          Row() {
            Text('弹幕设置')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Blank()
            Text('恢复默认')
              .fontSize(11)
              .fontColor('#CCFFFFFF')
              .onClick(() => {
                this.dmOpacity = 0.85;
                this.setDmSpeed(1);
                this.setDmFontScale(1);
                this.setDmDensity(12);
                this.blockScrollDm = false;
                this.blockTopDm = false;
                this.blockBottomDm = false;
                this.blockColorDm = false;
                this.applyDmFilters();
              })
          }
          .width('100%')
          this.DmSliderRow('透明度', this.dmOpacity, 0.2, 1.0, (value: number) => {
            this.dmOpacity = value;
          })
          this.DmSliderRow('速度', this.dmSpeed, 0.5, 2.0, (value: number) => {
            this.setDmSpeed(value);
          })
          this.DmSliderRow('字号', this.dmFontScale, 0.7, 1.5, (value: number) => {
            this.setDmFontScale(value);
          })
          this.DmSliderRow('密度', this.dmDensity, 6, 30, (value: number) => {
            this.setDmDensity(value);
          })
          Row({ space: 6 }) {
            this.DmBlockChip('滚动', this.blockScrollDm, () => {
              this.blockScrollDm = !this.blockScrollDm;
              this.applyDmFilters();
            })
            this.DmBlockChip('顶部', this.blockTopDm, () => {
              this.blockTopDm = !this.blockTopDm;
              this.applyDmFilters();
            })
            this.DmBlockChip('底部', this.blockBottomDm, () => {
              this.blockBottomDm = !this.blockBottomDm;
              this.applyDmFilters();
            })
            this.DmBlockChip('彩色', this.blockColorDm, () => {
              this.blockColorDm = !this.blockColorDm;
              this.applyDmFilters();
            })
          }
          .width('100%')
        }
        .width(this.fullscreen ? 420 : '100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 12 })
        .borderRadius({ topLeft: 16, topRight: 16 })
        .backgroundColor('#E81A1A1E')
        .backdropBlur(24)
        .border({ width: { top: 0.5 }, color: '#33FFFFFF' })
        .align(Alignment.Bottom)
      }

      if (this.showControls && this.showQualitySettings && this.errorText.length === 0) {
        Column({ space: 8 }) {
          Row() {
            Text('清晰度')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Blank()
            Text('灰色画质需要会员或当前片源未提供')
              .fontSize(9)
              .fontColor('#88FFFFFF')
          }
          .width('100%')
          Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, justifyContent: FlexAlign.Start }) {
            ForEach(this.runtimeQualityOptions, (option: VideoQualityOption) => {
              Text(option.label)
                .fontSize(12)
                .fontColor(option.available ? (option.qn === this.activeQuality ? '#FFFFFF' : '#CCFFFFFF') : '#66FFFFFF')
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .margin({ right: 8, bottom: 6 })
                .borderRadius(16)
                .backgroundColor(option.qn === this.activeQuality ? this.accent : (option.available ? '#33FFFFFF' : '#16FFFFFF'))
                .onClick(() => {
                  if (option.available) this.changeQuality(option.qn);
                  else promptAction.showToast({ message: option.label + ' 需要相应会员权限，或当前视频未提供该轨道' });
                })
            }, (option: VideoQualityOption) => String(option.qn))
          }
          .width('100%')
        }
        .width(this.fullscreen ? 420 : '100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .borderRadius({ topLeft: 16, topRight: 16 })
        .backgroundColor('#E81A1A1E')
        .backdropBlur(24)
        .align(Alignment.Bottom)
      }

      if (this.showControls && this.showChapterSettings && this.errorText.length === 0) {
        Column({ space: 8 }) {
          Text('视频章节')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .width('100%')
          List({ space: 6 }) {
            ForEach(this.chapters, (chapter: VideoChapter, index: number) => {
              ListItem() {
                Row({ space: 9 }) {
                  if (chapter.image.length > 0) {
                    Image(chapter.image)
                      .width(64)
                      .height(36)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(5)
                  }
                  Column({ space: 2 }) {
                    Text(chapter.title)
                      .fontSize(12)
                      .fontColor(this.curTime >= chapter.from && this.curTime < chapter.to ? '#FB7299' : '#FFFFFF')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(formatDuration(chapter.from) + ' - ' + formatDuration(chapter.to))
                      .fontSize(10)
                      .fontColor('#A6FFFFFF')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .borderRadius(8)
                .backgroundColor(this.curTime >= chapter.from && this.curTime < chapter.to ? '#26FB7299' : '#1FFFFFFF')
                .onClick(() => {
                  this.seekTo(chapter.from, true);
                  this.showChapterSettings = false;
                })
              }
            }, (chapter: VideoChapter, index: number) => String(chapter.from) + '-' + String(index))
          }
          .width('100%')
          .height(this.fullscreen ? 230 : 180)
          .scrollBar(BarState.Off)
        }
        .width(this.fullscreen ? 420 : '100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .borderRadius({ topLeft: 16, topRight: 16 })
        .backgroundColor('#E81A1A1E')
        .backdropBlur(24)
        .align(Alignment.Bottom)
      }

      if (this.showControls && this.showSpeedSettings && this.errorText.length === 0) {
        Column({ space: 8 }) {
          Text('播放速度')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .width('100%')
          Row({ space: 7 }) {
            this.SpeedChip('0.5x', 0.5)
            this.SpeedChip('0.75x', 0.75)
            this.SpeedChip('1x', 1)
            this.SpeedChip('1.25x', 1.25)
            this.SpeedChip('1.5x', 1.5)
            this.SpeedChip('2x', 2)
          }
          .width('100%')
        }
        .width(this.fullscreen ? 420 : '100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 14 })
        .borderRadius({ topLeft: 16, topRight: 16 })
        .backgroundColor('#E81A1A1E')
        .backdropBlur(24)
        .align(Alignment.Bottom)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor('#000000')
    .onClick(() => {
      this.toggleControls();
    })
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false })
          .onAction(() => this.beginHoldSpeed())
          .onActionEnd(() => this.endHoldSpeed()),
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 12 })
          .onActionStart(() => this.beginHorizontalSeek())
          .onActionUpdate((event: GestureEvent) => this.updateHorizontalSeek(event.offsetX))
          .onActionEnd(() => this.endHorizontalSeek())
          .onActionCancel(() => this.endHorizontalSeek())
      )
    )
  }

  isDarkGradientTop(): string {
    return '#99000000';
  }

  @Builder
  DmSliderRow(label: string, value: number, min: number, max: number, onChange: (value: number) => void) {
    Row({ space: 8 }) {
      Text(label)
        .width(38)
        .fontSize(11)
        .fontColor('#E6FFFFFF')
      Slider({ value: value, min: min, max: max, step: (max - min) / 20, style: SliderStyle.InSet })
        .layoutWeight(1)
        .height(22)
        .blockColor('#FFFFFF')
        .selectedColor('#FB7299')
        .trackColor('#40FFFFFF')
        .onChange((next: number) => {
          onChange(next);
        })
      Text(value.toFixed(value >= 6 ? 0 : 1))
        .width(28)
        .textAlign(TextAlign.End)
        .fontSize(10)
        .fontColor('#B3FFFFFF')
    }
    .width('100%')
    .height(27)
  }

  @Builder
  DmBlockChip(label: string, blocked: boolean, onClick: () => void) {
    Text(label)
      .fontSize(11)
      .fontColor(blocked ? '#FFFFFF' : '#CCFFFFFF')
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .borderRadius(13)
      .backgroundColor(blocked ? '#FB7299' : '#33FFFFFF')
      .onClick(() => {
        onClick();
      })
  }

  @Builder
  SpeedChip(label: string, rate: number) {
    Text(label)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .fontSize(11)
      .fontColor(this.playbackRate === rate ? '#FFFFFF' : '#CCFFFFFF')
      .padding({ top: 8, bottom: 8 })
      .borderRadius(16)
      .backgroundColor(this.playbackRate === rate ? '#FB7299' : '#33FFFFFF')
      .onClick(() => {
        this.setPlaybackSpeed(rate);
      })
  }
}

// 弹幕颜色：数字 → #RRGGBB
function colorHex(color: number): string {
  const r: number = (color >> 16) & 0xff;
  const g: number = (color >> 8) & 0xff;
  const b: number = color & 0xff;
  const to2 = (n: number): string => {
    const s: string = n.toString(16);
    return s.length === 1 ? '0' + s : s;
  };
  return '#' + to2(r) + to2(g) + to2(b);
}
