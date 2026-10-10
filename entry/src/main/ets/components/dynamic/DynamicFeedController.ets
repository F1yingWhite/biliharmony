import { DynamicApi } from '../../api/DynamicApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { DynamicItem, DynamicPageData } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';

export class DynamicFeedState {
  count: number = 0;
  loaded: boolean = false;
  loading: boolean = true;
  errorText: string = '';
  needsLogin: boolean = false;
  moreFailed: boolean = false;
  retryReset: boolean = false;
  hasMore: boolean = true;
  offset: string = '';
}

class DynamicFeedPage {
  readonly source: BasicDataSource<DynamicItem> = new BasicDataSource<DynamicItem>();
  state: DynamicFeedState = new DynamicFeedState();
  requesting: boolean = false;
}

/** 分类列表、游标和请求共用一个所有者，切换分类不会交换原生列表的数据源。 */
export class DynamicFeedController {
  readonly types: Array<string> = ['all', 'video', 'pgc', 'article'];
  private pages: Map<string, DynamicFeedPage> = new Map<string, DynamicFeedPage>();
  private selectedType: string = 'all';
  private epoch: RequestEpoch = new RequestEpoch();

  private getHostMid: () => number;
  private publish: (states: Array<DynamicFeedState>) => void;

  constructor(getHostMid: () => number, publish: (states: Array<DynamicFeedState>) => void) {
    this.getHostMid = getHostMid;
    this.publish = publish;
  }

  get activeType(): string { return this.selectedType; }

  source(type: string): BasicDataSource<DynamicItem> { return this.page(type).source; }

  state(type: string = this.selectedType): DynamicFeedState {
    const page: DynamicFeedPage = this.page(type);
    const state: DynamicFeedState = page.state;
    // 每次发布独立快照，ArkUI 只订阅状态，不代理控制器内部的 Map 和请求锁。
    return { count: page.source.totalCount(), loaded: state.loaded,
      loading: page.requesting || (!state.loaded && page.source.isEmpty() && state.errorText.length === 0),
      errorText: state.errorText, needsLogin: state.needsLogin, moreFailed: state.moreFailed,
      retryReset: state.retryReset, hasMore: state.hasMore, offset: state.offset };
  }

  snapshots(): Array<DynamicFeedState> {
    return this.types.map((type: string) => this.state(type));
  }

  /** 页面移除时撤销请求，不触碰已挂载列表或向消失的组件发布状态。 */
  cancel(): void {
    this.epoch.invalidate();
    this.pages.forEach((page: DynamicFeedPage) => { page.requesting = false; });
  }

  reset(): void {
    this.epoch.invalidate();
    this.pages.forEach((page: DynamicFeedPage) => {
      page.source.clear();
      page.state = new DynamicFeedState();
      page.requesting = false;
    });
    this.emit();
  }

  /** 保留已加载空页与错误恢复方式；首次进入的分类才发首屏请求。 */
  async select(type: string): Promise<void> {
    if (type === this.selectedType || this.types.indexOf(type) < 0) return;
    this.epoch.invalidate();
    this.page(this.selectedType).requesting = false;
    this.selectedType = type;
    this.emit();
    const page: DynamicFeedPage = this.page(type);
    if (!page.state.loaded && page.source.isEmpty()) await this.load(true);
  }

  async load(reset: boolean): Promise<void> {
    const page: DynamicFeedPage = this.page(this.selectedType);
    if (!reset && (page.requesting || !page.state.hasMore)) return;
    const request: number = this.epoch.next();
    const session: number = AuthSession.version;
    const hostMid: number = this.getHostMid();
    const type: string = this.selectedType;
    const state: DynamicFeedState = page.state;
    state.moreFailed = false;
    state.needsLogin = false;
    state.retryReset = reset;
    state.errorText = '';
    page.requesting = true;
    this.emit();
    const isCurrent = (): boolean => this.epoch.isCurrent(request) &&
      AuthSession.version === session && this.getHostMid() === hostMid;
    try {
      const offset: string = reset ? '' : state.offset;
      const result: DynamicPageData = hostMid > 0 ?
        await DynamicApi.getUserDynamicFeed(hostMid, offset) : await DynamicApi.getDynamicFeed(offset, type);
      if (!isCurrent()) return;
      const items: Array<DynamicItem> = this.uniqueItems(result.items, reset ? [] : page.source.getAll());
      if (reset) page.source.reset(items);
      else page.source.append(items);
      state.offset = result.offset;
      state.hasMore = result.hasMore;
      state.loaded = true;
    } catch (e) {
      if (!isCurrent()) return;
      const message: string = (e as Error).message || '动态加载失败，请稍后重试';
      state.needsLogin = message === '登录已失效，请重新登录后查看动态';
      if (page.source.isEmpty()) state.errorText = message;
      else state.moreFailed = true;
    } finally {
      // 账号变化而广播尚未到达时也释放本请求锁，但不接收旧账号的内容。
      if (this.epoch.isCurrent(request)) {
        page.requesting = false;
        this.emit();
      }
    }
  }

  setInitialError(message: string): void {
    this.page(this.selectedType).state.errorText = message;
    this.emit();
  }

  /** 同一账号的在途点赞可跨卡片复用与分类切换，按 id 更新所有持有该动态的页。 */
  updateLike(dynId: string, liked: boolean, count: number): void {
    this.pages.forEach((page: DynamicFeedPage) => {
      const items: Array<DynamicItem> = page.source.getAll();
      for (let i: number = 0; i < items.length; i++) {
        if (items[i].dynId === dynId) {
          items[i].liked = liked;
          items[i].like = count;
        }
      }
    });
  }

  /** 接口分页可能重叠；每个分类只保留首次出现的动态，避免 LazyForEach 的 dynId key 重复。 */
  private uniqueItems(items: Array<DynamicItem>, existing: Array<DynamicItem>): Array<DynamicItem> {
    const ids: Set<string> = new Set<string>();
    for (let i: number = 0; i < existing.length; i++) ids.add(existing[i].dynId);
    const unique: Array<DynamicItem> = [];
    for (let i: number = 0; i < items.length; i++) {
      const item: DynamicItem = items[i];
      if (ids.has(item.dynId)) continue;
      ids.add(item.dynId);
      unique.push(item);
    }
    return unique;
  }

  private page(type: string): DynamicFeedPage {
    let page: DynamicFeedPage | undefined = this.pages.get(type);
    if (page === undefined) {
      page = new DynamicFeedPage();
      this.pages.set(type, page);
    }
    return page;
  }

  private emit(): void { this.publish(this.snapshots()); }
}
