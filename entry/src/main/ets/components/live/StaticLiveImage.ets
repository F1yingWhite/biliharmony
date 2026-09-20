/**
 * 直播表情静态图：远程 GIF/WebP 只解码首帧，组件销毁时释放像素内存。
 * 表情 URL 在聊天流里高频重复（同一表情可同时出现几十条），按 URL 做
 * 引用计数 LRU 缓存 + 单飞下载：热门表情只下载/解码一次，纯展示方不再各自持有一份。
 */
import { image } from '@kit.ImageKit';
import { HttpClient } from '../../services/network/HttpClient';
import { Constants } from '../../common/Constants';

/** 解码边长：覆盖组件最大渲染尺寸（42vp × 2 倍密度 ≈ 84px）。 */
const FRAME_DECODE_SIZE: number = 96;
const FRAME_CACHE_MAX: number = 96;

/**
 * URL → PixelMap 缓存。引用计数 > 0 的帧不会被淘汰（仍在渲染）；
 * 引用归零后按 LRU 上限回收。PixelMap 所有权归缓存，组件只在渲染期间引用。
 */
class LiveEmoteFrameCache {
  private frames: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private refs: Map<string, number> = new Map<string, number>();
  /** LRU 顺序：越靠后越新。 */
  private order: Array<string> = [];
  private pending: Map<string, Promise<image.PixelMap | null>> = new Map<string, Promise<image.PixelMap | null>>();

  acquire(url: string): void {
    if (url.length === 0) return;
    this.refs.set(url, (this.refs.get(url) ?? 0) + 1);
    this.touch(url);
  }

  release(url: string): void {
    if (url.length === 0) return;
    const count: number = this.refs.get(url) ?? 0;
    if (count <= 1) {
      this.refs.delete(url);
    } else {
      this.refs.set(url, count - 1);
    }
    this.evict();
  }

  get(url: string): image.PixelMap | null {
    const hit: image.PixelMap | undefined = this.frames.get(url);
    if (hit !== undefined) this.touch(url);
    return hit ?? null;
  }

  /** 单飞加载：缓存命中直接返回；同一 URL 的并发请求共享同一次下载/解码。 */
  load(url: string): Promise<image.PixelMap | null> {
    const cached: image.PixelMap | undefined = this.frames.get(url);
    if (cached !== undefined) {
      this.touch(url);
      return Promise.resolve(cached);
    }
    const inflight: Promise<image.PixelMap | null> | undefined = this.pending.get(url);
    if (inflight !== undefined) return inflight;
    const task: Promise<image.PixelMap | null> = this.download(url).then((pixelMap: image.PixelMap | null) => {
      this.pending.delete(url);
      if (pixelMap !== null) this.store(url, pixelMap);
      return pixelMap;
    }).catch((): null => {
      this.pending.delete(url);
      return null;
    });
    this.pending.set(url, task);
    return task;
  }

  private async download(url: string): Promise<image.PixelMap | null> {
    let source: image.ImageSource | null = null;
    try {
      const bytes: ArrayBuffer = await HttpClient.getBytes(url, {
        'User-Agent': Constants.browserUa,
        'Referer': 'https://live.bilibili.com/',
      });
      if (bytes.byteLength === 0) return null;
      source = image.createImageSource(bytes);
      return await source.createPixelMap({
        index: 0,
        desiredSize: { width: FRAME_DECODE_SIZE, height: FRAME_DECODE_SIZE },
      });
    } catch (e) {
      return null;
    } finally {
      if (source !== null) {
        try { source.release(); } catch (e) {}
      }
    }
  }

  private store(url: string, pixelMap: image.PixelMap): void {
    if (this.frames.has(url)) {
      // 并发完成后已有同名帧（理论上不会发生，单飞保证），释放多余份。
      try { pixelMap.release(); } catch (e) {}
      return;
    }
    this.frames.set(url, pixelMap);
    this.order.push(url);
    this.evict();
  }

  private touch(url: string): void {
    const index: number = this.order.indexOf(url);
    if (index >= 0) {
      this.order.splice(index, 1);
      this.order.push(url);
    }
  }

  private evict(): void {
    if (this.frames.size <= FRAME_CACHE_MAX) return;
    for (let i: number = 0; i < this.order.length && this.frames.size > FRAME_CACHE_MAX;) {
      const key: string = this.order[i];
      if ((this.refs.get(key) ?? 0) > 0) {
        i++; // 仍在渲染的帧不可回收，跳过找下一个冷帧。
        continue;
      }
      this.order.splice(i, 1);
      const pixelMap: image.PixelMap | undefined = this.frames.get(key);
      this.frames.delete(key);
      if (pixelMap !== undefined) {
        try { pixelMap.release(); } catch (e) {}
      }
    }
  }
}

const liveEmoteFrames: LiveEmoteFrameCache = new LiveEmoteFrameCache();

@Component
export struct StaticLiveImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop imageWidth: number = 24;
  @Prop imageHeight: number = 24;
  @Prop fit: ImageFit = ImageFit.Contain;
  @State frame: image.PixelMap | null = null;
  private generation: number = 0;
  private visible: boolean = false;
  /** 已 acquire 的 URL：url 变化/销毁时按它 release，保持引用计数配对。 */
  private attachedUrl: string = '';

  aboutToAppear(): void {
    this.visible = true;
    this.attach(this.url);
    this.loadFrame();
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    this.detach();
    // 帧所有权在缓存，置空即可；缓存负责在安全时机 release。
    this.frame = null;
  }

  private onUrlChanged(): void {
    this.generation++;
    this.frame = null;
    this.detach();
    this.attach(this.url);
    this.loadFrame();
  }

  private attach(url: string): void {
    this.attachedUrl = url;
    liveEmoteFrames.acquire(url);
  }

  private detach(): void {
    liveEmoteFrames.release(this.attachedUrl);
    this.attachedUrl = '';
  }

  private loadFrame(): void {
    const url: string = this.url;
    if (url.length === 0) return;
    const cached: image.PixelMap | null = liveEmoteFrames.get(url);
    if (cached !== null) {
      this.frame = cached;
      return;
    }
    const generation: number = ++this.generation;
    liveEmoteFrames.load(url).then((pixelMap: image.PixelMap | null): void => {
      if (!this.visible || generation !== this.generation || url !== this.url) return;
      this.frame = pixelMap;
    }).catch((): void => {});
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
