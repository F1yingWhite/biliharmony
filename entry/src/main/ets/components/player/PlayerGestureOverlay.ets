import { image } from '@kit.ImageKit';

/** 在线人数、长按倍速、横滑预览、音量/亮度的轻量叠层。 */
@Component
export struct PlayerGestureOverlay {
  @Prop onlineTotal: string = '';
  @Prop chapterTitle: string = '';
  @Prop compactMode: boolean = false;
  @Prop showControls: boolean = false;
  @Prop fullscreen: boolean = false;
  @Prop holdSpeedActive: boolean = false;
  @Prop gestureSeekPreview: number = -1;
  @Prop sliderSeekPreview: number = -1;
  @Prop seekPreviewFrame: image.PixelMap | null = null;
  @Prop seekPreviewCover: string = '';
  @Prop seekPreviewSprite: string = '';
  @Prop seekPreviewSpriteCell: number = -1;
  @Prop seekPreviewSpriteXLen: number = 10;
  @Prop seekPreviewSpriteYLen: number = 10;
  @Prop gestureAdjustKind: string = '';
  @Prop gestureAdjustPercent: number = -1;
  @Prop panStartTime: number = 0;
  @Prop duration: number = 0;
  /** 长按倍速：三个右向小三角逐个亮起的循环动画步（0/1/2）。 */
  @State holdAnimStep: number = 0;
  private holdAnimTimer: number = -1;

  private startHoldAnimation(): void {
    if (this.holdAnimTimer >= 0) return;
    this.holdAnimTimer = setInterval(() => {
      if (!this.holdSpeedActive) {
        this.stopHoldAnimation();
        return;
      }
      this.holdAnimStep = (this.holdAnimStep + 1) % 3;
    }, 160);
  }

  private stopHoldAnimation(): void {
    if (this.holdAnimTimer >= 0) {
      clearInterval(this.holdAnimTimer);
      this.holdAnimTimer = -1;
    }
    this.holdAnimStep = 0;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 竖屏不再悬浮显示在线人数（已移到详情页"播放量"信息行的时间后面），横屏全屏保留。
      if (this.onlineTotal.length > 0 && !this.compactMode && this.showControls && this.fullscreen) {
        Text(this.onlineTotal + '人正在看')
          .fontSize(10)
          .fontColor('#CFFFFFFF')
          .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
          .position({ x: this.fullscreen ? 66 : 14, y: this.fullscreen ? 56 : 14 })
      }

      if (this.holdSpeedActive || this.gestureAdjustPercent >= 0) {
        this.HintBubble()
      }

      if (this.seekPreviewTime() >= 0) {
        this.SeekPreviewCard()
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  private seekPreviewTime(): number {
    return this.sliderSeekPreview >= 0 ? this.sliderSeekPreview : this.gestureSeekPreview;
  }

  /** 拖动定位预览：图片保持 16:9，时间固定覆盖在底部，避免取帧完成时改变布局。 */
  @Builder
  SeekPreviewCard() {
    Column({ space: this.fullscreen ? 14 : 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (this.seekPreviewSprite.length > 0 && this.seekPreviewSpriteCell >= 0) {
          Image(this.seekPreviewSprite)
            .width(this.previewWidth() * this.seekPreviewSpriteXLen)
            .height(this.previewHeight() * this.seekPreviewSpriteYLen)
            .sourceSize({
              width: Math.round(this.previewWidth() * this.seekPreviewSpriteXLen),
              height: Math.round(this.previewHeight() * this.seekPreviewSpriteYLen),
            })
            .objectFit(ImageFit.Fill)
            .position({
              x: -(this.seekPreviewSpriteCell % this.seekPreviewSpriteXLen) * this.previewWidth(),
              y: -Math.floor(this.seekPreviewSpriteCell / this.seekPreviewSpriteXLen) * this.previewHeight(),
            })
        } else if (this.seekPreviewFrame !== null) {
          Image(this.seekPreviewFrame)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        } else if (this.seekPreviewCover.length > 0) {
          Image(this.seekPreviewCover)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .opacity(0.7)
        } else {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#FF202124')
        }
      }
      .width(this.previewWidth())
      .aspectRatio(16 / 9)
      .borderRadius(5)
      .clip(true)
      .shadow({ radius: 5, color: '#77000000', offsetY: 1 })

      if (this.chapterTitle.length > 0) {
        Text(this.chapterTitle).fontSize(12).fontColor('#FFFFFF').maxLines(1)
          .width(this.previewWidth()).textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textShadow({ radius: 3, color: '#CC000000', offsetX: 0, offsetY: 1 })
      }
      Text(this.formatSeekTime(this.seekPreviewTime()) + ' / ' + this.formatSeekTime(this.duration))
        .fontSize(this.fullscreen ? 18 : 17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFFFF')
        // Text 上使用组件 shadow 会投影整个矩形边界，表现为时间文字外有一层方框。
        .textShadow({ radius: 3, color: '#CC000000', offsetX: 0, offsetY: 1 })
    }
    .align(Alignment.Center)
  }

  private previewWidth(): number {
    return this.fullscreen ? 148 : 116;
  }

  private previewHeight(): number {
    return this.previewWidth() * 9 / 16;
  }

  private formatSeekTime(seconds: number): string {
    const safe: number = Math.max(0, Math.floor(seconds));
    const hours: number = Math.floor(safe / 3600);
    const minutes: number = Math.floor((safe % 3600) / 60);
    const secs: number = safe % 60;
    const minuteText: string = minutes < 10 ? '0' + String(minutes) : String(minutes);
    const secondText: string = secs < 10 ? '0' + String(secs) : String(secs);
    if (hours <= 0) return minuteText + ':' + secondText;
    const hourText: string = hours < 10 ? '0' + String(hours) : String(hours);
    return hourText + ':' + minuteText + ':' + secondText;
  }

  /** 顶部小胶囊：长按倍速用三重快进标识；横滑/音量/亮度保持简洁符号。 */
  @Builder
  HintBubble() {
    Row({ space: 10 }) {
      if (this.holdSpeedActive) {
        Row({ space: 0 }) {
          Image($r('app.media.ic_play'))
            .width(13)
            .height(16)
            .fillColor(this.holdAnimStep === 0 ? '#FFFFFF' : '#70FFFFFF')
            .animation({ duration: 120, curve: Curve.EaseOut })
          Image($r('app.media.ic_play'))
            .width(13)
            .height(16)
            .fillColor(this.holdAnimStep === 1 ? '#FFFFFF' : '#70FFFFFF')
            .animation({ duration: 120, curve: Curve.EaseOut })
          Image($r('app.media.ic_play'))
            .width(13)
            .height(16)
            .fillColor(this.holdAnimStep === 2 ? '#FFFFFF' : '#70FFFFFF')
            .animation({ duration: 120, curve: Curve.EaseOut })
        }
        Text('倍速播放中')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      } else {
        Text((this.gestureAdjustKind === '亮度' ? '☀' : '♪') + ' ' + this.gestureAdjustPercent + '%')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
    }
    .padding({ left: 18, right: 18, top: 10, bottom: 10 })
    .borderRadius(8)
    .backgroundColor('#A6000000')
    .backdropBlur(12)
    // 顶部居中：位置 x 用百分比锚左侧，translate 回移一半实现水平居中。
    .position({ x: '50%', y: this.fullscreen ? 18 : 12 })
    .translate({ x: '-50%' })
    // 进入倍速态时启动动画；退出时停止并复位。
    .onAppear(() => {
      if (this.holdSpeedActive) this.startHoldAnimation();
    })
    .onDisAppear(() => {
      this.stopHoldAnimation();
    })
  }
}
