import { BiliApi, DanmakuItem, HotPoint, VideoChapter } from '../../api/BiliApi';
import { DM_SEGMENT_SECONDS } from './PlayerDanmakuSupport';

export interface PlayerAuxiliarySource {
  aid: number;
  bvid: string;
  cid: number;
}

export interface PlayerAuxiliaryHost {
  isDestroyed: () => boolean;
  duration: () => number;
  danmaku: (items: Array<DanmakuItem>, replace: boolean) => void;
  heatPoints: (items: Array<HotPoint>) => void;
  chapters: (items: Array<VideoChapter>) => void;
  online: (value: string) => void;
}

/** One source owns its auxiliary requests and segment locks, including an A → B → A switch. */
export class PlayerAuxiliaryController {
  private host: PlayerAuxiliaryHost;
  private source: PlayerAuxiliarySource = { aid: 0, bvid: '', cid: 0 };
  private generation: number = 0;
  private active: boolean = false;
  private initialized: boolean = false;
  private fallback: boolean = false;
  private loaded: Set<number> = new Set<number>();
  private loading: Set<number> = new Set<number>();
  private heatRequest: number = 0;
  private chapterRequest: number = 0;
  private onlineRequest: number = 0;

  constructor(host: PlayerAuxiliaryHost) {
    this.host = host;
  }

  bind(source: PlayerAuxiliarySource): void {
    if (this.active && source.aid === this.source.aid && source.bvid === this.source.bvid &&
      source.cid === this.source.cid) return;
    this.invalidate();
    this.source = { aid: source.aid, bvid: source.bvid, cid: source.cid };
    this.active = true;
  }

  invalidate(): void {
    ++this.generation;
    this.active = false;
    this.initialized = false;
    this.fallback = false;
    this.loaded.clear();
    this.loading.clear();
  }

  async loadDanmaku(): Promise<void> {
    if (!this.active || this.source.cid <= 0 || this.initialized || this.loading.has(0)) return;
    const generation: number = this.generation;
    const source: PlayerAuxiliarySource = this.source;
    this.loading.add(0);
    try {
      const first: Array<DanmakuItem> | null = await BiliApi.getDanmakuSeg(source.cid, source.aid, 1);
      if (!this.current(generation)) return;
      if (first === null) {
        const items: Array<DanmakuItem> = await BiliApi.getDanmaku(source.cid);
        if (!this.current(generation)) return;
        this.fallback = true;
        this.initialized = true;
        this.host.danmaku(items.slice().sort((a: DanmakuItem, b: DanmakuItem): number => a.time - b.time), true);
      } else {
        this.initialized = true;
        this.loaded.add(0);
        this.host.danmaku(first, true);
        // Unknown duration still allows the second segment; empty is a valid loaded segment.
        this.ensureSegment(1);
      }
    } catch (_) {
      // The same source may retry after an initial request failure.
    } finally {
      if (this.current(generation)) this.loading.delete(0);
    }
  }

  prefetch(now: number): void {
    if (!this.active || !this.initialized || this.fallback || !Number.isFinite(now) || now < 0) return;
    const index: number = Math.floor(now / DM_SEGMENT_SECONDS);
    this.ensureSegment(index);
    if (now + 30 >= (index + 1) * DM_SEGMENT_SECONDS) this.ensureSegment(index + 1);
  }

  async loadHeatPoints(): Promise<void> {
    const source: PlayerAuxiliarySource = this.source;
    const generation: number = this.generation;
    const request: number = ++this.heatRequest;
    if (!this.current(generation)) return;
    try {
      const items: Array<HotPoint> = await BiliApi.getVideoHeatPoints(source.aid, source.bvid, source.cid);
      if (this.current(generation) && request === this.heatRequest) this.host.heatPoints(items);
    } catch (_) {}
  }

  async loadChapters(): Promise<void> {
    const source: PlayerAuxiliarySource = this.source;
    const generation: number = this.generation;
    const request: number = ++this.chapterRequest;
    if (!this.current(generation)) return;
    try {
      const items: Array<VideoChapter> = await BiliApi.getVideoChapters(source.aid, source.bvid, source.cid);
      if (this.current(generation) && request === this.chapterRequest) this.host.chapters(items);
    } catch (_) {}
  }

  async loadOnline(): Promise<void> {
    const source: PlayerAuxiliarySource = this.source;
    const generation: number = this.generation;
    const request: number = ++this.onlineRequest;
    if (!this.current(generation)) return;
    try {
      const value: string = await BiliApi.getOnlineTotal(source.aid, source.bvid, source.cid);
      if (this.current(generation) && request === this.onlineRequest) this.host.online(value);
    } catch (_) {
      if (this.current(generation) && request === this.onlineRequest) this.host.online('');
    }
  }

  private current(generation: number): boolean {
    return this.active && generation === this.generation && !this.host.isDestroyed();
  }

  private ensureSegment(index: number): void {
    if (!this.active || this.fallback || this.source.cid <= 0 || index < 0) return;
    const duration: number = this.host.duration();
    if (duration > 0 && index >= Math.ceil(duration / DM_SEGMENT_SECONDS)) return;
    if (this.loaded.has(index) || this.loading.has(index)) return;
    const source: PlayerAuxiliarySource = this.source;
    const generation: number = this.generation;
    this.loading.add(index);
    BiliApi.getDanmakuSeg(source.cid, source.aid, index + 1).then((items: Array<DanmakuItem> | null): void => {
      if (!this.current(generation) || items === null) return;
      this.loaded.add(index);
      this.host.danmaku(items, false);
    }).catch(() => {}).finally((): void => {
      // A stale completion must not unlock a replacement request for the same segment.
      if (this.current(generation)) this.loading.delete(index);
    });
  }
}
