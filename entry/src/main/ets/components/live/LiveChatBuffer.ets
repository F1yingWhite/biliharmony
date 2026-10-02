import { BasicDataSource } from '../../common/BasicDataSource';
import { LiveChatMessage } from '../../model/LiveModels';

/** 播放器通道只接收数据；缓冲区不依赖 ArkUI 播放器组件。 */
export interface LiveChatOutput {
  resetMessages: (messages: Array<LiveChatMessage>) => void;
  publishMessages: (messages: Array<LiveChatMessage>) => void;
  publishSuperChats: (messages: Array<LiveChatMessage>) => void;
}

/** 聊天窗口、去重集合与 220ms 合批共享同一生命周期。所有消息类型都受相同容量约束。 */
export class LiveChatBuffer {
  readonly source: BasicDataSource<LiveChatMessage> = new BasicDataSource<LiveChatMessage>();
  private readonly output: LiveChatOutput;
  private readonly onMessages: (baseline: boolean) => void;
  private readonly onSuperChats: (messages: Array<LiveChatMessage>) => void;
  private isActive: () => boolean = () => false;
  private messages: Array<LiveChatMessage> = [];
  private superChats: Array<LiveChatMessage> = [];
  private known: Set<string> = new Set<string>();
  /** 固定初始快照的小集合，近期去重窗口轮转后也不能把首屏历史重新喷到画面。 */
  private baselineIds: Set<string> = new Set<string>();
  private pending: Array<LiveChatMessage> = [];
  private flushTimer: number = -1;
  private lastMessageAt: number = 0;
  private static readonly KNOWN_LIMIT: number = 2000;
  private static readonly PENDING_LIMIT: number = 240;

  constructor(output: LiveChatOutput, onMessages: (baseline: boolean) => void,
    onSuperChats: (messages: Array<LiveChatMessage>) => void) {
    this.output = output;
    this.onMessages = onMessages;
    this.onSuperChats = onSuperChats;
  }

  activate(isActive: () => boolean): void {
    this.clearPending();
    this.isActive = isActive;
  }

  dispose(): void {
    this.isActive = () => false;
    this.clearPending();
  }

  get lastReceivedAt(): number { return this.lastMessageAt; }

  markConnected(): void { this.lastMessageAt = Date.now(); }

  establishBaseline(history: Array<LiveChatMessage>, clearSuperChats: boolean = false): void {
    this.clearPending();
    this.known.clear();
    this.baselineIds.clear();
    const unique: Array<LiveChatMessage> = [];
    for (let i: number = 0; i < history.length; i++) {
      if (this.remember(history[i].id)) unique.push(history[i]);
    }
    unique.slice(-LiveChatBuffer.KNOWN_LIMIT).forEach((message: LiveChatMessage) => this.baselineIds.add(message.id));
    this.messages = unique.slice(-240);
    this.source.reset(unique.slice(-200));
    this.output.resetMessages(this.messages);
    this.lastMessageAt = Date.now();
    if (clearSuperChats) this.publishSuperChats([]);
    this.onMessages(true);
  }

  append(message: LiveChatMessage): void {
    if (!this.isActive() || !this.remember(message.id)) return;
    this.lastMessageAt = Date.now();
    if (message.type === 'sc') this.publishSuperChats(LiveChatBuffer.mergeSuperChats([message], this.superChats));
    this.pending.push(message);
    if (this.pending.length > LiveChatBuffer.PENDING_LIMIT) {
      this.pending = this.pending.slice(-LiveChatBuffer.PENDING_LIMIT);
    }
    if (this.flushTimer < 0) {
      this.flushTimer = setTimeout(() => {
        this.flushTimer = -1;
        this.flush();
      }, 220);
    }
  }

  appendLocal(message: LiveChatMessage): void {
    if (!this.isActive() || !this.remember(message.id)) return;
    // 先提交已接收消息，本地回显不会越过等待合批的早到消息。
    this.flush();
    this.commit([message]);
  }

  mergeSnapshot(snapshot: Array<LiveChatMessage>): void {
    if (this.isActive()) this.publishSuperChats(LiveChatBuffer.mergeSuperChats(this.superChats, snapshot));
  }

  static mergeSuperChats(first: Array<LiveChatMessage>, second: Array<LiveChatMessage>): Array<LiveChatMessage> {
    const seen: Set<string> = new Set<string>();
    return first.concat(second).filter((message: LiveChatMessage): boolean => {
      if (seen.has(message.id)) return false;
      seen.add(message.id);
      return true;
    }).sort((a: LiveChatMessage, b: LiveChatMessage): number => b.timestamp - a.timestamp).slice(0, 50);
  }

  clearPending(): void {
    if (this.flushTimer >= 0) clearTimeout(this.flushTimer);
    this.flushTimer = -1;
    this.pending = [];
  }

  private remember(id: string): boolean {
    if (this.known.has(id) || this.baselineIds.has(id)) return false;
    this.known.add(id);
    if (this.known.size > LiveChatBuffer.KNOWN_LIMIT) {
      const oldest: IteratorResult<string> = this.known.keys().next();
      if (!oldest.done) this.known.delete(oldest.value);
    }
    return true;
  }

  private flush(): void {
    if (!this.isActive()) { this.clearPending(); return; }
    if (this.pending.length === 0) return;
    const batch: Array<LiveChatMessage> = this.pending;
    this.clearPending();
    this.commit(batch);
  }

  private commit(batch: Array<LiveChatMessage>): void {
    const next: Array<LiveChatMessage> = this.messages.concat(batch);
    this.messages = next.length > 240 ? next.slice(-200) : next;
    this.output.publishMessages(this.messages);
    this.source.append(batch);
    const overflow: number = this.source.totalCount() - 200;
    if (overflow > 0) this.source.trimHead(overflow);
    this.onMessages(false);
  }

  private publishSuperChats(messages: Array<LiveChatMessage>): void {
    this.superChats = messages;
    this.output.publishSuperChats(messages);
    this.onSuperChats(messages);
  }
}
