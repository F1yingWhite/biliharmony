import { RemoteAssetCache } from '../../services/cache/RemoteAssetCache';

/** UI-owned lookup backed by the app's proxy-aware image service. */
export class YouTubeThumbnailCache {
  private local: Map<string, string> = new Map<string, string>();
  private pending: Set<string> = new Set<string>();
  private generation: number = 0;
  private readonly changed: (url: string) => void;

  constructor(changed: (url: string) => void) { this.changed = changed; }

  reset(): void {
    ++this.generation;
    this.local.clear();
    this.pending.clear();
  }

  resolve(url: string): string { return this.local.get(url) ?? url; }

  snapshot(): Map<string, string> { return new Map<string, string>(this.local); }

  prime(urls: Array<string>): void {
    const generation: number = this.generation;
    for (const url of urls) {
      if (url.length === 0 || this.local.has(url) || this.pending.has(url)) continue;
      const cached: string = RemoteAssetCache.cachedThumbnail(url);
      if (cached !== url) {
        this.local.set(url, cached);
        this.changed(url);
        continue;
      }
      this.pending.add(url);
      RemoteAssetCache.ensureThumbnail(url).then((local: string): void => {
        if (generation !== this.generation || local === url || local.length === 0) return;
        this.local.set(url, local);
        this.changed(url);
      }).catch(() => {}).finally((): void => {
        if (generation === this.generation) this.pending.delete(url);
      });
    }
  }
}
