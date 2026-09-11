import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { YouTubeVideo } from '../api/YouTubeApi';

/**
 * 本地 YouTube 列表里的一条记录。
 *
 * 只保存公开元数据与视频 ID——播放仍走官方客户端/官方播放器，
 * 不涉及任何取流或媒体地址（见 docs/YOUTUBE_2026-09-11.md 的游客边界）。
 */
export class YouTubeLocalVideo {
  id: string = '';
  title: string = '';
  channel: string = '';
  thumbnail: string = '';
  duration: string = '';
  views: string = '';
  published: string = '';
  /** 保存/观看时间：列表按它倒序，最近的在最上面。 */
  at: number = 0;
}

/**
 * 本地列表存储：稍后观看与观看历史共用同一套逻辑，只是键名、上限与广播键不同。
 *
 * 恢复是异步的，而用户可能在恢复完成前就写入，因此恢复时用「内存优先 + 磁盘补缺」合并，
 * 直接覆盖会让刚写进去的条目消失。
 */
export class YouTubeLocalStore {
  private readonly storageKey: string;
  private readonly preferencesName: string;
  private readonly maxItems: number;
  private readonly countKey: string;
  private cache: Array<YouTubeLocalVideo> = [];
  private store: preferences.Preferences | null = null;
  private ready: Promise<void> | null = null;

  constructor(storageKey: string, preferencesName: string, maxItems: number, countKey: string) {
    this.storageKey = storageKey;
    this.preferencesName = preferencesName;
    this.maxItems = maxItems;
    this.countKey = countKey;
  }

  init(context: common.UIAbilityContext): void {
    this.ready = this.restore(context);
  }

  private async restore(context: common.UIAbilityContext): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context,
        { name: this.preferencesName });
      this.store = store;
      const raw: string = store.getSync(this.storageKey, '') as string;
      this.cache = this.merge(this.cache, this.parse(raw));
      this.broadcast();
    } catch (e) {
      // 读不到就按空列表处理：本地列表不可用不该影响其它功能。
    }
  }

  async ensureLoaded(): Promise<Array<YouTubeLocalVideo>> {
    if (this.ready !== null) await this.ready;
    return this.list();
  }

  list(): Array<YouTubeLocalVideo> {
    return this.cache.slice(0, this.maxItems);
  }

  count(): number {
    return this.cache.length;
  }

  contains(id: string): boolean {
    if (id.length === 0) return false;
    for (const item of this.cache) {
      if (item.id === id) return true;
    }
    return false;
  }

  /** 写入或刷新一条（重复 id 提到最前并更新元数据）。 */
  add(video: YouTubeVideo): Array<YouTubeLocalVideo> {
    if (video.id.length === 0) return this.list();
    const item: YouTubeLocalVideo = new YouTubeLocalVideo();
    item.id = video.id;
    item.title = video.title;
    item.channel = video.channel;
    item.thumbnail = video.thumbnail;
    item.duration = video.duration;
    item.views = video.views;
    item.published = video.published;
    item.at = Date.now();
    const next: Array<YouTubeLocalVideo> = [item];
    for (const old of this.cache) {
      if (old.id !== item.id && next.length < this.maxItems) next.push(old);
    }
    this.save(next);
    return this.list();
  }

  remove(id: string): Array<YouTubeLocalVideo> {
    const next: Array<YouTubeLocalVideo> = [];
    for (const item of this.cache) {
      if (item.id !== id) next.push(item);
    }
    this.save(next);
    return this.list();
  }

  clear(): void {
    this.save([]);
  }

  private broadcast(): void {
    AppStorage.setOrCreate<number>(this.countKey, this.cache.length);
  }

  private save(items: Array<YouTubeLocalVideo>): void {
    this.cache = items.slice(0, this.maxItems);
    this.broadcast();
    this.persist(JSON.stringify(this.cache));
  }

  private async persist(raw: string): Promise<void> {
    if (this.ready !== null) await this.ready;
    if (this.store === null) return;
    this.store.putSync(this.storageKey, raw);
    await this.store.flush();
  }

  /** 内存优先、磁盘补缺；按时间倒序，最多 maxItems 条。 */
  private merge(memory: Array<YouTubeLocalVideo>, disk: Array<YouTubeLocalVideo>): Array<YouTubeLocalVideo> {
    const seen: Set<string> = new Set<string>();
    const merged: Array<YouTubeLocalVideo> = [];
    for (const item of memory) {
      if (seen.has(item.id)) continue;
      seen.add(item.id);
      merged.push(item);
    }
    for (const item of disk) {
      if (seen.has(item.id)) continue;
      seen.add(item.id);
      merged.push(item);
    }
    merged.sort((a: YouTubeLocalVideo, b: YouTubeLocalVideo) => b.at - a.at);
    return merged.slice(0, this.maxItems);
  }

  private parse(raw: string): Array<YouTubeLocalVideo> {
    if (raw.length === 0) return [];
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) return [];
      const out: Array<YouTubeLocalVideo> = [];
      for (const entry of parsed as Array<Object>) {
        const record: Record<string, Object> = (entry ?? {}) as Record<string, Object>;
        const id: string = typeof record['id'] === 'string' ? record['id'] as string : '';
        if (id.length === 0) continue;
        const item: YouTubeLocalVideo = new YouTubeLocalVideo();
        item.id = id;
        item.title = typeof record['title'] === 'string' ? record['title'] as string : '';
        item.channel = typeof record['channel'] === 'string' ? record['channel'] as string : '';
        item.thumbnail = typeof record['thumbnail'] === 'string' ? record['thumbnail'] as string : '';
        item.duration = typeof record['duration'] === 'string' ? record['duration'] as string : '';
        item.views = typeof record['views'] === 'string' ? record['views'] as string : '';
        item.published = typeof record['published'] === 'string' ? record['published'] as string : '';
        item.at = typeof record['at'] === 'number' ? record['at'] as number : 0;
        out.push(item);
        if (out.length >= this.maxItems) break;
      }
      return out;
    } catch (e) {
      return [];
    }
  }
}
