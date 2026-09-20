import { common } from '@kit.AbilityKit';
import { YouTubeVideo } from '../api/YouTubeApi';
import { PreferencesCollection } from './preferences/PreferencesCollection';

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

/** 解码钩子：磁盘 JSON 数组元素 → 记录；缺 id 的损坏条目返回 null 跳过。 */
function decodeLocalVideo(record: Object): YouTubeLocalVideo | null {
  const source: Record<string, Object> = (record ?? {}) as Record<string, Object>;
  const id: string = typeof source['id'] === 'string' ? source['id'] as string : '';
  if (id.length === 0) return null;
  const item: YouTubeLocalVideo = new YouTubeLocalVideo();
  item.id = id;
  item.title = typeof source['title'] === 'string' ? source['title'] as string : '';
  item.channel = typeof source['channel'] === 'string' ? source['channel'] as string : '';
  item.thumbnail = typeof source['thumbnail'] === 'string' ? source['thumbnail'] as string : '';
  item.duration = typeof source['duration'] === 'string' ? source['duration'] as string : '';
  item.views = typeof source['views'] === 'string' ? source['views'] as string : '';
  item.published = typeof source['published'] === 'string' ? source['published'] as string : '';
  item.at = typeof source['at'] === 'number' ? source['at'] as number : 0;
  return item;
}

/**
 * 本地列表存储：稍后观看与观看历史共用同一套逻辑，只是键名、上限与广播键不同。
 *
 * 门闩、内存优先磁盘补缺的恢复与落盘在 PreferencesCollection；
 * 这里只剩条目装配与「我的」页入口行的计数广播。
 */
export class YouTubeLocalStore extends PreferencesCollection<YouTubeLocalVideo> {
  private readonly countKey: string;

  constructor(storageKey: string, preferencesName: string, maxItems: number, countKey: string) {
    super({ prefName: preferencesName, storageKey: storageKey, maxItems: maxItems }, { decode: decodeLocalVideo });
    this.countKey = countKey;
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
    this.replace(next);
    return this.list();
  }

  remove(id: string): Array<YouTubeLocalVideo> {
    const next: Array<YouTubeLocalVideo> = [];
    for (const item of this.cache) {
      if (item.id !== id) next.push(item);
    }
    this.replace(next);
    return this.list();
  }

  clear(): void {
    this.replace([]);
  }

  protected keyOf(item: YouTubeLocalVideo): string {
    return item.id;
  }

  protected sortBy(a: YouTubeLocalVideo, b: YouTubeLocalVideo): number {
    return b.at - a.at;
  }

  protected onChanged(raw: string): void {
    this.broadcast();
  }

  protected onRestored(diskRaw: string): void {
    this.broadcast();
  }

  private broadcast(): void {
    AppStorage.setOrCreate<number>(this.countKey, this.cache.length);
  }
}
