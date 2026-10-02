import { YouTubeApi } from '../../api/YouTubeApi';
import { YouTubeSearchHistoryStore } from '../../common/YouTubeSearchHistoryStore';
import { RequestEpoch } from '../../common/RequestEpoch';

export class YouTubeDiscoveryState {
  suggestions: Array<string> = [];
  history: Array<string> = [];
}

/** Input suggestions and local edits have independent generations. */
export class YouTubeDiscoveryController {
  private state: YouTubeDiscoveryState = new YouTubeDiscoveryState();
  private suggestions: RequestEpoch = new RequestEpoch();
  private history: RequestEpoch = new RequestEpoch();
  private timer: number = -1;
  private active: boolean = false;
  private submitted: string = '';
  private readonly publish: (state: YouTubeDiscoveryState) => void;

  constructor(publish: (state: YouTubeDiscoveryState) => void) { this.publish = publish; }

  async activate(): Promise<void> {
    this.active = true;
    const request: number = this.history.next();
    this.emit();
    try {
      const items: Array<string> = await YouTubeSearchHistoryStore.ensureLoaded();
      if (this.active && this.history.isCurrent(request)) { this.state.history = items; this.emit(); }
    } catch (_) {}
  }

  dispose(): void {
    this.active = false;
    this.history.invalidate();
    this.clearSuggestions();
  }

  suggest(value: string): void {
    this.clearSuggestions();
    const term: string = value.trim();
    if (!this.active || term.length === 0 || term === this.submitted) return;
    const request: number = this.suggestions.next();
    this.timer = setTimeout((): void => {
      this.timer = -1;
      YouTubeApi.suggest(term).then((items: Array<string>): void => {
        if (!this.active || !this.suggestions.isCurrent(request)) return;
        this.state.suggestions = items;
        this.emit();
      }).catch(() => {});
    }, 250);
  }

  submit(term: string, remember: boolean = true): void {
    this.submitted = term;
    this.clearSuggestions();
    if (!remember) return;
    this.history.invalidate();
    this.state.history = YouTubeSearchHistoryStore.add(term);
    this.emit();
  }

  clearHistory(): void {
    this.history.invalidate();
    YouTubeSearchHistoryStore.clear();
    this.state.history = [];
    this.emit();
  }

  removeHistory(term: string): void {
    this.history.invalidate();
    this.state.history = YouTubeSearchHistoryStore.remove(term);
    this.emit();
  }

  clearSuggestions(): void {
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
    this.suggestions.invalidate();
    this.state.suggestions = [];
    this.emit();
  }

  private emit(): void {
    if (!this.active) return;
    const value: YouTubeDiscoveryState = new YouTubeDiscoveryState();
    value.suggestions = this.state.suggestions.slice();
    value.history = this.state.history.slice();
    this.publish(value);
  }
}
