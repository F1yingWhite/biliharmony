/**
 * 播放器中央播放状态的唯一视觉实现。
 * 默认控制层和双击反馈共同复用；文字绝对定位在图标下方，不参与中心布局。
 */
@Component
export struct PlayerPlaybackIndicator {
  @Prop playAction: boolean = true;
  @Prop showLabel: boolean = false;
  @Prop feedbackScale: number = 1;
  @Prop opacityValue: number = 1;
  @Prop interactive: boolean = false;
  onTap: () => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(50)
          .height(50)
          .fill('#8F000000')
        Image(this.playAction ? $r('app.media.ic_play') : $r('app.media.ic_pause'))
          .width(24)
          .height(24)
          .renderMode(ImageRenderMode.Template)
          .fillColor('#FFFFFF')
          // 三角形的有效图形偏右，补偿后与暂停图标共享同一个视觉中心。
          .translate({ x: this.playAction ? -1.5 : 0 })
      }
      .width(50)
      .height(50)
      if (this.showLabel) {
        Text(this.playAction ? '继续播放' : '已暂停')
          .width(84)
          .height(16)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2FFFFFF')
          .textAlign(TextAlign.Center)
          .position({ x: 0, y: 78 })
      }
    }
    .width(84)
    .height(100)
    .scale({ x: this.feedbackScale, y: this.feedbackScale })
    .opacity(this.opacityValue)
    .hitTestBehavior(this.interactive ? HitTestMode.Default : HitTestMode.None)
    .onClick(() => {
      if (this.interactive) this.onTap();
    })
  }
}
