import { CommentApi } from '../../api/CommentApi';
import { CommentLog } from '../../common/CommentLog';
import { RequestEpoch } from '../../common/RequestEpoch';
import { ReplyData, ReplyItem } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';
import { ReplyRevisionClock, ReplyScope, ReplySubject, ThreadRepliesState,
  mergeUniqueReplies, sameReplySubject } from './ReplyState';

export interface ReplyThreadHost extends ReplyScope {
  publish: (state: ThreadRepliesState) => void;
  onError?: () => void;
}

/** 根楼层、打开会话、分页与预取共同归属；关闭后再打开同一 root 也是新会话。 */
export class ReplyThreadSession {
  private readonly host: ReplyThreadHost;
  private readonly clock: ReplyRevisionClock;
  private readonly video: boolean;
  private state: ThreadRepliesState = new ThreadRepliesState();
  private epoch: RequestEpoch = new RequestEpoch();
  private subject: ReplySubject = { oid: 0, type: 0 };
  private account: number = -1;
  private cursor: string = '';
  private prefetchCount: number = 0;
  private localSent: Array<ReplyItem> = [];

  constructor(host: ReplyThreadHost, clock: ReplyRevisionClock, video: boolean) {
    this.host = host;
    this.clock = clock;
    this.video = video;
  }

  get root(): ReplyItem { return this.state.root; }
  get replies(): Array<ReplyItem> { return this.state.replies; }

  begin(root: ReplyItem, replies: Array<ReplyItem>): void {
    this.epoch.invalidate();
    const subject: ReplySubject = this.host.getSubject();
    this.subject = { oid: subject.oid, type: subject.type };
    this.account = AuthSession.version;
    this.state.root = root;
    this.state.replies = this.video ? mergeUniqueReplies([], replies) : replies.slice();
    this.state.active = true;
    this.state.loading = false;
    this.prefetchCount = 0;
    this.localSent = [];
    this.resetPaging();
  }

  async load(reset: boolean, allowPrefetch: boolean = true): Promise<void> {
    if (this.host.isDestroyed() || !this.state.active || this.subject.oid <= 0 || this.subject.type <= 0 ||
      this.state.root.rpid <= 0 || this.account !== AuthSession.version ||
      !sameReplySubject(this.subject, this.host.getSubject())) return;
    if (!reset && (this.state.loading || !this.state.hasMore)) {
      this.log('skip', 'root=' + String(this.root.rpid) + ' reset=' + String(reset) +
        ' loading=' + String(this.state.loading) + ' hasMore=' + String(this.state.hasMore));
      return;
    }
    const request: number = this.epoch.next();
    const root: number = this.root.rpid;
    const subject: ReplySubject = { oid: this.subject.oid, type: this.subject.type };
    const account: number = this.account;
    const cursor: string = reset ? '' : this.cursor;
    const before: number = this.replies.length;
    const startedAt: number = Date.now();
    this.state.loading = true;
    this.publish();
    this.log('start', 'aid=' + String(subject.oid) + ' root=' + String(root) + ' reset=' + String(reset) +
      ' cursorLen=' + String(cursor.length) + ' before=' + String(before));
    let loaded: boolean = false;
    try {
      const data: ReplyData = await CommentApi.getReplyReplies(subject.oid, subject.type, root, cursor);
      if (!this.isCurrent(request, root, subject, account)) return;
      const incoming: Array<ReplyItem> = this.clock.stamp(data.replies);
      const serverIds: Set<number> = new Set<number>(incoming.map((item: ReplyItem) => item.rpid));
      this.localSent = this.localSent.filter((item: ReplyItem) => !serverIds.has(item.rpid));
      this.state.replies = this.video ? mergeUniqueReplies(this.replies, incoming) :
        (reset ? (incoming.length > 0 ? incoming : this.replies) : this.replies.concat(incoming));
      if (!this.video && this.localSent.length > 0) {
        this.state.replies = mergeUniqueReplies(this.localSent, this.state.replies);
      }
      this.cursor = data.cursor;
      this.state.hasMore = data.hasMore;
      loaded = true;
      this.log('done', 'root=' + String(root) + ' reset=' + String(reset) + ' incoming=' + String(incoming.length) +
        ' before=' + String(before) + ' total=' + String(this.replies.length) + ' cursorLen=' +
        String(this.cursor.length) + ' hasMore=' + String(data.hasMore) + ' ms=' + String(CommentLog.elapsed(startedAt)));
    } catch (e) {
      if (!this.isCurrent(request, root, subject, account)) return;
      if (this.video) CommentLog.error('ui.thread.error', 'root=' + String(root) + ' reset=' + String(reset) +
        ' ms=' + String(CommentLog.elapsed(startedAt)) + ' error=' + CommentLog.errorText(e as Object));
      this.host.onError?.();
    } finally {
      if (this.isCurrent(request, root, subject, account)) { this.state.loading = false; this.publish(); }
    }
    if (!loaded || !this.isCurrent(request, root, subject, account)) return;
    const target: number = Math.min(20, Math.max(1, this.root.count));
    if (this.video && allowPrefetch && this.state.hasMore && this.replies.length < target && this.prefetchCount < 5) {
      this.prefetchCount++;
      this.log('prefetch', 'root=' + String(root) + ' attempt=' + String(this.prefetchCount) +
        ' total=' + String(this.replies.length) + ' target=' + String(target));
      await this.load(false);
    }
  }

  cancel(): void {
    this.epoch.invalidate();
    this.state.active = false;
    this.state.loading = false;
    this.publish();
  }

  updateRoot(root: ReplyItem): void {
    if (root.rpid !== this.root.rpid) this.cancel();
    this.state.root = root;
    this.publish();
  }

  replace(root: ReplyItem, replies: Array<ReplyItem>): void {
    if (root.rpid !== this.root.rpid) return;
    this.state.root = root;
    this.state.replies = replies.slice();
    this.localSent = this.localSent.map((item: ReplyItem) =>
      replies.find((current: ReplyItem) => current.rpid === item.rpid) ?? item);
    this.publish();
  }

  rememberSent(item: ReplyItem): void {
    this.localSent = [item].concat(this.localSent.filter((current: ReplyItem) => current.rpid !== item.rpid));
  }

  resetPaging(): void {
    this.cursor = '';
    this.state.hasMore = true;
    this.publish();
  }

  clearReplies(): void {
    this.state.replies = [];
    this.resetPaging();
  }

  remove(rpid: number, descendants: boolean = false): void {
    const blocked: Set<number> = new Set<number>([rpid]);
    if (descendants) {
      let changed: boolean = true;
      while (changed) {
        changed = false;
        for (let i: number = 0; i < this.replies.length; i++) {
          const item: ReplyItem = this.replies[i];
          if (!blocked.has(item.rpid) && (blocked.has(item.parentRpid) || blocked.has(item.rootRpid))) {
            blocked.add(item.rpid);
            changed = true;
          }
        }
      }
    }
    this.state.replies = this.replies.filter((item: ReplyItem) => !blocked.has(item.rpid));
    this.localSent = this.localSent.filter((item: ReplyItem) => !blocked.has(item.rpid));
    this.publish();
  }

  publish(): void {
    if (this.host.isDestroyed()) return;
    const state: ThreadRepliesState = new ThreadRepliesState();
    state.root = this.root;
    state.replies = this.replies.slice();
    state.active = this.state.active;
    state.loading = this.state.loading;
    state.hasMore = this.state.hasMore;
    state.version = this.clock.version;
    this.host.publish(state);
  }

  private isCurrent(request: number, root: number, subject: ReplySubject, account: number): boolean {
    return !this.host.isDestroyed() && this.state.active && this.epoch.isCurrent(request) && root === this.root.rpid &&
      account === AuthSession.version && sameReplySubject(subject, this.host.getSubject());
  }

  private log(event: string, details: string): void {
    if (!this.video) return;
    if (event === 'skip') CommentLog.warn('ui.thread.' + event, details);
    else CommentLog.info('ui.thread.' + event, details);
  }
}
