import { AuthSession } from '../auth/AuthSession';

/** 仅保存当前账号已确认的关注关系；批量响应不能覆盖随后发生的关注操作。 */
export class FollowStateStore {
  private static accountVersion: number = -1;
  private static revision: number = 0;
  private static values: Map<number, boolean> = new Map<number, boolean>();
  private static updatedAt: Map<number, number> = new Map<number, number>();

  private static ensureAccount(): void {
    if (FollowStateStore.accountVersion === AuthSession.version) return;
    FollowStateStore.accountVersion = AuthSession.version;
    FollowStateStore.values.clear();
    FollowStateStore.updatedAt.clear();
    FollowStateStore.revision++;
  }

  static get version(): number {
    FollowStateStore.ensureAccount();
    return FollowStateStore.revision;
  }

  static get(mid: number): boolean {
    FollowStateStore.ensureAccount();
    return FollowStateStore.values.get(mid) === true;
  }

  static needsLoad(mid: number): boolean {
    FollowStateStore.ensureAccount();
    return Date.now() - (FollowStateStore.updatedAt.get(mid) ?? 0) > 60000;
  }

  static apply(values: Map<number, boolean>, account: number, revision: number): void {
    FollowStateStore.ensureAccount();
    if (account !== AuthSession.version || revision !== FollowStateStore.revision) return;
    values.forEach((followed: boolean, mid: number) => {
      FollowStateStore.values.set(mid, followed);
      FollowStateStore.updatedAt.set(mid, Date.now());
    });
    FollowStateStore.publish();
  }

  static set(mid: number, followed: boolean, account: number): void {
    FollowStateStore.ensureAccount();
    if (account !== AuthSession.version) return;
    FollowStateStore.values.set(mid, followed);
    FollowStateStore.updatedAt.set(mid, Date.now());
    FollowStateStore.revision++;
    FollowStateStore.publish();
  }

  private static publish(): void {
    AppStorage.setOrCreate<number>('followStateVersion',
      (AppStorage.get<number>('followStateVersion') ?? 0) + 1);
  }
}
