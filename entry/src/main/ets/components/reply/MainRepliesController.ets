import { CommentApi } from '../../api/CommentApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { CommentLog } from '../../common/CommentLog';
import { RequestEpoch } from '../../common/RequestEpoch';
import { ReplyData, ReplyItem } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';
import { MainRepliesState, ReplyRevisionClock, ReplyScope, ReplySubject,
  mergeUniqueReplies, sameReplySubject, sanitizeReplies } from './ReplyState';

export interface MainRepliesHost extends ReplyScope {
  publish: (state: MainRepliesState) => void;
  afterLoaded?: () => void;
  afterSort?: () => void;
}

/** 主列表唯一写入方：排序/游标/错误/本地已发送楼层与分页都属于同一 subject 会话。 */
export class MainRepliesController {
  readonly source: BasicDataSource<ReplyItem> = new BasicDataSource<ReplyItem>();
  private readonly host: MainRepliesHost;
  private readonly clock: ReplyRevisionClock;
  private readonly clearOnSort: boolean;
  private readonly video: boolean;
  private state: MainRepliesState = new MainRepliesState();
  private epoch: RequestEpoch = new RequestEpoch();
  private subject: ReplySubject = { oid: 0, type: 0 };
  private account: number = -1;
  private localSent: Array<ReplyItem> = [];
  private prefetchCount: number = 0;
  cursor: string = '';
  retryReset: boolean = false;

  constructor(host: MainRepliesHost, clock: ReplyRevisionClock, clearOnSort: boolean, video: boolean) {
    this.host = host;
    this.clock = clock;
    this.clearOnSort = clearOnSort;
    this.video = video;
  }

  async load(reset: boolean): Promise<void> {
    if (this.host.isDestroyed()) return;
    const target: ReplySubject = this.host.getSubject();
    if (!sameReplySubject(target, this.subject) || this.account !== AuthSession.version) {
      this.clear();
      this.localSent = [];
      this.subject = { oid: target.oid, type: target.type };
      this.account = AuthSession.version;
      reset = true;
    }
    if (target.oid <= 0 || target.type <= 0 || (!reset && (this.state.loading || !this.state.hasMore))) {
      if (this.video && !reset && this.state.loading) CommentLog.warn('ui.replies.skip', 'reason=loading');
      return;
    }
    const request: number = this.epoch.next();
    const account: number = AuthSession.version;
    const subject: ReplySubject = { oid: target.oid, type: target.type };
    const cursor: string = reset ? '' : this.cursor;
    const startedAt: number = Date.now();
    const before: number = this.source.totalCount();
    if (reset) this.prefetchCount = 0;
    this.retryReset = reset;
    this.state.loading = true;
    this.state.error = '';
    this.state.moreFailed = false;
    if (reset) this.state.failed = false;
    this.publish();
    this.log('start', 'aid=' + String(subject.oid) + ' reset=' + String(reset) + ' mode=' +
      String(this.state.sort) + ' cursorLen=' + String(cursor.length) + ' before=' + String(before));
    let loaded: boolean = false;
    try {
      const data: ReplyData = await CommentApi.getReplies(subject.oid, subject.type, cursor, this.state.sort);
      if (!this.isCurrent(request, subject, account)) {
        if (this.video) CommentLog.warn('ui.replies.drop', 'reason=stale rows=' + String(data.replies.length));
        return;
      }
      const incoming: Array<ReplyItem> = this.clock.stamp(data.replies);
      if (reset) {
        if (this.video) {
          const clean: Array<ReplyItem> = sanitizeReplies(incoming, true);
          const ids: Set<number> = new Set<number>(clean.map((item: ReplyItem) => item.rpid));
          this.localSent = this.localSent.filter((item: ReplyItem) => !ids.has(item.rpid));
          this.source.reset(mergeUniqueReplies(this.localSent, clean));
        } else this.source.reset(incoming);
      } else if (this.video) {
        const clean: Array<ReplyItem> = sanitizeReplies(incoming, true);
        const ids: Set<number> = new Set<number>(this.source.getAll().map((item: ReplyItem) => item.rpid));
        const fresh: Array<ReplyItem> = clean.filter((item: ReplyItem) => !ids.has(item.rpid));
        this.source.append(fresh);
        this.log('append', 'incoming=' + String(incoming.length) + ' added=' + String(fresh.length) +
          ' duplicate=' + String(clean.length - fresh.length) + ' total=' + String(this.source.totalCount()));
      } else this.source.append(incoming);
      this.cursor = data.cursor;
      this.state.hasMore = data.hasMore;
      loaded = true;
      this.log('done', 'aid=' + String(subject.oid) + ' reset=' + String(reset) + ' incoming=' +
        String(data.replies.length) + ' before=' + String(before) + ' total=' + String(this.source.totalCount()) +
        ' cursorLen=' + String(this.cursor.length) + ' hasMore=' + String(data.hasMore) +
        ' ms=' + String(CommentLog.elapsed(startedAt)));
    } catch (e) {
      if (!this.isCurrent(request, subject, account)) return;
      this.state.error = '评论加载失败，请检查网络后重试';
      this.state.failed = this.source.totalCount() === 0;
      this.state.moreFailed = !this.state.failed;
      if (this.video) CommentLog.error('ui.replies.error', 'aid=' + String(subject.oid) + ' reset=' +
        String(reset) + ' cursorLen=' + String(cursor.length) + ' ms=' + String(CommentLog.elapsed(startedAt)) +
        ' error=' + CommentLog.errorText(e as Object));
    } finally {
      if (this.isCurrent(request, subject, account)) { this.state.loading = false; this.publish(); }
    }
    if (!loaded || !this.isCurrent(request, subject, account)) return;
    this.host.afterLoaded?.();
    if (this.video && this.state.hasMore && this.source.totalCount() < 20 && this.prefetchCount < 5) {
      this.prefetchCount++;
      this.log('prefetch', 'aid=' + String(subject.oid) + ' attempt=' + String(this.prefetchCount) +
        ' total=' + String(this.source.totalCount()) + ' cursorLen=' + String(this.cursor.length));
      await this.load(false);
    }
  }

  changeSort(sort: number): void {
    if (this.host.isDestroyed() || this.state.sort === sort) {
      this.log('sort.skip', 'current=' + String(this.state.sort) + ' requested=' + String(sort));
      return;
    }
    this.log('sort', 'aid=' + String(this.subject.oid) + ' from=' + String(this.state.sort) + ' to=' + String(sort));
    this.state.sort = sort;
    if (this.clearOnSort) this.clear();
    this.publish();
    this.host.afterSort?.();
    this.load(true).catch(() => {});
  }

  dispose(): void {
    this.epoch.invalidate();
    this.state.loading = false;
    this.publish();
  }

  resetPaging(): void {
    this.cursor = '';
    this.state.hasMore = true;
    this.publish();
  }

  clear(): void {
    this.epoch.invalidate();
    this.state.loading = false;
    this.state.error = '';
    this.state.failed = false;
    this.state.moreFailed = false;
    this.source.clear();
    this.resetPaging();
  }

  addSent(item: ReplyItem): void {
    this.localSent = [item].concat(this.localSent.filter((other: ReplyItem) => other.rpid !== item.rpid));
    this.source.reset([item].concat(this.source.getAll().filter((other: ReplyItem) => other.rpid !== item.rpid)));
    this.publish();
  }

  remove(rpid: number): void {
    this.localSent = this.localSent.filter((item: ReplyItem) => item.rpid !== rpid);
    this.source.reset(this.source.getAll().filter((item: ReplyItem) => item.rpid !== rpid));
    this.publish();
  }

  update(item: ReplyItem): void {
    this.localSent = this.localSent.map((candidate: ReplyItem) => candidate.rpid === item.rpid ? item : candidate);
    const index: number = this.source.getAll().findIndex((candidate: ReplyItem) => candidate.rpid === item.rpid);
    if (index >= 0) this.source.updateItem(index, item);
    this.publish();
  }

  publish(): void {
    if (this.host.isDestroyed()) return;
    const state: MainRepliesState = new MainRepliesState();
    state.sort = this.state.sort;
    state.loading = this.state.loading;
    state.hasMore = this.state.hasMore;
    state.count = this.source.totalCount();
    state.error = this.state.error;
    state.failed = this.state.failed;
    state.moreFailed = this.state.moreFailed;
    state.version = this.clock.version;
    this.host.publish(state);
  }

  private isCurrent(request: number, subject: ReplySubject, account: number): boolean {
    return !this.host.isDestroyed() && this.epoch.isCurrent(request) && account === AuthSession.version &&
      sameReplySubject(subject, this.host.getSubject());
  }

  private log(event: string, details: string): void {
    if (!this.video) return;
    if (event === 'sort.skip') CommentLog.warn('ui.replies.' + event, details);
    else CommentLog.info('ui.replies.' + event, details);
  }
}
