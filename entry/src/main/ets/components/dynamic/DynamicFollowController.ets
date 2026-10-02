import { RelationUserItem, RelationUserPageData } from '../../model/Models';
import { UserStore } from '../../services/auth/UserStore';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserApi } from '../../api/UserApi';
import { LiveApi } from '../../api/LiveApi';

export class DynamicFollowState {
  followed: Array<RelationUserItem> = [];
  liveRooms: Map<number, number> = new Map<number, number>();
}

/** 关注条独立于 feed 加载，账号切换同时撤销列表与直播角标请求。 */
export class DynamicFollowController {
  private followed: Array<RelationUserItem> = [];
  private liveRooms: Map<number, number> = new Map<number, number>();
  private followingLoaded: boolean = false;
  private followLoading: boolean = false;
  private liveFetching: boolean = false;
  private accountGeneration: number = 0;
  private publish: (state: DynamicFollowState) => void;

  constructor(publish: (state: DynamicFollowState) => void) { this.publish = publish; }

  cancel(): void {
    this.accountGeneration++;
    this.followLoading = false;
    this.liveFetching = false;
  }

  reset(): void {
    this.accountGeneration++;
    this.followed = [];
    this.liveRooms = new Map<number, number>();
    this.followingLoaded = false;
    this.followLoading = false;
    this.liveFetching = false;
    this.emit();
  }

  private emit(): void { this.publish({ followed: this.followed, liveRooms: this.liveRooms }); }

  /** 并行拉取关注 UP 主第一页，仅作横滑栏展示，失败静默（不影响动态主流程）。 */
  async load(): Promise<void> {
    if (this.followingLoaded || this.followLoading) return;
    const generation: number = this.accountGeneration;
    const session: number = AuthSession.version;
    this.followLoading = true;
    try {
      await UserStore.ensureLoaded();
      if (generation !== this.accountGeneration || session !== AuthSession.version) return;
      const mid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      if (mid <= 0) return;
      const page: RelationUserPageData = await UserApi.getRelationUsers(mid, 'following', 1);
      if (generation !== this.accountGeneration || session !== AuthSession.version || UserStore.current === null || UserStore.current.mid !== mid) return;
      if (page.users.length > 0) {
        this.followed = page.users;
      }
    } catch (e) {
      // 关注列表失败时静默隐藏横滑条。
    } finally {
      if (generation === this.accountGeneration) {
        this.followLoading = false;
        if (session !== AuthSession.version) return;
        this.followingLoaded = true;
        // 列表到位后异步补开播状态（直播角标）；失败静默。
        this.refreshLiveBadges();
        this.emit();
      }
    }
  }

  /** 批量查询关注 UP 的开播状态，驱动横滑栏「直播中」角标。 */
  private async refreshLiveBadges(): Promise<void> {
    if (this.followed.length === 0 || this.liveFetching) return;
    const generation: number = this.accountGeneration;
    const session: number = AuthSession.version;
    this.liveFetching = true;
    try {
      const uids: Array<number> = [];
      for (let i: number = 0; i < this.followed.length; i++) {
        uids.push(this.followed[i].mid);
      }
      const items = await LiveApi.getLiveStatusByUids(uids);
      if (generation !== this.accountGeneration || session !== AuthSession.version) return;
      const next: Map<number, number> = new Map<number, number>();
      for (let i: number = 0; i < items.length; i++) {
        if (items[i].liveStatus === 1 && items[i].roomId > 0) {
          next.set(items[i].uid, items[i].roomId);
        }
      }
      this.liveRooms = next;
      this.emit();
    } catch (e) {
      // 开播状态失败时只少一个角标，不打扰。
    } finally {
      if (generation === this.accountGeneration) this.liveFetching = false;
    }
  }

}
