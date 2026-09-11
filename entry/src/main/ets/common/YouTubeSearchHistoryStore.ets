import { common } from '@kit.AbilityKit';
import { KeywordHistoryStore } from './KeywordHistoryStore';

/**
 * YouTube 侧搜索历史：与哔哩哔哩同一套能力、各自独立存储。
 * 搜索词属于平台内容，混存会让两边的历史互相污染。
 */
const store: KeywordHistoryStore = new KeywordHistoryStore('youtubeSearchHistoryJson', 'youtube_search_state');

export class YouTubeSearchHistoryStore {
  static init(context: common.UIAbilityContext): void {
    store.init(context);
  }

  static async ensureLoaded(): Promise<Array<string>> {
    return await store.ensureLoaded();
  }

  static items(): Array<string> {
    return store.items();
  }

  static add(keyword: string): Array<string> {
    return store.add(keyword);
  }

  static remove(keyword: string): Array<string> {
    return store.remove(keyword);
  }

  static clear(): void {
    store.clear();
  }
}
