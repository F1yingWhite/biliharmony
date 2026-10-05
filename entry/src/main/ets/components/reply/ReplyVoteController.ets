import { ReplyVoteApi } from '../../api/ReplyVoteApi';
import { ReplyVoteCard, ReplyVoteOption, ReplyVoteSource, ReplyVoteResult } from '../../model/reply/ReplyVoteModels';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';

export class ReplyVoteState {
  detail: ReplyVoteCard | null = null;
  loading: boolean = false;
  submitting: boolean = false;
  resultsVisible: boolean = false;
  message: string = '';
  selectedOptionIds: Array<number> = [];
}

export interface ReplyVoteHost {
  isDestroyed: () => boolean;
  getSource: () => ReplyVoteSource;
  getVote: () => ReplyVoteCard | null;
  applyState: (state: ReplyVoteState) => void;
  toast: (message: string) => void;
}

/** A reusable comment card owns its source, account and every asynchronous vote result. */
export class ReplyVoteController {
  private readonly host: ReplyVoteHost;
  private source: ReplyVoteSource = { oid: 0, type: 0, rpid: 0, sourceKey: '' };
  private card: ReplyVoteCard | null = null;
  private active: boolean = false;
  private generation: number = 0;
  private account: number = AuthSession.version;
  private detail: ReplyVoteCard | null = null;
  private selected: Array<number> = [];
  private confirmed: boolean = false;
  private confirmedIds: Array<number> = [];
  private loaded: boolean = false;
  private loading: boolean = false;
  private submitting: boolean = false;
  private resultsVisible: boolean = false;
  private message: string = '';

  constructor(host: ReplyVoteHost) {
    this.host = host;
  }

  bind(source: ReplyVoteSource, card: ReplyVoteCard | null): void {
    this.syncAccount();
    if (this.active && card !== null && this.sameSource(source) && this.sameCard(card)) {
      // Repeated LazyForEach model snapshots must not overwrite a confirmed choice or an in-flight draft.
      this.card = card.clone();
      this.publish();
      return;
    }
    ++this.generation;
    this.account = AuthSession.version;
    this.clearData();
    this.source = { oid: source.oid, type: source.type, rpid: source.rpid, sourceKey: source.sourceKey };
    this.card = card === null ? null : card.clone();
    this.active = this.validSource(source) && card !== null && this.validCard(card);
    this.publish();
  }

  dispose(): void {
    ++this.generation;
    this.active = false;
    this.card = null;
    this.clearData();
    this.publish();
  }

  /** Watchers run after credentials finish changing, even if an earlier action saw the new epoch. */
  onAccountChanged(): void {
    this.resetAccount();
    this.publish();
    this.load();
  }

  private resetAccount(): void {
    ++this.generation;
    this.account = AuthSession.version;
    this.clearData();
  }

  private syncAccount(): boolean {
    if (this.account === AuthSession.version) return false;
    this.resetAccount();
    return true;
  }

  private clearData(): void {
    this.detail = null;
    this.selected = [];
    this.confirmed = false;
    this.confirmedIds = [];
    this.loaded = false;
    this.loading = false;
    this.submitting = false;
    this.resultsVisible = false;
    this.message = '';
  }

  async load(force: boolean = false): Promise<void> {
    if (this.syncAccount()) this.publish();
    if (!this.bindingCurrent() || this.card === null || this.loading || this.submitting || (this.loaded && !force)) return;
    const generation: number = this.generation;
    const account: number = this.account;
    const card: ReplyVoteCard = this.card.clone();
    this.loading = true;
    this.message = '';
    this.publish();
    try {
      const detail: ReplyVoteCard = await ReplyVoteApi.load(card);
      if (!this.current(generation, account)) return;
      if (!this.validDetail(detail)) throw new Error('Invalid vote detail');
      this.applyDetail(detail);
      this.loaded = true;
    } catch (_) {
      if (this.current(generation, account)) {
        this.message = this.confirmed ? '已投票，结果刷新失败，请重试' : '投票信息加载失败，请重试';
      }
    } finally {
      if (this.current(generation, account)) {
        this.loading = false;
        this.publish();
      }
    }
  }

  toggle(optionId: number): boolean {
    if (!this.actionCurrent() || !this.canChoose() || this.detail === null ||
      !Number.isSafeInteger(optionId) || optionId <= 0 ||
      !this.detail.options.some((option: ReplyVoteOption): boolean => option.id === optionId)) return false;
    const index: number = this.selected.indexOf(optionId);
    if (index >= 0) {
      this.selected = this.selected.filter((id: number): boolean => id !== optionId);
    } else if (this.selectionLimit(this.detail) === 1) {
      this.selected = [optionId];
    } else if (this.selected.length < this.selectionLimit(this.detail)) {
      this.selected = this.selected.concat([optionId]);
    } else {
      this.message = '最多选择 ' + String(this.selectionLimit(this.detail)) + ' 项';
      this.publish();
      return false;
    }
    this.message = '';
    this.publish();
    return true;
  }

  async submit(): Promise<boolean> {
    if (!this.actionCurrent() || !this.canChoose() || this.detail === null || this.card === null ||
      this.selected.length === 0 || this.selected.length > this.selectionLimit(this.detail)) return false;
    if (!UserStore.isLogin) {
      this.host.toast('请先登录后再投票');
      return false;
    }
    const generation: number = this.generation;
    const account: number = this.account;
    const source: ReplyVoteSource = {
      oid: this.source.oid, type: this.source.type, rpid: this.source.rpid, sourceKey: this.source.sourceKey,
    };
    const card: ReplyVoteCard = this.detail.clone();
    const selected: Array<number> = this.selected.slice();
    this.submitting = true;
    this.message = '';
    this.publish();
    try {
      const result: ReplyVoteResult = await ReplyVoteApi.submit(source, card, selected);
      if (!this.current(generation, account)) return false;
      if (!result.ok) {
        this.message = result.message.length > 0 ? result.message : '投票失败，请重试';
        return false;
      }
      // POST acceptance prevents another write even if the server result refresh failed or is briefly stale.
      this.confirmed = true;
      this.confirmedIds = selected.slice();
      this.selected = selected.slice();
      this.resultsVisible = true;
      if (result.card !== null && this.validDetail(result.card)) {
        this.applyDetail(result.card);
        this.loaded = true;
        this.message = '已投票';
      } else {
        const confirmed: ReplyVoteCard = card.clone();
        confirmed.selectedIds = selected.slice();
        this.detail = confirmed;
        this.loaded = false;
        this.message = '已投票，结果刷新失败，请重试';
      }
      return true;
    } catch (_) {
      if (this.current(generation, account)) this.message = '投票失败，请重试';
      return false;
    } finally {
      if (this.current(generation, account)) {
        this.submitting = false;
        this.publish();
      }
    }
  }

  async viewResults(): Promise<void> {
    if (!this.actionCurrent()) return;
    const refresh: boolean = this.resultsVisible;
    this.resultsVisible = true;
    this.publish();
    await this.load(refresh);
  }

  private actionCurrent(): boolean {
    if (this.syncAccount()) {
      this.publish();
      this.load();
      return false;
    }
    return this.bindingCurrent();
  }

  private applyDetail(value: ReplyVoteCard): void {
    const detail: ReplyVoteCard = value.clone();
    if (detail.selectedIds.length > 0) {
      this.confirmed = true;
      this.confirmedIds = detail.selectedIds.slice();
    }
    if (this.confirmed) {
      detail.selectedIds = this.confirmedIds.slice();
      this.selected = this.confirmedIds.slice();
    } else {
      this.selected = this.selected.filter((id: number): boolean =>
        detail.options.some((option: ReplyVoteOption): boolean => option.id === id)).slice(0, this.selectionLimit(detail));
    }
    this.detail = detail;
    if (this.confirmed || this.expired(detail) || this.ownVote(detail)) this.resultsVisible = true;
  }

  private canChoose(): boolean {
    return this.loaded && !this.loading && !this.submitting && !this.confirmed && this.detail !== null &&
      !this.expired(this.detail) && !this.detail.deleted && !this.ownVote(this.detail) && this.selectionLimit(this.detail) > 0 &&
      this.detail.options.length > 0;
  }

  private selectionLimit(card: ReplyVoteCard): number {
    if (!Number.isSafeInteger(card.maxSelect) || card.maxSelect < 1) return 0;
    return card.kind === 'reply' ? 1 : Math.min(card.maxSelect, card.options.length);
  }

  private expired(card: ReplyVoteCard): boolean {
    return card.ended || (Number.isFinite(card.endTime) && card.endTime > 0 && Date.now() >= card.endTime * 1000);
  }

  private ownVote(card: ReplyVoteCard): boolean {
    const mid: number = UserStore.current === null ? 0 : UserStore.current.mid;
    return mid > 0 && mid === card.publisherMid;
  }

  private validSource(source: ReplyVoteSource): boolean {
    return Number.isSafeInteger(source.oid) && source.oid > 0 && Number.isSafeInteger(source.type) && source.type > 0 &&
      Number.isSafeInteger(source.rpid) && source.rpid >= 0 && source.sourceKey.length > 0;
  }

  private validCard(card: ReplyVoteCard): boolean {
    return (card.kind === 'reply' || card.kind === 'dynamic') && ReplyVoteCard.readId(card.id).length > 0;
  }

  private validDetail(card: ReplyVoteCard): boolean {
    return this.validCard(card) && this.sameCard(card) && card.loaded;
  }

  private sameSource(source: ReplyVoteSource): boolean {
    return source.oid === this.source.oid && source.type === this.source.type && source.rpid === this.source.rpid &&
      source.sourceKey === this.source.sourceKey;
  }

  private sameCard(card: ReplyVoteCard): boolean {
    return this.card !== null && card.kind === this.card.kind && card.id === this.card.id;
  }

  private bindingCurrent(): boolean {
    const card: ReplyVoteCard | null = this.host.getVote();
    return this.active && !this.host.isDestroyed() && this.account === AuthSession.version && card !== null &&
      this.sameSource(this.host.getSource()) && this.sameCard(card);
  }

  private current(generation: number, account: number): boolean {
    return generation === this.generation && account === this.account && account === AuthSession.version && this.bindingCurrent();
  }

  private publish(): void {
    if (this.host.isDestroyed()) return;
    const state: ReplyVoteState = new ReplyVoteState();
    if (this.bindingCurrent()) {
      state.detail = this.detail === null ? null : this.detail.clone();
      state.loading = this.loading;
      state.submitting = this.submitting;
      state.resultsVisible = this.resultsVisible || (this.detail !== null && this.expired(this.detail));
      state.message = this.message;
      state.selectedOptionIds = this.selected.slice();
    }
    this.host.applyState(state);
  }
}
