import { RequestEpoch } from '../../common/RequestEpoch';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';

export interface FavoriteSessionToken {
  generation: number;
  auth: number;
  mid: number;
}

/** 收藏库各读写域共享同一个账号/可见期；各分页与事务另有自己的请求代际。 */
export class FavoriteLibrarySession {
  private lifetime: RequestEpoch = new RequestEpoch();
  private token: FavoriteSessionToken | null = null;

  async activate(): Promise<boolean> {
    this.token = null;
    const generation: number = this.lifetime.next();
    const auth: number = AuthSession.version;
    await UserStore.ensureLoaded();
    if (!this.lifetime.isCurrent(generation) || auth !== AuthSession.version) return false;
    const mid: number = UserStore.current?.mid ?? 0;
    this.token = { generation: generation, auth: auth, mid: mid };
    return true;
  }

  invalidate(): void {
    this.lifetime.invalidate();
    this.token = null;
  }

  capture(): FavoriteSessionToken | null {
    return this.token !== null && this.token.mid > 0 && this.current(this.token) ? this.token : null;
  }

  current(token: FavoriteSessionToken): boolean {
    return this.lifetime.isCurrent(token.generation) && token.auth === AuthSession.version &&
      UserStore.current !== null && UserStore.current.mid === token.mid;
  }
}
