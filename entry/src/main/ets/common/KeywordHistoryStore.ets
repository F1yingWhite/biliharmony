import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/**
 * 通用「关键词历史」存储：Preferences 显式 flush 为权威副本，兼容旧的 PersistentStorage 数据。
 *
 * 抽成实例是为了让两个平台各自持有独立历史：哔哩哔哩与 YouTube 的搜索词混在一起
 * 既没有意义，也会让清空历史互相影响。键名与 Preferences 名由调用方给出。
 */
export class KeywordHistoryStore {
  private readonly storageKey: string;
  private readonly preferencesName: string;
  private cache: Array<string> = [];
  private store: preferences.Preferences | null = null;
  private ready: Promise<void> | null = null;

  constructor(storageKey: string, preferencesName: string) {
    this.storageKey = storageKey;
    this.preferencesName = preferencesName;
  }

  init(context: common.UIAbilityContext): void {
    PersistentStorage.persistProp<string>(this.storageKey, '[]');
    const legacyRaw: string = AppStorage.get<string>(this.storageKey) ?? '[]';
    this.cache = this.parse(legacyRaw);
    this.ready = this.restore(context, legacyRaw);
  }

  private async restore(context: common.UIAbilityContext, legacyRaw: string): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context,
        { name: this.preferencesName });
      this.store = store;
      const diskRaw: string = store.getSync(this.storageKey, '') as string;
      const effectiveRaw: string = diskRaw.length > 0 ? diskRaw : legacyRaw;
      this.cache = this.parse(effectiveRaw);
      AppStorage.setOrCreate<string>(this.storageKey, JSON.stringify(this.cache));
      if (diskRaw.length === 0 && this.cache.length > 0) {
        store.putSync(this.storageKey, JSON.stringify(this.cache));
        await store.flush();
      }
    } catch (e) {
      // Preferences 不可用时继续使用已迁移的旧缓存。
    }
  }

  async ensureLoaded(): Promise<Array<string>> {
    if (this.ready !== null) await this.ready;
    return this.items();
  }

  items(): Array<string> {
    return this.cache.slice(0, 20);
  }

  add(keyword: string): Array<string> {
    const value: string = keyword.trim();
    if (value.length === 0) return this.items();
    const old: Array<string> = this.items();
    const next: Array<string> = [value];
    for (let i: number = 0; i < old.length && next.length < 20; i++) {
      if (old[i] !== value) next.push(old[i]);
    }
    this.save(next);
    return next;
  }

  remove(keyword: string): Array<string> {
    const old: Array<string> = this.items();
    const next: Array<string> = [];
    for (let i: number = 0; i < old.length; i++) {
      if (old[i] !== keyword) next.push(old[i]);
    }
    this.save(next);
    return next;
  }

  clear(): void {
    this.save([]);
  }

  private save(items: Array<string>): void {
    this.cache = items.slice(0, 20);
    const raw: string = JSON.stringify(this.cache);
    AppStorage.setOrCreate<string>(this.storageKey, raw);
    this.persistRaw(raw);
  }

  private async persistRaw(raw: string): Promise<void> {
    if (this.ready !== null) await this.ready;
    if (this.store === null) return;
    this.store.putSync(this.storageKey, raw);
    await this.store.flush();
  }

  private parse(raw: string): Array<string> {
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
