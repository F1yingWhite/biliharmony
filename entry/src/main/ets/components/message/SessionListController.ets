import { MessageApi } from '../../api/MessageApi';
import { ActionResult } from '../../api/BiliApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { compareMessageCursor } from '../../common/MessageCursor';
import { RequestEpoch } from '../../common/RequestEpoch';
import { MessageSessionItem, MessageSessionPageData } from '../../model/message/MessageModels';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';
import { MsgUnreadStore } from '../../services/message/MsgUnreadStore';
import { MessageSessionScope, MessageSessionToken } from './MessageSessionScope';
import { SessionActionSnapshot, SessionListState } from './MessageState';

/** 会话目录的分页、已读账本和会话管理事务；列表实例在整个页面生命周期内稳定。 */
export class SessionListController {
  readonly source: BasicDataSource<MessageSessionItem> = new BasicDataSource<MessageSessionItem>();
  private state: SessionListState = new SessionListState();
  private scope: MessageSessionScope = new MessageSessionScope();
  private pages: RequestEpoch = new RequestEpoch();
  private menus: RequestEpoch = new RequestEpoch();
  private mutations: RequestEpoch = new RequestEpoch();
  private allReads: RequestEpoch = new RequestEpoch();
  private confirmed: Map<number, string> = new Map<number, string>();
  private account: number = -1;
  private accountMid: number = -1;
  private cursor: number = 0;
  private mutating: boolean = false;
  private failedReset: boolean = true;
  private readonly publish: (state: SessionListState) => void;
  private readonly toast: (message: string) => void;
  private readonly readConfirmed: (talkerId: number, cursor: string) => void;

  constructor(publish: (state: SessionListState) => void, toast: (message: string) => void,
    readConfirmed: (talkerId: number, cursor: string) => void) {
    this.publish = publish;
    this.toast = toast;
    this.readConfirmed = readConfirmed;
  }

  snapshot(): SessionListState {
    return { loading: this.state.loading, error: this.state.error, hasMore: this.state.hasMore,
      count: this.source.totalCount(), readAllLoading: this.state.readAllLoading };
  }

  activate(): void {
    this.dispose();
    if (this.account !== AuthSession.version || this.accountMid !== (UserStore.current?.mid ?? 0)) {
      this.account = AuthSession.version;
      this.accountMid = UserStore.current?.mid ?? 0;
      this.confirmed.clear();
      this.source.clear();
      this.state = new SessionListState();
      this.cursor = 0;
    }
    this.scope.activate();
    this.emit();
  }

  dispose(): void {
    this.scope.invalidate();
    this.pages.invalidate();
    this.menus.invalidate();
    this.mutations.invalidate();
    this.allReads.invalidate();
    this.mutating = false;
    this.state.loading = false;
    this.state.readAllLoading = false;
  }

  async load(reset: boolean): Promise<void> {
    const session: MessageSessionToken | null = this.scope.capture();
    if (session === null || (!reset && (this.state.loading || !this.state.hasMore))) return;
    const request: number = this.pages.next();
    this.failedReset = reset;
    const beginTs: number = reset ? 0 : this.cursor;
    this.state.loading = true;
    this.state.error = '';
    this.emit();
    try {
      const data: MessageSessionPageData = await MessageApi.getMessageSessions(beginTs);
      if (!this.scope.current(session) || !this.pages.isCurrent(request)) return;
      if (data.error.length > 0) {
        this.state.error = data.error;
        return;
      }
      const seen: Set<number> = new Set<number>();
      if (!reset) this.source.getAll().forEach((item: MessageSessionItem) => seen.add(item.talkerId));
      const incoming: Array<MessageSessionItem> = [];
      data.sessions.forEach((item: MessageSessionItem) => {
        if (seen.has(item.talkerId)) return;
        seen.add(item.talkerId);
        incoming.push(this.applyConfirmed(item));
      });
      // 游标来自服务端这一页，不能因本地置顶/删除重排而跳页。
      let nextCursor: number = 0;
      data.sessions.forEach((item: MessageSessionItem) => {
        if (item.sessionTs > 0 && (nextCursor === 0 || item.sessionTs < nextCursor)) nextCursor = item.sessionTs;
      });
      if (reset) this.source.reset(incoming);
      else this.source.append(incoming);
      this.cursor = nextCursor;
      this.state.hasMore = data.hasMore && nextCursor > 0 && (reset || nextCursor < beginTs);
    } catch (error) {
      if (this.scope.current(session) && this.pages.isCurrent(request)) this.state.error = '会话加载失败，请重试';
    } finally {
      if (this.scope.current(session) && this.pages.isCurrent(request)) {
        this.state.loading = false;
        this.emit();
      }
    }
  }

  async retry(): Promise<void> {
    await this.load(this.failedReset);
  }

  private applyConfirmed(item: MessageSessionItem): MessageSessionItem {
    const confirmed: string | undefined = this.confirmed.get(item.talkerId);
    if (confirmed === undefined || !/^\d+$/.test(item.maxSeqno) ||
      compareMessageCursor(item.maxSeqno, confirmed) > 0 || item.unread === 0) return item;
    const updated: MessageSessionItem = item.clone();
    updated.unread = 0;
    return updated;
  }

  async acknowledge(talkerId: number, cursor: string): Promise<boolean> {
    const session: MessageSessionToken | null = this.scope.capture();
    if (session === null) return false;
    return this.acknowledgeInSession(talkerId, cursor, session);
  }

  private async acknowledgeInSession(talkerId: number, cursor: string, session: MessageSessionToken): Promise<boolean> {
    if (!this.scope.current(session) || !/^\d+$/.test(cursor)) return false;
    const result: ActionResult = await MessageApi.markPrivateMessagesRead(talkerId, cursor);
    if (!this.scope.current(session) || !result.ok) return false;
    const previous: string | undefined = this.confirmed.get(talkerId);
    const confirmed: string = previous !== undefined && compareMessageCursor(previous, cursor) > 0 ? previous : cursor;
    this.confirmed.set(talkerId, confirmed);
    const all: Array<MessageSessionItem> = this.source.getAll();
    for (let index: number = 0; index < all.length; index++) {
      if (all[index].talkerId !== talkerId) continue;
      const updated: MessageSessionItem = this.applyConfirmed(all[index]);
      if (updated !== all[index]) this.source.updateItem(index, updated);
    }
    this.readConfirmed(talkerId, confirmed);
    return true;
  }

  async markAllRead(): Promise<void> {
    const session: MessageSessionToken | null = this.scope.capture();
    if (session === null || this.state.readAllLoading) return;
    const request: number = this.allReads.next();
    // 点击时冻结精确游标。等待通知接口期间新到的私信不能被顺便标为已读。
    const rows: Array<MessageSessionItem> = this.source.getAll().map((item: MessageSessionItem) => item.clone());
    this.state.readAllLoading = true;
    this.emit();
    let failed: number = 0;
    try {
      const result: ActionResult = await MessageApi.markAllNotificationsRead();
      if (!this.scope.current(session)) return;
      if (result.ok) MsgUnreadStore.clearAll();
      else failed++;
      for (let index: number = 0; index < rows.length; index++) {
        if (rows[index].unread <= 0) continue;
        try {
          if (!await this.acknowledgeInSession(rows[index].talkerId, rows[index].maxSeqno, session)) failed++;
        } catch (error) {
          failed++;
        }
        if (!this.scope.current(session)) return;
      }
      this.toast(failed === 0 ? '已标记全部已读' : '部分消息标记失败，请稍后重试');
    } catch (error) {
      if (this.scope.current(session)) this.toast('标记已读失败，请稍后重试');
    } finally {
      if (this.scope.current(session) && this.allReads.isCurrent(request)) {
        this.state.readAllLoading = false;
        this.emit();
      }
    }
  }

  captureAction(item: MessageSessionItem): SessionActionSnapshot | null {
    const session: MessageSessionToken | null = this.scope.capture();
    if (session === null || this.mutating || item.talkerId <= 0) return null;
    return { session: session, menu: this.menus.next(), item: item.clone() };
  }

  actionCurrent(action: SessionActionSnapshot): boolean {
    return this.scope.current(action.session) && this.menus.isCurrent(action.menu) && !this.mutating;
  }

  async togglePin(action: SessionActionSnapshot): Promise<void> {
    if (!this.actionCurrent(action)) return;
    const request: number = this.beginMutation();
    const pin: boolean = !action.item.pinned;
    try {
      const result: ActionResult = await MessageApi.pinSession(action.item.talkerId, pin);
      if (!this.mutationCurrent(action.session, request)) return;
      this.toast(result.message);
      if (!result.ok) return;
      this.cancelPendingPage();
      const rows: Array<MessageSessionItem> = this.source.getAll().map((item: MessageSessionItem): MessageSessionItem => {
        const pinned: boolean = item.talkerId === action.item.talkerId ? pin : (pin ? false : item.pinned);
        if (pinned === item.pinned) return item;
        const updated: MessageSessionItem = item.clone();
        updated.pinned = pinned;
        return updated;
      });
      rows.sort((a: MessageSessionItem, b: MessageSessionItem): number =>
        a.pinned !== b.pinned ? (a.pinned ? -1 : 1) : b.sessionTs - a.sessionTs);
      this.source.reset(rows);
    } catch (error) {
      if (this.mutationCurrent(action.session, request)) this.toast('网络异常，操作失败');
    } finally {
      this.endMutation(action.session, request);
    }
  }

  async remove(action: SessionActionSnapshot): Promise<void> {
    if (!this.actionCurrent(action)) return;
    const request: number = this.beginMutation();
    try {
      const result: ActionResult = await MessageApi.removeSession(action.item.talkerId);
      if (!this.mutationCurrent(action.session, request)) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.cancelPendingPage();
      const index: number = this.source.getAll().findIndex((item: MessageSessionItem) => item.talkerId === action.item.talkerId);
      if (index >= 0) this.source.removeAt(index);
      this.toast('会话已删除');
    } catch (error) {
      if (this.mutationCurrent(action.session, request)) this.toast('删除失败，请稍后重试');
    } finally {
      this.endMutation(action.session, request);
    }
  }

  private beginMutation(): number {
    this.menus.invalidate();
    this.mutating = true;
    return this.mutations.next();
  }

  private mutationCurrent(session: MessageSessionToken, request: number): boolean {
    return this.scope.current(session) && this.mutations.isCurrent(request);
  }

  private cancelPendingPage(): void {
    this.pages.invalidate();
    this.state.loading = false;
  }

  private endMutation(session: MessageSessionToken, request: number): void {
    if (!this.mutationCurrent(session, request)) return;
    this.mutating = false;
    this.emit();
  }

  private emit(): void {
    this.publish(this.snapshot());
  }
}
