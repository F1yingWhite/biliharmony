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
import { UserStore } from '../../services/auth/UserStore';
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

export class VideoActionController {
  private readonly access: VideoActionAccess;

  constructor(access: VideoActionAccess) {
    this.access = access;
  }

  async actionFollow(): Promise<void> {
    if (!this.access.ensureLogin() || this.access.getFollowLoading() || this.access.getUpMid() <= 0) return;
    if (UserStore.current !== null && UserStore.current.mid === this.access.getUpMid()) {
      this.access.toast('不能关注自己');
      return;
    }
    const previous: boolean = this.access.getFollowing();
    const next: boolean = !previous;
    this.access.setFollowing(next);
    this.access.setFollowLoading(true);
    try {
      const result: ActionResult = await UserApi.setFollowed(this.access.getUpMid(), next);
      if (this.access.isDestroyed()) return;
      if (!result.ok) {
        this.access.setFollowing(previous);
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '关注成功' : '已取消关注');
    } catch (e) {
      if (!this.access.isDestroyed()) {
        this.access.setFollowing(previous);
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.access.isDestroyed()) this.access.setFollowLoading(false);
    }
  }

  async actionLike(): Promise<void> {
    if (!this.access.ensureLogin() || this.access.isActionBusy()) return;
    this.access.setActionBusy(true);
    this.access.bumpLikeVersion();
    const next: boolean = !this.access.getLiked();
    // 先给出本地主题色反馈，网络失败再回滚，避免按钮点击后长时间仍是灰色。
    this.access.setLiked(next);
    this.access.setLikeCount(Math.max(0, this.access.getLikeCount() + (next ? 1 : -1)));
    // 赞与踩互斥：点赞成功时顺带清掉本地踩状态（服务端 like=1 会自动取消踩）。
    if (next && this.access.getDisliked()) this.access.setDisliked(false);
    try {
      const result: ActionResult = await BiliApi.likeVideo(this.access.getAid(), this.access.getBvid(), next);
      if (this.access.isDestroyed()) return;
      if (!result.ok) {
        this.access.setLiked(!next);
        this.access.setLikeCount(Math.max(0, this.access.getLikeCount() + (next ? -1 : 1)));
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '点赞成功' : '已取消点赞');
    } catch (e) {
      if (!this.access.isDestroyed()) {
        this.access.setLiked(!next);
        this.access.setLikeCount(Math.max(0, this.access.getLikeCount() + (next ? -1 : 1)));
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.access.isDestroyed()) this.access.setActionBusy(false);
    }
  }

  /** 点踩（App 端协议，需 App 授权）：与赞本地互斥。 */
  async actionDislike(): Promise<void> {
    if (!this.access.ensureLogin() || this.access.isActionBusy()) return;
    this.access.setActionBusy(true);
    const next: boolean = !this.access.getDisliked();
    this.access.setDisliked(next);
    if (next && this.access.getLiked()) this.access.setLiked(false);
    try {
      const result: ActionResult = await BiliApi.dislikeVideo(this.access.getAid(), this.access.getBvid(), next);
      if (this.access.isDestroyed()) return;
      if (!result.ok) {
        this.access.setDisliked(!next);
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '已点踩' : '已取消点踩');
    } catch (e) {
      if (!this.access.isDestroyed()) {
        this.access.setDisliked(!next);
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.access.isDestroyed()) this.access.setActionBusy(false);
    }
  }

  /** 点赞按钮长按：一键三连（点赞+投一币+收藏），弹确认后执行。 */
  actionTriple(): void {
    if (!this.access.ensureLogin() || this.access.isActionBusy()) return;
    if (this.access.getLiked() && this.access.getCoinCountByMe() > 0 && this.access.getFavorited()) {
      this.access.toast('已三连过啦');
      return;
    }
    try {
      this.access.getUIContext().getPromptAction().showDialog({
        title: '一键三连',
        message: '点赞 + 投 1 枚硬币 + 收藏',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '三连', color: this.access.getAccent() },
        ],
      }).then((dialogResult) => {
        if (Number(dialogResult.index) !== 1) return;
        this.doTriple();
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  async doTriple(): Promise<void> {
    this.access.setActionBusy(true);
    try {
      const result: ActionResult = await BiliApi.likeTriple(this.access.getAid());
      if (this.access.isDestroyed()) return;
      if (result.ok) {
        this.access.setLiked(true);
        this.access.setCoinCountByMe(1);
        this.access.setFavorited(true);
        this.access.setFavoriteCount(this.access.getFavoriteCount() + 1);
        this.access.toast('三连成功 🎉');
      } else {
        this.access.toast(result.message);
      }
    } catch (e) {
      if (!this.access.isDestroyed()) this.access.toast('三连失败，请稍后重试');
    } finally {
      if (!this.access.isDestroyed()) this.access.setActionBusy(false);
    }
  }

  async actionFavorite(): Promise<void> {
    if (!this.access.ensureLogin() || this.access.isActionBusy()) return;
    this.access.setActionBusy(true);
    this.access.bumpFavoriteVersion();
    const next: boolean = !this.access.getFavorited();
    this.access.setFavorited(next);
    this.access.setFavoriteCount(Math.max(0, this.access.getFavoriteCount() + (next ? 1 : -1)));
    try {
      const selfMid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      let folders: Array<FavoriteFolderItem> = await FavoriteApi.getFavoriteFoldersForVideo(this.access.getAid(),
        selfMid);
      if (this.access.isDestroyed()) return;
      if (folders.length === 0 && next) {
        // 没有可用收藏夹：先自动创建一个默认收藏夹再收藏，避免"未找到可用的收藏夹"卡住收藏。
        const created: ActionResult = await FavoriteApi.addFavoriteFolder('默认收藏夹');
        if (this.access.isDestroyed()) return;
        if (created.ok) {
          folders = await FavoriteApi.getFavoriteFoldersForVideo(this.access.getAid(), selfMid);
        }
        if (this.access.isDestroyed()) return;
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
      const result: ActionResult = await FavoriteApi.modifyVideoFavorite(this.access.getAid(), addIds, deleteIds);
      if (this.access.isDestroyed()) return;
      if (!result.ok) {
        this.access.setFavorited(!next);
        this.access.setFavoriteCount(Math.max(0, this.access.getFavoriteCount() + (next ? -1 : 1)));
        this.access.toast(result.message);
        return;
      }
      this.access.toast(next ? '收藏成功' : '已取消收藏');
    } catch (e) {
      if (!this.access.isDestroyed()) {
        this.access.setFavorited(!next);
        this.access.setFavoriteCount(Math.max(0, this.access.getFavoriteCount() + (next ? -1 : 1)));
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.access.isDestroyed()) this.access.setActionBusy(false);
    }
  }

  async submitCoin(): Promise<void> {
    if (this.access.isActionBusy()) return;
    const available: number = Math.max(0, 2 - this.access.getCoinCountByMe());
    const multiply: number = Math.min(this.access.getCoinChoice(), available);
    if (multiply <= 0) {
      this.access.setCoinSheetOpen(false);
      return;
    }
    this.access.setActionBusy(true);
    this.access.bumpCoinVersion();
    if (this.access.getCoinWithLike()) this.access.bumpLikeVersion();
    // 乐观更新：先变红并收起弹层，失败再整体回滚。
    const likedBefore: boolean = this.access.getLiked();
    this.access.setCoinCountByMe(this.access.getCoinCountByMe() + multiply);
    this.access.setCoinCount(this.access.getCoinCount() + multiply);
    if (this.access.getCoinWithLike() && !this.access.getLiked()) {
      this.access.setLiked(true);
      this.access.setLikeCount(this.access.getLikeCount() + 1);
    }
    this.access.setCoinSheetOpen(false);
    const rollback = (): void => {
      this.access.setCoinCountByMe(Math.max(0, this.access.getCoinCountByMe() - multiply));
      this.access.setCoinCount(Math.max(0, this.access.getCoinCount() - multiply));
      if (this.access.getCoinWithLike() && !likedBefore) {
        this.access.setLiked(false);
        this.access.setLikeCount(Math.max(0, this.access.getLikeCount() - 1));
      }
    };
    try {
      const result: ActionResult = await BiliApi.coinVideo(this.access.getAid(), this.access.getBvid(), multiply,
        this.access.getCoinWithLike());
      if (this.access.isDestroyed()) return;
      if (!result.ok) {
        rollback();
        this.access.toast(result.message);
        return;
      }
      this.access.toast('投币成功');
    } catch (e) {
      if (!this.access.isDestroyed()) {
        rollback();
        this.access.toast('网络异常，请稍后重试');
      }
    } finally {
      if (!this.access.isDestroyed()) this.access.setActionBusy(false);
    }
  }

}
