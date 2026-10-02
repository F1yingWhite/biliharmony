import { YouTubeApi, YouTubeSearchFilterGroup, YouTubeSearchPage, YouTubeVideo } from '../../api/YouTubeApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { YouTubeThumbnailCache } from './YouTubeThumbnailCache';

export class YouTubeSearchState {
  searched: string = '';
  loading: boolean = false;
  loadingMore: boolean = false;
  error: string = '';
  moreError: string = '';
  continuation: string = '';
  count: number = 0;
  filterGroups: Array<YouTubeSearchFilterGroup> = [];
  filterLabel: string = '';
  filterParams: string = '';
}

export class YouTubeSearchController {
  readonly source: BasicDataSource<YouTubeVideo> = new BasicDataSource<YouTubeVideo>();
  readonly thumbnails: YouTubeThumbnailCache = new YouTubeThumbnailCache((url: string): void => {
    const videos: Array<YouTubeVideo> = this.source.getAll();
    for (let i: number = 0; i < videos.length; i++) {
      if (videos[i].thumbnail === url) this.source.updateItem(i, videos[i]);
    }
  });
  private state: YouTubeSearchState = new YouTubeSearchState();
  private requests: RequestEpoch = new RequestEpoch();
  private active: boolean = true;
  private readonly publish: (state: YouTubeSearchState) => void;

  constructor(publish: (state: YouTubeSearchState) => void) { this.publish = publish; }

  activate(): void {
    this.active = true;
    this.thumbnails.prime(this.source.getAll().map((video: YouTubeVideo): string => video.thumbnail));
    this.emit();
  }

  dispose(): void {
    this.active = false;
    this.requests.invalidate();
    this.thumbnails.reset();
    this.state.loading = false;
    this.state.loadingMore = false;
  }

  clear(): void {
    this.requests.invalidate();
    this.state = new YouTubeSearchState();
    this.source.clear();
    this.thumbnails.reset();
    this.emit();
  }

  async search(query: string, params: string = '', label: string = ''): Promise<void> {
    if (!this.active || query.trim().length === 0) return;
    const request: number = this.requests.next();
    const groups: Array<YouTubeSearchFilterGroup> = query === this.state.searched ? this.state.filterGroups : [];
    this.state = new YouTubeSearchState();
    this.state.searched = query;
    this.state.filterParams = params;
    this.state.filterLabel = label;
    this.state.filterGroups = groups;
    this.state.loading = true;
    this.source.clear();
    this.thumbnails.reset();
    this.emit();
    try {
      const page: YouTubeSearchPage = await YouTubeApi.search(query, params);
      if (!this.current(request)) return;
      this.append(page.videos);
      this.state.continuation = page.continuation;
      if (page.filters.length > 0) this.state.filterGroups = page.filters;
    } catch (error) {
      if (this.current(request)) this.state.error = (error as Error).message || '搜索失败，请重试';
    } finally {
      if (this.current(request)) { this.state.loading = false; this.emit(); }
    }
  }

  async loadMore(retry: boolean = false): Promise<void> {
    if (!this.active || this.state.loading || this.state.loadingMore ||
      (!retry && this.state.moreError.length > 0) || this.state.continuation.length === 0) return;
    const request: number = this.requests.next();
    const token: string = this.state.continuation;
    this.state.loadingMore = true;
    this.state.moreError = '';
    this.emit();
    try {
      const page: YouTubeSearchPage = await YouTubeApi.searchMore(token);
      if (!this.current(request)) return;
      this.append(page.videos);
      // A repeated continuation cannot advance; stop instead of endlessly fetching duplicates.
      this.state.continuation = page.continuation === token ? '' : page.continuation;
    } catch (error) {
      if (this.current(request)) this.state.moreError = (error as Error).message || '加载更多失败，请重试';
    } finally {
      if (this.current(request)) { this.state.loadingMore = false; this.emit(); }
    }
  }

  private append(incoming: Array<YouTubeVideo>): void {
    const seen: Set<string> = new Set<string>();
    for (const video of this.source.getAll()) seen.add(video.id);
    const fresh: Array<YouTubeVideo> = [];
    for (const video of incoming) {
      if (video.id.length === 0 || seen.has(video.id)) continue;
      seen.add(video.id);
      fresh.push(video);
    }
    this.source.append(fresh);
    this.state.count = this.source.totalCount();
    this.thumbnails.prime(fresh.map((video: YouTubeVideo): string => video.thumbnail));
  }

  private current(request: number): boolean { return this.active && this.requests.isCurrent(request); }

  private emit(): void {
    if (!this.active) return;
    const value: YouTubeSearchState = new YouTubeSearchState();
    value.searched = this.state.searched;
    value.loading = this.state.loading;
    value.loadingMore = this.state.loadingMore;
    value.error = this.state.error;
    value.moreError = this.state.moreError;
    value.continuation = this.state.continuation;
    value.count = this.state.count;
    value.filterGroups = this.state.filterGroups.slice();
    value.filterLabel = this.state.filterLabel;
    value.filterParams = this.state.filterParams;
    this.publish(value);
  }
}
