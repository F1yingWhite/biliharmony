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

/** 972:162 一类评论装扮条保持原始 6:1 比例通栏铺底；动态页则用 fitWidth 模式按图片
 *  原始宽高比显示为右上角小卡（官方动态卡片样式），编号叠加在图右侧 1:1 编号区。 */
@Component
export struct UserDecorationBanner {
  @Prop imageUrl: string = '';
  @Prop numberPrefix: string = 'NO.';
  @Prop numberText: string = '';
  @Prop numberColor: string = '#FFFFFF';
  @Prop bannerHeight: number = 46;
  /** true 编号靠左（动态页）；false 编号靠右（评论区）。 */
  @Prop numberOnLeft: boolean = false;
  /** false 时不在装扮图上叠加编号，由业务方自行把编号放在名字旁（动态页用）。 */
  @Prop renderNumber: boolean = true;
  /** true 时宽度 = 高度 × 图片原始宽高比（Contain，不裁切）；false 通栏 Cover。 */
  @Prop fitWidth: boolean = false;
  /** 图片原始宽高比（onComplete 实测），未加载完成前按 3:1 预留。 */
  @State imageAspect: number = 0;

  private normalizedNumber(): string {
    // 不同接口可能返回 "No. 000318"、"NO.000318" 或纯编号，统一只保留下行数字。
    return this.numberText.trim().replace(/^no\.?\s*/i, '');
  }

  private bannerWidth(): number {
    const aspect: number = this.imageAspect > 0 ? this.imageAspect : 3;
    return this.bannerHeight * aspect;
  }

  build() {
    Stack({ alignContent: this.fitWidth ? Alignment.Start : (this.numberOnLeft ? Alignment.TopStart : Alignment.TopEnd) }) {
      if (this.imageUrl.length > 0) {
        Image(this.imageUrl)
          .width(this.fitWidth ? this.bannerWidth() : '100%')
          .height(this.bannerHeight)
          .objectFit(this.fitWidth ? ImageFit.Contain : ImageFit.Cover)
          .opacity(0.96)
          .hitTestBehavior(HitTestMode.None)
          .onComplete((msg) => {
            if (msg !== undefined && msg.height > 0) {
              this.imageAspect = msg.width / msg.height;
            }
          })
      }
      if (this.numberText.length > 0 && this.renderNumber) {
        if (this.fitWidth) {
          // 官方粉丝卡（438:132）：左侧约 2/3 是编号空白区、右侧约 1:1 是形象图；
          // 编号单行斜体在空白区内右对齐，贴近形象图但不压图。
          Row({ space: 2 }) {
            Text(this.numberPrefix.length > 0 ? this.numberPrefix.toUpperCase() : 'NO.')
              .fontSize(7)
              .lineHeight(10)
              .fontWeight(FontWeight.Bold)
              .fontStyle(FontStyle.Italic)
              .fontColor(this.numberColor)
            Text(this.normalizedNumber())
              .fontSize(11)
              .lineHeight(14)
              .fontWeight(FontWeight.Bold)
              .fontStyle(FontStyle.Italic)
              .fontColor(this.numberColor)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width(this.bannerWidth() - this.bannerHeight)
          .height(this.bannerHeight)
          .padding({ right: 4 })
          .justifyContent(FlexAlign.End)
          .alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.None)
        } else {
          Column({ space: 0 }) {
            Text(this.numberPrefix.length > 0 ? this.numberPrefix.toUpperCase() : 'NO.')
              .fontSize(7)
              .lineHeight(10)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.numberColor)
            Text(this.normalizedNumber())
              .fontSize(10)
              .lineHeight(13)
              .fontWeight(FontWeight.Bold)
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
    }
    .width(this.fitWidth ? this.bannerWidth() : '100%')
    .height(this.bannerHeight)
  }
}
