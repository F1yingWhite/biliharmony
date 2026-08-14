/** 直播播放器：低延迟 AVPlayer、基础画质、弹幕开关与全屏；不含礼物/发送入口。 */
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Immersive } from '../common/Immersive';
import { Constants } from '../common/Constants';
import { LiveChatMessage, LivePlayInfo, LiveQualityOption } from '../model/LiveModels';

@Component
export struct LivePlayerView {
  @Prop @Watch('onPlayInfoChanged') playInfo: LivePlayInfo = new LivePlayInfo();
  @Prop messages: Array<LiveChatMessage> = [];
  @Prop title: string = '';
  @Prop uname: string = '';
  onQualityChange: (qn: number) => void = () => {};
  onFullscreenChange: (fullscreen: boolean) => void = () => {};
  @State playing: boolean = false;
  @State prepared: boolean = false;
  @State buffering: boolean = true;
  @State controls: boolean = true;
  @State danmakuOn: boolean = true;
  @State showQuality: boolean = false;
  @State fullscreen: boolean = false;
  @State errorText: string = '';
  @StorageProp('livePlayerExitRequest') @Watch('onExitRequested') exitRequest: number = 0;
  private player: media.AVPlayer | null = null;
  private controller: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private sourceIndex: number = 0;
  private hideTimer: number = -1;
  private fullscreenTimer: number = -1;
  private destroyed: boolean = false;
  private playerGeneration: number = 0;
  private playerCreating: boolean = false;

  aboutToAppear(): void {
    this.destroyed = false;
    AppStorage.setOrCreate<boolean>('livePlayerFullscreen', false);
    AppStorage.setOrCreate<number>('livePlayerExitRequest', 0);
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.playerGeneration++;
    this.release();
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
    if (this.destroyed || this.player !== null || this.playerCreating || this.surfaceId.length === 0 ||
      this.playInfo.urls.length === 0) return;
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
          this.scheduleHide();
        } else if (state === 'paused') {
          this.playing = false;
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
      if (p !== null && this.player !== p) {
        try { await p.release(); } catch (releaseError) {}
      }
      if (!this.destroyed && generation === this.playerGeneration) {
        this.errorText = '直播播放失败';
        this.buffering = false;
      }
    } finally {
      if (generation === this.playerGeneration) this.playerCreating = false;
    }
  }

  async handleError(failed: media.AVPlayer, message: string): Promise<void> {
    if (this.destroyed || this.player !== failed) return;
    this.player = null;
    try { await failed.release(); } catch (e) {}
    if (this.sourceIndex + 1 < this.playInfo.urls.length) {
      this.sourceIndex++;
      this.errorText = '正在切换备用线路…';
      await this.initPlayer();
    } else {
      this.buffering = false;
      this.errorText = '直播暂时无法播放：' + message.substring(0, 80);
    }
  }

  release(): void {
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = -1;
    if (this.fullscreenTimer >= 0) clearTimeout(this.fullscreenTimer);
    this.fullscreenTimer = -1;
    this.playerGeneration++;
    this.playerCreating = false;
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

  scheduleHide(): void {
    if (this.hideTimer >= 0) clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      if (this.playing && !this.showQuality) this.controls = false;
    }, 4000);
  }

  toggleFullscreen(): void {
    if (this.fullscreen) {
      this.exitFullscreen();
      return;
    }
    this.fullscreen = true;
    AppStorage.setOrCreate<boolean>('livePlayerFullscreen', true);
    this.onFullscreenChange(true);
    Immersive.setFullscreen(true);
  }

  exitFullscreen(): void {
    if (!this.fullscreen) return;
    this.fullscreen = false;
    Immersive.setFullscreen(false);
    if (this.fullscreenTimer >= 0) clearTimeout(this.fullscreenTimer);
    this.fullscreenTimer = setTimeout(() => {
      this.fullscreenTimer = -1;
      if (this.destroyed) return;
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

  @Builder
  DanmakuOverlay() {
    Column({ space: 4 }) {
      ForEach(this.messages.slice(Math.max(0, this.messages.length - (this.fullscreen ? 7 : 4))),
        (msg: LiveChatMessage) => {
          Marquee({
            start: this.playing,
            step: this.fullscreen ? 7 : 5,
            loop: -1,
            fromStart: true,
            src: msg.type === 'sc' ? 'SC ¥' + String(msg.price) + '  ' + msg.text : msg.text,
          })
            .width('100%')
            .height(this.fullscreen ? 30 : 25)
            .fontSize(this.fullscreen ? 22 : 18)
            .fontWeight(FontWeight.Bold)
            .fontColor(msg.type === 'sc' ? '#FFD45A' : '#FFFFFF')
        }, (msg: LiveChatMessage) => msg.id)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: this.fullscreen ? 56 : 8 })
    .alignSelf(ItemAlign.Start)
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'livePlayerSurface', type: XComponentType.SURFACE, controller: this.controller })
        .width('100%')
        .height('100%')
        .onLoad(() => this.onSurfaceReady())

      // 控件隐藏时才铺手势层；控件显示时移除，避免它抢走画质/弹幕/全屏按钮事件。
      if (!this.controls) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000000')
          .onClick(() => this.toggleControls())
      }

      if (this.danmakuOn) this.DanmakuOverlay()

      if (this.buffering) {
        LoadingProgress().width(38).height(38).color('#FFFFFF')
      }
      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .maxLines(3)
          .padding(20)
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
          Blank()
          Row({ space: 10 }) {
            Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
              .width(24).height(24).fillColor('#FFFFFF')
              .onClick(() => this.togglePlay())
            Image(this.danmakuOn ? $r('app.media.ic_danmaku_on') : $r('app.media.ic_danmaku_off'))
              .width(23).height(23).fillColor(this.danmakuOn ? '#FB7299' : '#AAFFFFFF')
              .onClick(() => this.danmakuOn = !this.danmakuOn)
            Text(this.showQuality ? '收起画质' : this.qualityLabel())
              .fontSize(12).fontColor('#FFFFFF')
              .padding({ left: 9, right: 9, top: 6, bottom: 6 })
              .backgroundColor('#33000000').borderRadius(14)
              .onClick(() => this.showQuality = !this.showQuality)
            Blank()
            Row({ space: 4 }) {
              Circle().width(7).height(7).fill('#FB7299')
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
                .backgroundColor(option.qn === this.playInfo.currentQn ? '#FB7299' : '#33FFFFFF')
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
  }
}
