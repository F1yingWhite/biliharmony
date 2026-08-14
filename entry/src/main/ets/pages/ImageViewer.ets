import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { promptAction } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { ImageViewerParam } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { BackButton } from '../components/BackButton';

@Component
struct ZoomableImage {
  @Prop source: string = '';
  onLongPress: () => void = () => {};
  onZoomChange: (zoomed: boolean) => void = () => {};
  @State scaleValue: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private pinchBase: number = 1;
  private panBaseX: number = 0;
  private panBaseY: number = 0;

  private clampScale(value: number): number {
    return Math.max(1, Math.min(5, value));
  }

  private resetTransform(animated: boolean): void {
    const update = (): void => {
      this.scaleValue = 1;
      this.offsetX = 0;
      this.offsetY = 0;
    };
    if (animated) animateTo({ duration: 180, curve: Curve.EaseOut }, update);
    else update();
    this.onZoomChange(false);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image(this.source)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .scale({ x: this.scaleValue, y: this.scaleValue })
        .translate({ x: this.offsetX, y: this.offsetY })
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.pinchBase = this.scaleValue;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.scaleValue = this.clampScale(this.pinchBase * event.scale);
                this.onZoomChange(this.scaleValue > 1.05);
                if (this.scaleValue <= 1.01) this.resetTransform(false);
              })
              .onActionEnd(() => {
                if (this.scaleValue < 1.05) this.resetTransform(true);
              }),
            // 原始尺寸下不要截获横滑，交由外层 Swiper 切换图片。
            PanGesture({ fingers: 1, direction: this.scaleValue > 1.05 ? PanDirection.All : PanDirection.None })
              .onActionStart(() => {
                this.panBaseX = this.offsetX;
                this.panBaseY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (this.scaleValue <= 1) return;
                const limitX: number = 180 * (this.scaleValue - 1);
                const limitY: number = 320 * (this.scaleValue - 1);
                this.offsetX = Math.max(-limitX, Math.min(limitX, this.panBaseX + event.offsetX));
                this.offsetY = Math.max(-limitY, Math.min(limitY, this.panBaseY + event.offsetY));
              }),
            TapGesture({ count: 2 })
              .onAction(() => {
                if (this.scaleValue > 1.05) this.resetTransform(true);
                else {
                  animateTo({ duration: 180, curve: Curve.EaseOut }, () => this.scaleValue = 2.5);
                  this.onZoomChange(true);
                }
              }),
            LongPressGesture({ fingers: 1, repeat: false, duration: 500 })
              .onAction(() => this.onLongPress())
          )
        )
    }
    .width('100%')
    .height('100%')
    .clip(true)
  }
}

@Component
export struct ImageViewerPage {
  param: ImageViewerParam = { images: [], initialIndex: 0 };
  @State currentIndex: number = 0;
  @State saving: boolean = false;
  @State actionMenuOpen: boolean = false;
  @State currentZoomed: boolean = false;

  aboutToAppear(): void {
    this.currentIndex = Math.max(0, Math.min(this.param.images.length - 1, this.param.initialIndex));
    Immersive.setBarIcons(true, true);
  }

  private currentUrl(): string {
    return this.param.images.length > 0 ? this.param.images[this.currentIndex] : '';
  }

  /** 非当前页用缩略参数图（B 站 @<宽>w 后缀），滑到该页时再加载原图。 */
  private thumbUrl(url: string): string {
    const clean: string = url.split('?')[0];
    if (clean.indexOf('hdslb.com') < 0) {
      return url;
    }
    return clean + '@640w.webp';
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
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
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
      promptAction.showToast({ message: '已保存到图库' });
    } catch (e) {
      promptAction.showToast({ message: '保存失败，请稍后重试' });
    } finally {
      request.destroy();
      this.saving = false;
    }
  }

  private shareCurrentImage(): void {
    const url: string = this.currentUrl();
    if (url.length === 0) return;
    this.actionMenuOpen = false;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: 'general.hyperlink',
      title: '分享图片',
      content: url,
      description: '来自哔哩哔哩的图片',
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL }).catch(() => {
      promptAction.showToast({ message: '无法打开系统分享' });
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
        Text('图片操作')
          .fontSize(13)
          .fontColor('#9499A0')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 6, bottom: 2 })
        SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE,
          buttonType: ButtonType.Normal })
          .width('100%')
          .height(48)
          .fontSize(16)
          .borderRadius(12)
          .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
            this.actionMenuOpen = false;
            if (result === SaveButtonOnClickResult.SUCCESS) this.saveCurrentImage();
          })
        Button('分享图片')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontColor('#18191C')
          .backgroundColor('#F4F5F7')
          .borderRadius(12)
          .onClick(() => this.shareCurrentImage())
        Button('取消')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontColor('#61666D')
          .backgroundColor('#F4F5F7')
          .borderRadius(12)
          .onClick(() => this.actionMenuOpen = false)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: Immersive.bottomInset() + 12 })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.param.images.length > 0) {
        Swiper() {
          ForEach(this.param.images, (source: string, index: number) => {
            ZoomableImage({
              source: index === this.currentIndex ? source : this.thumbUrl(source),
              onLongPress: () => this.actionMenuOpen = true,
              onZoomChange: (zoomed: boolean) => this.currentZoomed = zoomed,
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
        })
      }

      // 顶部只放返回键，页码固定在底部，不再悬在图片正中央。
      Column() {
        Row() {
          BackButton({ triggerWidth: 44, triggerHeight: 44, fontSize: 34, color: '#FFFFFF', nudgeY: 0 })
          Blank()
        }
        .width('100%')
        .padding({ left: 8, right: 12 })
        .margin({ top: Immersive.statusBarHeight() + 4 })
        Blank()
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
    .backgroundColor('#000000')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
