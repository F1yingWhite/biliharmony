import { common } from '@kit.AbilityKit';
import { PreferencesCollection } from './preferences/PreferencesCollection';

/** 解码钩子：磁盘 JSON 数组元素 → 去空格后的关键词；非字符串或空白返回 null 跳过。 */
function decodeKeyword(record: Object): string | null {
  if (typeof record !== 'string') return null;
  const value: string = (record as string).trim();
  return value.length === 0 ? null : value;
}

/**
 * 通用「关键词历史」存储：Preferences 显式 flush 为权威副本，兼容旧的 PersistentStorage 数据。
 *
 * 抽成实例是为了让两个平台各自持有独立历史：哔哩哔哩与 YouTube 的搜索词混在一起
 * 既没有意义，也会让清空历史互相影响。键名与 Preferences 名由调用方给出。
 * 门闩、恢复合并与落盘在 PreferencesCollection：这里只剩旧数据迁移与 AppStorage 镜像。
 */
export class KeywordHistoryStore extends PreferencesCollection<string> {
  private static readonly MAX_ITEMS: number = 20;

  constructor(storageKey: string, preferencesName: string) {
    super({ prefName: preferencesName, storageKey: storageKey, maxItems: KeywordHistoryStore.MAX_ITEMS },
      { decode: decodeKeyword });
  }

  /** 旧 PersistentStorage 数据先解析进内存：恢复是异步的，用户可能在它完成前就搜了一次。 */
  protected onInit(): void {
    PersistentStorage.persistProp<string>(this.storageKey, '[]');
    const legacyRaw: string = AppStorage.get<string>(this.storageKey) ?? '[]';
    this.cache = this.merge([], this.parseList(legacyRaw));
  }

  protected keyOf(item: string): string {
    return item;
  }

  protected sortBy(a: string, b: string): number {
    // 关键词历史按插入序（最新在前），不重排。
    return 0;
  }

  protected onChanged(raw: string): void {
    // AppStorage 键由 PersistentStorage 联动给页面响应式使用。
    AppStorage.setOrCreate<string>(this.storageKey, raw);
  }

  protected onRestored(diskRaw: string): void {
    AppStorage.setOrCreate<string>(this.storageKey, JSON.stringify(this.cache));
    if (diskRaw.length === 0 && this.cache.length > 0) {
      // 磁盘还没有权威副本（首次升级）：把迁移结果立即写穿，不等防抖。
      this.writeThrough(JSON.stringify(this.cache));
    }
  }

  items(): Array<string> {
    return this.list();
  }

  add(keyword: string): Array<string> {
    const value: string = keyword.trim();
    if (value.length === 0) return this.items();
    const old: Array<string> = this.items();
    const next: Array<string> = [value];
    for (let i: number = 0; i < old.length && next.length < KeywordHistoryStore.MAX_ITEMS; i++) {
      if (old[i] !== value) next.push(old[i]);
    }
    this.replace(next);
    return next;
  }

  remove(keyword: string): Array<string> {
    const old: Array<string> = this.items();
    const next: Array<string> = [];
    for (let i: number = 0; i < old.length; i++) {
      if (old[i] !== keyword) next.push(old[i]);
    }
    this.replace(next);
    return next;
  }

  clear(): void {
    this.replace([]);
  }
}
