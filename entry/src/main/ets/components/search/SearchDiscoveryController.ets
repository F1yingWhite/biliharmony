import { RequestEpoch } from '../../common/RequestEpoch';
import { HotSearchStore } from '../../common/HotSearchStore';
import { SearchHistoryStore } from '../../common/SearchHistoryStore';
import { SearchApi } from '../../api/SearchApi';
import { HotSearchItem } from '../../model/Models';

export class SearchDiscoveryView {
  history: Array<string> = [];
  hot: Array<HotSearchItem> = [];
  trending: Array<HotSearchItem> = [];
  suggests: Array<string> = [];
}

/** 搜索前的发现数据与建议防抖。结果查询不会读取输入草稿。 */
export class SearchDiscoveryController {
  view: SearchDiscoveryView = new SearchDiscoveryView();
  onChange: (view: SearchDiscoveryView) => void = (): void => {};
  onDefault: (keyword: string) => void = (): void => {};
  private lifetime: RequestEpoch = new RequestEpoch();
  private suggestions: RequestEpoch = new RequestEpoch();
  private timer: number = -1;
  private disposed: boolean = false;
  private historyRevision: number = 0;

  async activate(): Promise<void> {
    this.disposed = false;
    const request: number = this.lifetime.next();
    const historyRevision: number = this.historyRevision;
    this.loadHot(request).catch(() => {});
    this.loadTrending(request).catch(() => {});
    this.loadDefault(request).catch(() => {});
    const history: Array<string> = await SearchHistoryStore.ensureLoaded();
    if (!this.current(request) || this.historyRevision !== historyRevision) return;
    const next: SearchDiscoveryView = this.copy();
    next.history = history;
    this.publish(next);
  }

  dispose(): void {
    this.disposed = true;
    this.lifetime.invalidate();
    this.cancelSuggestions();
  }

  input(value: string): void {
    this.cancelSuggestions();
    const next: SearchDiscoveryView = this.copy();
    next.suggests = [];
    this.publish(next);
    if (this.disposed || value.trim().length === 0) return;
    const request: number = this.suggestions.next();
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.fetchSuggestions(value, request).catch(() => {});
    }, 300);
  }

  submit(keyword: string): void {
    this.cancelSuggestions();
    this.historyRevision++;
    const next: SearchDiscoveryView = this.copy();
    next.suggests = [];
    next.history = SearchHistoryStore.add(keyword);
    this.publish(next);
  }

  removeHistory(keyword: string): void {
    this.historyRevision++;
    const next: SearchDiscoveryView = this.copy();
    next.history = SearchHistoryStore.remove(keyword);
    this.publish(next);
  }

  clearHistory(): void {
    this.historyRevision++;
    SearchHistoryStore.clear();
    const next: SearchDiscoveryView = this.copy();
    next.history = [];
    this.publish(next);
  }

  private cancelSuggestions(): void {
    this.suggestions.invalidate();
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
  }

  private async fetchSuggestions(value: string, request: number): Promise<void> {
    const suggests: Array<string> = await SearchApi.searchSuggest(value);
    if (this.disposed || !this.suggestions.isCurrent(request)) return;
    const next: SearchDiscoveryView = this.copy();
    next.suggests = suggests;
    this.publish(next);
  }

  private async loadHot(request: number): Promise<void> {
    const hot: Array<HotSearchItem> = await HotSearchStore.load();
    if (!this.current(request)) return;
    const next: SearchDiscoveryView = this.copy();
    next.hot = hot;
    this.publish(next);
  }

  private async loadTrending(request: number): Promise<void> {
    const trending: Array<HotSearchItem> = await SearchApi.getSearchTrending();
    if (!this.current(request)) return;
    const next: SearchDiscoveryView = this.copy();
    next.trending = trending;
    this.publish(next);
  }

  private async loadDefault(request: number): Promise<void> {
    const keyword: string = await SearchApi.getSearchDefault();
    if (this.current(request) && keyword.length > 0) this.onDefault(keyword);
  }

  private current(request: number): boolean {
    return !this.disposed && this.lifetime.isCurrent(request);
  }

  private copy(): SearchDiscoveryView {
    const next: SearchDiscoveryView = new SearchDiscoveryView();
    next.history = this.view.history;
    next.hot = this.view.hot;
    next.trending = this.view.trending;
    next.suggests = this.view.suggests;
    return next;
  }

  private publish(next: SearchDiscoveryView): void {
    if (this.disposed) return;
    this.view = next;
    this.onChange(next);
  }
}
