import { DanmakuItem } from '../../model/video/VideoAuxiliaryModels';

/** Precise server IDs identify rows; object tokens distinguish legacy and duplicate records. */
export class DanmakuListKeys {
  private serial: number = 0;
  private tokens: WeakMap<DanmakuItem, number> = new WeakMap<DanmakuItem, number>();
  private copies: WeakMap<DanmakuItem, string> = new WeakMap<DanmakuItem, string>();
  private current: Array<DanmakuItem> | null = null;
  private refs: Array<DanmakuItem> = [];
  private ids: Array<string> = [];
  private keys: Array<string> = [];
  private primary: Map<string, DanmakuItem> = new Map<string, DanmakuItem>();

  keyFor(items: Array<DanmakuItem>, index: number): string {
    const item: DanmakuItem = items[index];
    if (this.current !== items || this.refs.length !== items.length || this.refs[index] !== item ||
      this.ids[index] !== item.idStr) this.prepare(items);
    return this.keys[index];
  }

  private token(item: DanmakuItem): number {
    let value: number | undefined = this.tokens.get(item);
    if (value === undefined) {
      value = ++this.serial;
      this.tokens.set(item, value);
    }
    return value;
  }

  private prepare(items: Array<DanmakuItem>): void {
    const present: Set<DanmakuItem> = new Set<DanmakuItem>(items);
    const primary: Map<string, DanmakuItem> = new Map<string, DanmakuItem>();
    for (const item of items) {
      if (!/^[1-9][0-9]*$/.test(item.idStr) || primary.has(item.idStr)) continue;
      const previous: DanmakuItem | undefined = this.primary.get(item.idStr);
      // A duplicate keeps its token even if the original row has since been removed.
      if ((previous === undefined || !present.has(previous)) && this.copies.get(item) === item.idStr) continue;
      primary.set(item.idStr, previous !== undefined && present.has(previous) ? previous : item);
    }
    const occurrences: Map<DanmakuItem, number> = new Map<DanmakuItem, number>();
    this.keys = items.map((item: DanmakuItem): string => {
      const precise: boolean = /^[1-9][0-9]*$/.test(item.idStr);
      let key: string = precise ? 'dm:' + item.idStr : 'local:' + String(this.token(item));
      if (precise && primary.get(item.idStr) !== item) {
        this.copies.set(item, item.idStr);
        key += ':copy:' + String(this.token(item));
      }
      const occurrence: number = occurrences.get(item) ?? 0;
      occurrences.set(item, occurrence + 1);
      if (occurrence > 0) key += ':repeat:' + String(occurrence);
      return key;
    });
    this.primary = primary;
    this.current = items;
    this.refs = items.slice();
    this.ids = items.map((item: DanmakuItem): string => item.idStr);
  }
}
