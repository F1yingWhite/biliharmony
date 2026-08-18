import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { AppNavStack, ImageViewerParam } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { BackButton } from '../components/BackButton';
import { biliImageThumbnail } from '../common/ImageUrl';

@Component
struct ZoomableImage {
  @Prop source: string = '';
  @Prop previewSource: string = '';
  @Prop transitionId: string = '';
  onLongPress: () => void = () => {};
  onZoomChange: (zoomed: boolean) => void = () => {};
  /** 单击（含黑色留白区）退出查看器。 */
  onSingleTap: () => void = () => {};
  @State scaleValue: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  @State entranceScale: number = 1;
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  private pinchBase: number = 1;
  private pinchBaseX: number = 0;
  private pinchBaseY: number = 0;
  private pinchCenterX: number = 0;
  private pinchCenterY: number = 0;
  private panBaseX: number = 0;
  private panBaseY: number = 0;

  aboutToAppear(): void {
    // 评论/动态等通过 geometryTransition 进入时，额外做一次轻微放大入场；
    // 即使共享元素动画在某些容器里失效，也不会出现“瞬间变满屏”的生硬感。
    if (this.transitionId.length > 0) {
      this.entranceScale = 0.8;
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, () => {
        this.entranceScale = 1;
      });
    }
  }

  private clampScale(value: number): number {
    return Math.max(1, Math.min(5, value));
  }

  private clampX(value: number, scale: number): number {
    const limit: number = Math.max(0, this.viewportWidth * 0.5 * (scale - 1));
    return Math.max(-limit, Math.min(limit, value));
  }

  private clampY(value: number, scale: number): number {
    const limit: number = Math.max(0, this.viewportHeight * 0.5 * (scale - 1));
    return Math.max(-limit, Math.min(limit, value));
  }

  /** 保持 focus 对应的图片内容缩放前后仍停在 focus 下方。 */
  private zoomAt(targetScale: number, focusX: number, focusY: number, animated: boolean): void {
    const nextScale: number = this.clampScale(targetScale);
    const ratio: number = nextScale / Math.max(0.01, this.scaleValue);
    const centeredX: number = focusX - this.viewportWidth * 0.5;
    const centeredY: number = focusY - this.viewportHeight * 0.5;
    const nextX: number = this.clampX(centeredX - (centeredX - this.offsetX) * ratio, nextScale);
    const nextY: number = this.clampY(centeredY - (centeredY - this.offsetY) * ratio, nextScale);
    const update = (): void => {
      this.scaleValue = nextScale;
      this.offsetX = nextX;
      this.offsetY = nextY;
    };
    if (animated) this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, update);
    else update();
    this.onZoomChange(nextScale > 1.05);
  }

  private resetTransform(animated: boolean): void {
    const update = (): void => {
      this.scaleValue = 1;
      this.offsetX = 0;
      this.offsetY = 0;
    };
    if (animated) this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, update);
    else update();
    this.onZoomChange(false);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.source)
        .alt(this.previewSource)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        // Navigation 栈下用 geometryTransition（一镜到底）；旧 sharedTransition 只对 legacy router 生效。
        .geometryTransition(this.transitionId.length > 0 ? this.transitionId : 'image-viewer-none')
        .scale({ x: this.scaleValue * this.entranceScale, y: this.scaleValue * this.entranceScale })
        .translate({ x: this.offsetX, y: this.offsetY })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart((event: GestureEvent) => {
                this.pinchBase = this.scaleValue;
                this.pinchBaseX = this.offsetX;
                this.pinchBaseY = this.offsetY;
                this.pinchCenterX = event.pinchCenterX;
                this.pinchCenterY = event.pinchCenterY;
              })
              .onActionUpdate((event: GestureEvent) => {
                const nextScale: number = this.clampScale(this.pinchBase * event.scale);
                const ratio: number = nextScale / Math.max(0.01, this.pinchBase);
                const startX: number = this.pinchCenterX - this.viewportWidth * 0.5;
                const startY: number = this.pinchCenterY - this.viewportHeight * 0.5;
                const currentX: number = event.pinchCenterX - this.viewportWidth * 0.5;
                const currentY: number = event.pinchCenterY - this.viewportHeight * 0.5;
                // 缩放与两指中心移动一起计算；锚点不再固定在画面中心。
                this.offsetX = this.clampX(currentX - (startX - this.pinchBaseX) * ratio, nextScale);
                this.offsetY = this.clampY(currentY - (startY - this.pinchBaseY) * ratio, nextScale);
                this.scaleValue = nextScale;
                this.onZoomChange(this.scaleValue > 1.05);
                if (this.scaleValue <= 1.01) this.resetTransform(false);
              })
              .onActionEnd(() => {
                if (this.scaleValue < 1.05) this.resetTransform(true);
              }),
            // 原始尺寸下不要截获横滑，交由外层 Swiper 切换图片。
            PanGesture({ fingers: 1, direction: this.scaleValue > 1.05 ? PanDirection.All : PanDirection.None, distance: 1 })
              .onActionStart(() => {
                this.panBaseX = this.offsetX;
                this.panBaseY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.scaleValue <= 1) return;
                // 高倍缩放时同样的手指位移在画面上显得偏慢，做有上限的倍率补偿保持跟手。
                const followRate: number = Math.min(1.6, 0.75 + this.scaleValue * 0.35);
                this.offsetX = this.clampX(this.panBaseX + event.offsetX * followRate, this.scaleValue);
                this.offsetY = this.clampY(this.panBaseY + event.offsetY * followRate, this.scaleValue);
              }),
            // 单击/双击互斥识别：双击缩放优先，单击等待双击超时后退出查看器。
            GestureGroup(GestureMode.Exclusive,
              TapGesture({ count: 2 })
                .onAction((event: GestureEvent) => {
                  if (this.scaleValue > 1.05) this.resetTransform(true);
                  else {
                    const finger: FingerInfo | undefined = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
                    const focusX: number = finger !== undefined ? finger.localX : this.viewportWidth * 0.5;
                    const focusY: number = finger !== undefined ? finger.localY : this.viewportHeight * 0.5;
                    this.zoomAt(2.5, focusX, focusY, true);
                  }
                }),
              TapGesture({ count: 1 })
                .onAction(() => this.onSingleTap())
            )
          )
        )
        // Swiper 的横滑识别会与图片长按竞争；高优先级长按保证按住图片一定弹出操作菜单。
        .priorityGesture(
          LongPressGesture({ fingers: 1, repeat: false, duration: 450 })
            .onAction(() => this.onLongPress())
        )
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number.parseFloat(String(newValue.width));
      const height: number = Number.parseFloat(String(newValue.height));
      if (Number.isFinite(width) && width > 0) this.viewportWidth = width;
      if (Number.isFinite(height) && height > 0) this.viewportHeight = height;
    })
  }
}

@Component
export struct ImageViewerPage {
  param: ImageViewerParam = { images: [], initialIndex: 0 };
  @State currentIndex: number = 0;
  @State saving: boolean = false;
  @State actionMenuOpen: boolean = false;
  @State currentZoomed: boolean = false;
  /** 黑底：首帧直接置为不透明，避免从底层白页淡入造成黑白闪烁。 */
  @State bgOpacity: number = 1;
  /** 每张图是否已切换为原图（默认只加载缩略图，点"查看原图"才加载原图，节约内存） */
  @State originalFlags: Array<boolean> = [];
  /** 原图 HEAD 体积过小视为低清图，不展示“查看原图”入口。 */
  @State lowResFlags: Array<boolean> = [];
  @State originalSizeText: string = '';
  private sizeCache: Map<number, string> = new Map<number, string>();
  @StorageProp('imageViewerCloseRequest') @Watch('onCloseRequested') closeRequest: number = 0;
  private closing: boolean = false;
  /** 低于此体积（3MB）的图片直接加载原图，不再先缩略图后手动“查看原图”。 */
  private static readonly ORIGINAL_SIZE_THRESHOLD: number = 3 * 1024 * 1024;

  aboutToAppear(): void {
    this.currentIndex = Math.max(0, Math.min(this.param.images.length - 1, this.param.initialIndex));
    Immersive.setBarIcons(true, true);
    this.originalFlags = this.param.images.map(() => false);
    this.lowResFlags = this.param.images.map(() => false);
    this.fetchOriginalSize(this.currentIndex);
  }

  onCloseRequested(): void {
    this.goBack();
  }

  goBack(): void {
    if (this.closing) return;
    this.closing = true;
    // 保持黑底不先淡出，直接让 geometryTransition 把图片缩回缩略图；
    // 如果先 fade 黑底，收缩动画会被白底/透明底盖掉，看起来像没有缩小动画。
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      AppNavStack.pop(false);
    });
  }

  private currentUrl(): string {
    return this.param.images.length > 0 ? this.param.images[this.currentIndex] : '';
  }

  /** 非当前页用缩略参数图（B 站 @<宽>w 后缀），滑到该页时再加载原图。 */
  private thumbUrl(url: string): string {
    return biliImageThumbnail(url, 640);
  }

  /** 首屏展示用缩略图：先快速加载小图，点“查看原图”才切原图。 */
  private previewUrl(url: string): string {
    return biliImageThumbnail(url, 640);
  }

  private isOriginal(index: number): boolean {
    return index >= 0 && index < this.originalFlags.length && this.originalFlags[index];
  }

  /**
   * 生成当前 index 对应的共享元素 ID。
   * transitionId 只携带了打开时那一张的完整 ID，多图滑动后需要按同一前缀推导出当前图片的 ID，
   * 关闭时才能缩回当前图片对应的缩略图。
   */
  private transitionIdFor(index: number): string {
    const base: string = this.param.transitionId ?? '';
    if (base.length === 0) return '';
    if (index === this.param.initialIndex) return base;
    const suffix: string = '-' + String(this.param.initialIndex);
    const prefix: string = base.endsWith(suffix) ? base.substring(0, base.length - suffix.length) : base;
    return prefix + '-' + String(index);
  }

  /** 查看原图：仅切换当前张，其余保持中图。 */
  private viewOriginal(): void {
    const next: Array<boolean> = this.originalFlags.slice();
    next[this.currentIndex] = true;
    this.originalFlags = next;
  }

  /** HEAD 请求读 Content-Length，给"查看原图"按钮带上文件大小；失败则不显示大小。 */
  private fetchOriginalSize(index: number): void {
    if (index < 0 || index >= this.param.images.length) return;
    if (this.sizeCache.has(index)) {
      this.originalSizeText = this.sizeCache.get(index) ?? '';
      return;
    }
    const request: http.HttpRequest = http.createHttp();
    request.request(this.param.images[index], {
      method: http.RequestMethod.HEAD,
      header: { 'Referer': 'https://www.bilibili.com/' },
      connectTimeout: 8000,
      readTimeout: 8000,
    }).then((response: http.HttpResponse) => {
      const headers: Record<string, Object> = response.header as Record<string, Object>;
      const lengthText: string = String(headers['content-length'] ?? '');
      const bytes: number = Number.parseInt(lengthText);
      let label: string = '';
      // 3MB 以下的图片打开即加载原图：体积小，先缩略图再手动换原图反而闪一次。
      const autoOriginal: boolean = Number.isFinite(bytes) && bytes > 0 &&
        bytes < ImageViewerPage.ORIGINAL_SIZE_THRESHOLD;
      const lowRes: boolean = Number.isFinite(bytes) && bytes > 0 && bytes < 200 * 1024;
      if (Number.isFinite(bytes) && bytes > 0 && !lowRes) {
        label = bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : String(Math.ceil(bytes / 1024)) + ' KB';
      }
      this.lowResFlags[index] = lowRes;
      if (autoOriginal && !this.originalFlags[index]) {
        const next: Array<boolean> = this.originalFlags.slice();
        next[index] = true;
        this.originalFlags = next;
      }
      this.sizeCache.set(index, label);
      if (index === this.currentIndex) this.originalSizeText = label;
      request.destroy();
    }).catch(() => {
      this.lowResFlags[index] = false;
      this.sizeCache.set(index, '');
      if (index === this.currentIndex) this.originalSizeText = '';
      request.destroy();
    });
  }

  private imageExtension(url: string): string {
    const clean: string = url.split('?')[0].toLowerCase();
    const dot: number = clean.lastIndexOf('.');
    if (dot >= 0) {
      const extension: string = clean.substring(dot + 1);
      if (extension === 'png' || extension === 'gif' || extension === 'webp' || extension === 'jpeg') return extension;
    }
    return 'jpg';
  }

  private async saveCurrentImage(): Promise<void> {
    const url: string = this.currentUrl();
    if (url.length === 0 || this.saving) return;
    this.saving = true;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: { 'Referer': 'https://www.bilibili.com/' },
        connectTimeout: 15000,
        readTimeout: 30000,
      });
      if (Number(response.responseCode) < 200 || Number(response.responseCode) >= 300) {
        throw new Error('HTTP ' + response.responseCode);
      }
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
      const extension: string = this.imageExtension(url);
      const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, extension,
        { title: 'BiliHarmony_' + Date.now() });
      const file: fs.File = await fs.open(uri, fs.OpenMode.READ_WRITE);
      try {
        await fs.write(file.fd, response.result as ArrayBuffer);
      } finally {
        fs.closeSync(file);
      }
      this.getUIContext().getPromptAction().showToast({ message: '已保存到图库' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '保存失败，请稍后重试' });
    } finally {
      request.destroy();
      this.saving = false;
    }
  }

  private shareCurrentImage(): void {
    const url: string = this.currentUrl();
    if (url.length === 0) return;
    this.actionMenuOpen = false;
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: 'general.hyperlink',
      title: '分享图片',
      content: url,
      description: '来自哔哩哔哩的图片',
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开系统分享' });
    });
  }

  @Builder
  ImageActionMenu() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => this.actionMenuOpen = false)
      Column({ space: 8 }) {
        Text('图片')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2F2F4')
          .width('100%')
          .padding({ left: 2, top: 2, bottom: 8 })
        Row({ space: 12 }) {
          SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE,
            buttonType: ButtonType.Normal })
            .width('48%')
            .height(48)
            .fontSize(14)
            .fontColor('#F2F2F4')
            .backgroundColor('#2A2C31')
            .borderRadius(14)
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              this.actionMenuOpen = false;
              if (result === SaveButtonOnClickResult.SUCCESS) this.saveCurrentImage();
            })
          Button() {
            Row({ space: 7 }) {
              Image($r('app.media.ic_share'))
                .width(18)
                .height(18)
                .renderMode(ImageRenderMode.Template)
                .fillColor('#F2F2F4')
              Text('分享').fontSize(14).fontColor('#F2F2F4')
            }
          }
          .width('48%')
          .height(48)
          .backgroundColor('#2A2C31')
          .borderRadius(14)
          .onClick(() => this.shareCurrentImage())
        }
        .width('100%')
        Text('取消')
          .width('100%')
          .height(42)
          .fontSize(14)
          .fontColor('#A8ABB2')
          .textAlign(TextAlign.Center)
          .onClick(() => this.actionMenuOpen = false)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: Immersive.bottomInset() + 8 })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor('#191A1F')
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseOut }),
      TransitionEffect.opacity(0).animation({ duration: 150, curve: Curve.EaseIn })))
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .opacity(this.bgOpacity)

      if (this.param.images.length > 0) {
        Swiper() {
          ForEach(this.param.images, (source: string, index: number) => {
            ZoomableImage({
              // 默认只加载 1080w 中图，点"查看原图"后该张才换原图
              source: this.isOriginal(index) ? source : this.previewUrl(source),
              previewSource: this.thumbUrl(source),
              transitionId: this.transitionIdFor(index),
              onLongPress: () => this.actionMenuOpen = true,
              onZoomChange: (zoomed: boolean) => this.currentZoomed = zoomed,
              onSingleTap: () => this.goBack(),
            })
          }, (source: string, index: number) => source + String(index))
        }
        .width('100%')
        .height('100%')
        .index(this.currentIndex)
        .indicator(false)
        .loop(false)
        .cachedCount(1)
        .disableSwipe(this.currentZoomed)
        .onChange((index: number) => {
          this.currentIndex = index;
          this.currentZoomed = false;
          this.originalSizeText = this.sizeCache.get(index) ?? '';
          this.fetchOriginalSize(index);
        })
      }

      // 顶部只放返回键，页码固定在底部，不再悬在图片正中央。
      Column() {
        Row() {
          BackButton({ triggerWidth: 44, triggerHeight: 44, fontSize: 34, color: '#FFFFFF', nudgeY: 0,
            onBack: () => this.goBack() })
          Blank()
        }
        .width('100%')
        .padding({ left: 8, right: 12 })
        .margin({ top: Immersive.statusBarHeight() + 4 })
        Blank()
        if (!this.isOriginal(this.currentIndex) && !this.lowResFlags[this.currentIndex]) {
          Text(this.originalSizeText.length > 0 ? '查看原图 (' + this.originalSizeText + ')' : '查看原图')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundColor('#73000000')
            .margin({ bottom: 12 })
            .onClick(() => this.viewOriginal())
        }
        if (this.param.images.length > 1) {
          Text((this.currentIndex + 1) + ' / ' + this.param.images.length)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor('#73000000')
            .margin({ bottom: Immersive.bottomInset() + 16 })
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      .hitTestBehavior(HitTestMode.Transparent)

      if (this.actionMenuOpen) {
        this.ImageActionMenu()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000000')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
