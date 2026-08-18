/**
 * 通用表情解析表：动态/评论文本里的 [xxx] 占位符在接口没下发 emoji 节点时的兜底。
 * 占位符 → 图片 URL 的映射表是**磁盘持久化**的（Preferences 缓存）：
 * - 冷启动先读磁盘缓存立即可用（离线/弱网不再空白），后台再拉取接口刷新；
 * - 刷新成功后写回磁盘，表版本号 +1 驱动订阅方重渲染（卡片把版本号纳入拆分缓存键）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CommentApi } from '../api/CommentApi';
import { BiliEmotePackage } from '../model/Models';

const VERSION_KEY: string = 'emoteResolverVersion';
const PREF_NAME: string = 'emote_resolver';
const PREF_TABLE_ENTRIES: string = 'emote_table_entries';

const table: Map<string, string> = new Map<string, string>();
let loading: boolean = false;
let loaded: boolean = false;
/** 本进程是否已对磁盘表做过头一轮接口刷新（不阻塞首次渲染）。 */
let refreshStarted: boolean = false;
let prefs: preferences.Preferences | null = null;

export class EmoteResolver {
  static version(): number {
    const v: number | undefined = AppStorage.get<number>(VERSION_KEY);
    return v === undefined ? 0 : v;
  }

  /** 由 EntryAbility 注入 Context，并立即从 Preferences 恢复磁盘缓存。 */
  static attach(context: common.Context): void {
    try {
      prefs = preferences.getPreferencesSync(context, { name: PREF_NAME });
      EmoteResolver.loadPersisted();
    } catch (e) {
      prefs = null;
    }
  }

  /** 查占位符（含方括号，如 [tv_流鼻血]）对应的表情图 URL；未加载或不存在返回空串。 */
  static lookup(text: string): string {
    const url: string | undefined = table.get(text);
    return url === undefined ? '' : url;
  }

  /** 磁盘缓存就绪则无需等网络：确保表可用并顺手在后台刷新一次。 */
  static ensureLoaded(): void {
    if (loading || refreshStarted) {
      return;
    }
    loading = true;
    refreshStarted = true;
    (async () => {
      let packages: Array<BiliEmotePackage> = await CommentApi.getUserEmotes('dynamic');
      if (packages.length === 0) {
        packages = await CommentApi.getUserEmotes('reply');
      }
      let changed: boolean = false;
      for (let i: number = 0; i < packages.length; i++) {
        for (let j: number = 0; j < packages[i].emotes.length; j++) {
          const text: string = packages[i].emotes[j].text;
          const url: string = packages[i].emotes[j].url;
          if (table.get(text) !== url) {
            table.set(text, url);
            changed = true;
          }
        }
      }
      if (packages.length > 0) {
        loaded = true;
        EmoteResolver.persist();
      }
      if (changed || loaded) {
        AppStorage.setOrCreate<number>(VERSION_KEY, EmoteResolver.version() + 1);
      }
    })()
      .catch(() => {
        // 网络失败保留磁盘缓存表；表为空时保持未加载，下次进入页面重试。
      })
      .finally(() => {
        loading = false;
      });
  }

  /** 从 Preferences 磁盘缓存恢复映射表（冷启动后不联网立即可用）。 */
  private static loadPersisted(): void {
    if (prefs === null) {
      return;
    }
    prefs.get(PREF_TABLE_ENTRIES, '').then((raw: preferences.ValueType) => {
      const rawStr: string = String(raw);
      if (rawStr.length === 0) {
        return;
      }
      try {
        const entries: Array<Array<string>> = JSON.parse(rawStr) as Array<Array<string>>;
        for (let i: number = 0; i < entries.length; i++) {
          const pair: Array<string> = entries[i];
          if (pair.length === 2 && pair[0].length > 0 && pair[1].length > 0) {
            table.set(pair[0], pair[1]);
          }
        }
        if (table.size > 0) {
          loaded = true;
          // 触发一次订阅方重渲染：卡片表情立刻有图，不等接口返回。
          AppStorage.setOrCreate<number>(VERSION_KEY, EmoteResolver.version() + 1);
        }
      } catch (e) {
        // 缓存损坏直接忽略，走接口重拉。
      }
    }).catch(() => {
      // 读取失败忽略，走接口重拉。
    });
  }

  /** 映射表写回 Preferences（异步落盘）。 */
  private static persist(): void {
    const p: preferences.Preferences | null = prefs;
    if (p === null) {
      return;
    }
    const entries: Array<Array<string>> = new Array<Array<string>>();
    table.forEach((url: string, text: string) => {
      entries.push([text, url]);
    });
    p.put(PREF_TABLE_ENTRIES, JSON.stringify(entries)).then(() => {
      p.flush().catch(() => {
      });
    }).catch(() => {
      // 写缓存失败不影响本次显示。
    });
  }
}