import { common } from '@kit.AbilityKit';
import { YouTubeVideo } from '../api/YouTubeApi';
import { YouTubeLocalStore, YouTubeLocalVideo } from './YouTubeLocalStore';

/**
 * YouTube 侧本地观看历史：打开详情页即记录，不需要账号。
 *
 * 只是"本机看过什么"，不是服务端同步的观看记录；与哔哩哔哩的历史互不相干。
 * 上限比稍后观看大一些（历史是流水，稍后观看是待办）。
 */
const store: YouTubeLocalStore =
  new YouTubeLocalStore('youtubeHistoryJson', 'youtube_history', 200, 'youtubeHistoryCount');

export class YouTubeHistoryStore {
  static init(context: common.UIAbilityContext): void {
    store.init(context);
  }

  static async ensureLoaded(): Promise<Array<YouTubeLocalVideo>> {
    return await store.ensureLoaded();
  }

  static list(): Array<YouTubeLocalVideo> {
    return store.list();
  }

  static count(): number {
    return store.count();
  }

  static remove(id: string): Array<YouTubeLocalVideo> {
    return store.remove(id);
  }

  static clear(): void {
    store.clear();
  }

  /** 记录一次观看：重复打开同一视频只更新时间与元数据，不产生第二条。 */
  static record(video: YouTubeVideo): Array<YouTubeLocalVideo> {
    return store.add(video);
  }
}
