import { BiliApi } from '../api/BiliApi';
import { HotSearchItem } from '../model/Models';
import { SearchApi } from '../api/SearchApi';

/** 首页头栏与搜索页共享一份热搜请求和内存缓存。 */
export class HotSearchStore {
  private static items: Array<HotSearchItem> = [];
  private static pending: Promise<Array<HotSearchItem>> | null = null;

  static async load(force: boolean = false): Promise<Array<HotSearchItem>> {
    if (!force && HotSearchStore.items.length > 0) return HotSearchStore.items;
    if (!force && HotSearchStore.pending !== null) return HotSearchStore.pending;
    const request: Promise<Array<HotSearchItem>> = SearchApi.getHotSearch();
    HotSearchStore.pending = request;
    let list: Array<HotSearchItem> = [];
    try {
      list = await request;
    } finally {
      // force 加载可能覆盖 pending；旧请求完成时不能把新请求的标记清掉。
      if (HotSearchStore.pending === request) HotSearchStore.pending = null;
    }
    if (list.length > 0) {
      HotSearchStore.items = list;
      AppStorage.setOrCreate<string>('homeHotSearch', list[0].showName);
    }
    return HotSearchStore.items;
  }

  static publish(index: number): void {
    if (HotSearchStore.items.length === 0) return;
    const item: HotSearchItem = HotSearchStore.items[index % Math.min(8, HotSearchStore.items.length)];
    AppStorage.setOrCreate<string>('homeHotSearch', item.showName);
  }
}
