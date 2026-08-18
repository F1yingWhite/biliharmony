import { formatDuration } from '../common/Utils';

/** 在线人数、长按倍速、横滑预览、音量/亮度的轻量叠层。 */
@Component
export struct PlayerGestureOverlay {
  @Prop onlineTotal: string = '';
  @Prop compactMode: boolean = false;
  @Prop showControls: boolean = false;
  @Prop fullscreen: boolean = false;
  @Prop holdSpeedActive: boolean = false;
  @Prop gestureSeekPreview: number = -1;
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
    }, 220);
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
      if (this.onlineTotal.length > 0 && !this.compactMode && this.showControls) {
        Text(this.onlineTotal + '人正在看')
          .fontSize(10)
          .fontColor('#CFFFFFFF')
          .shadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
          .position({ x: this.fullscreen ? 66 : 14, y: this.fullscreen ? 56 : 14 })
      }

      if (this.holdSpeedActive || this.gestureSeekPreview >= 0 || this.gestureAdjustPercent >= 0) {
        this.HintBubble()
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /** 顶部小胶囊：长按倍速 = »»» 逐个点亮；横滑/音量/亮度保持简洁符号。 */
  @Builder
  HintBubble() {
    Row({ space: 7 }) {
      if (this.holdSpeedActive) {
        // 三个右向实心三角逐个亮起：亮 = 白，灭 = 半透明，间隔刷新实现循环（对齐官方样式）。
        Row({ space: 2 }) {
          Text('▶').fontSize(10)
            .fontColor(this.holdAnimStep >= 0 ? '#FFFFFF' : '#59FFFFFF')
            .animation({ duration: 160, curve: Curve.EaseOut })
          Text('▶').fontSize(10)
            .fontColor(this.holdAnimStep >= 1 ? '#FFFFFF' : '#59FFFFFF')
            .animation({ duration: 160, curve: Curve.EaseOut })
          Text('▶').fontSize(10)
            .fontColor(this.holdAnimStep >= 2 ? '#FFFFFF' : '#59FFFFFF')
            .animation({ duration: 160, curve: Curve.EaseOut })
        }
        Text('倍速播放中')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      } else {
        Text(this.gestureAdjustPercent >= 0 ?
          ((this.gestureAdjustKind === '亮度' ? '☀' : '♪') + ' ' + this.gestureAdjustPercent + '%') :
          (formatDuration(this.gestureSeekPreview) + ' / ' + formatDuration(this.duration)))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
    }
    .padding({ left: 16, right: 16, top: 9, bottom: 9 })
    .borderRadius(8)
    .backgroundColor('#8C000000')
    .backdropBlur(10)
    // 顶部居中：位置 x 用百分比锚左侧，translate 回移一半实现水平居中。
    .position({ x: '50%', y: this.fullscreen ? 60 : 44 })
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