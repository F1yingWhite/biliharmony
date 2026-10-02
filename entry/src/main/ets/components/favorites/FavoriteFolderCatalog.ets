import { FavoriteApi } from '../../api/FavoriteApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { FavoriteFolderItem, FavoriteFolderPageData } from '../../model/library/LibraryModels';
import { FavoriteLibrarySession, FavoriteSessionToken } from './FavoriteLibrarySession';
import { FavoritePageState } from './FavoriteLibraryState';

/** 自建收藏夹与收藏集各持有一个实例，游标、错误和请求互不覆盖。 */
export class FavoriteFolderCatalog {
  readonly source: BasicDataSource<FavoriteFolderItem> = new BasicDataSource<FavoriteFolderItem>();
  view: FavoritePageState = new FavoritePageState();
  onChange: () => void = (): void => {};
  private requests: RequestEpoch = new RequestEpoch();
  private session: FavoriteLibrarySession;
  private collected: boolean;

  constructor(session: FavoriteLibrarySession, collected: boolean) {
    this.session = session;
    this.collected = collected;
  }

  invalidate(): void {
    this.requests.invalidate();
    const view: FavoritePageState = this.view.copy();
    view.loading = false;
    this.publish(view);
  }

  clear(): void {
    this.requests.invalidate();
    this.source.clear();
    this.publish(new FavoritePageState());
  }

  async load(reset: boolean): Promise<void> {
    const session: FavoriteSessionToken | null = this.session.capture();
    if (session === null || (!reset && (this.view.loading || !this.view.hasMore))) return;
    const request: number = this.requests.next();
    const page: number = reset ? 1 : this.view.page + 1;
    const pending: FavoritePageState = this.view.copy();
    pending.loading = true;
    pending.error = '';
    this.publish(pending);
    try {
      const data: FavoriteFolderPageData = this.collected ?
        await FavoriteApi.getCollectedFolders(session.mid, page) : await FavoriteApi.getFavoriteFolders(session.mid, page);
      if (!this.current(request, session)) return;
      const seen: Set<number> = new Set<number>();
      if (!reset) this.source.getAll().forEach((folder: FavoriteFolderItem): void => { seen.add(folder.id); });
      const fresh: Array<FavoriteFolderItem> = data.folders.filter((folder: FavoriteFolderItem): boolean => {
        if (seen.has(folder.id)) return false;
        seen.add(folder.id);
        return true;
      });
      if (reset) this.source.reset(fresh);
      else this.source.append(fresh);
      const next: FavoritePageState = this.view.copy();
      next.page = page;
      next.hasMore = data.hasMore;
      this.publish(next);
    } catch (error) {
      if (this.current(request, session)) {
        const failed: FavoritePageState = this.view.copy();
        failed.error = '加载失败，请检查网络后重试';
        this.publish(failed);
      }
    } finally {
      if (this.current(request, session)) {
        const done: FavoritePageState = this.view.copy();
        done.loading = false;
        this.publish(done);
      }
    }
  }

  private current(request: number, session: FavoriteSessionToken): boolean {
    return this.requests.isCurrent(request) && this.session.current(session);
  }

  private publish(view: FavoritePageState): void {
    view.count = this.source.totalCount();
    this.view = view;
    this.onChange();
  }
}
