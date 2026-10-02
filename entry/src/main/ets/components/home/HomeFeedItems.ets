import { VideoItem } from '../../model/Models';
import { LocalVideoFilter } from '../../common/LocalVideoFilter';

export function homeVideoKey(item: VideoItem): string {
  return item.aid > 0 ? 'a' + String(item.aid) : item.bvid;
}

export function freshHomeVideos(current: Array<VideoItem>, incoming: Array<VideoItem>): Array<VideoItem> {
  const seen: Set<string> = new Set<string>();
  for (const item of current) seen.add(homeVideoKey(item));
  const result: Array<VideoItem> = [];
  for (const item of LocalVideoFilter.filterVideos(incoming)) {
    const key: string = homeVideoKey(item);
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result;
}

/** Remembers actual exposure, not fetched-but-unseen recommendation rows. */
export class HomeExposureWindow {
  private order: Array<string> = [];
  private seen: Set<string> = new Set<string>();

  clear(): void { this.order = []; this.seen.clear(); }

  filter(items: Array<VideoItem>): Array<VideoItem> {
    return items.filter((item: VideoItem): boolean => !this.seen.has(homeVideoKey(item)));
  }

  remember(items: Array<VideoItem>): void {
    for (const item of items) {
      const key: string = homeVideoKey(item);
      if (this.seen.has(key)) continue;
      this.seen.add(key);
      this.order.push(key);
    }
    while (this.order.length > 400) {
      const key: string | undefined = this.order.shift();
      if (key !== undefined) this.seen.delete(key);
    }
  }
}
