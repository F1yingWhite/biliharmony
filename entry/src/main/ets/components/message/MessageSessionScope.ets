import { RequestEpoch } from '../../common/RequestEpoch';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';

export interface MessageSessionToken {
  generation: number;
  auth: number;
  mid: number;
}

/** 列表可见期与聊天会话各自持有作用域；账号与生命周期同时匹配才可提交。 */
export class MessageSessionScope {
  private epoch: RequestEpoch = new RequestEpoch();
  private token: MessageSessionToken | null = null;

  activate(): void {
    this.token = { generation: this.epoch.next(), auth: AuthSession.version, mid: UserStore.current?.mid ?? 0 };
  }

  invalidate(): void {
    this.epoch.invalidate();
    this.token = null;
  }

  capture(): MessageSessionToken | null {
    if (this.token === null || !this.current(this.token)) return null;
    // Cookie 恢复后 nav 用户信息可能才到达；同一个 AuthSession 可以补全初始未知的 uid。
    if (this.token.mid === 0 && (UserStore.current?.mid ?? 0) > 0) {
      this.token = { generation: this.token.generation, auth: this.token.auth, mid: UserStore.current?.mid ?? 0 };
    }
    return { generation: this.token.generation, auth: this.token.auth, mid: this.token.mid };
  }

  current(token: MessageSessionToken): boolean {
    const expectedMid: number = token.mid > 0 ? token.mid : (this.token?.mid ?? 0);
    return this.epoch.isCurrent(token.generation) && token.auth === AuthSession.version &&
      (expectedMid === 0 || expectedMid === (UserStore.current?.mid ?? 0)) && UserStore.isLogin;
  }
}
