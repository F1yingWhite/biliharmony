/** 直播表情静态图：远程 GIF/WebP 只解码首帧，组件销毁时释放像素内存。 */
import { image } from '@kit.ImageKit';
import { HttpClient } from '../../common/HttpClient';
import { Constants } from '../../common/Constants';

@Component
export struct StaticLiveImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop imageWidth: number = 24;
  @Prop imageHeight: number = 24;
  @Prop fit: ImageFit = ImageFit.Contain;
  @State frame: image.PixelMap | null = null;
  private generation: number = 0;
  private visible: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.loadFrame();
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    this.releaseFrame();
  }

  private onUrlChanged(): void {
    this.generation++;
    this.releaseFrame();
    if (this.visible) this.loadFrame();
  }

  private releaseFrame(): void {
    const previous: image.PixelMap | null = this.frame;
    this.frame = null;
    if (previous !== null) {
      try { previous.release(); } catch (e) {}
    }
  }

  private loadFrame(): void {
    const url: string = this.url;
    if (url.length === 0) return;
    const generation: number = ++this.generation;
    this.decodeFirstFrame(url).then((pixelMap: image.PixelMap | null): void => {
      if (!this.visible || generation !== this.generation || url !== this.url) {
        if (pixelMap !== null) {
          try { pixelMap.release(); } catch (e) {}
        }
        return;
      }
      this.frame = pixelMap;
    }).catch((): void => {});
  }

  private async decodeFirstFrame(url: string): Promise<image.PixelMap | null> {
    let source: image.ImageSource | null = null;
    try {
      const bytes: ArrayBuffer = await HttpClient.getBytes(url, {
        'User-Agent': Constants.browserUa,
        'Referer': 'https://live.bilibili.com/',
      });
      if (bytes.byteLength === 0) return null;
      source = image.createImageSource(bytes);
      const width: number = Math.max(24, Math.round(this.imageWidth * 2));
      const height: number = Math.max(24, Math.round(this.imageHeight * 2));
      return await source.createPixelMap({ index: 0, desiredSize: { width: width, height: height } });
    } catch (e) {
      return null;
    } finally {
      if (source !== null) {
        try { source.release(); } catch (e) {}
      }
    }
  }

  build() {
    Stack() {
      if (this.frame !== null) {
        Image(this.frame)
          .width('100%')
          .height('100%')
          .objectFit(this.fit)
      }
    }
    .width(this.imageWidth)
    .height(this.imageHeight)
  }
}
