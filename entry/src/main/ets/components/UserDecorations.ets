/**
 * 用户装扮公用组件。
 * 评论、动态和个人空间共用同一套头像/挂件比例，避免各页面分别调尺寸后互相漂移。
 */

@Component
export struct DecoratedAvatar {
  @Prop face: string = '';
  @Prop pendant: string = '';
  @Prop avatarSize: number = 40;
  @Prop containerSize: number = 54;
  @Prop pendantScale: number = 1.38;
  @Prop avatarBorderWidth: number = 0;
  @Prop avatarBorderColor: string = '#00FFFFFF';

  @Builder
  AvatarImage() {
    if (this.avatarBorderWidth > 0) {
      Image(this.face.length > 0 ? this.face : $r('app.media.placeholder_avatar_noface'))
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.avatarSize / 2)
        .objectFit(ImageFit.Cover)
        .border({ width: this.avatarBorderWidth, color: this.avatarBorderColor })
        .clip(true)
    } else {
      // ArkUI 即使收到 0 宽边框也可能在圆形裁切边缘留下半透明描边；
      // 普通头像与带挂件头像完全不挂 border 修饰器。
      Image(this.face.length > 0 ? this.face : $r('app.media.placeholder_avatar_noface'))
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.avatarSize / 2)
        .objectFit(ImageFit.Cover)
        .clip(true)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      this.AvatarImage()
      if (this.pendant.length > 0) {
        Image(this.pendant)
          .width(this.avatarSize * this.pendantScale)
          .height(this.avatarSize * this.pendantScale)
          .objectFit(ImageFit.Contain)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(this.containerSize)
    .height(this.containerSize)
    .clip(false)
  }
}

/** 972:162 一类评论/动态装扮条保持原始 6:1 比例，并靠作者信息区右侧摆放。 */
@Component
export struct UserDecorationBanner {
  @Prop imageUrl: string = '';
  @Prop numberPrefix: string = 'NO.';
  @Prop numberText: string = '';
  @Prop numberColor: string = '#FFFFFF';
  @Prop bannerHeight: number = 46;

  private normalizedNumber(): string {
    // 不同接口可能返回 "No. 000318"、"NO.000318" 或纯编号，统一只保留下行数字。
    return this.numberText.trim().replace(/^no\.?\s*/i, '');
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      if (this.imageUrl.length > 0) {
        Image(this.imageUrl)
          .width(this.bannerHeight * 6)
          .height(this.bannerHeight)
          .objectFit(ImageFit.Contain)
          .opacity(0.96)
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.numberText.length > 0) {
        Column({ space: 0 }) {
          Text(this.numberPrefix.length > 0 ? this.numberPrefix.toUpperCase() : 'NO.')
            .fontSize(6)
            .lineHeight(8)
            .fontColor(this.numberColor)
          Text(this.normalizedNumber())
            .fontSize(8)
            .lineHeight(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.numberColor)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
          // 972:162 装扮图的最右侧 1:1 区域专门留给粉丝编号；
          // 与背景图同高并右对齐，保持在装扮内容上层，不另加深色胶囊。
          .width(this.bannerHeight)
          .height(this.bannerHeight)
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height(this.bannerHeight)
  }
}
