@Component
export struct PlayerDanmakuAction {
  icon: Resource = $r('app.media.ic_more');
  onTap: () => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.icon)
        .width(15)
        .height(15)
        .renderMode(ImageRenderMode.Template)
        .fillColor('#FFFFFF')
    }
    .width(30)
    .height(28)
    .borderRadius(14)
    .backgroundColor('#00000000')
    .stateStyles({
      pressed: {
        .backgroundColor('#59FFFFFF')
        .scale({ x: 0.88, y: 0.88 })
      },
    })
    .onClick(() => this.onTap())
  }
}
