import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { BiliApi, VideoShotData } from '../../api/BiliApi';
import { HttpClient } from '../../services/network/HttpClient';

export class PlayerSeekPreviewController {
  private shots: VideoShotData | null = null;
  private shotsLoading: boolean = false;
  private extractor: media.AVMetadataExtractor | null = null;
  private extractorSource: string = '';
  private timer: number = -1;
  private pendingTime: number = -1;
  private fetchingGeneration: number = -1;
  private generation: number = 0;
  private frame: image.PixelMap | null = null;
  private aid: number = 0;
  private bvid: string = '';
  private cid: number = 0;
  private source: string = '';
  private headers: Record<string, string> = {};
  private onSprite: (url: string, cell: number, xLen: number, yLen: number) => void = () => {};
  private onFrame: (frame: image.PixelMap | null) => void = () => {};

  preload(aid: number, bvid: string, cid: number): void {
    this.adoptIdentity(aid, bvid, cid);
    if (cid <= 0 || this.shotsLoading || this.shots !== null) return;
    this.loadShots(this.generation, aid, bvid, cid).catch(() => {});
  }

  request(seconds: number, aid: number, bvid: string, cid: number, source: string,
    headers: Record<string, string>,
    onSprite: (url: string, cell: number, xLen: number, yLen: number) => void,
    onFrame: (frame: image.PixelMap | null) => void): void {
    if (!Number.isFinite(seconds) || seconds < 0) return;
    this.adoptIdentity(aid, bvid, cid);
    // 同一视频切 CDN/画质时废弃旧抽帧器，已取得的分镜仍属于当前视频，可以复用。
    if (this.source.length > 0 && this.source !== source) this.reset(true);
    this.pendingTime = seconds;
    this.source = source;
    this.headers = this.copyHeaders(headers);
    this.onSprite = onSprite;
    this.onFrame = onFrame;
    if (this.updateShot(seconds)) return;
    if (!this.shotsLoading && this.shots === null && cid > 0) {
      this.loadShots(this.generation, aid, bvid, cid).catch(() => {});
    }
    if (this.timer >= 0 || this.fetchingGeneration === this.generation) return;
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.fetchFrame().catch(() => {});
    }, 180);
  }

  close(): void {
    this.pendingTime = -1;
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  release(): void {
    this.reset(false);
    this.aid = 0;
    this.bvid = '';
    this.cid = 0;
  }

  private adoptIdentity(aid: number, bvid: string, cid: number): void {
    if (aid !== this.aid || bvid !== this.bvid || cid !== this.cid) this.release();
    this.aid = aid;
    this.bvid = bvid;
    this.cid = cid;
  }

  private matches(generation: number, aid: number, bvid: string, cid: number): boolean {
    return generation === this.generation && aid === this.aid && bvid === this.bvid && cid === this.cid;
  }

  private copyHeaders(headers: Record<string, string>): Record<string, string> {
    const copied: Record<string, string> = {};
    Object.keys(headers).forEach((key: string): void => { copied[key] = headers[key]; });
    return copied;
  }

  private reset(keepShots: boolean): void {
    this.generation++;
    this.close();
    if (!keepShots) this.shots = null;
    this.shotsLoading = false;
    this.fetchingGeneration = -1;
    this.source = '';
    this.headers = {};
    this.onSprite('', -1, 10, 10);
    const frame: image.PixelMap | null = this.frame;
    this.frame = null;
    this.onFrame(null);
    if (frame !== null) frame.release().catch(() => {});
    const extractor: media.AVMetadataExtractor | null = this.extractor;
    this.extractor = null;
    this.extractorSource = '';
    if (extractor !== null) extractor.release().catch(() => {});
  }

  private async loadShots(generation: number, aid: number, bvid: string, cid: number): Promise<void> {
    this.shotsLoading = true;
    try {
      const shots: VideoShotData | null = await BiliApi.getVideoShots(aid, bvid, cid);
      if (!this.matches(generation, aid, bvid, cid)) return;
      this.shots = shots;
      if (shots !== null && this.pendingTime >= 0) this.updateShot(this.pendingTime);
    } catch (e) {
      // 分镜图是增强能力，失败时由本地抽帧兜底。
    } finally {
      if (this.matches(generation, aid, bvid, cid)) {
        this.shotsLoading = false;
      }
    }
  }

  /**
   * 截图：取当前播放时刻最近的雪碧图帧并裁剪为独立 PixelMap。
   * 优先复用预加载的 VideoShotData；未加载时现取一次。失败返回 null。
   */
  async captureAt(seconds: number): Promise<image.PixelMap | null> {
    if (!Number.isFinite(seconds) || seconds < 0 || this.cid <= 0) return null;
    const generation: number = this.generation;
    const aid: number = this.aid;
    const bvid: string = this.bvid;
    const cid: number = this.cid;
    let shots: VideoShotData | null = this.shots;
    if (shots === null) {
      try {
        shots = await BiliApi.getVideoShots(aid, bvid, cid);
        if (!this.matches(generation, aid, bvid, cid)) return null;
        this.shots = shots;
      } catch (e) {
        return null;
      }
    }
    if (shots === null || !this.validShots(shots)) return null;
    let left: number = 0;
    let right: number = shots.index.length - 1;
    while (left < right) {
      const middle: number = Math.ceil((left + right) / 2);
      if (shots.index[middle] <= seconds) left = middle;
      else right = middle - 1;
    }
    const cellsPerImage: number = shots.xLen * shots.yLen;
    const imageIndex: number = Math.min(shots.images.length - 1, Math.floor(left / cellsPerImage));
    const cellIndex: number = left % cellsPerImage;
    let source: image.ImageSource | null = null;
    let sprite: image.PixelMap | null = null;
    try {
      const bytes: ArrayBuffer = await HttpClient.getBytes(shots.images[imageIndex]);
      if (!this.matches(generation, aid, bvid, cid)) return null;
      source = image.createImageSource(bytes);
      sprite = await source.createPixelMap();
      if (!this.matches(generation, aid, bvid, cid)) return null;
      const info: image.ImageInfo = await sprite.getImageInfo();
      if (!this.matches(generation, aid, bvid, cid)) return null;
      const cellW: number = Math.floor(info.size.width / shots.xLen);
      const cellH: number = Math.floor(info.size.height / shots.yLen);
      if (!Number.isFinite(cellW) || !Number.isFinite(cellH) || cellW <= 0 || cellH <= 0) return null;
      const col: number = cellIndex % shots.xLen;
      const row: number = Math.floor(cellIndex / shots.xLen);
      await sprite.crop({ x: col * cellW, y: row * cellH, size: { width: cellW, height: cellH } });
      // ImageSource 清理也可能异步；在转交 PixelMap 所有权前最后复查源代际。
      const ownedSource: image.ImageSource = source;
      source = null;
      await ownedSource.release();
      if (!this.matches(generation, aid, bvid, cid)) return null;
      const result: image.PixelMap = sprite;
      sprite = null;
      return result;
    } catch (e) {
      return null;
    } finally {
      if (source !== null) { try { await source.release(); } catch (e) {} }
      if (sprite !== null) { try { await sprite.release(); } catch (e) {} }
    }
  }

  private validShots(shots: VideoShotData): boolean {
    return shots.index.length > 0 && shots.images.length > 0 &&
      Number.isInteger(shots.xLen) && shots.xLen > 0 && Number.isInteger(shots.yLen) && shots.yLen > 0;
  }

  private updateShot(seconds: number): boolean {
    const shots: VideoShotData | null = this.shots;
    if (shots === null || !this.validShots(shots)) return false;
    let left: number = 0;
    let right: number = shots.index.length - 1;
    while (left < right) {
      const middle: number = Math.ceil((left + right) / 2);
      if (shots.index[middle] <= seconds) left = middle;
      else right = middle - 1;
    }
    const cellsPerImage: number = shots.xLen * shots.yLen;
    const imageIndex: number = Math.min(shots.images.length - 1, Math.floor(left / cellsPerImage));
    this.onSprite(shots.images[imageIndex], left % cellsPerImage, shots.xLen, shots.yLen);
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    return true;
  }

  private async fetchFrame(): Promise<void> {
    if (this.fetchingGeneration === this.generation || this.pendingTime < 0) return;
    const target: number = this.pendingTime;
    const generation: number = this.generation;
    this.fetchingGeneration = generation;
    try {
      const extractor: media.AVMetadataExtractor | null = await this.ensureExtractor(generation);
      if (extractor === null || generation !== this.generation || this.pendingTime < 0) return;
      const frame: image.PixelMap | undefined = await extractor.fetchFrameByTimeWithTimeout(
        Math.max(0, Math.round(target * 1000000)),
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
        { width: 320, height: 180 },
        3000,
      );
      if (frame === undefined) return;
      if (generation !== this.generation || this.pendingTime < 0 || Math.abs(this.pendingTime - target) > 0.25) {
        frame.release().catch(() => {});
        return;
      }
      const oldFrame: image.PixelMap | null = this.frame;
      this.frame = frame;
      this.onFrame(frame);
      if (oldFrame !== null && oldFrame !== frame) oldFrame.release().catch(() => {});
      if (DEBUG) hilog.info(0x0000, 'BiliPlayback', 'seekPreview.frame time=%{public}d', Math.round(target * 1000));
    } catch (e) {
      if (DEBUG) hilog.warn(0x0000, 'BiliPlayback', 'seekPreview.error %{public}s', String(e));
    } finally {
      // 旧源的 finally 不能解除新源的抽帧门闩，也不能阻止新源自行排队。
      if (this.fetchingGeneration === generation) this.fetchingGeneration = -1;
      if (generation === this.generation && this.pendingTime >= 0 &&
        Math.abs(this.pendingTime - target) > 0.25) {
        this.request(this.pendingTime, this.aid, this.bvid, this.cid, this.source, this.headers,
          this.onSprite, this.onFrame);
      }
    }
  }

  private async ensureExtractor(generation: number): Promise<media.AVMetadataExtractor | null> {
    if (generation !== this.generation || this.source.length === 0 || this.pendingTime < 0) return null;
    const source: string = this.source;
    const headers: Record<string, string> = this.copyHeaders(this.headers);
    if (this.extractor !== null && this.extractorSource === source) return this.extractor;
    const oldExtractor: media.AVMetadataExtractor | null = this.extractor;
    this.extractor = null;
    this.extractorSource = '';
    if (oldExtractor !== null) {
      try {
        await oldExtractor.release();
      } catch (e) {
      }
    }
    if (generation !== this.generation || this.pendingTime < 0) return null;
    const extractor: media.AVMetadataExtractor = await media.createAVMetadataExtractor();
    let adopted: boolean = false;
    try {
      if (generation !== this.generation || this.pendingTime < 0) return null;
      extractor.setUrlSource(source, headers);
      this.extractor = extractor;
      this.extractorSource = source;
      adopted = true;
      return extractor;
    } finally {
      if (!adopted) { try { await extractor.release(); } catch (e) {} }
    }
  }
}
