/**
 * 视频详情页互动动作控制器：点赞/点踩/投币/收藏/关注/一键三连的“乐观更新 + 失败回滚”。
 *
 * 从 VideoDetail 抽出。@State 全部留在页面（ArkUI 响应式要求页面自己重新赋值状态字段），
 * 状态访问经 VideoActionAccess 闭包注入（同 ReplyReactionHooks 的注入风格）；
 * 登录检查与 toast 也由页面注入——ensureLogin 同时服务稍后再看、收藏夹多选、发评论等
 * 页面侧入口，故保留在页面。本文件不 import 任何页面 struct。
 */
import { UIContext } from '@kit.ArkUI';
import { ActionResult, BiliApi } from '../../api/BiliApi';
import { FavoriteApi } from '../../api/FavoriteApi';
import { UserApi } from '../../api/UserApi';
import { HistoryApi } from '../../api/HistoryApi';
import { UserStore } from '../../services/auth/UserStore';
import { AuthSession } from '../../services/auth/AuthSession';
import { FavoriteFolderItem } from '../../model/Models';

/**
 * 页面互动状态的读写面：@State 留在页面，控制器经闭包读写。
 * 成员统一用「属性 + 箭头函数」声明：ArkTS 的对象字面量检查只按属性语法匹配。
 */
export interface VideoActionAccess {
  /** 页面销毁标记：异步回调回来后不再写任何状态（与抽取前各 finally 的守卫一致）。 */
  isDestroyed: () => boolean;
  /** 登录检查：未登录时页面自行 toast + 跳登录页，返回 false 终止流程。 */
  ensureLogin: () => boolean;
  toast: (message: string) => void;

  /** 动作防重入与互动状态版本号（旧的关系接口响应不得覆盖更新的本地操作，init 里消费）。 */
  isActionBusy: () => boolean;
  setActionBusy: (value: boolean) => void;
  bumpLikeVersion: () => void;
  bumpCoinVersion: () => void;
  bumpFavoriteVersion: () => void;

  /** 当前稿件标识。 */
  getAid: () => number;
  getBvid: () => string;
  getUpMid: () => number;

  /** 点赞/点踩（本地互斥）与点赞数。 */
  getLiked: () => boolean;
  setLiked: (value: boolean) => void;
  getDisliked: () => boolean;
  setDisliked: (value: boolean) => void;
  getLikeCount: () => number;
  setLikeCount: (value: number) => void;

  /** 投币：我的硬币数/总数/弹窗选项/是否同时点赞/弹层开关。 */
  getCoinCountByMe: () => number;
  setCoinCountByMe: (value: number) => void;
  getCoinCount: () => number;
  setCoinCount: (value: number) => void;
  getCoinChoice: () => number;
  getCoinWithLike: () => boolean;
  setCoinSheetOpen: (value: boolean) => void;

  /** 收藏与收藏数。 */
  getFavorited: () => boolean;
  setFavorited: (value: boolean) => void;
  getFavoriteCount: () => number;
  setFavoriteCount: (value: number) => void;

  /** 关注与加载态。 */
  getFollowing: () => boolean;
  setFollowing: (value: boolean) => void;
  getFollowLoading: () => boolean;
  setFollowLoading: (value: boolean) => void;

  /** 一键三连确认弹窗需要主题色与 UIContext（promptAction）。 */
  getAccent: () => string;
  getUIContext: () => UIContext;
}

interface VideoActionSession {
  readonly generation: number;
  readonly account: number;
  readonly aid: number;
  readonly bvid: string;
  readonly upMid: number;
  readonly selfMid: number;
}

export class VideoActionController {
  private readonly access: VideoActionAccess;
  private generation: number = 0;

  constructor(access: VideoActionAccess) {
    this.access = access;
  }

  reset(): void {
    this.generation++;
    if (this.access.isDestroyed()) return;
    this.access.setActionBusy(false);
    this.access.setFollowLoading(false);
  }

  dispose(): void {
    this.generation++;
  }

  private capture(): VideoActionSession {
    return { generation: this.generation, account: AuthSession.version,
      aid: this.access.getAid(), bvid: this.access.getBvid(), upMid: this.access.getUpMid(),
      selfMid: UserStore.current !== null ? UserStore.current.mid : 0 };
  }

  private isCurrent(scope: VideoActionSession): boolean {
    return !this.access.isDestroyed() && scope.generation === this.generation &&
      scope.account === AuthSession.version && scope.aid === this.access.getAid() &&
      scope.bvid === this.access.getBvid() && scope.upMid === this.access.getUpMid();
  }

  async actionWatchLater(): Promise<void> {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.isActionBusy()) return;
    const scope: VideoActionSession = this.capture();
    this.access.setActionBusy(true);
    try {
      const result: ActionResult = await HistoryApi.addWatchLater(scope.aid, scope.bvid);
      if (!this.isCurrent(scope)) return;
      this.access.toast(result.ok ? '已加入稍后再看' : result.message);
    } catch (e) {
      if (this.isCurrent(scope)) this.access.toast('网络异常，请稍后重试');
    } finally {
      if (this.isCurrent(scope)) this.access.setActionBusy(false);
    }
  }

  async actionFollow(): Promise<void> {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.getFollowLoading() || this.access.getUpMid() <= 0) return;
    if (UserStore.current !== null && UserStore.current.mid === this.access.getUpMid()) {
      this.access.toast('不能关注自己');
      return;
    }
    const scope: VideoActionSession = this.capture();
    const previous: boolean = this.access.getFollowing();
    const next: boolean = !previous;
    this.access.setFollowing(next);
    this.access.setFollowLoading(true);
    try {
      const result: ActionResult = await UserApi.setFollowed(scope.upMid, next);
      if (!this.isCurrent(scope)) return;
      if (!result.ok) {
        this.access.setFollowing(previous);
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '关注成功' : '已取消关注');
    } catch (e) {
      if (this.isCurrent(scope)) {
        this.access.setFollowing(previous);
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (this.isCurrent(scope)) this.access.setFollowLoading(false);
    }
  }

  async actionLike(): Promise<void> {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.isActionBusy()) return;
    const scope: VideoActionSession = this.capture();
    this.access.setActionBusy(true);
    this.access.bumpLikeVersion();
    const likedBefore: boolean = this.access.getLiked();
    const dislikedBefore: boolean = this.access.getDisliked();
    const countBefore: number = this.access.getLikeCount();
    const rollback = (): void => {
      this.access.setLiked(likedBefore);
      this.access.setDisliked(dislikedBefore);
      this.access.setLikeCount(countBefore);
    };
    const next: boolean = !this.access.getLiked();
    // 先给出本地主题色反馈，网络失败再回滚，避免按钮点击后长时间仍是灰色。
    this.access.setLiked(next);
    this.access.setLikeCount(Math.max(0, this.access.getLikeCount() + (next ? 1 : -1)));
    // 赞与踩互斥：点赞成功时顺带清掉本地踩状态（服务端 like=1 会自动取消踩）。
    if (next && this.access.getDisliked()) this.access.setDisliked(false);
    try {
      const result: ActionResult = await BiliApi.likeVideo(scope.aid, scope.bvid, next);
      if (!this.isCurrent(scope)) return;
      if (!result.ok) {
        rollback();
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '点赞成功' : '已取消点赞');
    } catch (e) {
      if (this.isCurrent(scope)) {
        rollback();
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (this.isCurrent(scope)) this.access.setActionBusy(false);
    }
  }

  /** 点踩（App 端协议，需 App 授权）：与赞本地互斥。 */
  async actionDislike(): Promise<void> {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.isActionBusy()) return;
    const scope: VideoActionSession = this.capture();
    this.access.setActionBusy(true);
    this.access.bumpLikeVersion();
    const likedBefore: boolean = this.access.getLiked();
    const next: boolean = !this.access.getDisliked();
    this.access.setDisliked(next);
    if (next && this.access.getLiked()) this.access.setLiked(false);
    try {
      const result: ActionResult = await BiliApi.dislikeVideo(scope.aid, scope.bvid, next);
      if (!this.isCurrent(scope)) return;
      if (!result.ok) {
        this.access.setDisliked(!next);
        this.access.setLiked(likedBefore);
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '已点踩' : '已取消点踩');
    } catch (e) {
      if (this.isCurrent(scope)) {
        this.access.setDisliked(!next);
        this.access.setLiked(likedBefore);
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (this.isCurrent(scope)) this.access.setActionBusy(false);
    }
  }

  /** 点赞按钮长按：一键三连（点赞+投一币+收藏），弹确认后执行。 */
  actionTriple(): void {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.isActionBusy()) return;
    if (this.access.getLiked() && this.access.getCoinCountByMe() > 0 && this.access.getFavorited()) {
      this.access.toast('已三连过啦');
      return;
    }
    const scope: VideoActionSession = this.capture();
    try {
      this.access.getUIContext().getPromptAction().showDialog({
        title: '一键三连',
        message: '点赞 + 投 1 枚硬币 + 收藏',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '三连', color: this.access.getAccent() },
        ],
      }).then((dialogResult) => {
        if (Number(dialogResult.index) !== 1 || !this.isCurrent(scope)) return;
        this.doTriple().catch(() => {});
      }).catch(() => {});
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  async doTriple(): Promise<void> {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.isActionBusy()) return;
    if (this.access.getLiked() && this.access.getCoinCountByMe() > 0 && this.access.getFavorited()) return;
    this.access.bumpLikeVersion();
    this.access.bumpCoinVersion();
    this.access.bumpFavoriteVersion();
    const scope: VideoActionSession = this.capture();
    this.access.setActionBusy(true);
    try {
      const result: ActionResult = await BiliApi.likeTriple(scope.aid);
      if (!this.isCurrent(scope)) return;
      if (result.ok) {
        this.access.setLiked(true);
        this.access.setCoinCountByMe(Math.max(1, this.access.getCoinCountByMe()));
        if (!this.access.getFavorited()) this.access.setFavoriteCount(this.access.getFavoriteCount() + 1);
        this.access.setFavorited(true);
        this.access.toast('三连成功 🎉');
      } else {
        this.access.toast(result.message);
      }
    } catch (e) {
      if (this.isCurrent(scope)) this.access.toast('三连失败，请稍后重试');
    } finally {
      if (this.isCurrent(scope)) this.access.setActionBusy(false);
    }
  }

  async actionFavorite(): Promise<void> {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.isActionBusy()) return;
    const scope: VideoActionSession = this.capture();
    this.access.setActionBusy(true);
    this.access.bumpFavoriteVersion();
    const next: boolean = !this.access.getFavorited();
    this.access.setFavorited(next);
    this.access.setFavoriteCount(Math.max(0, this.access.getFavoriteCount() + (next ? 1 : -1)));
    try {
      const selfMid: number = scope.selfMid;
      let folders: Array<FavoriteFolderItem> = await FavoriteApi.getFavoriteFoldersForVideo(scope.aid,
        selfMid);
      if (!this.isCurrent(scope)) return;
      if (folders.length === 0 && next) {
        // 没有可用收藏夹：先自动创建一个默认收藏夹再收藏，避免"未找到可用的收藏夹"卡住收藏。
        const created: ActionResult = await FavoriteApi.addFavoriteFolder('默认收藏夹');
        if (!this.isCurrent(scope)) return;
        if (created.ok) {
          folders = await FavoriteApi.getFavoriteFoldersForVideo(scope.aid, selfMid);
        }
        if (!this.isCurrent(scope)) return;
      }
      if (folders.length === 0) {
        this.access.setFavorited(!next);
        this.access.setFavoriteCount(Math.max(0, this.access.getFavoriteCount() + (next ? -1 : 1)));
        this.access.toast(next ? '收藏夹创建失败，请稍后重试' : '未找到可用的收藏夹');
        return;
      }
      const selected: Array<number> = [];
      for (let i: number = 0; i < folders.length; i++) {
        if (folders[i].favorited) selected.push(folders[i].id);
      }
      const addIds: Array<number> = next ? [folders[0].id] : [];
      const deleteIds: Array<number> = next ? [] : selected;
      if (!next && deleteIds.length === 0) deleteIds.push(folders[0].id);
      const result: ActionResult = await FavoriteApi.modifyVideoFavorite(scope.aid, addIds, deleteIds);
      if (!this.isCurrent(scope)) return;
      if (!result.ok) {
        this.access.setFavorited(!next);
        this.access.setFavoriteCount(Math.max(0, this.access.getFavoriteCount() + (next ? -1 : 1)));
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '收藏成功' : '已取消收藏');
    } catch (e) {
      if (this.isCurrent(scope)) {
        this.access.setFavorited(!next);
        this.access.setFavoriteCount(Math.max(0, this.access.getFavoriteCount() + (next ? -1 : 1)));
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (this.isCurrent(scope)) this.access.setActionBusy(false);
    }
  }

  async submitCoin(): Promise<void> {
    if (this.access.isDestroyed() || !this.access.ensureLogin() || this.access.isActionBusy()) return;
    const available: number = Math.max(0, 2 - this.access.getCoinCountByMe());
    const multiply: number = Math.min(this.access.getCoinChoice(), available);
    if (multiply <= 0) {
      this.access.setCoinSheetOpen(false);
      return;
    }
    const scope: VideoActionSession = this.capture();
    this.access.setActionBusy(true);
    const withLike: boolean = this.access.getCoinWithLike();
    this.access.bumpCoinVersion();
    if (withLike) this.access.bumpLikeVersion();
    // 乐观更新：先变红并收起弹层，失败再整体回滚。
    const likedBefore: boolean = this.access.getLiked();
    this.access.setCoinCountByMe(this.access.getCoinCountByMe() + multiply);
    this.access.setCoinCount(this.access.getCoinCount() + multiply);
    if (withLike && !this.access.getLiked()) {
      this.access.setLiked(true);
      this.access.setLikeCount(this.access.getLikeCount() + 1);
    }
    this.access.setCoinSheetOpen(false);
    const rollback = (): void => {
      this.access.setCoinCountByMe(Math.max(0, this.access.getCoinCountByMe() - multiply));
      this.access.setCoinCount(Math.max(0, this.access.getCoinCount() - multiply));
      if (withLike && !likedBefore) {
        this.access.setLiked(false);
        this.access.setLikeCount(Math.max(0, this.access.getLikeCount() - 1));
      }
    };
    try {
      const result: ActionResult = await BiliApi.coinVideo(scope.aid, scope.bvid, multiply,
        withLike);
      if (!this.isCurrent(scope)) return;
      if (!result.ok) {
        rollback();
        this.access.toast(result.message);
        return;
      }
      this.access.toast('投币成功');
    } catch (e) {
      if (this.isCurrent(scope)) {
        rollback();
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (this.isCurrent(scope)) this.access.setActionBusy(false);
    }
  }

}
