import { UserApi } from '../../api/UserApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { VideoItem } from '../../model/video/VideoModels';
import { SpaceArcData } from '../../model/discovery/DiscoveryModels';
import { AuthSession } from '../../services/auth/AuthSession';

export class UserSpaceFeedState {
  order: string = 'pubdate';
  total: number = 0;
  loading: boolean = false;
  loadingMore: boolean = false;
  hasMore: boolean = false;
  error: string = '';
}

/** 投稿列表的请求、排序和分页归属；页面只发布状态并渲染 source。 */
export class UserSpaceFeedController {
  readonly source: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private readonly publishState: (state: UserSpaceFeedState) => void;
  private state: UserSpaceFeedState = new UserSpaceFeedState();
  private requests: RequestEpoch = new RequestEpoch();
  private mid: number = 0;
  private account: number = -1;
  private page: number = 1;
  private active: boolean = false;
  private retryReset: boolean = true;

  constructor(publish: (state: UserSpaceFeedState) => void) {
    this.publishState = publish;
  }

  activate(mid: number): void {
    this.requests.invalidate();
    this.mid = mid;
    this.account = AuthSession.version;
    this.active = true;
    this.page = 1;
    this.retryReset = true;
    this.state = new UserSpaceFeedState();
    this.source.clear();
    this.publish();
  }

  dispose(): void {
    this.active = false;
    this.requests.invalidate();
  }

  async changeOrder(order: string): Promise<void> {
    if (!this.active || this.state.order === order ||
      (order !== 'pubdate' && order !== 'click' && order !== 'stow')) return;
    this.state.order = order;
    this.state.total = 0;
    this.state.hasMore = false;
    // 旧排序的内容不能留在新标签下；刷新仍保留同一排序的既有内容。
    this.source.clear();
    await this.load(true);
  }

  async retry(): Promise<void> {
    await this.load(this.state.error.length > 0 ? this.retryReset : false);
  }

  async load(reset: boolean): Promise<void> {
    if (!this.active || this.mid <= 0) return;
    if (this.account !== AuthSession.version) {
      const order: string = this.state.order;
      this.activate(this.mid);
      this.state.order = order;
      reset = true;
    }
    if (!reset && (this.state.loading || this.state.loadingMore || !this.state.hasMore)) return;
    const request: number = this.requests.next();
    const account: number = this.account;
    const page: number = reset ? 1 : this.page;
    const order: string = this.state.order;
    this.retryReset = reset;
    this.state.loading = reset;
    this.state.loadingMore = !reset;
    this.state.error = '';
    this.publish();
    try {
      const data: SpaceArcData = await UserApi.getUserSpaceArcs(this.mid, page, order);
      if (!this.isCurrent(request, account)) return;
      const seen: Set<string> = new Set<string>();
      if (!reset) this.source.getAll().forEach((item: VideoItem) => seen.add(this.key(item)));
      const incoming: Array<VideoItem> = data.videos.filter((item: VideoItem): boolean => {
        const key: string = this.key(item);
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
      if (reset) this.source.reset(incoming);
      else this.source.append(incoming);
      this.page = page + 1;
      this.state.total = data.total;
      this.state.hasMore = data.videos.length > 0 && this.source.totalCount() < data.total;
    } catch (e) {
      if (this.isCurrent(request, account)) {
        this.state.error = (e as Error).message || '投稿加载失败，请检查网络后重试';
      }
    } finally {
      if (this.isCurrent(request, account)) {
        this.state.loading = false;
        this.state.loadingMore = false;
        this.publish();
      }
    }
  }

  private key(item: VideoItem): string {
    return item.bvid.length > 0 ? item.bvid : String(item.aid);
  }

  private isCurrent(request: number, account: number): boolean {
    return this.active && account === AuthSession.version && this.requests.isCurrent(request);
  }

  private publish(): void {
    const state: UserSpaceFeedState = new UserSpaceFeedState();
    state.order = this.state.order;
    state.total = this.state.total;
    state.loading = this.state.loading;
    state.loadingMore = this.state.loadingMore;
    state.hasMore = this.state.hasMore;
    state.error = this.state.error;
    this.publishState(state);
  }
}
