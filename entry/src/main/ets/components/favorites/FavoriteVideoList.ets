import { FavoriteApi } from '../../api/FavoriteApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { FavoriteFolderItem, FavoriteVideoPageData } from '../../model/library/LibraryModels';
import { VideoItem } from '../../model/video/VideoModels';
import { FavoriteLibrarySession, FavoriteSessionToken } from './FavoriteLibrarySession';
import { FavoritePageState, copyFavoriteFolder } from './FavoriteLibraryState';

export class FavoriteVideoList {
  readonly source: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  selected: FavoriteFolderItem = new FavoriteFolderItem();
  view: FavoritePageState = new FavoritePageState();
  onChange: () => void = (): void => {};
  canLoad: () => boolean = (): boolean => true;
  private session: FavoriteLibrarySession;
  private requests: RequestEpoch = new RequestEpoch();
  private refreshBeforePaging: boolean = false;

  constructor(session: FavoriteLibrarySession) { this.session = session; }

  invalidate(): void {
    this.requests.invalidate();
    const view: FavoritePageState = this.view.copy();
    view.loading = false;
    this.publish(view);
  }

  clear(): void {
    this.requests.invalidate();
    this.selected = new FavoriteFolderItem();
    this.source.clear();
    this.refreshBeforePaging = false;
    this.publish(new FavoritePageState());
  }

  async open(folder: FavoriteFolderItem, collected: boolean): Promise<void> {
    this.clear();
    this.selected = copyFavoriteFolder(folder);
    if (collected && this.selected.type === 0) this.selected.type = 21;
    await this.load(true);
  }

  async load(reset: boolean): Promise<void> {
    const session: FavoriteSessionToken | null = this.session.capture();
    if (session === null || this.selected.id <= 0 || !this.canLoad() ||
      (!reset && (this.view.loading || !this.view.hasMore))) return;
    const replace: boolean = reset || this.refreshBeforePaging;
    const page: number = replace ? 1 : this.view.page + 1;
    const folderId: number = this.selected.id;
    const folderType: number = this.selected.type;
    const request: number = this.requests.next();
    const pending: FavoritePageState = this.view.copy();
    pending.loading = true;
    pending.error = '';
    this.publish(pending);
    try {
      const data: FavoriteVideoPageData = folderType === 21 ?
        await FavoriteApi.getCollectionVideos(folderId, page) : await FavoriteApi.getFavoriteVideos(folderId, page);
      if (!this.current(request, session)) return;
      const seen: Set<number> = new Set<number>();
      if (!replace) this.source.getAll().forEach((video: VideoItem): void => { seen.add(video.aid); });
      const fresh: Array<VideoItem> = data.videos.filter((video: VideoItem): boolean => {
        if (seen.has(video.aid)) return false;
        seen.add(video.aid);
        return true;
      });
      if (replace) this.source.reset(fresh);
      else this.source.append(fresh);
      this.refreshBeforePaging = false;
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

  remove(aids: Array<number>): void {
    this.invalidate();
    const removed: Set<number> = new Set<number>(aids);
    for (let index: number = this.source.totalCount() - 1; index >= 0; index--) {
      if (removed.has(this.source.getData(index).aid)) this.source.removeAt(index);
    }
    // 删除会改变服务端页边界。下次继续加载先重新对齐第一页，避免跳过前移的视频。
    this.refreshBeforePaging = this.view.hasMore;
    this.publish(this.view.copy());
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
