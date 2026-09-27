import { common } from '@kit.AbilityKit';
import { PreferencesCollection } from './preferences/PreferencesCollection';
import { VideoItem } from '../model/Models';

function decodeAid(record: Object): number | null {
  if (typeof record !== 'number' || !isFinite(record as number) || (record as number) <= 0) return null;
  return record as number;
}

/**
 * 本地「不想看」过滤：持久化的 aid 黑名单，首页推荐/热门与视频详情相关推荐在入列前过滤。
 *
 * B 站 Web 端没有公开的推荐负反馈接口，所以长按卡片与播放器「我不想看」都落在本地：
 * 与会话级隐藏（HomeView.dislikeLocal 只动当前列表）不同，这里跨启动生效，
 * 上限 500 条（FIFO），可在「设置 → 隐私与数据」一键清空。
 */
export class LocalVideoFilter extends PreferencesCollection<number> {
  private static readonly MAX_ITEMS: number = 500;
  private static instance: LocalVideoFilter | null = null;

  private constructor() {
    super({ prefName: 'local_video_filter', storageKey: 'hidden_aids', maxItems: LocalVideoFilter.MAX_ITEMS },
      { decode: decodeAid });
  }

  static get(): LocalVideoFilter {
    if (LocalVideoFilter.instance === null) LocalVideoFilter.instance = new LocalVideoFilter();
    return LocalVideoFilter.instance;
  }

  /** 由 EntryAbility 在 onCreate 调用：启动异步恢复。 */
  static init(context: common.UIAbilityContext): void {
    LocalVideoFilter.get().init(context);
  }

  static async isHidden(aid: number): Promise<boolean> {
    if (aid <= 0) return false;
    await LocalVideoFilter.get().ensureLoaded();
    return LocalVideoFilter.get().contains(aid);
  }

  /** 同步查询：恢复完成前启动的 feed 首屏用内存副本判断，保证同一次启动口径一致。 */
  static contains(aid: number): boolean {
    if (aid <= 0) return false;
    return LocalVideoFilter.get().list().indexOf(aid) >= 0;
  }

  /** 过滤器：批量入列前使用（推荐/热门/相关推荐）。 */
  static filterVideos(items: Array<VideoItem>): Array<VideoItem> {
    const hidden: Array<number> = LocalVideoFilter.get().list();
    if (hidden.length === 0) return items;
    const hiddenSet: Set<number> = new Set<number>(hidden);
    return items.filter((item: VideoItem): boolean => !hiddenSet.has(item.aid));
  }

  static async hide(aid: number): Promise<void> {
    if (aid <= 0) return;
    await LocalVideoFilter.get().ensureLoaded();
    await LocalVideoFilter.get().add(aid);
  }

  static async clearAll(): Promise<void> {
    await LocalVideoFilter.get().ensureLoaded();
    await LocalVideoFilter.get().clear();
  }

  static count(): number {
    return LocalVideoFilter.get().list().length;
  }

  protected keyOf(item: number): string {
    return String(item);
  }

  protected sortBy(a: number, b: number): number {
    // 新隐藏的排前面（插入序），超限时淘汰最旧的。
    return 0;
  }

  protected onChanged(raw: string): void {
    // 无 AppStorage 镜像需求：读取方都走 contains/filterVideos 的内存副本。
  }

  protected onRestored(diskRaw: string): void {
  }

  async add(aid: number): Promise<void> {
    await this.ensureLoaded();
    const next: Array<number> = this.list().filter((v: number): boolean => v !== aid);
    next.unshift(aid);
    this.replace(next.slice(0, this.maxItems));
  }

  contains(aid: number): boolean {
    return this.list().indexOf(aid) >= 0;
  }

  async clear(): Promise<void> {
    await this.ensureLoaded();
    this.replace([]);
  }
}
