import { MessageApi } from '../../api/MessageApi';
import { ActionResult } from '../../api/BiliApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { compareMessageCursor } from '../../common/MessageCursor';
import { RequestEpoch } from '../../common/RequestEpoch';
import { MessageSessionItem, PrivateMessageItem, PrivateMessagePageData } from '../../model/message/MessageModels';
import { MessageSessionScope, MessageSessionToken } from './MessageSessionScope';
import { ChatActionSnapshot, ChatScrollRequest, PrivateChatState } from './MessageState';
import { privateMessageIdentity } from './MessageIdentity';

/** 一个打开的私信会话：历史、草稿、发送和举报均绑定同一账号与会话可见期。 */
export class PrivateChatSession {
  readonly source: BasicDataSource<PrivateMessageItem> = new BasicDataSource<PrivateMessageItem>();
  private state: PrivateChatState = new PrivateChatState();
  private scope: MessageSessionScope = new MessageSessionScope();
  private pages: RequestEpoch = new RequestEpoch();
  private sends: RequestEpoch = new RequestEpoch();
  private reports: RequestEpoch = new RequestEpoch();
  private reporting: boolean = false;
  private minSeqno: number = 0;
  private minSeqnoText: string = '';
  private draftRevision: number = 0;
  private localSequence: number = 0;
  private readonly publish: (state: PrivateChatState) => void;
  private readonly toast: (message: string) => void;
  private readonly scroll: (request: ChatScrollRequest) => void;
  private readonly acknowledge: (talkerId: number, cursor: string) => Promise<boolean>;

  constructor(publish: (state: PrivateChatState) => void, toast: (message: string) => void,
    scroll: (request: ChatScrollRequest) => void,
    acknowledge: (talkerId: number, cursor: string) => Promise<boolean>) {
    this.publish = publish;
    this.toast = toast;
    this.scroll = scroll;
    this.acknowledge = acknowledge;
  }

  snapshot(): PrivateChatState {
    return { current: this.state.current.clone(), open: this.state.open, loading: this.state.loading,
      error: this.state.error, hasMore: this.state.hasMore, draft: this.state.draft, sending: this.state.sending };
  }

  async open(item: MessageSessionItem): Promise<void> {
    this.close();
    this.scope.activate();
    if (this.scope.capture() === null || item.talkerId <= 0) return;
    this.state = new PrivateChatState();
    this.state.current = item.clone();
    this.state.open = true;
    this.minSeqno = 0;
    this.minSeqnoText = '';
    this.draftRevision++;
    this.source.clear();
    this.emit();
    await this.load(true);
  }

  close(): void {
    this.scope.invalidate();
    this.pages.invalidate();
    this.sends.invalidate();
    this.reports.invalidate();
    this.reporting = false;
    this.state.open = false;
    this.state.loading = false;
    this.state.sending = false;
    this.emit();
  }

  isCurrent(session: MessageSessionToken): boolean {
    return this.state.open && this.scope.current(session);
  }

  setDraft(value: string): void {
    if (this.scope.capture() === null) return;
    this.draftRevision++;
    this.state.draft = value;
    this.emit();
  }

  confirmRead(talkerId: number, cursor: string): void {
    if (this.scope.capture() === null || talkerId !== this.state.current.talkerId || !/^\d+$/.test(cursor) ||
      !/^\d+$/.test(this.state.current.maxSeqno) || compareMessageCursor(this.state.current.maxSeqno, cursor) > 0) return;
    this.state.current = this.state.current.clone();
    this.state.current.unread = 0;
    this.emit();
  }

  async load(reset: boolean): Promise<void> {
    const session: MessageSessionToken | null = this.scope.capture();
    if (session === null || !this.state.open || (!reset && (this.state.loading || !this.state.hasMore))) return;
    const request: number = this.pages.next();
    const talkerId: number = this.state.current.talkerId;
    const openingCursor: string = this.state.current.maxSeqno;
    const localWatermark: number = this.localSequence;
    const beginSeqno: number | string = reset ? 0 : (this.minSeqnoText.length > 0 ? this.minSeqnoText : this.minSeqno);
    this.state.loading = true;
    this.state.error = '';
    this.emit();
    try {
      const data: PrivateMessagePageData = await MessageApi.getPrivateMessages(talkerId, beginSeqno);
      if (!this.isCurrent(session) || !this.pages.isCurrent(request)) return;
      if (data.error.length > 0) {
        this.state.error = data.error;
        return;
      }
      if (reset) {
        // 首屏请求等待期间发送成功的本地消息继续保留，避免响应覆盖刚发送的内容。
        const sentDuringLoad: Array<PrivateMessageItem> = this.source.getAll().filter((item: PrivateMessageItem) =>
          item.seqnoText.length === 0 && item.seqno > localWatermark);
        this.source.reset(this.uniqueMessages(data.messages, []).concat(sentDuringLoad));
        this.scroll({ session: session, latest: true, added: 0 });
      } else {
        const older: Array<PrivateMessageItem> = this.uniqueMessages(data.messages, this.source.getAll());
        // 先通知页面记录当前阅读位置，随后 prepend 的数据源事件不会覆盖该锚点。
        if (older.length > 0) this.scroll({ session: session, latest: false, added: older.length });
        this.source.prepend(older);
      }
      this.minSeqno = data.minSeqno > 0 ? data.minSeqno : (reset ? 0 : this.minSeqno);
      this.minSeqnoText = /^\d+$/.test(data.minSeqnoText) ? data.minSeqnoText : (reset ? '' : this.minSeqnoText);
      this.state.hasMore = data.hasMore;
      if (reset) {
        let cursor: string = data.messages.length === 0 ? openingCursor : '';
        data.messages.forEach((item: PrivateMessageItem) => {
          if (/^\d+$/.test(item.seqnoText) && (cursor.length === 0 || compareMessageCursor(item.seqnoText, cursor) > 0)) {
            cursor = item.seqnoText;
          }
        });
        this.acknowledge(talkerId, cursor).catch(() => {});
      }
    } catch (error) {
      if (this.isCurrent(session) && this.pages.isCurrent(request)) this.state.error = '消息加载失败，请重试';
    } finally {
      if (this.isCurrent(session) && this.pages.isCurrent(request)) {
        this.state.loading = false;
        this.emit();
      }
    }
  }

  private uniqueMessages(incoming: Array<PrivateMessageItem>, existing: Array<PrivateMessageItem>): Array<PrivateMessageItem> {
    const seen: Set<string> = new Set<string>();
    existing.forEach((item: PrivateMessageItem) => seen.add(privateMessageIdentity(item)));
    const fresh: Array<PrivateMessageItem> = [];
    incoming.forEach((item: PrivateMessageItem) => {
      const identity: string = privateMessageIdentity(item);
      if (seen.has(identity)) return;
      seen.add(identity);
      fresh.push(item);
    });
    return fresh;
  }

  async send(): Promise<void> {
    const session: MessageSessionToken | null = this.scope.capture();
    const content: string = this.state.draft.trim();
    if (session === null || session.mid <= 0 || !this.state.open || content.length === 0 || this.state.sending) return;
    const talkerId: number = this.state.current.talkerId;
    const draftRevision: number = this.draftRevision;
    const request: number = this.sends.next();
    this.state.sending = true;
    this.emit();
    try {
      const result: ActionResult = await MessageApi.sendPrivateMessage(session.mid, talkerId, content);
      if (!this.isCurrent(session) || !this.sends.isCurrent(request)) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      const local: PrivateMessageItem = new PrivateMessageItem();
      local.senderId = session.mid;
      local.receiverId = talkerId;
      local.text = content;
      local.timestamp = Math.floor(Date.now() / 1000);
      this.localSequence = Math.max(Date.now(), this.localSequence + 1);
      local.seqno = this.localSequence;
      this.source.append([local]);
      this.scroll({ session: session, latest: true, added: 0 });
      // 即使后来重新输入了相同文本，也不能清掉这份新草稿。
      if (this.draftRevision === draftRevision) this.state.draft = '';
    } catch (error) {
      if (this.isCurrent(session) && this.sends.isCurrent(request)) this.toast('发送失败，请检查网络');
    } finally {
      if (this.isCurrent(session) && this.sends.isCurrent(request)) {
        this.state.sending = false;
        this.emit();
      }
    }
  }

  captureAction(): ChatActionSnapshot | null {
    const session: MessageSessionToken | null = this.scope.capture();
    return session === null || !this.state.open ? null :
      { session: session, talkerId: this.state.current.talkerId, name: this.state.current.name };
  }

  async report(action: ChatActionSnapshot, reason: number, description: string): Promise<void> {
    if (!this.isCurrent(action.session) || action.talkerId !== this.state.current.talkerId || this.reporting) return;
    const request: number = this.reports.next();
    this.reporting = true;
    try {
      const result: ActionResult = await MessageApi.reportImMessage(action.talkerId, reason, description);
      if (this.isCurrent(action.session) && this.reports.isCurrent(request)) {
        this.toast(result.ok ? '已提交举报，感谢反馈' : result.message);
      }
    } catch (error) {
      if (this.isCurrent(action.session) && this.reports.isCurrent(request)) this.toast('举报失败，请稍后重试');
    } finally {
      if (this.isCurrent(action.session) && this.reports.isCurrent(request)) this.reporting = false;
    }
  }

  private emit(): void {
    this.publish(this.snapshot());
  }
}
