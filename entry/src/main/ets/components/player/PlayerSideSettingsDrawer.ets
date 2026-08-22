/**
 * 横屏右侧设置抽屉：左侧空白遮罩关闭，右侧 320px 承载更多菜单。
 */
@Component
export struct PlayerSideSettingsDrawer {
  onClose: () => void = () => {};
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
  }

  build() {
    Row() {
      Blank()
        .layoutWeight(1)
        .height('100%')
        .onClick(() => this.onClose())
      Column() {
        this.content()
      }
      .width(320)
      .height('100%')
      .backgroundColor('#18191C')
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
}
