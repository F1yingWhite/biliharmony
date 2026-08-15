import { ReplyItem } from '../model/Models';

export class ReplyTreeMeta {
  depth: number = 1;
  /** 每一层竖线是否需要继续连接到下一兄弟；最后一项属于当前节点。 */
  guides: Array<boolean> = [];
  hasChildren: boolean = false;
  collapsed: boolean = false;
}

export class ReplyTreeSnapshot {
  visible: Array<ReplyItem> = [];
  names: Map<number, string> = new Map<number, string>();
  meta: Map<number, ReplyTreeMeta> = new Map<number, ReplyTreeMeta>();
}

function walkReplies(parentRpid: number, depth: number, ancestorGuides: Array<boolean>,
  children: Map<number, Array<ReplyItem>>, collapsed: Set<number>, snapshot: ReplyTreeSnapshot,
  visited: Set<number>): void {
  const siblings: Array<ReplyItem> | undefined = children.get(parentRpid);
  if (siblings === undefined) return;
  for (let i: number = 0; i < siblings.length; i++) {
    const item: ReplyItem = siblings[i];
    if (visited.has(item.rpid)) continue;
    visited.add(item.rpid);
    const hasNext: boolean = i < siblings.length - 1;
    const descendants: Array<ReplyItem> | undefined = children.get(item.rpid);
    const node: ReplyTreeMeta = new ReplyTreeMeta();
    node.depth = depth;
    node.guides = ancestorGuides.concat([hasNext]);
    node.hasChildren = descendants !== undefined && descendants.length > 0;
    node.collapsed = collapsed.has(item.rpid);
    snapshot.meta.set(item.rpid, node);
    snapshot.visible.push(item);
    if (node.hasChildren && !node.collapsed) {
      walkReplies(item.rpid, depth + 1, node.guides, children, collapsed, snapshot, visited);
    }
  }
}

/**
 * 标记结构上已经挂到当前根评论下的所有节点。
 *
 * `visited` 只表示本次实际渲染过的节点；折叠分支的后代不会进入 `visited`。
 * 如果拿它判断孤立节点，折叠的子回复就会被错误地作为一级回复追加，表现为
 * 点“−”后内容向左跳而不是消失。
 */
function markAttached(parentRpid: number, children: Map<number, Array<ReplyItem>>,
  attached: Set<number>): void {
  const siblings: Array<ReplyItem> | undefined = children.get(parentRpid);
  if (siblings === undefined) return;
  for (let i: number = 0; i < siblings.length; i++) {
    const item: ReplyItem = siblings[i];
    if (attached.has(item.rpid)) continue;
    attached.add(item.rpid);
    markAttached(item.rpid, children, attached);
  }
}

/** 将接口的扁平回复数组整理为稳定的深度优先回复树。 */
export function buildReplyTree(rootRpid: number, replies: Array<ReplyItem>, collapsed: Set<number>): ReplyTreeSnapshot {
  const snapshot: ReplyTreeSnapshot = new ReplyTreeSnapshot();
  const validIds: Set<number> = new Set<number>();
  for (let i: number = 0; i < replies.length; i++) {
    if (replies[i].rpid > 0) {
      validIds.add(replies[i].rpid);
      snapshot.names.set(replies[i].rpid, replies[i].uname);
    }
  }
  const children: Map<number, Array<ReplyItem>> = new Map<number, Array<ReplyItem>>();
  const accepted: Set<number> = new Set<number>();
  for (let i: number = 0; i < replies.length; i++) {
    const item: ReplyItem = replies[i];
    if (item.rpid <= 0 || accepted.has(item.rpid)) continue;
    accepted.add(item.rpid);
    let parent: number = item.parentRpid;
    if (parent <= 0 || parent === item.rpid || (!validIds.has(parent) && parent !== rootRpid)) {
      // reply/reply 是分页扁平流：直接 parent 可能尚未加载，但 dialog 始终指向
      // 当前对话分组的首条回复。优先挂到已存在的 dialog，避免分页前后误挂根节点、
      // 折叠圆点突然换楼层；dialog 也缺失时才降级为一级回复。
      const dialog: number = item.dialogRpid;
      parent = dialog > 0 && dialog !== item.rpid && validIds.has(dialog) ? dialog : rootRpid;
    }
    let siblings: Array<ReplyItem> | undefined = children.get(parent);
    if (siblings === undefined) {
      siblings = [];
      children.set(parent, siblings);
    }
    siblings.push(item);
  }
  const attached: Set<number> = new Set<number>();
  markAttached(rootRpid, children, attached);
  const visited: Set<number> = new Set<number>();
  walkReplies(rootRpid, 1, [], children, collapsed, snapshot, visited);
  // 异常循环或缺失父节点不能让回复消失，降级为一级节点追加。
  for (let i: number = 0; i < replies.length; i++) {
    const item: ReplyItem = replies[i];
    // 折叠分支的后代虽然没有进入 visible/visited，但结构上仍然属于当前树，
    // 不能当作孤立回复回填，否则会从缩进位置跳到最左侧。
    if (item.rpid <= 0 || attached.has(item.rpid)) continue;
    const node: ReplyTreeMeta = new ReplyTreeMeta();
    node.depth = 1;
    node.guides = [false];
    node.hasChildren = children.has(item.rpid);
    node.collapsed = collapsed.has(item.rpid);
    snapshot.meta.set(item.rpid, node);
    snapshot.visible.push(item);
  }
  return snapshot;
}
