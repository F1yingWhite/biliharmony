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

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.face.length > 0 ? this.face : $r('app.media.placeholder_avatar_noface'))
        .width(this.avatarSize)
        .height(this.avatarSize)
        .borderRadius(this.avatarSize / 2)
        .objectFit(ImageFit.Cover)
        .border({ width: this.avatarBorderWidth, color: this.avatarBorderColor })
        .clip(true)
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
          Text('No.')
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
          // 右端通常是角色/徽标图案；编号放进其左侧的独立安全区，避免覆盖装扮主体。
          .width(42)
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 3, right: 3, top: 1, bottom: 1 })
          .borderRadius(5)
          .backgroundColor('#33000000')
          .margin({ top: 6, right: 78 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height(this.bannerHeight)
  }
}
