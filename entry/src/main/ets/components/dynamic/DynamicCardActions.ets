import { DynamicItem } from '../../model/Models';
import { ActionResult } from '../../api/BiliApi';
import { DynamicApi } from '../../api/DynamicApi';
import { AuthSession } from '../../services/auth/AuthSession';
import { UserStore } from '../../services/auth/UserStore';

export class DynamicActionState {
  liked: boolean = false;
  likeCount: number = 0;
  forwardCount: number = 0;
  busy: boolean = false;
}

/** 复用卡片的互动事务：分离账号有效期、模型身份与乐观回滚。 */
export class DynamicCardActions {
  private liked: boolean = false;
  private likeCount: number = 0;
  private forwardCount: number = 0;
  private actionBusy: boolean = false;
  private actionGeneration: number = 0;
  private actionItem: DynamicItem | null = null;

  private getItem: () => DynamicItem;
  private getLikeCallback: () => ((dynId: string, liked: boolean, count: number) => void);
  private publish: (state: DynamicActionState) => void;
  private toast: (message: string) => void;

  constructor(getItem: () => DynamicItem,
    getLikeCallback: () => ((dynId: string, liked: boolean, count: number) => void),
    publish: (state: DynamicActionState) => void, toast: (message: string) => void) {
    this.getItem = getItem;
    this.getLikeCallback = getLikeCallback;
    this.publish = publish;
    this.toast = toast;
  }

  sync(): void {
    const item: DynamicItem = this.getItem();
    // 乐观字段引发的 @Watch 不会撤销自己的事务；重绑相同 id 的新模型仍会失效。
    if (this.actionItem !== item) {
      this.actionGeneration++;
      this.actionBusy = false;
      this.actionItem = item;
    }
    this.liked = item.liked;
    this.likeCount = item.like;
    this.forwardCount = item.forward;
    this.emit();
  }

  invalidate(): void {
    this.actionGeneration++;
    this.actionBusy = false;
    this.emit();
  }

  private emit(): void {
    this.publish({ liked: this.liked, likeCount: this.likeCount,
      forwardCount: this.forwardCount, busy: this.actionBusy });
  }

  async toggleLike(): Promise<void> {
    if (this.actionBusy) return;
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再点赞');
      return;
    }
    if (this.getItem().dynId.length === 0) return;
    // 点赞期间卡片可能被复用成另一条动态：本地状态只允许写回同一 dynId 的卡片，跨卡写入会串卡。
    const dynId: string = this.getItem().dynId;
    const item: DynamicItem = this.getItem();
    this.actionItem = item;
    const generation: number = ++this.actionGeneration;
    const session: number = AuthSession.version;
    const onLikeResult: (dynId: string, liked: boolean, count: number) => void = this.getLikeCallback();
    const isCurrent = (): boolean => this.actionGeneration === generation &&
      AuthSession.version === session && this.getItem() === item;
    const next: boolean = this.liked ? false : true;
    const prevLiked: boolean = this.liked;
    const prevCount: number = this.likeCount;
    const nextCount: number = Math.max(0, prevCount + (next ? 1 : -1));
    // 乐观更新只写本卡 UI（@Prop 深拷贝），权威值由 onLikeResult 回写父级数据源。
    this.liked = next;
    this.likeCount = nextCount;
    this.getItem().liked = next;
    this.getItem().like = nextCount;
    this.actionBusy = true;
    this.emit();
    try {
      const result: ActionResult = await DynamicApi.likeDynamic(dynId, next);
      if (AuthSession.version !== session) return;
      if (result.ok === false) {
        if (isCurrent()) {
          this.liked = prevLiked;
          this.likeCount = prevCount;
          this.getItem().liked = prevLiked;
          this.getItem().like = prevCount;
          this.toast(result.message);
        }
      } else {
        // 接口成功才回写数据源真身：卡片复用重建（aboutToReuse → syncFromItem）从数据源回读，
        // 不回写则点赞态会随回收滚动回退。回调按 dynId 定位，卡片即使已复用也不受影响。
        onLikeResult(dynId, next, nextCount);
        if (isCurrent()) this.toast(next ? '点赞成功' : '已取消点赞');
      }
    } catch (e) {
      if (isCurrent()) {
        this.liked = prevLiked;
        this.likeCount = prevCount;
        this.getItem().liked = prevLiked;
        this.getItem().like = prevCount;
        this.toast('网络异常，请稍后重试');
      }
    } finally {
      if (this.actionGeneration === generation && this.getItem() === item) {
        this.actionBusy = false;
        this.emit();
      }
    }
  }

  async forwardDynamic(): Promise<void> {
    if (this.actionBusy) return;
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再转发');
      return;
    }
    if (this.getItem().dynId.length === 0) return;
    const item: DynamicItem = this.getItem();
    this.actionItem = item;
    const generation: number = ++this.actionGeneration;
    const session: number = AuthSession.version;
    const isCurrent = (): boolean => this.actionGeneration === generation &&
      AuthSession.version === session && this.getItem() === item;
    this.actionBusy = true;
    this.emit();
    try {
      const result: ActionResult = await DynamicApi.repostDynamic(item.dynId);
      if (!isCurrent()) return;
      if (result.ok) {
        this.forwardCount++;
        this.getItem().forward = this.forwardCount;
        this.toast('转发成功');
      } else {
        this.toast(result.message);
      }
    } catch (e) {
      if (isCurrent()) this.toast('网络异常，请稍后重试');
    } finally {
      if (this.actionGeneration === generation && this.getItem() === item) {
        this.actionBusy = false;
        this.emit();
      }
    }
  }

}
