import { formatDuration } from '../common/Utils';
import { PlayerPlaybackIndicator } from './PlayerPlaybackIndicator';

/** 在线人数、长按倍速、横滑预览、音量/亮度与双击反馈的轻量叠层。 */
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
  @Prop doubleTapVisible: boolean = false;
  @Prop doubleTapPlaying: boolean = false;
  @Prop doubleTapScale: number = 1;
  @Prop doubleTapOpacity: number = 0;

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
        Row({ space: 7 }) {
          Text(this.holdSpeedActive ? '»' : (this.gestureAdjustPercent >= 0 ?
            (this.gestureAdjustKind === '亮度' ? '☀' : '♪') :
            (this.gestureSeekPreview >= this.panStartTime ? '››' : '‹‹')))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text(this.holdSpeedActive ? '2× 快速播放' : (this.gestureAdjustPercent >= 0 ?
            this.gestureAdjustKind + ' ' + this.gestureAdjustPercent + '%' :
            formatDuration(this.gestureSeekPreview) + ' / ' + formatDuration(this.duration)))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
        .padding({ left: 14, right: 14, top: 9, bottom: 9 })
        .borderRadius(18)
        .backgroundColor('#A6000000')
        .backdropBlur(12)
      }

      if (this.doubleTapVisible) {
        PlayerPlaybackIndicator({
          playAction: this.doubleTapPlaying,
          showLabel: true,
          feedbackScale: this.doubleTapScale,
          opacityValue: this.doubleTapOpacity,
          interactive: false,
        })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
