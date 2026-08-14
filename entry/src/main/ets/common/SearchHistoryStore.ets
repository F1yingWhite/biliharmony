import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 本地搜索历史：Preferences 显式 flush 为权威副本，兼容旧 PersistentStorage 数据。 */
export class SearchHistoryStore {
  private static readonly STORAGE_KEY: string = 'searchHistoryJson';
  private static readonly PREFERENCES_NAME: string = 'bili_search_state';
  private static cache: Array<string> = [];
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;

  static init(context: common.UIAbilityContext): void {
    PersistentStorage.persistProp<string>(SearchHistoryStore.STORAGE_KEY, '[]');
    const legacyRaw: string = AppStorage.get<string>(SearchHistoryStore.STORAGE_KEY) ?? '[]';
    SearchHistoryStore.cache = SearchHistoryStore.parse(legacyRaw);
    SearchHistoryStore.ready = SearchHistoryStore.restore(context, legacyRaw);
  }

  private static async restore(context: common.UIAbilityContext, legacyRaw: string): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context,
        { name: SearchHistoryStore.PREFERENCES_NAME });
      SearchHistoryStore.store = store;
      const diskRaw: string = store.getSync(SearchHistoryStore.STORAGE_KEY, '') as string;
      const effectiveRaw: string = diskRaw.length > 0 ? diskRaw : legacyRaw;
      SearchHistoryStore.cache = SearchHistoryStore.parse(effectiveRaw);
      AppStorage.setOrCreate<string>(SearchHistoryStore.STORAGE_KEY,
        JSON.stringify(SearchHistoryStore.cache));
      if (diskRaw.length === 0 && SearchHistoryStore.cache.length > 0) {
        store.putSync(SearchHistoryStore.STORAGE_KEY, JSON.stringify(SearchHistoryStore.cache));
        await store.flush();
      }
    } catch (e) {
      // Preferences 不可用时继续使用已迁移的旧缓存。
    }
  }

  static async ensureLoaded(): Promise<Array<string>> {
    if (SearchHistoryStore.ready !== null) await SearchHistoryStore.ready;
    return SearchHistoryStore.items();
  }

  static items(): Array<string> {
    return SearchHistoryStore.cache.slice(0, 20);
  }

  static add(keyword: string): Array<string> {
    const value: string = keyword.trim();
    if (value.length === 0) return SearchHistoryStore.items();
    const old: Array<string> = SearchHistoryStore.items();
    const next: Array<string> = [value];
    for (let i: number = 0; i < old.length && next.length < 20; i++) {
      if (old[i] !== value) next.push(old[i]);
    }
    SearchHistoryStore.save(next);
    return next;
  }

  static remove(keyword: string): Array<string> {
    const old: Array<string> = SearchHistoryStore.items();
    const next: Array<string> = [];
    for (let i: number = 0; i < old.length; i++) {
      if (old[i] !== keyword) next.push(old[i]);
    }
    SearchHistoryStore.save(next);
    return next;
  }

  static clear(): void {
    SearchHistoryStore.save([]);
  }

  private static save(items: Array<string>): void {
    SearchHistoryStore.cache = items.slice(0, 20);
    const raw: string = JSON.stringify(SearchHistoryStore.cache);
    AppStorage.setOrCreate<string>(SearchHistoryStore.STORAGE_KEY, raw);
    SearchHistoryStore.persistRaw(raw);
  }

  private static async persistRaw(raw: string): Promise<void> {
    if (SearchHistoryStore.ready !== null) await SearchHistoryStore.ready;
    if (SearchHistoryStore.store === null) return;
    SearchHistoryStore.store.putSync(SearchHistoryStore.STORAGE_KEY, raw);
    await SearchHistoryStore.store.flush();
  }

  private static parse(raw: string): Array<string> {
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) return [];
      const source: Array<Object> = parsed as Array<Object>;
      const result: Array<string> = [];
      for (let i: number = 0; i < source.length && result.length < 20; i++) {
        if (typeof source[i] === 'string') {
          const value: string = (source[i] as string).trim();
          if (value.length > 0 && result.indexOf(value) < 0) result.push(value);
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }
}
