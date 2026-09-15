/** 横屏播放器顶部身份与互动栏。 */
@Component
export struct PlayerFullscreenHeader {
  @Prop title: string = '';
  @Prop ownerName: string = '';
  @Prop ownerFace: string = '';
  @Prop liked: boolean = false;
  @Prop coined: boolean = false;
  @Prop favorited: boolean = false;
  @Prop accent: string = '#FB7299';
  onBack: () => void = () => {};
  onHome: () => void = () => {};
  onLike: () => void = () => {};
  onCoin: () => void = () => {};
  onFavorite: () => void = () => {};
  onShare: () => void = () => {};

  @Builder
  IconButton(icon: Resource, size: number, color: ResourceColor, onClick: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Image(icon)
        .width(size)
        .height(size)
        .renderMode(ImageRenderMode.Template)
        .fillColor(color)
    }
    .width(42)
    .height(42)
    .onClick(() => onClick())
  }

  build() {
    Row({ space: 10 }) {
      this.IconButton($r('app.media.ic_back'), 24, '#FFFFFF', () => this.onBack())
      Image($r('app.media.ic_tab_home'))
        .width(42).height(42).padding(10)
        .renderMode(ImageRenderMode.Template).fillColor('#FFFFFF')
        .accessibilityText('返回主页').id('player-home-entry')
        .onClick(() => this.onHome())
      if (this.ownerFace.length > 0) {
        Image(this.ownerFace).width(30).height(30).borderRadius(15).objectFit(ImageFit.Cover)
      }
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.ownerName).fontSize(11).fontColor('#B3FFFFFF').maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      this.IconButton(this.liked ? $r('app.media.ic_like_fill') : $r('app.media.ic_like'), 24,
        this.liked ? this.accent : '#FFFFFF', () => this.onLike())
      this.IconButton($r('app.media.bilix_icon_coin'), 24, this.coined ? this.accent : '#FFFFFF', () => this.onCoin())
      this.IconButton(this.favorited ? $r('app.media.ic_favorite_fill') : $r('app.media.bilix_icon_fav'), 24,
        this.favorited ? this.accent : '#FFFFFF', () => this.onFavorite())
      this.IconButton($r('app.media.ic_share'), 24, '#FFFFFF', () => this.onShare())
    }
    .width('100%')
    .height(54)
    .padding({ left: 12, right: 18, top: 4 })
  }
}
