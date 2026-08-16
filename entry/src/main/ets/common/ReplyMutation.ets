/**
 * 评论点赞/点踩乐观更新的共享实现。
 *
 * 背景：ReplyCard 的 @Prop item 是深拷贝快照，改它既不影响数据源也不会刷新 UI。
 * 必须在数据源里的"真身"上执行修改，再克隆换引用（rev+1 进入列表键）驱动重渲染。
 * ArkUI 响应式要求页面自己重新赋值 @State 字段，因此本模块只提供：
 * 1. “找到真身 → mutate → 克隆 rev+1”的核心操作（页面负责把克隆写回自己的 @State/数据源）；
 * 2. like/dislike 的完整乐观更新流程（登录检查、busy 防重入、乐观改、API 调用、失败回滚），
 *    页面通过 ReplyReactionHooks 注入各自的登录处理、toast、oid/type 兜底等上下文。
 */
import { ReplyItem } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';

/** 在数组中按 rpid 找到真身并 mutate 后的结果：克隆（rev 已 +1）与原下标。 */
export class ReplyCloneResult {
  clone: ReplyItem = new ReplyItem();
  index: number = 0;
}

/** 对单个 ReplyItem 真身执行 mutate，返回 rev+1 的克隆（用于换引用触发重渲染）。 */
export function mutatedReplyClone(item: ReplyItem, mutate: (target: ReplyItem) => void): ReplyItem {
  mutate(item);
  const next: ReplyItem = item.clone();
  next.rev = item.rev + 1;
  return next;
}

/** 在数组中按 rpid 找到真身执行 mutate，返回克隆与下标；未找到返回 null（不改动数组）。 */
export function mutateReplyInArray(list: Array<ReplyItem>, rpid: number,
  mutate: (target: ReplyItem) => void): ReplyCloneResult | null {
  for (let i: number = 0; i < list.length; i++) {
    if (list[i].rpid === rpid) {
      const result: ReplyCloneResult = new ReplyCloneResult();
      result.clone = mutatedReplyClone(list[i], mutate);
      result.index = i;
      return result;
    }
  }
  return null;
}

/**
 * 页面侧"评论项状态修改统一入口"的签名：同一 rpid 可能同时存在于主列表、
 * 楼中楼列表和楼中楼根节点，页面逐处各改一次并返回任一真身（未找到返回 null）。
 */
export type ReplyItemMutator = (rpid: number, mutate: (target: ReplyItem) => void) => ReplyItem | null;

/** like/dislike 流程中页面必须注入的上下文。 */
export interface ReplyReactionHooks {
  /** 登录检查：未登录时页面自行 toast + 跳登录，返回 false 终止流程。 */
  ensureLogin: () => boolean;
  toast: (message: string) => void;
  isDestroyed: () => boolean;
  /** 接口 oid：各页兜底策略不同（item.oid 优先或直接取页面 oid），由页面决定。 */
  resolveOid: (item: ReplyItem) => number;
  /** 接口 type：同上。 */
  resolveType: (item: ReplyItem) => number;
  /** 赞踩互斥：点赞成功时是否本地清踩（视频详情页为 true，其余页面为 false）。 */
  clearDislikeOnLike: boolean;
}

/** 评论点赞：乐观更新主题色与计数，接口拒绝或网络异常时精确回滚。 */
export async function runReplyLike(item: ReplyItem, busy: Set<number>, mutateItem: ReplyItemMutator,
  hooks: ReplyReactionHooks): Promise<void> {
  if (!hooks.ensureLogin() || busy.has(item.rpid)) return;
  busy.add(item.rpid);
  const current: ReplyItem | null = mutateItem(item.rpid, () => {});
  if (current === null) {
    busy.delete(item.rpid);
    return;
  }
  const next: boolean = !current.liked;
  mutateItem(item.rpid, (target: ReplyItem) => {
    target.liked = next;
    target.like = Math.max(0, target.like + (next ? 1 : -1));
    if (hooks.clearDislikeOnLike && next && target.disliked) target.disliked = false;
  });
  const rollback = (): void => {
    mutateItem(item.rpid, (target: ReplyItem) => {
      target.liked = !next;
      target.like = Math.max(0, target.like + (next ? -1 : 1));
    });
  };
  try {
    const result: ActionResult = await BiliApi.likeReply(hooks.resolveOid(item), hooks.resolveType(item),
      item.rpid, next);
    if (hooks.isDestroyed()) return;
    if (!result.ok) {
      rollback();
      hooks.toast(result.message);
    }
  } catch (e) {
    if (!hooks.isDestroyed()) {
      rollback();
      hooks.toast('评论点赞失败，请稍后重试');
    }
  } finally {
    busy.delete(item.rpid);
  }
}

/** 评论点踩：踩赞互斥（踩上时本地取消赞），失败整体回滚。 */
export async function runReplyDislike(item: ReplyItem, busy: Set<number>, mutateItem: ReplyItemMutator,
  hooks: ReplyReactionHooks): Promise<void> {
  if (!hooks.ensureLogin() || busy.has(item.rpid)) return;
  busy.add(item.rpid);
  const current: ReplyItem | null = mutateItem(item.rpid, () => {});
  if (current === null) {
    busy.delete(item.rpid);
    return;
  }
  const next: boolean = !current.disliked;
  const wasLiked: boolean = current.liked;
  mutateItem(item.rpid, (target: ReplyItem) => {
    target.disliked = next;
    if (next && target.liked) {
      target.liked = false;
      target.like = Math.max(0, target.like - 1);
    }
  });
  const rollback = (): void => {
    mutateItem(item.rpid, (target: ReplyItem) => {
      target.disliked = !next;
      if (next && wasLiked) {
        target.liked = true;
        target.like++;
      }
    });
  };
  try {
    const result: ActionResult = await BiliApi.hateReply(hooks.resolveOid(item), hooks.resolveType(item),
      item.rpid, next);
    if (hooks.isDestroyed()) return;
    if (!result.ok) {
      rollback();
      hooks.toast(result.message);
    }
  } catch (e) {
    if (!hooks.isDestroyed()) {
      rollback();
      hooks.toast('点踩失败，请稍后重试');
    }
  } finally {
    busy.delete(item.rpid);
  }
}
