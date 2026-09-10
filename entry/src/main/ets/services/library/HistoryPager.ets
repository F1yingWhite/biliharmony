import { HistoryApi } from '../../api/HistoryApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { HistoryPageData, HistoryVideoItem } from '../../model/Models';
import { AuthSession } from '../auth/AuthSession';
import { ApiResult } from '../network/ApiResult';

/** 只有成功且属于当前页面/账号的结果才能更新数据和分页游标。 */
export class HistoryPager {
  readonly source: BasicDataSource<HistoryVideoItem> = new BasicDataSource<HistoryVideoItem>();
  loading: boolean = false;
  hasMore: boolean = true;
  error: string = '';
  private max: number = 0;
  private viewAt: number = 0;
  private epoch: RequestEpoch = new RequestEpoch();
  private session: number = AuthSession.version;
  private retryReset: boolean = true;

  cancel(): void {
    this.epoch.invalidate();
    this.loading = false;
  }

  remove(bvid: string): void {
    this.cancel();
    this.source.reset(this.source.getAll().filter((item: HistoryVideoItem) => item.video.bvid !== bvid));
  }

  clear(): void {
    this.cancel();
    this.source.clear();
    this.max = 0;
    this.viewAt = 0;
    this.hasMore = false;
    this.error = '';
  }

  async retry(): Promise<void> {
    await this.load(this.retryReset);
  }

  async load(reset: boolean): Promise<void> {
    if (this.session !== AuthSession.version) {
      this.cancel();
      this.source.clear();
      this.max = 0;
      this.viewAt = 0;
      this.hasMore = true;
      this.session = AuthSession.version;
      reset = true;
    }
    if (this.loading || (!reset && !this.hasMore)) return;
    const request: number = this.epoch.next();
    const session: number = this.session;
    this.loading = true;
    this.error = '';
    this.retryReset = reset;
    try {
      const result: ApiResult<HistoryPageData> = await HistoryApi.getHistory(reset ? 0 : this.max, reset ? 0 : this.viewAt);
      if (!this.epoch.isCurrent(request) || session !== AuthSession.version) return;
      if (!result.ok || result.data === null) {
        this.error = result.message;
        return;
      }
      const data: HistoryPageData = result.data;
      const keys: Set<string> = new Set<string>();
      if (!reset) {
        this.source.getAll().forEach((item: HistoryVideoItem) => keys.add(item.video.bvid + ':' + String(item.viewAt)));
      }
      const fresh: Array<HistoryVideoItem> = [];
      data.items.forEach((item: HistoryVideoItem) => {
        const key: string = item.video.bvid + ':' + String(item.viewAt);
        if (!keys.has(key)) {
          keys.add(key);
          fresh.push(item);
        }
      });
      if (reset) this.source.reset(fresh);
      else this.source.append(fresh);
      this.max = data.max;
      this.viewAt = data.viewAt;
      this.hasMore = data.hasMore;
    } catch (e) {
      if (this.epoch.isCurrent(request) && session === AuthSession.version) this.error = '历史记录加载失败，请重试';
    } finally {
      if (this.epoch.isCurrent(request)) this.loading = false;
    }
  }
}
