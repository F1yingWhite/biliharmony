/**
 * 通用表情解析表：动态/评论文本里的 [xxx] 占位符在接口没下发 emoji 节点时的兜底。
 * 懒加载官方表情包（dynamic 域，失败回退 reply 域），加载完成后通过
 * AppStorage 版本号驱动订阅方重渲染（卡片把版本号纳入拆分缓存键）。
 */
import { CommentApi } from '../api/CommentApi';
import { BiliEmotePackage } from '../model/Models';

const VERSION_KEY: string = 'emoteResolverVersion';
const table: Map<string, string> = new Map<string, string>();
let loading: boolean = false;
let loaded: boolean = false;

export class EmoteResolver {
  static version(): number {
    const v: number | undefined = AppStorage.get<number>(VERSION_KEY);
    return v === undefined ? 0 : v;
  }

  /** 查占位符（含方括号，如 [tv_流鼻血]）对应的表情图 URL；未加载或不存在返回空串。 */
  static lookup(text: string): string {
    const url: string | undefined = table.get(text);
    return url === undefined ? '' : url;
  }

  static ensureLoaded(): void {
    if (loading || loaded) {
      return;
    }
    loading = true;
    (async () => {
      let packages: Array<BiliEmotePackage> = await CommentApi.getUserEmotes('dynamic');
      if (packages.length === 0) {
        packages = await CommentApi.getUserEmotes('reply');
      }
      for (let i: number = 0; i < packages.length; i++) {
        for (let j: number = 0; j < packages[i].emotes.length; j++) {
          const text: string = packages[i].emotes[j].text;
          if (!table.has(text)) {
            table.set(text, packages[i].emotes[j].url);
          }
        }
      }
      loaded = table.size > 0;
    })()
      .catch(() => {
        // 网络失败保持未加载，下次进入页面重试。
      })
      .finally(() => {
        loading = false;
        if (loaded) {
          AppStorage.setOrCreate<number>(VERSION_KEY, EmoteResolver.version() + 1);
        }
      });
  }
}
