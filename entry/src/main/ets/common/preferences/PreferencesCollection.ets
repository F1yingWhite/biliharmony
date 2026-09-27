/**
 * Preferences 列表存储基类：把「getPreferences → ready 门闩 → putSync + flush → JSON 编解码 →
 * 内存优先磁盘补缺」这套流程收敛为一处（原先在 KeywordHistoryStore 与 YouTubeLocalStore
 * 是两份平行的参数化实现）。
 *
 * 磁盘结构是「存储键 → JSON 数组」；子类只注入：
 * - decode：数组元素 → T 的防御式解码（损坏元素返回 null 跳过）；
 * - keyOf / sortBy：条目身份与排序；
 * - onInit / onRestored / onChanged：PersistentStorage 迁移与 AppStorage 镜像等平台联动。
 *
 * flush 采用尾部防抖（与 AppTheme 弹幕/亮度写入的 400ms 先例一致）：putSync 即时更新
 * Preferences 内存副本，连续写入合并为一次磁盘写。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** 列表存储装配参数：Preferences 文件名、存储键与条目上限。 */
export interface PreferencesListSpec {
  prefName: string;
  storageKey: string;
  maxItems: number;
}

/** 注入的解码钩子：磁盘 JSON 数组的单个元素 → T；损坏或非本类型返回 null 并跳过。 */
export interface PreferencesDecoder<T> {
  decode: (record: Object) => T | null;
}

export abstract class PreferencesCollection<T> {
  /** flush 尾部防抖（毫秒）：滑条/连续记录类写入不能每次都落盘。 */
  private static readonly FLUSH_DEBOUNCE_MS: number = 400;
  protected readonly storageKey: string;
  private readonly prefName: string;
  protected readonly maxItems: number;
  private readonly decoder: PreferencesDecoder<T>;
  protected cache: Array<T> = [];
  private store: preferences.Preferences | null = null;
  private ready: Promise<void> | null = null;
  private flushTimer: number = -1;

  protected constructor(spec: PreferencesListSpec, decoder: PreferencesDecoder<T>) {
    this.prefName = spec.prefName;
    this.storageKey = spec.storageKey;
    this.maxItems = spec.maxItems;
    this.decoder = decoder;
  }

  /** 条目身份键：解析与恢复合并的去重都以它为准；返回空串表示无效条目。 */
  protected abstract keyOf(item: T): string;

  /** 排序比较器；与列表无关的存储返回 0（稳定排序即保持插入序）。 */
  protected abstract sortBy(a: T, b: T): number;

  /** 每次写入缓存后的联动：AppStorage 镜像 / 计数广播（raw 为刚生成的 JSON 串）。 */
  protected abstract onChanged(raw: string): void;

  /** 恢复完成后的联动：镜像同步、旧数据迁移写等（diskRaw 为空串说明磁盘尚无此键）。 */
  protected abstract onRestored(diskRaw: string): void;

  /** 启动准备钩子（PersistentStorage 迁移等），默认无事可做。 */
  protected onInit(): void {
  }

  /** 由 EntryAbility 在 onCreate 调用：启动异步恢复，写入方靠 ready 门闩等它完成。 */
  init(context: common.UIAbilityContext): void {
    this.onInit();
    this.ready = this.restore(context);
  }

  async ensureLoaded(): Promise<Array<T>> {
    if (this.ready !== null) await this.ready;
    return this.list();
  }

  list(): Array<T> {
    return this.cache.slice(0, this.maxItems);
  }

  /** 全量替换缓存并落盘：上限截断、联动回调、异步持久化。 */
  protected replace(items: Array<T>): void {
    this.cache = items.slice(0, this.maxItems);
    const raw: string = JSON.stringify(this.cache);
    this.onChanged(raw);
    this.persist(raw);
  }

  /** 立即写穿（不走防抖）：仅用于恢复时把旧副本迁移成权威副本这类一次性写入。 */
  protected writeThrough(raw: string): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) return;
    try {
      store.putSync(this.storageKey, raw);
      store.flush().catch(() => {
        // 迁移写失败不阻断启动：旧副本仍在，下次启动会再次迁移。
      });
    } catch (e) {
      // Preferences 写失败按降级处理。
    }
  }

  /** 内存优先、磁盘补缺：按 keyOf 去重、sortBy 排序后截断到上限。 */
  protected merge(memory: Array<T>, disk: Array<T>): Array<T> {
    const seen: Set<string> = new Set<string>();
    const merged: Array<T> = [];
    for (const item of memory) {
      const key: string = this.keyOf(item);
      if (key.length === 0 || seen.has(key)) continue;
      seen.add(key);
      merged.push(item);
    }
    for (const item of disk) {
      const key: string = this.keyOf(item);
      if (key.length === 0 || seen.has(key)) continue;
      seen.add(key);
      merged.push(item);
    }
    merged.sort((a: T, b: T): number => this.sortBy(a, b));
    return merged.slice(0, this.maxItems);
  }

  /** 防御式解析：非 JSON / 非数组 / 单元素损坏都按跳过或空列表处理，绝不抛给调用方。 */
  protected parseList(raw: string): Array<T> {
    if (raw.length === 0) return [];
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) return [];
      const seen: Set<string> = new Set<string>();
      const out: Array<T> = [];
      for (const entry of parsed as Array<Object>) {
        const item: T | null = this.decoder.decode(entry);
        if (item === null) continue;
        const key: string = this.keyOf(item);
        if (key.length === 0 || seen.has(key)) continue;
        seen.add(key);
        out.push(item);
        if (out.length >= this.maxItems) break;
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private async restore(context: common.UIAbilityContext): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context,
        { name: this.prefName });
      this.store = store;
      const diskRaw: string = store.getSync(this.storageKey, '') as string;
      // 恢复是异步的：用户可能在它完成前就写入。内存里的新条目优先，
      // 磁盘只补缺失项，避免刚记下的内容被旧数据顶掉。
      this.cache = this.merge(this.cache, this.parseList(diskRaw));
      this.onRestored(diskRaw);
    } catch (e) {
      // Preferences 不可用时继续使用内存缓存：列表功能降级，不影响其它功能。
    }
  }

  /** putSync 即时更新内存副本，flush 尾部防抖合并磁盘写；未就绪时等 ready 门闩再写。 */
  private async persist(raw: string): Promise<void> {
    if (this.ready !== null) await this.ready;
    const store: preferences.Preferences | null = this.store;
    if (store === null) return;
    try {
      store.putSync(this.storageKey, raw);
    } catch (e) {
      return;
    }
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      const target: preferences.Preferences | null = this.store;
      if (target === null) return;
      try {
        target.flush().catch(() => {
          // 磁盘同步失败只丢一次落盘时机，Preferences 内存副本仍是新的。
        });
      } catch (e) {
        // 同上：写盘失败不影响内存态。
      }
    }, PreferencesCollection.FLUSH_DEBOUNCE_MS);
  }
}
