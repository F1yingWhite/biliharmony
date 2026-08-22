import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { BiliApi, VideoShotData } from '../../api/BiliApi';

export class PlayerSeekPreviewController {
  private shots: VideoShotData | null = null;
  private shotsLoading: boolean = false;
  private extractor: media.AVMetadataExtractor | null = null;
  private extractorSource: string = '';
  private timer: number = -1;
  private pendingTime: number = -1;
  private fetching: boolean = false;
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
    if (cid <= 0 || this.shotsLoading || this.shots !== null) return;
    this.aid = aid;
    this.bvid = bvid;
    this.cid = cid;
    this.loadShots(this.generation, aid, bvid, cid).catch(() => {});
  }

  request(seconds: number, aid: number, bvid: string, cid: number, source: string,
    headers: Record<string, string>,
    onSprite: (url: string, cell: number, xLen: number, yLen: number) => void,
    onFrame: (frame: image.PixelMap | null) => void): void {
    if (seconds < 0) return;
    this.pendingTime = seconds;
    this.aid = aid;
    this.bvid = bvid;
    this.cid = cid;
    this.source = source;
    this.headers = headers;
    this.onSprite = onSprite;
    this.onFrame = onFrame;
    if (this.updateShot(seconds)) return;
    if (!this.shotsLoading && this.shots === null && cid > 0) {
      this.loadShots(this.generation, aid, bvid, cid).catch(() => {});
    }
    if (this.timer >= 0 || this.fetching) return;
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
    this.generation++;
    this.close();
    this.shots = null;
    this.shotsLoading = false;
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
      if (generation !== this.generation || aid !== this.aid || bvid !== this.bvid || cid !== this.cid) return;
      this.shots = shots;
      if (shots !== null && this.pendingTime >= 0) this.updateShot(this.pendingTime);
    } catch (e) {
      // 分镜图是增强能力，失败时由本地抽帧兜底。
    } finally {
      if (generation === this.generation && aid === this.aid && bvid === this.bvid && cid === this.cid) {
        this.shotsLoading = false;
      }
    }
  }

  private updateShot(seconds: number): boolean {
    const shots: VideoShotData | null = this.shots;
    if (shots === null || shots.index.length === 0 || shots.images.length === 0) return false;
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
    if (this.fetching || this.pendingTime < 0) return;
    const target: number = this.pendingTime;
    const generation: number = this.generation;
    this.fetching = true;
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
      if (generation !== this.generation || this.pendingTime < 0) {
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
      this.fetching = false;
      if (generation === this.generation && this.pendingTime >= 0 &&
        Math.abs(this.pendingTime - target) > 0.25) {
        this.request(this.pendingTime, this.aid, this.bvid, this.cid, this.source, this.headers,
          this.onSprite, this.onFrame);
      }
    }
  }

  private async ensureExtractor(generation: number): Promise<media.AVMetadataExtractor | null> {
    if (this.source.length === 0) return null;
    if (this.extractor !== null && this.extractorSource === this.source) return this.extractor;
    const oldExtractor: media.AVMetadataExtractor | null = this.extractor;
    this.extractor = null;
    this.extractorSource = '';
    if (oldExtractor !== null) {
      try {
        await oldExtractor.release();
      } catch (e) {
      }
    }
    const extractor: media.AVMetadataExtractor = await media.createAVMetadataExtractor();
    if (generation !== this.generation || this.pendingTime < 0) {
      extractor.release().catch(() => {});
      return null;
    }
    extractor.setUrlSource(this.source, this.headers);
    this.extractor = extractor;
    this.extractorSource = this.source;
    return extractor;
  }
}
