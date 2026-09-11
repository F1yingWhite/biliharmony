import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { YouTubeVideo } from '../api/YouTubeApi';

/**
 * 本地「稍后观看」的一条记录。
 *
 * 只保存公开元数据与视频 ID——播放仍然走官方客户端/官方播放器，
 * 不涉及任何取流或媒体地址（见 docs/YOUTUBE_2026-09-11.md 的游客边界）。
 */
export class YouTubeSavedVideo {
  id: string = '';
  title: string = '';
  channel: string = '';
  thumbnail: string = '';
  duration: string = '';
  views: string = '';
  published: string = '';
  /** 保存时间：列表按它倒序，最近保存的在最上面。 */
  savedAt: number = 0;
}

const STORAGE_KEY: string = 'youtubeWatchLaterJson';
const PREFERENCES_NAME: string = 'youtube_watch_later';
/** 本地列表上限：只做"回头再看"，不做收藏夹，超出丢最旧的。 */
const MAX_ITEMS: number = 100;

/**
 * YouTube 侧本地稍后观看：不需要账号，因此游客也能用。
 * 与哔哩哔哩的稍后观看（服务端数据）互不相干，两边不共享存储。
 */
export class YouTubeWatchLaterStore {
  /** 数量广播给「我的」页入口行，避免返回时读到过期数字。 */
  static readonly KEY_COUNT: string = 'youtubeWatchLaterCount';
  private static cache: Array<YouTubeSavedVideo> = [];
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;

  static init(context: common.UIAbilityContext): void {
    YouTubeWatchLaterStore.ready = YouTubeWatchLaterStore.restore(context);
  }

  private static async restore(context: common.UIAbilityContext): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context,
        { name: PREFERENCES_NAME });
      YouTubeWatchLaterStore.store = store;
      const raw: string = store.getSync(STORAGE_KEY, '') as string;
      // 恢复是异步的：用户可能在它完成前就保存了视频。此时必须合并而不是覆盖，
      // 否则刚保存的条目会被磁盘里的旧内容顶掉（内存优先，磁盘只补缺失项）。
      YouTubeWatchLaterStore.cache =
        YouTubeWatchLaterStore.merge(YouTubeWatchLaterStore.cache, YouTubeWatchLaterStore.parse(raw));
      AppStorage.setOrCreate<number>(YouTubeWatchLaterStore.KEY_COUNT,
        YouTubeWatchLaterStore.cache.length);
    } catch (e) {
      // 读不到就按空列表处理：本地列表不可用不该影响其它功能。
    }
  }

  static async ensureLoaded(): Promise<Array<YouTubeSavedVideo>> {
    if (YouTubeWatchLaterStore.ready !== null) await YouTubeWatchLaterStore.ready;
    return YouTubeWatchLaterStore.list();
  }

  static list(): Array<YouTubeSavedVideo> {
    return YouTubeWatchLaterStore.cache.slice(0, MAX_ITEMS);
  }

  static count(): number {
    return YouTubeWatchLaterStore.cache.length;
  }

  static contains(id: string): boolean {
    if (id.length === 0) return false;
    for (const item of YouTubeWatchLaterStore.cache) {
      if (item.id === id) return true;
    }
    return false;
  }

  /** 保存/取消保存；返回操作后是否处于"已保存"状态。 */
  static toggle(video: YouTubeVideo): boolean {
    if (YouTubeWatchLaterStore.contains(video.id)) {
      YouTubeWatchLaterStore.remove(video.id);
      return false;
    }
    YouTubeWatchLaterStore.add(video);
    return true;
  }

  static add(video: YouTubeVideo): Array<YouTubeSavedVideo> {
    if (video.id.length === 0) return YouTubeWatchLaterStore.list();
    const item: YouTubeSavedVideo = new YouTubeSavedVideo();
    item.id = video.id;
    item.title = video.title;
    item.channel = video.channel;
    item.thumbnail = video.thumbnail;
    item.duration = video.duration;
    item.views = video.views;
    item.published = video.published;
    item.savedAt = Date.now();
    const next: Array<YouTubeSavedVideo> = [item];
    for (const old of YouTubeWatchLaterStore.cache) {
      if (old.id !== item.id && next.length < MAX_ITEMS) next.push(old);
    }
    YouTubeWatchLaterStore.save(next);
    return YouTubeWatchLaterStore.list();
  }

  static remove(id: string): Array<YouTubeSavedVideo> {
    const next: Array<YouTubeSavedVideo> = [];
    for (const item of YouTubeWatchLaterStore.cache) {
      if (item.id !== id) next.push(item);
    }
    YouTubeWatchLaterStore.save(next);
    return YouTubeWatchLaterStore.list();
  }

  static clear(): void {
    YouTubeWatchLaterStore.save([]);
  }

  private static save(items: Array<YouTubeSavedVideo>): void {
    YouTubeWatchLaterStore.cache = items.slice(0, MAX_ITEMS);
    AppStorage.setOrCreate<number>(YouTubeWatchLaterStore.KEY_COUNT,
      YouTubeWatchLaterStore.cache.length);
    YouTubeWatchLaterStore.persist(JSON.stringify(YouTubeWatchLaterStore.cache));
  }

  private static async persist(raw: string): Promise<void> {
    if (YouTubeWatchLaterStore.ready !== null) await YouTubeWatchLaterStore.ready;
    if (YouTubeWatchLaterStore.store === null) return;
    YouTubeWatchLaterStore.store.putSync(STORAGE_KEY, raw);
    await YouTubeWatchLaterStore.store.flush();
  }

  /** 内存优先、磁盘补缺；按保存时间倒序，最多 MAX_ITEMS 条。 */
  private static merge(memory: Array<YouTubeSavedVideo>,
    disk: Array<YouTubeSavedVideo>): Array<YouTubeSavedVideo> {
    const seen: Set<string> = new Set<string>();
    const merged: Array<YouTubeSavedVideo> = [];
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
    merged.sort((a: YouTubeSavedVideo, b: YouTubeSavedVideo) => b.savedAt - a.savedAt);
    return merged.slice(0, MAX_ITEMS);
  }

  private static parse(raw: string): Array<YouTubeSavedVideo> {
    if (raw.length === 0) return [];
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) return [];
      const out: Array<YouTubeSavedVideo> = [];
      for (const entry of parsed as Array<Object>) {
        const record: Record<string, Object> = (entry ?? {}) as Record<string, Object>;
        const id: string = typeof record['id'] === 'string' ? record['id'] as string : '';
        if (id.length === 0) continue;
        const item: YouTubeSavedVideo = new YouTubeSavedVideo();
        item.id = id;
        item.title = typeof record['title'] === 'string' ? record['title'] as string : '';
        item.channel = typeof record['channel'] === 'string' ? record['channel'] as string : '';
        item.thumbnail = typeof record['thumbnail'] === 'string' ? record['thumbnail'] as string : '';
        item.duration = typeof record['duration'] === 'string' ? record['duration'] as string : '';
        item.views = typeof record['views'] === 'string' ? record['views'] as string : '';
        item.published = typeof record['published'] === 'string' ? record['published'] as string : '';
        item.savedAt = typeof record['savedAt'] === 'number' ? record['savedAt'] as number : 0;
        out.push(item);
        if (out.length >= MAX_ITEMS) break;
      }
      return out;
    } catch (e) {
      return [];
    }
  }
}
