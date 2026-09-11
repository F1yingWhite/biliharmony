import { AVVolumePanel } from '@kit.AudioKit';
import { SystemMediaVolume } from '../player/SystemMediaVolume';
import { PlayerGestureController } from '../player/PlayerGestureController';
import { PlayerGestureOverlay } from '../player/PlayerGestureOverlay';
/** 直播播放器：低延迟 AVPlayer、基础画质与视频同款 Canvas 分轨弹幕。 */
import { LiveSuperChatShelf } from './LiveSuperChatShelf';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Immersive } from '../../common/Immersive';
import { Constants } from '../../common/Constants';
import { LiveChatMessage, LivePlayInfo, LiveQualityOption } from '../../model/LiveModels';
import { LiveDanmakuRenderer } from './LiveDanmakuRenderer';
import { PlayerSettingsPanel } from '../player/PlayerSettingsPanel';
import { AppTheme, DanmakuSettings } from '../../common/AppTheme';


@Component
export struct LivePlayerView {
  @Prop @Watch('onPlayInfoChanged') playInfo: LivePlayInfo = new LivePlayInfo();
  @Prop @Watch('onMessagesChanged') messages: Array<LiveChatMessage> = [];
  @Prop @Watch('onSyncVersionChanged') syncVersion: number = 0;
  @Prop title: string = '';
  @Prop retrying: boolean = false;
  onRetry: () => void = () => {};
  @Prop superChats: Array<LiveChatMessage> = [];
  @State viewportHeight: number = 240;
  @Prop uname: string = '';
  onQualityChange: (qn: number) => void = () => {};
  onFullscreenChange: (fullscreen: boolean) => void = () => {};
  @State playing: boolean = false;
  @State prepared: boolean = false;
  @State buffering: boolean = true;
  @State systemVolumeLevel: number = 0;
  @State gestureAdjustKind: string = '';
  @State gestureAdjustPercent: number = -1;
  private systemVolume: SystemMediaVolume = new SystemMediaVolume();
  private gestureCtl: PlayerGestureController | null = null;
  @State controls: boolean = true;
  @State scExpanded: boolean = false;
  @State danmakuOn: boolean = true;
  @State showQuality: boolean = false;
  @State showDmSettings: boolean = false;
  // 弹幕设置（对齐视频播放页）：透明度/速度/字号/密度，直接作用于渲染器。
  @State dmOpacity: number = 0.88;
  @State dmFrameRate: number = 60;
  @State dmSpeed: number = 1;
  @State dmFontScale: number = 1;
  @State dmSpacing: number = 1;
  @State dmDensity: number = 22;
  @State fullscreen: boolean = false;
  @State errorText: string = '';
  @StorageProp('livePlayerExitRequest') @Watch('onExitRequested') exitRequest: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  private player: media.AVPlayer | null = null;
  private controller: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private sourceIndex: number = 0;
  private hideTimer: number = -1;
  private fullscreenTimer: number = -1;
  private destroyed: boolean = false;
  private playerGeneration: number = 0;
  private playerCreating: boolean = false;
  private playerRestartPending: boolean = false;
  private dmContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private dmRenderer: LiveDanmakuRenderer = new LiveDanmakuRenderer(this.dmContext);

  aboutToAppear(): void {
    this.destroyed = false;
    try { this.systemVolumeLevel = this.systemVolume.level(); } catch (e) {}
    this.systemVolume.start((percent: number) => {
      if (this.destroyed) return;
      try { this.systemVolumeLevel = this.systemVolume.level(); } catch (e) {}
      if (!this.destroyed && this.gestureAdjustKind === '音量') this.gestureAdjustPercent = percent;
    });
    this.gestureCtl = new PlayerGestureController(
      (value: number) => {}, (value: number) => {},
      (kind: string, percent: number) => {
        this.gestureAdjustKind = kind === 'brightness' ? '亮度' : (kind === 'volume' ? '音量' : '');
        this.gestureAdjustPercent = kind === 'volume' ? this.systemVolume.percent() : percent;
      },
      (value: number) => {},
      (value: number) => {
        try { this.systemVolumeLevel = this.systemVolume.levelForPercent(value); } catch (e) {}
      },
      (value: number) => { AppTheme.saveLastBrightness(value); },
      (value: number) => { Immersive.setWindowBrightness(value); },
    );
    AppStorage.setOrCreate<boolean>('livePlayerFullscreen', false);
    AppStorage.setOrCreate<number>('livePlayerExitRequest', 0);
    this.restoreDanmakuSettings();
    this.dmRenderer.setBaseline(this.messages);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.systemVolume.stop();
    Immersive.restoreWindowBrightness();
    this.playerGeneration++;
    this.release();
    this.dmRenderer.release();
    if (this.fullscreen) Immersive.setFullscreen(false);
    AppStorage.setOrCreate<boolean>('livePlayerFullscreen', false);
  }

  onExitRequested(): void {
    if (this.fullscreen) this.exitFullscreen();
  }

  onPlayInfoChanged(): void {
    this.restartForSource();
  }

  onSurfaceReady(): void {
    this.surfaceId = this.controller.getXComponentSurfaceId();
    this.initPlayer();
  }

  async restartForSource(): Promise<void> {
    const generation: number = ++this.playerGeneration;
    this.sourceIndex = 0;
    this.prepared = false;
    this.playing = false;
    this.dmRenderer.setPlayback(false, this.fullscreen);
    this.buffering = true;
    this.errorText = '';
    const old: media.AVPlayer | null = this.player;
    this.player = null;
    if (old !== null) {
      try { await old.release(); } catch (e) {}
    }
    if (!this.destroyed && generation === this.playerGeneration && this.surfaceId.length > 0) await this.initPlayer();
  }

  async initPlayer(): Promise<void> {
    if (this.destroyed || this.player !== null || this.surfaceId.length === 0 ||
      this.playInfo.urls.length === 0) return;
    if (this.playerCreating) {
      this.playerRestartPending = true;
      return;
    }
    this.playerRestartPending = false;
    const generation: number = this.playerGeneration;
    this.playerCreating = true;
    let p: media.AVPlayer | null = null;
    try {
      const createdPlayer: media.AVPlayer = await media.createAVPlayer();
      p = createdPlayer;
      if (this.destroyed || generation !== this.playerGeneration) {
        try { await createdPlayer.release(); } catch (e) {}
        return;
      }
      this.player = createdPlayer;
      createdPlayer.on('stateChange', (state: media.AVPlayerState) => {
        if (this.player !== createdPlayer) return;
        if (state === 'initialized') {
          createdPlayer.surfaceId = this.surfaceId;
          createdPlayer.prepare();
        } else if (state === 'prepared') {
          this.prepared = true;
          this.buffering = false;
          createdPlayer.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
          createdPlayer.play();
        } else if (state === 'playing') {
          this.playing = true;
          this.buffering = false;
          this.dmRenderer.setPlayback(true, this.fullscreen);
          this.scheduleHide();
        } else if (state === 'paused') {
          this.playing = false;
          this.dmRenderer.setPlayback(false, this.fullscreen);
          this.controls = true;
        }
      });
      createdPlayer.on('bufferingUpdate', (type: media.BufferingInfoType) => {
        if (this.player !== createdPlayer) return;
        if (type === media.BufferingInfoType.BUFFERING_START) this.buffering = true;
        if (type === media.BufferingInfoType.BUFFERING_END) this.buffering = false;
      });
      createdPlayer.on('error', (err: BusinessError) => this.handleError(createdPlayer, err.message));
      const url: string = this.playInfo.urls[this.sourceIndex] ?? '';
      const source: media.MediaSource = media.createMediaSourceWithUrl(url, {
        'User-Agent': Constants.browserUa,
        'Referer': 'https://live.bilibili.com/',
      });
      await createdPlayer.setMediaSource(source, {
        preferredBufferDuration: 8,
        preferredBufferDurationForPlaying: 0.8,
        thresholdForAutoQuickPlay: 2,
        showFirstFrameOnPrepare: true,
      });
    } catch (e) {
      if (p !== null && this.player === p) {
        await this.handleError(p, '媒体源初始化失败');
      } else if (p === null && !this.destroyed && generation === this.playerGeneration) {
        this.errorText = '直播播放失败';
        this.buffering = false;
      }
    } finally {
      this.playerCreating = false;
      // error 回调可能发生在 setMediaSource 完成前。创建退场后落实最新换源请求。
      if (this.playerRestartPending && !this.destroyed) {
        this.playerRestartPending = false;
        await this.initPlayer();
      }
    }
  }

  async handleError(failed: media.AVPlayer, message: string): Promise<void> {
    if (this.destroyed || this.player !== failed) return;
    const generation: number = this.playerGeneration;
    this.player = null;
    this.prepared = false;
    this.playing = false;
    this.dmRenderer.setPlayback(false, this.fullscreen);
    try { await failed.release(); } catch (e) {}
    if (this.destroyed || generation !== this.playerGeneration) return;
    if (this.sourceIndex + 1 < this.playInfo.urls.length) {
      this.sourceIndex++;
      this.errorText = '正在切换备用线路…';
      await this.initPlayer();
    } else {
      this.buffering = false;
      this.errorText = '直播暂时无法播放，请重新加载';
    }
  }

  release(): void {
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = -1;
    if (this.fullscreenTimer >= 0) clearTimeout(this.fullscreenTimer);
    this.fullscreenTimer = -1;
    this.playerGeneration++;
    this.dmRenderer.release();
    this.playerRestartPending = false;
    const p: media.AVPlayer | null = this.player;
    this.player = null;
    if (p !== null) {
      try { p.setVolume(0); } catch (e) {}
      p.release().catch(() => {
      });
    }
  }

  togglePlay(): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null || !this.prepared) return;
    if (this.playing) p.pause(); else p.play();
  }

  toggleControls(): void {
    if (this.showQuality) {
      this.showQuality = false;
      return;
    }
    this.controls = !this.controls;
    if (this.controls) this.scheduleHide();
  }

  private canAutoHideControls(): boolean {
    return this.playing && !this.showQuality && !this.showDmSettings && !this.scExpanded;
  }

  scheduleHide(): void {
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      if (this.canAutoHideControls()) this.controls = false;
    }, 4000);
  }

  toggleFullscreen(): void {
    if (this.fullscreen) {
      this.exitFullscreen();
      return;
    }
    if (this.destroyed) return;
    if (this.fullscreenTimer >= 0) {
      clearTimeout(this.fullscreenTimer);
      this.fullscreenTimer = -1;
    }
    this.fullscreen = true;
    this.dmRenderer.setPlayback(this.playing, true);
    AppStorage.setOrCreate<boolean>('livePlayerFullscreen', true);
    this.onFullscreenChange(true);
    Immersive.setFullscreen(true);
  }

  exitFullscreen(): void {
    if (!this.fullscreen) return;
    this.fullscreen = false;
    this.dmRenderer.setPlayback(this.playing, false);
    Immersive.setFullscreen(false);
    if (this.fullscreenTimer >= 0) clearTimeout(this.fullscreenTimer);
    this.fullscreenTimer = setTimeout(() => {
      this.fullscreenTimer = -1;
      if (this.destroyed || this.fullscreen) return;
      this.onFullscreenChange(false);
      AppStorage.setOrCreate<boolean>('livePlayerFullscreen', false);
    }, 220);
  }

  qualityLabel(): string {
    for (let i: number = 0; i < this.playInfo.qualities.length; i++) {
      if (this.playInfo.qualities[i].qn === this.playInfo.currentQn) return this.playInfo.qualities[i].label;
    }
    return '画质';
  }

  onMessagesChanged(): void {
    this.dmRenderer.onMessagesChanged(this.messages);
  }

  onSyncVersionChanged(): void {
    this.dmRenderer.resetBaseline(this.messages);
  }

  private toggleDanmaku(): void {
    this.danmakuOn = !this.danmakuOn;
    this.dmRenderer.toggle(this.danmakuOn);
    this.persistDanmakuSettings();
  }

  private restoreDanmakuSettings(): void {
    const settings: DanmakuSettings = AppTheme.loadDanmakuSettings();
    this.danmakuOn = settings.enabled;
    this.dmOpacity = settings.opacity;
    this.dmFrameRate = settings.frameRate;
    this.dmSpeed = settings.speed;
    this.dmFontScale = settings.fontScale;
    this.dmSpacing = settings.spacing;
    this.dmDensity = settings.density;
    this.dmRenderer.enabled = settings.enabled;
    this.dmRenderer.opacity = settings.opacity;
    this.dmRenderer.setFrameRate(settings.frameRate);
    this.dmRenderer.speedScale = settings.speed;
    this.dmRenderer.fontScale = settings.fontScale;
    this.dmRenderer.spacing = settings.spacing;
    this.dmRenderer.density = settings.density;
  }

  private persistDanmakuSettings(): void {
    const settings: DanmakuSettings = AppTheme.loadDanmakuSettings();
    settings.enabled = this.danmakuOn;
    settings.opacity = this.dmOpacity;
    settings.frameRate = this.dmFrameRate;
    settings.speed = this.dmSpeed;
    settings.fontScale = this.dmFontScale;
    settings.spacing = this.dmSpacing;
    settings.density = this.dmDensity;
    AppTheme.persistDanmakuSettings(settings);
  }

  private resetDanmakuSettings(): void {
    const defaults: DanmakuSettings = new DanmakuSettings();
    this.danmakuOn = defaults.enabled;
    this.dmOpacity = defaults.opacity;
    this.dmFrameRate = defaults.frameRate;
    this.dmSpeed = defaults.speed;
    this.dmFontScale = defaults.fontScale;
    this.dmSpacing = defaults.spacing;
    this.dmDensity = defaults.density;
    this.dmRenderer.toggle(defaults.enabled);
    this.dmRenderer.opacity = defaults.opacity;
    this.dmRenderer.setFrameRate(defaults.frameRate);
    this.dmRenderer.speedScale = defaults.speed;
    this.dmRenderer.fontScale = defaults.fontScale;
    this.dmRenderer.spacing = defaults.spacing;
    this.dmRenderer.density = defaults.density;
    AppTheme.persistDanmakuSettings(defaults);
  }

  /** 弹幕设置滑杆行：标签 + Slider + 当前值（保留一位小数/整数）。 */
  @Builder
  DmSettingSlider(label: string, value: number, min: number, max: number, onChange: (value: number) => void) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(12).fontColor('#CCFFFFFF')
        .width(44)
      Slider({ value: value, min: min, max: max, step: (max - min) / 20, style: SliderStyle.OutSet })
        .layoutWeight(1)
        .height(22)
        .blockColor('#FFFFFF')
        .trackColor('#40FFFFFF')
        .selectedColor(this.accent)
        .onChange((v: number, mode: SliderChangeMode) => {
          onChange(v);
        })
      Text(max <= 2 ? value.toFixed(1) : String(Math.round(value)))
        .fontSize(11).fontColor('#CCFFFFFF')
        .width(30)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(32)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  LiveDanmakuSettingsSheet() {
    Scroll() {
      PlayerSettingsPanel({
        which: 0,
        embedded: true,
        basicDanmakuOnly: true,
        forceDark: true,
        accent: this.accent,
        dmOpacity: this.dmOpacity,
        dmFrameRate: this.dmFrameRate,
        dmSpeed: this.dmSpeed,
        dmFontScale: this.dmFontScale,
        dmSpacing: this.dmSpacing,
        dmDensity: this.dmDensity,
        onDmOpacityChange: (value: number): void => {
          this.dmOpacity = value;
          this.dmRenderer.opacity = value;
          this.persistDanmakuSettings();
        },
        onDmFrameRateChange: (value: number): void => {
          this.dmFrameRate = value;
          this.dmRenderer.setFrameRate(value);
          this.persistDanmakuSettings();
        },
        onDmSpeedChange: (value: number): void => {
          this.dmSpeed = value;
          this.dmRenderer.speedScale = value;
          this.persistDanmakuSettings();
        },
        onDmFontScaleChange: (value: number): void => {
          this.dmFontScale = value;
          this.dmRenderer.fontScale = value;
          this.persistDanmakuSettings();
        },
        onDmSpacingChange: (value: number): void => {
          this.dmSpacing = Math.max(0.5, Math.min(2, value));
          this.dmRenderer.setSpacing(this.dmSpacing);
          this.persistDanmakuSettings();
        },
        onDmDensityChange: (value: number): void => {
          this.dmDensity = value;
          this.dmRenderer.density = value;
          this.persistDanmakuSettings();
        },
        onResetDanmaku: (): void => this.resetDanmakuSettings(),
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .padding({ left: 16, right: 16, top: 10, bottom: 24 })
  }

  private beginPan(event: GestureEvent): void {
    if (!this.fullscreen || this.showQuality || this.showDmSettings) return;
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
    const volume: number = this.systemVolume.percent();
    if (this.gestureCtl !== null && volume >= 0) this.gestureCtl.gestureVolume = volume;
    const x: number = event.fingerList.length > 0 ? event.fingerList[0].localX : this.dmRenderer.width / 2;
    this.gestureCtl?.beginPan(x, this.dmRenderer.width, 0, 0);
  }

  private endPan(): void {
    this.gestureCtl?.endPan();
    this.gestureAdjustKind = '';
    this.gestureAdjustPercent = -1;
    if (this.controls) this.scheduleHide();
  }

  @Builder
  GestureArea() {
    Column()
      .width('100%').height('100%')
      .backgroundColor('#00000000')
      .onClick(() => this.toggleControls())
      .gesture(PanGesture({ direction: PanDirection.Vertical, distance: 10 })
        .onActionStart((event: GestureEvent) => this.beginPan(event))
        .onActionUpdate((event: GestureEvent) => {
          if (this.fullscreen && !this.showQuality && !this.showDmSettings) {
            this.gestureCtl?.updatePan(0, event.offsetY, this.dmRenderer.width, 0);
          }
        })
        .onActionEnd(() => this.endPan())
        .onActionCancel(() => this.endPan()))
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      AVVolumePanel({ volumeLevel: this.systemVolumeLevel })
      XComponent({ id: 'livePlayerSurface', type: XComponentType.SURFACE, controller: this.controller })
        .width('100%')
        .height('100%')
        .onLoad(() => this.onSurfaceReady())

      // 控件隐藏时才铺手势层；控件显示时移除，避免它抢走画质/弹幕/全屏按钮事件。
      if (!this.controls) {
        this.GestureArea()
      }

      Canvas(this.dmContext)
        .width('100%').height('100%')
        .visibility(this.danmakuOn && this.fullscreen ? Visibility.Visible : Visibility.Hidden)
        .hitTestBehavior(HitTestMode.None)
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const width: number = Number(newValue.width);
          const height: number = Number(newValue.height);
          if (width > 0) this.dmRenderer.width = width;
          if (height > 0) {
            this.dmRenderer.height = height;
            this.viewportHeight = height;
          }
        })

      if (this.buffering) {
        LoadingProgress().width(38).height(38).color('#FFFFFF')
      }
      if (this.errorText.length > 0) {
        Column({ space: 10 }) {
          Text(this.errorText).fontSize(13).fontColor('#FFFFFF').maxLines(3).textAlign(TextAlign.Center)
          if (!this.buffering) {
            Button(this.retrying ? '正在重新加载…' : '重新加载')
              .height(36).fontSize(12).fontColor('#FFFFFF')
              .backgroundColor('#993D424A').borderRadius(18)
              .enabled(!this.retrying)
              .onClick(() => this.onRetry())
          }
        }.padding(20).zIndex(5)
      }

      if (this.controls) {
        Column() {
          if (this.fullscreen) {
            Row({ space: 10 }) {
              Image($r('app.media.ic_back')).width(22).height(22).fillColor('#FFFFFF')
              Column({ space: 2 }) {
                Text(this.title).fontSize(16).fontColor('#FFFFFF').maxLines(1)
                Text(this.uname).fontSize(11).fontColor('#B3FFFFFF').maxLines(1)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text('只看直播').fontSize(11).fontColor('#B3FFFFFF')
            }
            .height(52)
            .padding({ left: 14, right: 18 })
            .onClick(() => this.exitFullscreen())
          }
          Stack() { this.GestureArea() }.width('100%').layoutWeight(1)
          Row({ space: 10 }) {
            Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
              .width(24).height(24).fillColor('#FFFFFF')
              .onClick(() => this.togglePlay())
            Image(this.danmakuOn ? $r('app.media.ic_danmaku_on') : $r('app.media.ic_danmaku_off'))
              .width(23).height(23).fillColor(this.danmakuOn ? this.accent : '#AAFFFFFF')
              .onClick(() => this.toggleDanmaku())
            Text(this.showQuality ? '收起画质' : this.qualityLabel())
              .fontSize(12).fontColor('#FFFFFF')
              .padding({ left: 9, right: 9, top: 6, bottom: 6 })
              .backgroundColor('#33000000').borderRadius(14)
              .onClick(() => {
                this.showDmSettings = false;
                this.showQuality = !this.showQuality;
              })
            Text(this.showDmSettings ? '收起设置' : '弹幕设置')
              .fontSize(12).fontColor('#FFFFFF')
              .padding({ left: 9, right: 9, top: 6, bottom: 6 })
              .backgroundColor('#33000000').borderRadius(14)
              .onClick(() => {
                this.showQuality = false;
                this.showDmSettings = !this.showDmSettings;
              })
            Blank()
            Row({ space: 4 }) {
              Circle().width(7).height(7).fill(this.accent)
              Text('直播').fontSize(12).fontColor('#FFFFFF')
            }
            Image(this.fullscreen ? $r('app.media.ic_fullscreen_exit') : $r('app.media.ic_fullscreen'))
              .width(23).height(23).fillColor('#FFFFFF')
              .onClick(() => this.toggleFullscreen())
          }
          .width('100%')
          .height(48)
          .padding({ left: 14, right: 14, bottom: 6 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [['#66000000', 0], ['#00000000', 0.4], ['#99000000', 1]] })
      }

      PlayerGestureOverlay({
        fullscreen: this.fullscreen,
        gestureAdjustKind: this.gestureAdjustKind,
        gestureAdjustPercent: this.gestureAdjustPercent,
      })

      if (this.fullscreen && this.controls && this.superChats.length > 0 && !this.showQuality && !this.showDmSettings) {
        LiveSuperChatShelf({
          messages: this.superChats,
          floating: true,
          onExpandedChange: (expanded: boolean) => {
            this.scExpanded = expanded;
            if (!expanded && this.controls && !this.destroyed) this.scheduleHide();
          },
          panelHeight: Math.max(80, this.viewportHeight - 220),
        })
        .width('34%').constraintSize({ maxWidth: 280 })
        .position({ top: 60, left: 18 })
      }

      if (this.controls && this.showQuality) {
        Column({ space: 8 }) {
          Text('直播画质')
            .width('100%').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, justifyContent: FlexAlign.Start }) {
            ForEach(this.playInfo.qualities, (option: LiveQualityOption) => {
              Text(option.label)
                .fontSize(12)
                .fontColor('#FFFFFF')
                .padding({ left: 13, right: 13, top: 7, bottom: 7 })
                .margin({ right: 8, bottom: 4 })
                .borderRadius(16)
                .backgroundColor(option.qn === this.playInfo.currentQn ? this.accent : '#33FFFFFF')
                .onClick(() => {
                  this.showQuality = false;
                  if (option.qn !== this.playInfo.currentQn) this.onQualityChange(option.qn);
                })
            }, (option: LiveQualityOption) => String(option.qn))
          }.width('100%')
        }
        .width(this.fullscreen ? 360 : '100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 58 })
        .borderRadius({ topLeft: 16, topRight: 16 })
        .backgroundColor('#E81A1A1E')
        .backdropBlur(20)
        .align(Alignment.Bottom)
      }

    }
    .width('100%').height('100%')
    .backgroundColor('#000000')
    .bindSheet($$this.showDmSettings, this.LiveDanmakuSettingsSheet(), {
      height: 510,
      dragBar: true,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: '#18191C',
    })
  }
}
