import { ActionResult } from '../../api/BiliApi';
import { BangumiApi } from '../../api/BangumiApi';
import { RequestEpoch } from '../../common/RequestEpoch';
import { BangumiSeason } from '../../model/Models';
import { BangumiEpisodeCatalog } from './BangumiEpisodeCatalog';

/** 页面接收完整快照，使业务控制器的状态与 ArkUI 响应式发布解耦。 */
export class BangumiFollowState {
  followed: boolean = false;
  status: number = 0;
  favorites: number = 0;
  busy: boolean = false;
}

export interface BangumiFollowAccess {
  getSeason: () => BangumiSeason;
  isDestroyed: () => boolean;
  ensureLogin: (message: string) => boolean;
  toast: (message: string) => void;
  publish: (state: BangumiFollowState) => void;
  closeStatusPanel: () => void;
}

/** 追番与观看状态共用防重入及请求代际；异步完成不会写已离场或已换季的页面。 */
export class BangumiFollowController {
  private readonly access: BangumiFollowAccess;
  private state: BangumiFollowState = new BangumiFollowState();
  private epoch: RequestEpoch = new RequestEpoch();

  constructor(access: BangumiFollowAccess) {
    this.access = access;
  }

  initialize(season: BangumiSeason): void {
    this.epoch.invalidate();
    this.state.followed = season.followed;
    this.state.favorites = season.favorites;
    this.state.busy = false;
    this.publish();
  }

  dispose(): void {
    this.epoch.invalidate();
  }

  async toggle(): Promise<void> {
    const season: BangumiSeason = this.access.getSeason();
    if (!this.access.ensureLogin('请先登录后再' + BangumiEpisodeCatalog.followLabel(season))) return;
    if (this.state.busy || season.seasonId <= 0) return;
    const request: number = this.begin();
    try {
      const result: ActionResult = await BangumiApi.setFollowed(season.seasonId, !this.state.followed);
      if (!this.isCurrent(request)) return;
      this.access.toast(result.message);
      if (result.ok) {
        this.state.followed = !this.state.followed;
        this.state.favorites = Math.max(0, this.state.favorites + (this.state.followed ? 1 : -1));
      }
    } catch (e) {
      if (this.isCurrent(request)) this.access.toast('网络异常，操作失败');
    } finally {
      this.finish(request, false);
    }
  }

  /** 1 想看 / 2 在看 / 4 看过。设置状态成功会自动追番。 */
  async setStatus(status: number): Promise<void> {
    const season: BangumiSeason = this.access.getSeason();
    if (season.seasonId <= 0 || !this.access.ensureLogin('') || this.state.busy) return;
    const request: number = this.begin();
    try {
      const result: ActionResult = await BangumiApi.updateFollowStatus(season.seasonId, status);
      if (!this.isCurrent(request)) return;
      this.access.toast(result.ok ? ['想看', '在看', '', '看过'][status - 1] ?? '已更新状态' : result.message);
      if (result.ok) {
        this.state.status = status;
        if (!this.state.followed) {
          this.state.followed = true;
          this.state.favorites = Math.max(0, this.state.favorites + 1);
        }
      }
    } catch (e) {
      if (this.isCurrent(request)) this.access.toast('网络异常，操作失败');
    } finally {
      this.finish(request, true);
    }
  }

  private begin(): number {
    const request: number = this.epoch.next();
    this.state.busy = true;
    this.publish();
    return request;
  }

  private isCurrent(request: number): boolean {
    return !this.access.isDestroyed() && this.epoch.isCurrent(request);
  }

  private finish(request: number, closePanel: boolean): void {
    if (!this.isCurrent(request)) return;
    this.state.busy = false;
    this.publish();
    if (closePanel) this.access.closeStatusPanel();
  }

  private publish(): void {
    const snapshot: BangumiFollowState = new BangumiFollowState();
    snapshot.followed = this.state.followed;
    snapshot.status = this.state.status;
    snapshot.favorites = this.state.favorites;
    snapshot.busy = this.state.busy;
    this.access.publish(snapshot);
  }
}
