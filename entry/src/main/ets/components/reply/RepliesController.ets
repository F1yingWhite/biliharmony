import { BasicDataSource } from '../../common/BasicDataSource';
import { CommentLog } from '../../common/CommentLog';
import { mutatedReplyClone } from '../../common/ReplyMutation';
import { ReplyItem } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';
import { MainRepliesController } from './MainRepliesController';
import { ReplyThreadSession } from './ReplyThreadSession';
import { ReplyShareController } from './ReplyShareController';
import { MainRepliesState, ReplyRevisionClock, ReplyScope, ReplySubject, ThreadRepliesState, sameReplySubject } from './ReplyState';
import { SentThreadReply, mergeSentThreadReply } from './ReplySubmissionController';

/** 页面接收展示快照；列表、游标、会话及锁均由所属控制器持有。 */
export interface RepliesHost extends ReplyScope {
  publishMain: (state: MainRepliesState) => void;
  publishThread: (state: ThreadRepliesState) => void;
  afterMainLoaded?: () => void;
  onThreadError?: () => void;
  onSortApplied?: () => void;
}

export interface RepliesOptions {
  readonly clearOnSort: boolean;
  /** 视频评论清洗、发送后保留、唯一楼层合并、预取与诊断日志。 */
  readonly video: boolean;
}

/** 三种详情页共用的评论领域入口；只编排跨主列表/线程的修改，不承载分页或导出流程。 */
export class RepliesController {
  readonly main: MainRepliesController;
  readonly thread: ReplyThreadSession;
  readonly sharing: ReplyShareController;
  private readonly clock: ReplyRevisionClock;
  private readonly video: boolean;
  private readonly scope: ReplyScope;
  private lifetime: number = 0;

  constructor(host: RepliesHost, options: RepliesOptions, sharing: ReplyShareController) {
    this.video = options.video;
    this.scope = { isDestroyed: host.isDestroyed, getSubject: host.getSubject };
    this.sharing = sharing;
    this.clock = new ReplyRevisionClock((): Array<ReplyItem> =>
      this.main.source.getAll().concat(this.thread.replies, [this.thread.root]));
    this.main = new MainRepliesController({
      isDestroyed: host.isDestroyed, getSubject: host.getSubject, publish: host.publishMain,
      afterLoaded: host.afterMainLoaded, afterSort: host.onSortApplied,
    }, this.clock, options.clearOnSort, options.video);
    this.thread = new ReplyThreadSession({
      isDestroyed: host.isDestroyed, getSubject: host.getSubject, publish: host.publishThread,
      onError: host.onThreadError,
    }, this.clock, options.video);
  }

  get source(): BasicDataSource<ReplyItem> { return this.main.source; }
  async load(reset: boolean): Promise<void> { await this.main.load(reset); }
  changeReplySort(mode: number): void { this.main.changeSort(mode); }
  async loadThread(reset: boolean, allowPrefetch: boolean = true): Promise<void> {
    await this.thread.load(reset, allowPrefetch);
  }
  beginThread(root: ReplyItem, replies: Array<ReplyItem>): void { this.thread.begin(root, replies); }
  updateThreadRoot(root: ReplyItem): void { this.thread.updateRoot(root); }
  cancelThread(): void { this.thread.cancel(); }
  resetMainPaging(): void { this.main.resetPaging(); }
  clearMainReplies(): void { this.main.clear(); }
  resetThreadPaging(): void { this.thread.resetPaging(); }
  getRepliesRetryReset(): boolean { return this.main.retryReset; }
  getReplyCursor(): string { return this.main.cursor; }

  dispose(): void {
    this.lifetime++;
    this.main.dispose();
    this.thread.cancel();
    this.sharing.dispose();
  }

  /** 评论赞/踩复用自己的动作实现，但必须遵守这次页面/账号/主体会话的有效期。 */
  captureGuard(): () => boolean {
    const current: ReplySubject = this.scope.getSubject();
    const subject: ReplySubject = { oid: current.oid, type: current.type };
    const account: number = AuthSession.version;
    const lifetime: number = this.lifetime;
    return (): boolean => !this.scope.isDestroyed() && lifetime === this.lifetime &&
      account === AuthSession.version && sameReplySubject(subject, this.scope.getSubject());
  }

  /** 数据源真身、线程与根楼层分别克隆换引用；全局 rev 驱动 ReplyCard 镜像同步。 */
  mutate(rpid: number, mutate: (target: ReplyItem) => void): ReplyItem | null {
    let found: ReplyItem | null = null;
    this.clock.version++;
    const mainItem: ReplyItem | undefined = this.source.getAll().find((item: ReplyItem) => item.rpid === rpid);
    // 先复制再修改，避免主列表和线程根节点引用同一对象时累计执行两次 +1/-1。
    const main: ReplyItem | null = mainItem !== undefined ? mutatedReplyClone(mainItem.clone(), mutate) : null;
    if (main !== null) { found = main; this.main.update(main); }
    const replies: Array<ReplyItem> = this.thread.replies.slice();
    const threadIndex: number = replies.findIndex((item: ReplyItem) => item.rpid === rpid);
    const thread: ReplyItem | null = threadIndex >= 0 ? mutatedReplyClone(replies[threadIndex].clone(), mutate) : null;
    if (thread !== null) { if (found === null) found = thread; replies[threadIndex] = thread; }
    const rootChanged: boolean = this.thread.root.rpid === rpid;
    const root: ReplyItem = rootChanged ? mutatedReplyClone(this.thread.root.clone(), mutate) : this.thread.root;
    if (found === null && rootChanged) found = root;
    this.thread.replace(root, replies);
    this.main.publish();
    if (this.video) CommentLog.info('ui.reply.mutate', 'rpid=' + String(rpid) + ' main=' + String(main !== null) +
      ' thread=' + String(thread !== null) + ' root=' + String(rootChanged) + ' found=' + String(found !== null) +
      ' version=' + String(this.clock.version));
    return found;
  }

  addSentMain(item: ReplyItem): void { this.main.addSent(item); }
  removeMain(rpid: number): void { this.main.remove(rpid); }

  removeThread(rpid: number, descendants: boolean = false): void {
    const before: number = this.thread.replies.length;
    this.thread.remove(rpid, descendants);
    if (this.video) CommentLog.info('ui.thread.remove', 'root=' + String(this.thread.root.rpid) +
      ' target=' + String(rpid) + ' removed=' + String(before - this.thread.replies.length) +
      ' remaining=' + String(this.thread.replies.length));
  }

  addSentThread(item: ReplyItem): void {
    const update: SentThreadReply | null = mergeSentThreadReply(this.thread.root, this.thread.replies, item);
    if (update === null) return;
    this.thread.rememberSent(item);
    this.thread.replace(update.root, update.replies);
    this.main.update(update.root);
  }

  addSentInline(item: ReplyItem, rootRpid: number): void {
    const root: ReplyItem | undefined = this.source.getAll().find((candidate: ReplyItem) => candidate.rpid === rootRpid);
    if (root === undefined) return;
    const update: SentThreadReply | null = mergeSentThreadReply(root, root.replies, item);
    if (update === null) return;
    this.main.update(update.root);
    this.thread.updateRoot(update.root);
  }
}
