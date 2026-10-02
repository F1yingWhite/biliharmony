import { BiliApi } from '../../api/BiliApi';
import { CommentApi } from '../../api/CommentApi';
import { UserApi } from '../../api/UserApi';
import { RequestEpoch } from '../../common/RequestEpoch';
import { BiliEmotePackage, VideoDetail, VideoRelationState } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';

export interface VideoInteractionRevision {
  readonly like: number;
  readonly coin: number;
  readonly favorite: number;
  readonly follow: number;
}

export interface VideoAccountRelation {
  readonly value: VideoRelationState;
  readonly revision: VideoInteractionRevision;
}

export interface VideoFollowStatus {
  /** null 表示保留当前用户操作产生的状态。 */
  readonly following: boolean | null;
  readonly loading: boolean;
  readonly revision: number;
}

export interface VideoEmoteStatus {
  readonly packages: Array<BiliEmotePackage>;
  readonly loading: boolean;
}

export interface VideoAccountHost {
  isAlive: () => boolean;
  getRevision: () => VideoInteractionRevision;
  publishRelation: (state: VideoAccountRelation) => void;
  publishFollow: (state: VideoFollowStatus) => void;
  publishEmotes: (state: VideoEmoteStatus) => void;
}

/** 视频、UP 与账号三者确定关系请求的归属；表情缓存也只在同一账号会话中复用。 */
export class VideoAccountController {
  private readonly host: VideoAccountHost;
  private epoch: RequestEpoch = new RequestEpoch();
  private currentRequest: number = 0;
  private aid: number = 0;
  private bvid: string = '';
  private upMid: number = 0;
  private account: number = -1;
  private packages: Array<BiliEmotePackage> = [];
  private emoteLoading: boolean = false;

  constructor(host: VideoAccountHost) {
    this.host = host;
  }

  reset(): void {
    this.currentRequest = this.epoch.next();
    this.aid = 0;
    this.bvid = '';
    this.upMid = 0;
    this.account = AuthSession.version;
    this.clearAccountState();
  }

  dispose(): void {
    this.epoch.invalidate();
    this.emoteLoading = false;
  }

  activate(detail: VideoDetail): void {
    this.aid = detail.aid;
    this.bvid = detail.bvid;
    this.upMid = detail.upMid;
    this.refresh();
  }

  refresh(): void {
    if (!this.host.isAlive()) return;
    this.currentRequest = this.epoch.next();
    const request: number = this.currentRequest;
    this.account = AuthSession.version;
    this.clearAccountState();
    if (!UserStore.isLogin || this.aid <= 0) return;
    const revision: VideoInteractionRevision = this.copyRevision();
    BiliApi.getVideoRelation(this.aid, this.bvid).then((relation: VideoRelationState | null) => {
      if (relation !== null && this.isCurrent(request)) {
        this.host.publishRelation({ value: relation, revision: revision });
      }
    }).catch(() => {});
    this.loadFollow(request, revision.follow).catch(() => {});
    this.loadEmotes().catch(() => {});
  }

  async loadEmotes(): Promise<void> {
    if (!this.host.isAlive() || !UserStore.isLogin) return;
    if (this.account !== AuthSession.version) {
      this.refresh();
      return;
    }
    if (this.emoteLoading || this.packages.length > 0) return;
    // 与关系共用会话，但重复打开表情面板不会使关注/关系请求失效。
    const request: number = this.currentRequest;
    this.emoteLoading = true;
    this.publishEmotes();
    try {
      let packages: Array<BiliEmotePackage> = await CommentApi.getUserEmotes('reply');
      if (!this.isCurrent(request)) return;
      if (packages.length === 0) {
        packages = await CommentApi.getUserEmotes('dynamic');
        if (!this.isCurrent(request)) return;
      }
      this.packages = packages.slice();
    } catch (e) {
      // 空态保留重试入口；表情加载失败不阻塞文本评论。
    } finally {
      if (this.isCurrent(request)) {
        this.emoteLoading = false;
        this.publishEmotes();
      }
    }
  }

  private clearAccountState(): void {
    this.packages = [];
    this.emoteLoading = false;
    if (!this.host.isAlive()) return;
    const revision: VideoInteractionRevision = this.copyRevision();
    this.host.publishRelation({ value: new VideoRelationState(), revision: revision });
    this.host.publishFollow({ following: false, loading: false, revision: revision.follow });
    this.publishEmotes();
  }

  private async loadFollow(request: number, revision: number): Promise<void> {
    if (this.upMid <= 0) return;
    this.host.publishFollow({ following: null, loading: true, revision: revision });
    let following: boolean | null = null;
    try {
      const attribute: number | null = await UserApi.getRelation(this.upMid);
      if (attribute !== null) following = attribute === 2 || attribute === 6;
    } catch (e) {
      // 失败不推测关注状态。
    } finally {
      if (this.isCurrent(request)) {
        this.host.publishFollow({ following: following, loading: false, revision: revision });
      }
    }
  }

  private copyRevision(): VideoInteractionRevision {
    const revision: VideoInteractionRevision = this.host.getRevision();
    return { like: revision.like, coin: revision.coin, favorite: revision.favorite, follow: revision.follow };
  }

  private isCurrent(request: number): boolean {
    return this.host.isAlive() && this.epoch.isCurrent(request) && this.account === AuthSession.version;
  }

  private publishEmotes(): void {
    this.host.publishEmotes({ packages: this.packages.slice(), loading: this.emoteLoading });
  }
}
