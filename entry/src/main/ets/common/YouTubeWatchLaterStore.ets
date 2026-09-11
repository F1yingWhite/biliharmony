import { common } from '@kit.AbilityKit';
import { YouTubeVideo } from '../api/YouTubeApi';
import { YouTubeLocalStore, YouTubeLocalVideo } from './YouTubeLocalStore';

/**
 * YouTube 侧本地稍后观看：不需要账号，因此游客也能用。
 * 与哔哩哔哩的稍后观看（服务端数据）互不相干，两边不共享存储。
 */
const store: YouTubeLocalStore =
  new YouTubeLocalStore('youtubeWatchLaterJson', 'youtube_watch_later', 100, 'youtubeWatchLaterCount');

export class YouTubeWatchLaterStore {
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

  static contains(id: string): boolean {
    return store.contains(id);
  }

  /** 保存/取消保存；返回操作后是否处于"已保存"状态。 */
  static toggle(video: YouTubeVideo): boolean {
    if (store.contains(video.id)) {
      store.remove(video.id);
      return false;
    }
    store.add(video);
    return true;
  }

  static add(video: YouTubeVideo): Array<YouTubeLocalVideo> {
    return store.add(video);
  }

  static remove(id: string): Array<YouTubeLocalVideo> {
    return store.remove(id);
  }

  static clear(): void {
    store.clear();
  }
}
