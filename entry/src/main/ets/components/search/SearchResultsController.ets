import { RequestEpoch } from '../../common/RequestEpoch';
import { SearchAllSection } from '../../model/Models';
import { SearchCategory, SearchQuery } from './SearchQuery';
import { SearchPageResult, SearchResultsStore } from './SearchResultsStore';

class SearchCategoryState {
  queryKey: string = '';
  loaded: boolean = false;
  page: number = 1;
  hasMore: boolean = true;
  error: string = '';
  moreError: string = '';
}

/** 每次发布新实例，页面无需依赖控制器内部字段的深层观察。 */
export class SearchResultsView {
  keyword: string = '';
  tab: SearchCategory = SearchCategory.All;
  searching: boolean = false;
  loading: boolean = false;
  loadingMore: boolean = false;
  hasMore: boolean = true;
  error: string = '';
  moreError: string = '';
  totals: Array<number> = [-1, -1, -1, -1, -1, -1, -1];
  sections: Array<SearchAllSection> = [];
}

/** 查询提交、分类缓存与异步分页的单一所有者；不依赖 ArkUI、导航或输入法。 */
export class SearchResultsController {
  readonly store: SearchResultsStore = new SearchResultsStore();
  view: SearchResultsView = new SearchResultsView();
  onChange: (view: SearchResultsView) => void = (): void => {};
  private keyword: string = '';
  private tab: SearchCategory = SearchCategory.All;
  private query: SearchQuery = new SearchQuery();
  private categories: Map<SearchCategory, SearchCategoryState> = new Map<SearchCategory, SearchCategoryState>();
  private requests: RequestEpoch = new RequestEpoch();
  private inflight: boolean = false;
  private disposed: boolean = false;

  activate(): void {
    this.disposed = false;
    this.publish();
  }

  dispose(): void {
    this.disposed = true;
    this.requests.invalidate();
    this.inflight = false;
  }

  clear(): void {
    this.requests.invalidate();
    this.inflight = false;
    this.keyword = '';
    this.categories.clear();
    this.store.clear();
    this.publish();
  }

  async submit(keyword: string, query: SearchQuery): Promise<void> {
    if (this.disposed || keyword.trim().length === 0) return;
    this.keyword = keyword.trim();
    this.query = query.copy();
    this.tab = SearchCategory.All;
    this.categories.clear();
    this.store.clear();
    await this.search(true);
  }

  async select(tab: SearchCategory, query: SearchQuery): Promise<void> {
    if (this.disposed || this.tab === tab) return;
    this.requests.invalidate();
    this.inflight = false;
    this.tab = tab;
    this.query = query.copy();
    const state: SearchCategoryState = this.category();
    this.publish();
    if (!state.loaded && state.error.length === 0) await this.search(true);
  }

  async refresh(query: SearchQuery): Promise<void> {
    this.query = query.copy();
    await this.search(true);
  }

  async loadMore(retry: boolean = false): Promise<void> {
    const state: SearchCategoryState = this.category();
    if (!state.loaded || !state.hasMore || (!retry && state.moreError.length > 0)) return;
    await this.search(false);
  }

  private category(): SearchCategoryState {
    const key: string = this.query.key(this.keyword, this.tab);
    const cached: SearchCategoryState | undefined = this.categories.get(this.tab);
    if (cached !== undefined && cached.queryKey === key) return cached;
    const state: SearchCategoryState = new SearchCategoryState();
    state.queryKey = key;
    this.categories.set(this.tab, state);
    return state;
  }

  private async search(reset: boolean): Promise<void> {
    if (this.disposed || this.keyword.length === 0 || (!reset && this.inflight)) return;
    const state: SearchCategoryState = this.category();
    const request: number = this.requests.next();
    const tab: SearchCategory = this.tab;
    const page: number = reset ? 1 : state.page;
    this.inflight = true;
    state.error = '';
    state.moreError = '';
    this.publish(reset, !reset);
    try {
      const result: SearchPageResult = await SearchPageResult.fetch(this.keyword, tab, page, this.query.copy());
      if (!this.current(request)) return;
      state.hasMore = this.store.apply(tab, result, reset);
      state.page = page + 1;
      state.loaded = true;
    } catch (error) {
      if (this.current(request)) {
        const message: string = error instanceof Error ? error.message : '搜索失败，请重试';
        if (reset) state.error = message;
        else state.moreError = message;
      }
    } finally {
      if (this.current(request)) {
        this.inflight = false;
        this.publish();
      }
    }
  }

  private current(request: number): boolean {
    return !this.disposed && this.requests.isCurrent(request);
  }

  private publish(loading: boolean = false, loadingMore: boolean = false): void {
    if (this.disposed) return;
    const state: SearchCategoryState = this.category();
    const view: SearchResultsView = new SearchResultsView();
    view.keyword = this.keyword;
    view.tab = this.tab;
    view.searching = this.keyword.length > 0;
    view.loading = loading;
    view.loadingMore = loadingMore;
    view.hasMore = state.hasMore;
    view.error = state.error;
    view.moreError = state.moreError;
    view.totals = this.store.totals.slice();
    view.sections = this.store.sections;
    this.view = view;
    this.onChange(view);
  }
}
