import { RemoteAssetCache } from '../../services/cache/RemoteAssetCache';

/** Only the visible list window and two neighbouring rows may enter the download queue. */
export class YouTubeSavedThumbnails {
  private static readonly PREFETCH_ROWS: number = 2;
  private static readonly MAX_PENDING: number = 3;
  private active: boolean = false;
  private generation: number = 0;
  private urls: Array<string> = [];
  private allowed: Set<string> = new Set<string>();
  private wanted: Array<string> = [];
  private local: Map<string, string> = new Map<string, string>();
  private pending: Set<string> = new Set<string>();
  private failed: Set<string> = new Set<string>();
  private publishTimer: number = -1;
  private readonly publish: (local: Map<string, string>) => void;

  constructor(publish: (local: Map<string, string>) => void) { this.publish = publish; }

  activate(): void {
    this.deactivate();
    this.active = true;
    this.urls = [];
    this.allowed.clear();
    this.local.clear();
  }

  deactivate(): void {
    this.active = false;
    ++this.generation;
    this.pending.clear();
    this.failed.clear();
    this.wanted = [];
    if (this.publishTimer >= 0) clearTimeout(this.publishTimer);
    this.publishTimer = -1;
  }

  setItems(urls: Array<string>): void {
    const unpublished: boolean = this.publishTimer >= 0;
    if (unpublished) clearTimeout(this.publishTimer);
    this.publishTimer = -1;
    ++this.generation;
    this.urls = urls.slice();
    this.allowed = new Set<string>(urls);
    this.pending.clear();
    this.failed.clear();
    this.wanted = [];
    const retained: Map<string, string> = new Map<string, string>();
    this.local.forEach((local: string, url: string) => {
      if (this.allowed.has(url)) retained.set(url, local);
    });
    if (retained.size !== this.local.size || unpublished) {
      this.local = retained;
      this.schedulePublish();
    }
  }

  primeVisible(first: number, last: number): void {
    if (!this.active || this.urls.length === 0 || !Number.isFinite(first) || !Number.isFinite(last)) return;
    const start: number = Math.max(0, Math.floor(first) - YouTubeSavedThumbnails.PREFETCH_ROWS);
    const end: number = Math.min(this.urls.length - 1, Math.floor(last) + YouTubeSavedThumbnails.PREFETCH_ROWS);
    const wanted: Array<string> = [];
    const seen: Set<string> = new Set<string>();
    for (let index: number = start; index <= end; index++) {
      const url: string = this.urls[index];
      if (!url.startsWith('http') || seen.has(url)) continue;
      seen.add(url);
      wanted.push(url);
    }
    if (wanted.join('\n') !== this.wanted.join('\n')) this.failed.clear();
    this.wanted = wanted;
    this.pump();
  }

  private pump(): void {
    if (!this.active) return;
    const generation: number = this.generation;
    for (const url of this.wanted) {
      if (this.local.has(url) || this.pending.has(url) || this.failed.has(url)) continue;
      const cached: string = RemoteAssetCache.cachedThumbnail(url);
      if (cached.length > 0 && cached !== url) {
        this.local.set(url, cached);
        this.schedulePublish();
        continue;
      }
      if (this.pending.size >= YouTubeSavedThumbnails.MAX_PENDING) continue;
      this.pending.add(url);
      RemoteAssetCache.ensureThumbnail(url).then((local: string): void => {
        if (!this.active || generation !== this.generation || !this.allowed.has(url)) return;
        if (local.length === 0 || local === url) {
          this.failed.add(url);
          return;
        }
        this.local.set(url, local);
        this.schedulePublish();
      }).catch(() => {
        if (generation === this.generation) this.failed.add(url);
      }).finally(() => {
        if (!this.active || generation !== this.generation) return;
        this.pending.delete(url);
        this.pump();
      });
    }
  }

  /** Several cache hits/completions publish one immutable UI snapshot in the next frame. */
  private schedulePublish(): void {
    if (!this.active || this.publishTimer >= 0) return;
    const generation: number = this.generation;
    this.publishTimer = setTimeout(() => {
      this.publishTimer = -1;
      if (this.active && generation === this.generation) this.publish(new Map<string, string>(this.local));
    }, 16);
  }
}
