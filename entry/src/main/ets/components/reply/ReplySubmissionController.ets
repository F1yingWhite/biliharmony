import { CommentApi } from '../../api/CommentApi';
import { ActionResult } from '../../api/BiliApi';
import { asNumber, asObject } from '../../common/Utils';
import { CommentLog } from '../../common/CommentLog';
import { ReplyItem } from '../../model/reply/ReplyModels';
import { UserInfo } from '../../model/user/UserModels';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';

export interface ReplySubmissionTarget {
  oid: number;
  type: number;
  root: number;
  parent: number;
  /** 同一楼层的面板与行内输入也属于不同的编辑会话。 */
  scope: string;
  active: boolean;
}

/** 只有值类型的提交快照，不保留页面、目标对象或可变账号模型引用。 */
export class ReplySubmissionSnapshot {
  readonly oid: number;
  readonly type: number;
  readonly root: number;
  readonly parent: number;
  readonly scope: string;
  readonly draft: string;
  readonly content: string;
  readonly account: number;
  readonly session: number;
  readonly draftRevision: number;
  readonly mid: number;
  readonly uname: string;
  readonly avatar: string;
  readonly level: number;
  readonly timestamp: number;

  constructor(target: ReplySubmissionTarget, draft: string, user: UserInfo, account: number,
    session: number, draftRevision: number, timestamp: number) {
    this.oid = target.oid;
    this.type = target.type;
    this.root = target.root;
    this.parent = target.root > 0 ? (target.parent > 0 ? target.parent : target.root) : 0;
    this.scope = target.scope;
    this.draft = draft;
    this.content = draft.trim();
    this.account = account;
    this.session = session;
    this.draftRevision = draftRevision;
    this.mid = user.mid;
    this.uname = user.uname;
    this.avatar = user.face;
    this.level = user.level;
    this.timestamp = timestamp;
  }
}

/** 补齐精简发布响应；身份和目标来自提交时快照，不读取当前页面或全局账号。 */
export function normalizeSentReply(result: ActionResult, snapshot: ReplySubmissionSnapshot): ReplyItem | null {
  if (!result.ok) return null;
  const returned: ReplyItem = ReplyItem.from(asObject(result.data['reply']));
  const rpid: number = returned.rpid > 0 ? returned.rpid :
    asNumber(result.data['rpid'], asNumber(result.data['rpid_str'], 0));
  if (!Number.isFinite(rpid) || rpid <= 0) return null;
  const item: ReplyItem = returned.rpid > 0 ? returned : new ReplyItem();
  item.rpid = rpid;
  item.oid = snapshot.oid;
  item.type = snapshot.type;
  item.rootRpid = snapshot.root;
  item.parentRpid = snapshot.parent;
  item.dialogRpid = asNumber(result.data['dialog'], item.dialogRpid);
  if (item.mid <= 0) item.mid = snapshot.mid;
  if (item.uname.length === 0) item.uname = snapshot.uname.length > 0 ? snapshot.uname : '我';
  if (item.avatar.length === 0) item.avatar = snapshot.avatar;
  if (item.level <= 0) item.level = snapshot.level;
  if (item.content.length === 0) item.content = snapshot.content;
  if (item.ctime <= 0) item.ctime = snapshot.timestamp;
  return item;
}

export class SentThreadReply {
  readonly root: ReplyItem;
  readonly replies: Array<ReplyItem>;

  constructor(root: ReplyItem, replies: Array<ReplyItem>) {
    this.root = root;
    this.replies = replies;
  }
}

/** 三页共用的本地楼中楼更新；绝不把回复挂到另一个根节点。 */
export function mergeSentThreadReply(root: ReplyItem, replies: Array<ReplyItem>, sent: ReplyItem): SentThreadReply | null {
  if (root.rpid !== sent.rootRpid || sent.rootRpid <= 0) return null;
  const updated: ReplyItem = root.clone();
  updated.rev = root.rev + 1;
  const exists: boolean = replies.some((item: ReplyItem) => item.rpid === sent.rpid) ||
    root.replies.some((item: ReplyItem) => item.rpid === sent.rpid);
  if (!exists) updated.count++;
  updated.replies = [sent].concat(root.replies.filter((item: ReplyItem) => item.rpid !== sent.rpid));
  return new SentThreadReply(updated, [sent].concat(replies.filter((item: ReplyItem) => item.rpid !== sent.rpid)));
}

export interface ReplySubmissionHost {
  isAlive: () => boolean;
  getTarget: () => ReplySubmissionTarget;
  getDraft: () => string;
  setSending: (sending: boolean) => void;
  toast: (message: string) => void;
  /** 同步提交 UI 状态；后续刷新由已有分页控制器自行维护代际。 */
  onSuccess: (snapshot: ReplySubmissionSnapshot, reply: ReplyItem | null, clearDraft: boolean) => void;
}

/** 一个输入框的发送事务；草稿编辑不会被晚到的成功响应清空。 */
export class ReplySubmissionController {
  private readonly host: ReplySubmissionHost;
  private operation: number = 0;
  private session: number = 0;
  private draftRevision: number = 0;
  private busy: boolean = false;

  constructor(host: ReplySubmissionHost) {
    this.host = host;
  }

  draftChanged(): void {
    this.draftRevision++;
  }

  reset(): void {
    this.dispose();
    if (this.host.isAlive()) this.host.setSending(false);
  }

  dispose(): void {
    this.operation++;
    this.session++;
    this.draftRevision++;
    this.busy = false;
  }

  async send(): Promise<void> {
    const target: ReplySubmissionTarget = this.host.getTarget();
    const draft: string = this.host.getDraft();
    const user: UserInfo | null = UserStore.current;
    if (this.busy || !this.host.isAlive() || !target.active || target.oid <= 0 || target.type <= 0 ||
      draft.trim().length === 0 || !UserStore.isLogin || user === null) return;
    const snapshot: ReplySubmissionSnapshot = new ReplySubmissionSnapshot(target, draft, user,
      AuthSession.version, this.session, this.draftRevision, Math.floor(Date.now() / 1000));
    const operation: number = ++this.operation;
    this.busy = true;
    this.host.setSending(true);
    CommentLog.info('ui.send.start', 'oid=' + String(snapshot.oid) + ' root=' + String(snapshot.root) +
      ' parent=' + String(snapshot.parent) + ' messageLen=' + String(snapshot.content.length));
    let accepted: boolean = false;
    try {
      const result: ActionResult = await CommentApi.addReply(snapshot.oid, snapshot.type,
        snapshot.content, snapshot.root, snapshot.parent);
      if (!this.isCurrent(operation, snapshot)) {
        CommentLog.info('ui.send.drop', 'reason=stale-session root=' + String(snapshot.root));
        return;
      }
      if (!result.ok) {
        this.host.toast(result.message);
        return;
      }
      accepted = true;
      const reply: ReplyItem | null = normalizeSentReply(result, snapshot);
      const clearDraft: boolean = this.draftRevision === snapshot.draftRevision &&
        this.host.getDraft() === snapshot.draft;
      CommentLog.info('ui.send.done', 'root=' + String(snapshot.root) + ' local=' + String(reply !== null));
      this.host.toast(snapshot.root > 0 ? '回复成功' : '评论成功');
      this.host.onSuccess(snapshot, reply, clearDraft);
    } catch (e) {
      if (this.isCurrent(operation, snapshot)) {
        this.host.toast(accepted ? '评论已发送，请刷新查看' : '网络异常，发送失败');
      }
    } finally {
      // 账号切换丢弃内容，但当前发送仍需解锁；旧会话不能解锁新的发送。
      if (operation === this.operation) {
        this.busy = false;
        if (this.host.isAlive()) this.host.setSending(false);
      }
    }
  }

  private isCurrent(operation: number, snapshot: ReplySubmissionSnapshot): boolean {
    if (operation !== this.operation || snapshot.session !== this.session ||
      snapshot.account !== AuthSession.version || !this.host.isAlive()) return false;
    const target: ReplySubmissionTarget = this.host.getTarget();
    const parent: number = target.root > 0 ? (target.parent > 0 ? target.parent : target.root) : 0;
    return target.active && target.oid === snapshot.oid && target.type === snapshot.type &&
      target.root === snapshot.root && parent === snapshot.parent && target.scope === snapshot.scope;
  }
}
