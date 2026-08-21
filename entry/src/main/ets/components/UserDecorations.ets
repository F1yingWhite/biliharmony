/**
 * 用户装扮公用组件。
 * 评论、动态和个人空间共用同一套头像/挂件比例，避免各页面分别调尺寸后互相漂移。
 */
import { RemoteAssetCache } from '../common/RemoteAssetCache';

@Component
export struct DecoratedAvatar {
  @StorageProp('isDark') isDark: boolean = false;
  @Prop @Watch('onFaceChanged') face: string = '';
  @Prop @Watch('onPendantChanged') pendant: string = '';
  @Prop avatarSize: number = 40;
  @Prop containerSize: number = 54;
  @Prop pendantScale: number = 1.38;
  @Prop avatarBorderWidth: number = 0;
  @Prop avatarBorderColor: string = '#00FFFFFF';
  @State avatarLoaded: boolean = false;
  @State faceLocal: string = '';
  @State pendantLocal: string = '';
  private faceGeneration: number = 0;
  private pendantGeneration: number = 0;

  aboutToAppear(): void {
    this.primeFace();
    this.primePendant();
  }

  aboutToDisappear(): void {
    this.faceGeneration++;
    this.pendantGeneration++;
  }

  private onFaceChanged(): void {
    this.avatarLoaded = false;
    this.primeFace();
  }

  private onPendantChanged(): void {
    this.primePendant();
  }

  private primeFace(): void {
    const url: string = this.face;
    const generation: number = ++this.faceGeneration;
    const cached: string = RemoteAssetCache.cachedAvatar(url);
    this.faceLocal = cached !== url ? cached : '';
    if (!url.startsWith('http') || cached !== url) return;
    RemoteAssetCache.ensureAvatar(url).then((local: string): void => {
      if (generation === this.faceGeneration && this.face === url && local !== url) {
        this.avatarLoaded = false;
        this.faceLocal = local;
      }
    }).catch((): void => {
    });
  }

  private faceSource(): string {
    return this.faceLocal.length > 0 ? this.faceLocal : this.face;
  }

  private primePendant(): void {
    const url: string = this.pendant;
    const generation: number = ++this.pendantGeneration;
    const cached: string = RemoteAssetCache.cachedDecoration(url);
    this.pendantLocal = cached !== url ? cached : '';
    if (!url.startsWith('http') || cached !== url) return;
    RemoteAssetCache.ensureDecoration(url).then((local: string): void => {
      if (generation === this.pendantGeneration && this.pendant === url && local !== url) {
        this.pendantLocal = local;
      }
    }).catch((): void => {
    });
  }

  private pendantSource(): string {
    return this.pendantLocal.length > 0 ? this.pendantLocal : this.pendant;
  }

  @Builder
  AvatarImage() {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(this.avatarSize)
        .height(this.avatarSize)
        .fill(this.isDark ? '#303238' : '#E7E9EC')
        .opacity(this.avatarLoaded ? 0 : 1)
      if (this.avatarBorderWidth > 0) {
        ForEach([this.faceSource()], (source: string) => {
          Image(source.length > 0 ? source : $r('app.media.placeholder_avatar_noface'))
            .alt($r('app.media.placeholder_avatar_noface'))
            .width(this.avatarSize)
            .height(this.avatarSize)
            .borderRadius(this.avatarSize / 2)
            .objectFit(ImageFit.Cover)
            .border({ width: this.avatarBorderWidth, color: this.avatarBorderColor })
            .clip(true)
            .opacity(this.avatarLoaded ? 1 : 0)
            .animation({ duration: 120, curve: Curve.EaseOut })
            .onComplete(() => {
              this.avatarLoaded = true;
            })
            .onError(() => {
              this.avatarLoaded = true;
            })
        }, (source: string) => source)
      } else {
        // ArkUI 即使收到 0 宽边框也可能在圆形裁切边缘留下半透明描边；
        // 普通头像与带挂件头像完全不挂 border 修饰器。
        ForEach([this.faceSource()], (source: string) => {
          Image(source.length > 0 ? source : $r('app.media.placeholder_avatar_noface'))
            .alt($r('app.media.placeholder_avatar_noface'))
            .width(this.avatarSize)
            .height(this.avatarSize)
            .borderRadius(this.avatarSize / 2)
            .objectFit(ImageFit.Cover)
            .clip(true)
            .opacity(this.avatarLoaded ? 1 : 0)
            .animation({ duration: 120, curve: Curve.EaseOut })
            .onComplete(() => {
              this.avatarLoaded = true;
            })
            .onError(() => {
              this.avatarLoaded = true;
            })
        }, (source: string) => source)
      }
    }
    .width(this.avatarSize)
    .height(this.avatarSize)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      this.AvatarImage()
      if (this.pendant.length > 0) {
        Image(this.pendantSource())
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
  @Prop @Watch('onImageUrlChanged') imageUrl: string = '';
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
  @State imageLocal: string = '';
  private imageGeneration: number = 0;

  aboutToAppear(): void {
    this.primeImage();
  }

  aboutToDisappear(): void {
    this.imageGeneration++;
  }

  private onImageUrlChanged(): void {
    this.imageAspect = 0;
    this.primeImage();
  }

  private primeImage(): void {
    const url: string = this.imageUrl;
    const generation: number = ++this.imageGeneration;
    const cached: string = RemoteAssetCache.cachedDecoration(url);
    this.imageLocal = cached !== url ? cached : '';
    if (!url.startsWith('http') || cached !== url) return;
    RemoteAssetCache.ensureDecoration(url).then((local: string): void => {
      if (generation === this.imageGeneration && this.imageUrl === url && local !== url) this.imageLocal = local;
    }).catch((): void => {
    });
  }

  private imageSource(): string {
    return this.imageLocal.length > 0 ? this.imageLocal : this.imageUrl;
  }

  private normalizedNumber(): string {
    // 不同接口可能返回 "No. 000318"、"NO.000318" 或纯编号，统一只保留下行数字。
    return this.numberText.trim().replace(/^no\.?\s*/i, '');
  }

  private bannerWidth(): number {
    const aspect: number = this.imageAspect > 0 ? this.imageAspect : 3;
    return this.bannerHeight * aspect;
  }

  /** 评论装扮的编号区只有一个 bannerHeight 宽，按位数收缩以完整显示序号。 */
  private compactNumberFontSize(): number {
    const length: number = Math.max(1, this.normalizedNumber().length);
    const available: number = Math.max(16, this.bannerHeight - 6);
    return Math.max(5, Math.min(10, Math.floor(available * 1.65 / length)));
  }

  build() {
    Stack({ alignContent: this.fitWidth ? Alignment.Start : (this.numberOnLeft ? Alignment.TopStart : Alignment.TopEnd) }) {
      if (this.imageUrl.length > 0) {
        Image(this.imageSource())
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
              .fontSize(this.compactNumberFontSize())
              .lineHeight(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.numberColor)
              .maxLines(1)
              .letterSpacing(0)
          }
            // 评论卡片右侧通常还有一段透明留白，编号向内收后能贴近装扮主体。
            .width(this.bannerHeight)
            .height(this.bannerHeight)
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Center)
            .translate({ x: -12 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
    }
    .width(this.fitWidth ? this.bannerWidth() : '100%')
    .height(this.bannerHeight)
  }
}
