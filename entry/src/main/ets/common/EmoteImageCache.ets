/** 表情缓存兼容入口；实际下载、校验与并发去重由通用资源缓存负责。 */
import { common } from '@kit.AbilityKit';
import { RemoteAssetCache } from '../services/cache/RemoteAssetCache';

export class EmoteImageCache {
  static attach(context: common.Context): void {
    RemoteAssetCache.attach(context);
  }

  static localPathOf(url: string): string {
    return RemoteAssetCache.cachedEmote(url);
  }

  static ensure(url: string): Promise<string> {
    return RemoteAssetCache.ensureEmote(url);
  }
}
