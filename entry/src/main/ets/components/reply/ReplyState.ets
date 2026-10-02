import { ReplyItem } from '../../model/Models';
import { CommentLog } from '../../common/CommentLog';

export interface ReplySubject {
  readonly oid: number;
  readonly type: number;
}

export interface ReplyScope {
  isDestroyed: () => boolean;
  getSubject: () => ReplySubject;
}

export class MainRepliesState {
  sort: number = 3;
  loading: boolean = false;
  hasMore: boolean = true;
  count: number = 0;
  error: string = '';
  failed: boolean = false;
  moreFailed: boolean = false;
  version: number = 0;
}

export class ThreadRepliesState {
  root: ReplyItem = new ReplyItem();
  replies: Array<ReplyItem> = [];
  active: boolean = false;
  loading: boolean = false;
  hasMore: boolean = true;
  version: number = 0;
}

/** 楼层在三个可见位置共享同一修订时钟，服务端新值始终高于本地镜像版本。 */
export class ReplyRevisionClock {
  version: number = 0;
  private ceiling: number = 0;
  private readonly existing: () => Array<ReplyItem>;

  constructor(existing: () => Array<ReplyItem>) {
    this.existing = existing;
  }

  stamp(items: Array<ReplyItem>): Array<ReplyItem> {
    let base: number = this.ceiling;
    const existing: Array<ReplyItem> = this.existing();
    for (let i: number = 0; i < existing.length; i++) base = Math.max(base, existing[i].rev);
    for (let i: number = 0; i < items.length; i++) items[i].rev = base + i + 1;
    this.ceiling = base + items.length;
    return items;
  }
}

export function sameReplySubject(a: ReplySubject, b: ReplySubject): boolean {
  return a.oid === b.oid && a.type === b.type;
}

export function mergeUniqueReplies(base: Array<ReplyItem>, incoming: Array<ReplyItem>): Array<ReplyItem> {
  const result: Array<ReplyItem> = [];
  const indexes: Map<number, number> = new Map<number, number>();
  const all: Array<ReplyItem> = base.concat(incoming);
  for (let i: number = 0; i < all.length; i++) {
    const index: number | undefined = indexes.get(all[i].rpid);
    if (index === undefined) {
      indexes.set(all[i].rpid, result.length);
      result.push(all[i]);
    } else result[index] = all[i];
  }
  return result;
}

export function sanitizeReplies(items: Array<ReplyItem>, trace: boolean): Array<ReplyItem> {
  const seen: Set<number> = new Set<number>();
  const result: Array<ReplyItem> = [];
  let invalid: number = 0;
  let duplicate: number = 0;
  let empty: number = 0;
  for (let i: number = 0; i < items.length; i++) {
    const item: ReplyItem = items[i];
    if (item.rpid <= 0) { invalid++; continue; }
    if (seen.has(item.rpid)) { duplicate++; continue; }
    seen.add(item.rpid);
    if (item.content.trim().length === 0 && item.pictures.length === 0) { empty++; continue; }
    result.push(item);
  }
  if (trace) {
    const details: string = 'incoming=' + String(items.length) + ' kept=' + String(result.length) +
      ' invalid=' + String(invalid) + ' duplicate=' + String(duplicate) + ' empty=' + String(empty);
    if (invalid + duplicate + empty > 0) CommentLog.warn('ui.replies.sanitize.drop', details);
    else CommentLog.info('ui.replies.sanitize', details);
  }
  return result;
}
