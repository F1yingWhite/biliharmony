import { VideoInteractionApi } from '../../api/VideoInteractionApi';
import { ActionResult } from '../../api/internal/ApiCommon';
import { VideoInteractionCard, VideoInteractionLink, VideoInteractionOption,
  VideoInteractionSource } from '../../model/video/VideoInteractionModels';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';

const INTERACTION_RETRY_MS: number = 5000;

/** A new state object and card reference let the view publish confirmed choices reactively. */
export class PlayerInteractionState {
  current: VideoInteractionCard | null = null;
  loading: boolean = false;
  submitting: boolean = false;
  message: string = '';
}

export interface PlayerInteractionHost {
  isDestroyed: () => boolean;
  getPlayhead: () => number;
  applyState: (state: PlayerInteractionState) => void;
  toast: (message: string) => void;
  openVideo: (target: VideoInteractionLink) => void;
}

/** Timed command cards; source, account and settings changes own every asynchronous completion. */
export class PlayerInteractionController {
  private readonly host: PlayerInteractionHost;
  private source: VideoInteractionSource = { aid: 0, bvid: '', cid: 0, duration: 0 };
  private active: boolean = false;
  private enabled: boolean = true;
  private generation: number = 0;
  private account: number = AuthSession.version;
  private cards: Array<VideoInteractionCard> = [];
  private loaded: boolean = false;
  private loading: boolean = false;
  private loadAttempted: boolean = false;
  private retryAfter: number = 0;
  private time: number = 0;
  private loadMessage: string = '';
  private readonly submitting: Set<string> = new Set<string>();
  private readonly messages: Map<string, string> = new Map<string, string>();
  private readonly dismissed: Set<string> = new Set<string>();
  private published: PlayerInteractionState | null = null;

  constructor(host: PlayerInteractionHost) {
    this.host = host;
  }

  bind(source: VideoInteractionSource): void {
    if (this.active && source.aid === this.source.aid && source.bvid === this.source.bvid &&
      source.cid === this.source.cid) {
      this.source.duration = source.duration;
      return;
    }
    this.invalidate();
    this.source = { aid: source.aid, bvid: source.bvid, cid: source.cid, duration: source.duration };
    this.active = source.cid > 0;
    this.time = this.playhead();
    this.publish();
  }

  invalidate(): void {
    ++this.generation;
    this.active = false;
    this.account = AuthSession.version;
    this.clearAccountData();
    this.publish();
  }

  private clearAccountData(): void {
    this.cards = [];
    this.loaded = false;
    this.loading = false;
    this.loadAttempted = false;
    this.retryAfter = 0;
    this.loadMessage = '';
    this.submitting.clear();
    this.messages.clear();
    this.dismissed.clear();
  }

  /** Login watchers call this immediately; progress and actions also check the session themselves. */
  onAccountChanged(): void {
    // The login watcher also runs after credentials have finished changing, possibly within the same epoch.
    this.resetAccount();
    this.time = this.playhead();
    this.publish();
    if (this.active && this.enabled && !this.host.isDestroyed()) this.load();
  }

  private syncAccount(): boolean {
    if (this.account === AuthSession.version) return false;
    this.resetAccount();
    return true;
  }

  private resetAccount(): void {
    ++this.generation;
    this.account = AuthSession.version;
    this.clearAccountData();
  }

  setEnabled(enabled: boolean): void {
    if (this.enabled === enabled) return;
    ++this.generation;
    this.enabled = enabled;
    // A request already sent may still reach the server. Re-read before another submission.
    if (this.submitting.size > 0 || this.loading) this.loaded = false;
    this.loading = false;
    this.submitting.clear();
    this.loadMessage = '';
    this.messages.clear();
    this.retryAfter = 0;
    this.time = this.playhead();
    this.syncAccount();
    this.publish();
    if (enabled && this.active && !this.loaded && !this.host.isDestroyed()) this.load();
  }

  async load(): Promise<void> {
    this.syncAccount();
    if (!this.active || !this.enabled || this.host.isDestroyed() || this.loading || this.loaded || this.retryAfter > Date.now()) return;
    const generation: number = this.generation;
    const account: number = this.account;
    const source: VideoInteractionSource = {
      aid: this.source.aid, bvid: this.source.bvid, cid: this.source.cid, duration: this.source.duration,
    };
    this.loading = true;
    this.loadAttempted = true;
    this.loadMessage = '';
    this.publish();
    try {
      const cards: Array<VideoInteractionCard> = await VideoInteractionApi.load(source);
      if (!this.current(generation, account)) return;
      const seen: Set<string> = new Set<string>();
      this.cards = cards.filter((card: VideoInteractionCard): boolean => {
        if (seen.has(card.id) || !this.supported(card)) return false;
        seen.add(card.id);
        return true;
      }).map((card: VideoInteractionCard): VideoInteractionCard => card.clone())
        .sort((a: VideoInteractionCard, b: VideoInteractionCard): number => a.start - b.start);
      this.loaded = true;
      this.time = this.playhead();
    } catch (_) {
      if (this.current(generation, account)) {
        this.loadMessage = '互动信息加载失败，请稍后重试';
        this.retryAfter = Date.now() + INTERACTION_RETRY_MS;
      }
    } finally {
      if (this.current(generation, account)) {
        this.loading = false;
        this.publish();
      }
    }
  }

  update(seconds: number): void {
    const accountChanged: boolean = this.syncAccount();
    if (!Number.isFinite(seconds) || seconds < 0) {
      if (accountChanged) this.publish();
      if (accountChanged && this.active && this.enabled && !this.host.isDestroyed()) this.load();
      return;
    }
    if (seconds < this.time - 0.5) this.dismissed.clear();
    this.time = seconds;
    for (const card of this.cards) {
      if (seconds < card.start || seconds >= card.end) this.dismissed.delete(card.id);
    }
    this.publish();
    if (this.active && this.enabled && !this.host.isDestroyed() &&
      (accountChanged || (this.loadAttempted && !this.loaded && !this.loading && this.retryAfter <= Date.now()))) this.load();
  }

  resetForReplay(): void {
    this.dismissed.clear();
    this.update(this.playhead());
  }

  dismiss(id: string): void {
    const card: VideoInteractionCard | null = this.actionCard(id);
    if (card === null) return;
    this.dismissed.add(id);
    this.publish();
  }

  async submitGrade(id: string, stars: number): Promise<boolean> {
    const card: VideoInteractionCard | null = this.actionCard(id);
    if (card === null || card.kind !== 'grade' || card.gradeId.length === 0 ||
      !Number.isInteger(stars) || stars < 1 || stars > card.maxStars || card.selectedStars > 0) return false;
    return this.submit(card, stars, true);
  }

  async submitVote(id: string, optionId: number): Promise<boolean> {
    const card: VideoInteractionCard | null = this.actionCard(id);
    if (card === null || card.kind !== 'vote' || card.voteId.length === 0 || card.selectedOptionId > 0 ||
      !Number.isInteger(optionId) || optionId <= 0) return false;
    const option: VideoInteractionOption | undefined = card.options.find((item: VideoInteractionOption): boolean => item.id === optionId);
    if (option === undefined || option.hasSelfDef) return false;
    return this.submit(card, optionId, false);
  }

  private async submit(card: VideoInteractionCard, selection: number, grade: boolean): Promise<boolean> {
    if (this.submitting.has(card.id) || !this.loaded || this.loading) return false;
    if (!UserStore.isLogin) {
      this.host.toast('请先登录后再参与互动');
      return false;
    }
    const generation: number = this.generation;
    const account: number = this.account;
    this.submitting.add(card.id);
    this.messages.delete(card.id);
    this.publish();
    try {
      const result: ActionResult = grade ?
        await VideoInteractionApi.submitGrade(this.source, card, selection, this.time) :
        await VideoInteractionApi.submitVote(this.source, card, selection, this.time);
      if (!this.current(generation, account)) return false;
      if (!result.ok) {
        this.messages.set(card.id, result.message.length > 0 ? result.message : '提交失败，请稍后重试');
        return false;
      }
      const confirmed: VideoInteractionCard = card.clone();
      if (grade) {
        confirmed.selectedStars = selection;
        confirmed.averageScore = (card.averageScore * card.count + selection * 2) / (card.count + 1);
        confirmed.count = card.count + 1;
      } else {
        confirmed.selectedOptionId = selection;
        for (const option of confirmed.options) {
          if (option.id === selection) option.votes++;
        }
      }
      this.cards = this.cards.map((item: VideoInteractionCard): VideoInteractionCard => item.id === card.id ? confirmed : item);
      this.messages.set(card.id, grade ? '已评分' : '已投票');
      return true;
    } catch (_) {
      if (this.current(generation, account)) this.messages.set(card.id, '提交失败，请稍后重试');
      return false;
    } finally {
      if (this.current(generation, account)) {
        this.submitting.delete(card.id);
        this.publish();
      }
    }
  }

  openLink(id: string): void {
    const card: VideoInteractionCard | null = this.actionCard(id);
    if (card === null || card.kind !== 'link' || card.link === null ||
      (card.link.aid <= 0 && card.link.bvid.length === 0 && card.link.epId <= 0)) return;
    this.host.openVideo(card.link);
  }

  private actionCard(id: string): VideoInteractionCard | null {
    if (this.syncAccount()) {
      this.time = this.playhead();
      this.publish();
      if (this.active && this.enabled && !this.host.isDestroyed()) this.load();
      return null;
    }
    this.time = this.playhead();
    const card: VideoInteractionCard | null = this.choose();
    return card !== null && card.id === id ? card : null;
  }

  private playhead(): number {
    const seconds: number = this.host.getPlayhead();
    return Number.isFinite(seconds) && seconds >= 0 ? seconds : 0;
  }

  private supported(card: VideoInteractionCard): boolean {
    return card.id.length > 0 && (card.kind === 'grade' || card.kind === 'vote' || card.kind === 'link') &&
      Number.isFinite(card.start) && Number.isFinite(card.end) && card.start >= 0 && card.end > card.start &&
      (this.source.duration <= 0 || card.start < this.source.duration);
  }

  private current(generation: number, account: number): boolean {
    return this.active && this.enabled && !this.host.isDestroyed() && generation === this.generation &&
      account === this.account && account === AuthSession.version;
  }

  private choose(): VideoInteractionCard | null {
    if (!this.active || !this.enabled || this.host.isDestroyed() || this.account !== AuthSession.version) return null;
    for (const card of this.cards) {
      if (this.time >= card.start && this.time < card.end &&
        (this.source.duration <= 0 || this.time < this.source.duration) && !this.dismissed.has(card.id)) return card;
    }
    return null;
  }

  private publish(): void {
    if (this.host.isDestroyed()) return;
    const state: PlayerInteractionState = new PlayerInteractionState();
    state.current = this.choose();
    state.loading = this.active && this.enabled && this.loading;
    state.submitting = state.current !== null && this.submitting.has(state.current.id);
    state.message = !this.active || !this.enabled ? '' : state.current !== null ?
      (this.messages.get(state.current.id) ?? this.loadMessage) : this.loadMessage;
    if (this.published !== null && state.current === this.published.current && state.loading === this.published.loading &&
      state.submitting === this.published.submitting && state.message === this.published.message) return;
    this.published = state;
    this.host.applyState(state);
  }
}
