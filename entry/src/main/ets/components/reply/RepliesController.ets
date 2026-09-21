/**
 * 评论编排控制器：主评论列表分页、排序切换、楼中楼分页、评论项状态修改与评论分享图。
 *
 * 从 VideoDetail / DynamicDetail / BangumiDetail 抽出（三页原本逐行重复）。
 * 注入模式同 VideoActionController：@State 全部留在页面（ArkUI 响应式要求页面自己
 * 重新赋值状态字段），控制器经 RepliesAccess 闭包读写；游标、请求代际（RequestEpoch）、
 * 重试标记与分享卡临时状态是纯编排内部量，由控制器自己持有。
 *
 * 页面差异全部参数化，方法体与抽取前逐行等价：
 * - oid/type 解析：动态取 item.commentId/commentType，番剧取当前集 aid（type=1），视频取 detail.aid（type=1）；
 * - 排序清列表分叉：视频/番剧切排序清空列表与游标，动态特意保留旧楼层（clearOnSort）；
 * - 视频页专属的 sanitize/预取/localSentReplies 合并/日志经可选钩子注入，不污染共享流程。
 * 本文件不 import 任何页面 struct。
 */
import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { ReplyCloneResult, mutateReplyInArray, mutatedReplyClone } from '../../common/ReplyMutation';
import { ReplyData, ReplyItem } from '../../model/Models';
import { CommentApi } from '../../api/CommentApi';
import { makeReplyQr, makeReplyShareSnapshot, sharePixelMapAsImage } from './ReplyShareCard';

/**
 * 页面评论编排状态的读写面：@State 留在页面，控制器经闭包读写。
 * 成员统一用「属性 + 箭头函数」声明：ArkTS 的对象字面量检查只按属性语法匹配。
 * 可选成员是页面差异钩子（视频页的日志/预取/清洗等），未注入时走共享默认路径。
 */
export interface RepliesAccess {
  /** 页面销毁标记：异步回调回来后不再写任何状态（与抽取前各守卫一致）。 */
  isDestroyed: () => boolean;
  toast: (message: string) => void;
  getUIContext: () => UIContext;

  /** 评论主体 oid/type：动态取 item.commentId/commentType，番剧取当前集 aid，视频取 detail.aid。 */
  resolveOid: () => number;
  resolveType: () => number;
  /** 进入主评论加载前的页面级前置守卫（动态页校验 commentId/commentType > 0，其余页面恒真）。 */
  canLoadReplies: () => boolean;

  // ===== 主评论列表 =====
  getMainSource: () => BasicDataSource<ReplyItem>;
  getSortMode: () => number;
  setSortMode: (value: number) => void;
  getRepliesLoading: () => boolean;
  setRepliesLoading: (value: boolean) => void;
  getRepliesHasMore: () => boolean;
  setRepliesHasMore: (value: boolean) => void;
  getRepliesCount: () => number;
  setRepliesCount: (value: number) => void;
  /** 发起请求前清错误态：动态/番剧复位 repliesFailed/repliesMoreFailed，视频页清 replyLoadError。 */
  clearRepliesError: (reset: boolean) => void;
  /** 请求失败（代际内）：动态/番剧按已有楼层数写 failed/moreFailed，视频页写 replyLoadError 并记日志。 */
  showRepliesError: (reset: boolean, cursor: string, startedAt: number, error: Object) => void;
  /** 首屏写入主列表：动态/番剧整表 reset，视频页 sanitize + localSentReplies 合并。 */
  applyRepliesReset: (incoming: Array<ReplyItem>) => void;
  /** 翻页追加主列表：动态/番剧直接 append，视频页按 rpid 去重追加。 */
  applyRepliesAppend: (incoming: Array<ReplyItem>) => void;

  // ===== 楼中楼 =====
  getThreadRoot: () => ReplyItem;
  setThreadRoot: (root: ReplyItem) => void;
  getThreadReplies: () => Array<ReplyItem>;
  setThreadReplies: (list: Array<ReplyItem>) => void;
  getThreadLoading: () => boolean;
  setThreadLoading: (value: boolean) => void;
  getThreadHasMore: () => boolean;
  setThreadHasMore: (value: boolean) => void;
  /** 响应是否已过期：动态/番剧校验面板仍打开且根节点未变，视频页校验根节点与 aid 均未变。 */
  isThreadStale: (root: number, oid: number) => boolean;
  /** 楼中楼数据合并口径：动态/番剧 reset 整表替换 + concat 追加，视频页按 rpid 合并保留预览楼层。 */
  mergeThreadReplies: (current: Array<ReplyItem>, incoming: Array<ReplyItem>, reset: boolean) => Array<ReplyItem>;
  /** 楼中楼加载失败（代际内）：动态/番剧 toast 提示，视频页记日志保持静默。 */
  onThreadError: (reset: boolean, startedAt: number, error: Object) => void;

  // ===== 评论项修改 / 分享 =====
  /** 重渲染版本号：动态/番剧为 replyVersion，视频页为 replyLikeVersion。 */
  bumpVersion: () => void;
  getVersion: () => number;
  /** 分享链接：视频 /video/bvid、动态 t.bilibili.com/<dynId>、番剧 bangumi/play/ep<epId>。 */
  buildShareLink: (item: ReplyItem) => string;
  /** 离屏分享卡内容（页面 @Builder）。 */
  renderShareCard: () => void;
  /** 分享前置检查：番剧校验 hostContext 非空（失败自行 toast），其余页面直接通过。 */
  ensureShareContext: (context: common.UIAbilityContext | undefined) => boolean;
  /** 分享失败兜底：视频页降级为复制链接，动态/番剧 toast 提示。 */
  onShareFailed: (item: ReplyItem, link: string, error: Object) => void;

  // ===== 可选钩子（当前仅视频页注入） =====
  /** 主评论加载被守卫拦下时（视频页用于 ui.replies.skip 日志）。 */
  onRepliesSkip?: (reset: boolean, loading: boolean, hasMore: boolean) => void;
  /** 主评论请求发出后（视频页用于复位预取计数并记 ui.replies.start 日志）。 */
  onRepliesStart?: (reset: boolean, cursor: string, before: number) => void;
  /** 主评论响应被更新的代际丢弃时（视频页用于 ui.replies.drop 日志）。 */
  onRepliesDropped?: (rows: number) => void;
  /** 主评论一页写入成功后（视频页用于 ui.replies.done 日志）。 */
  onRepliesDone?: (reset: boolean, incoming: number, before: number, cursor: string, hasMore: boolean,
    startedAt: number) => void;
  /** 一页写入完成且未被丢弃后：动态页滚动到评论区，视频页按需自动续取。 */
  afterRepliesLoaded?: (reset: boolean) => Promise<void>;
  /** 排序切换被跳过时（视频页用于 ui.replies.sort.skip 日志）。 */
  onSortSkip?: (current: number, requested: number) => void;
  /** 排序切换生效前（视频页用于 ui.replies.sort 日志）。 */
  onSortChange?: (from: number, to: number) => void;
  /** 清列表之后、重新拉首屏之前：视频页借此关闭楼中楼面板。 */
  onSortApplied?: () => void;
  /** 楼中楼加载被守卫拦下时（视频页用于 ui.thread.skip 日志，自行按条件过滤）。 */
  onThreadSkip?: (reset: boolean) => void;
  /** 楼中楼请求发出后（视频页用于 ui.thread.start 日志）。 */
  onThreadStart?: (reset: boolean, root: number, oid: number, cursor: string, before: number) => void;
  /** 楼中楼一页写入成功后（视频页用于 ui.thread.done 日志）。 */
  onThreadDone?: (reset: boolean, incoming: number, before: number, cursor: string, hasMore: boolean,
    startedAt: number) => void;
  /** 评论项修改完成后（视频页用于 ui.reply.mutate 日志）。 */
  onAfterMutate?: (rpid: number, mainChanged: boolean, threadChanged: boolean, rootChanged: boolean,
    found: boolean) => void;
  /** 楼中楼一页加载完成后（视频页按已声明回复数自动续取）。 */
  afterThreadLoaded?: (allowPrefetch: boolean) => Promise<void>;
}

export class RepliesController {
  private readonly access: RepliesAccess;
  /** 切换排序时是否清空主列表：视频/番剧为 true，动态页特意保留旧楼层直到新首屏返回。 */
  private readonly clearOnSort: boolean;
  private replyCursor: string = '';
  private repliesEpoch: RequestEpoch = new RequestEpoch();
  /** 保留现有楼层直到新排序首屏返回时记录本次是否为 reset（重试按钮据此选择 reset/翻页）。 */
  private repliesRetryReset: boolean = false;
  private threadCursor: string = '';
  private threadEpoch: RequestEpoch = new RequestEpoch();
  /** 服务端交付过的最大 rev：加载路径给新条目盖更高的 rev，让卡片镜像守卫接受服务端真值。 */
  private deliveredRevCeiling: number = 0;
  // 评论分享卡离屏渲染用的待截内容；只在生成分享图期间短暂赋值。
  private shareCardItem: ReplyItem = new ReplyItem();
  private shareCardQr: image.PixelMap | null = null;
  private shareCardBusy: boolean = false;

  constructor(access: RepliesAccess, clearOnSort: boolean) {
    this.access = access;
    this.clearOnSort = clearOnSort;
  }

  async load(reset: boolean): Promise<void> {
    if (this.access.isDestroyed() || !this.access.canLoadReplies() ||
      (!reset && (this.access.getRepliesLoading() || !this.access.getRepliesHasMore()))) {
      if (this.access.onRepliesSkip !== undefined) {
        this.access.onRepliesSkip(reset, this.access.getRepliesLoading(), this.access.getRepliesHasMore());
      }
      return;
    }
    const request: number = this.repliesEpoch.next();
    const oid: number = this.access.resolveOid();
    if (oid <= 0) {
      this.access.setRepliesLoading(false);
      return;
    }
    const type: number = this.access.resolveType();
    this.repliesRetryReset = reset;
    this.access.setRepliesLoading(true);
    this.access.clearRepliesError(reset);
    const cursor: string = reset ? '' : this.replyCursor;
    const startedAt: number = Date.now();
    const before: number = this.access.getMainSource().totalCount();
    if (this.access.onRepliesStart !== undefined) this.access.onRepliesStart(reset, cursor, before);
    let loaded: boolean = false;
    try {
      const data: ReplyData = await CommentApi.getReplies(oid, type, cursor, this.access.getSortMode());
      if (this.access.isDestroyed() || !this.repliesEpoch.isCurrent(request)) {
        if (this.access.onRepliesDropped !== undefined) this.access.onRepliesDropped(data.replies.length);
        return;
      }
      if (reset) this.access.applyRepliesReset(this.stampServerRevs(data.replies));
      else this.access.applyRepliesAppend(this.stampServerRevs(data.replies));
      this.access.setRepliesCount(this.access.getMainSource().totalCount());
      this.replyCursor = data.cursor;
      this.access.setRepliesHasMore(data.hasMore);
      loaded = true;
      if (this.access.onRepliesDone !== undefined) {
        this.access.onRepliesDone(reset, data.replies.length, before, this.replyCursor, data.hasMore, startedAt);
      }
    } catch (e) {
      if (this.access.isDestroyed() || !this.repliesEpoch.isCurrent(request)) return;
      this.access.showRepliesError(reset, cursor, startedAt, e as Object);
    } finally {
      if (!this.access.isDestroyed() && this.repliesEpoch.isCurrent(request)) {
        this.access.setRepliesLoading(false);
      }
    }
    if (!loaded || this.access.isDestroyed() || !this.repliesEpoch.isCurrent(request)) return;
    if (this.access.afterRepliesLoaded !== undefined) await this.access.afterRepliesLoaded(reset);
  }

  changeReplySort(mode: number): void {
    if (this.access.getSortMode() === mode || this.access.isDestroyed()) {
      if (this.access.onSortSkip !== undefined) this.access.onSortSkip(this.access.getSortMode(), mode);
      return;
    }
    if (this.access.onSortChange !== undefined) this.access.onSortChange(this.access.getSortMode(), mode);
    this.access.setSortMode(mode);
    if (this.clearOnSort) {
      this.replyCursor = '';
      this.access.setRepliesHasMore(true);
      this.access.getMainSource().clear();
      this.access.setRepliesCount(0);
    }
    if (this.access.onSortApplied !== undefined) this.access.onSortApplied();
    this.load(true).catch(() => {
    });
  }

  async loadThread(reset: boolean, allowPrefetch: boolean = true): Promise<void> {
    const oid: number = this.access.resolveOid();
    if (oid <= 0) return;
    if ((!reset && this.access.getThreadLoading()) || this.access.getThreadRoot().rpid <= 0 ||
      (!reset && !this.access.getThreadHasMore())) {
      if (this.access.onThreadSkip !== undefined) this.access.onThreadSkip(reset);
      return;
    }
    const epoch: number = this.threadEpoch.next();
    this.access.setThreadLoading(true);
    const root: number = this.access.getThreadRoot().rpid;
    const cursor: string = reset ? '' : this.threadCursor;
    const startedAt: number = Date.now();
    const before: number = this.access.getThreadReplies().length;
    if (this.access.onThreadStart !== undefined) this.access.onThreadStart(reset, root, oid, cursor, before);
    let loaded: boolean = false;
    try {
      const result: ReplyData = await CommentApi.getReplyReplies(oid, this.access.resolveType(), root, cursor);
      if (this.access.isDestroyed() || !this.threadEpoch.isCurrent(epoch) ||
        this.access.isThreadStale(root, oid)) return;
      this.access.setThreadReplies(this.access.mergeThreadReplies(this.access.getThreadReplies(),
        this.stampServerRevs(result.replies), reset));
      this.threadCursor = result.cursor;
      this.access.setThreadHasMore(result.hasMore);
      loaded = true;
      if (this.access.onThreadDone !== undefined) {
        this.access.onThreadDone(reset, result.replies.length, before, this.threadCursor, result.hasMore, startedAt);
      }
    } catch (e) {
      if (!this.threadEpoch.isCurrent(epoch)) return;
      this.access.onThreadError(reset, startedAt, e as Object);
    } finally {
      if (!this.access.isDestroyed() && this.threadEpoch.isCurrent(epoch)) {
        this.access.setThreadLoading(false);
      }
    }
    if (!loaded) return;
    if (this.access.afterThreadLoaded !== undefined) await this.access.afterThreadLoaded(allowPrefetch);
  }

  /**
   * 评论项状态修改统一入口：ReplyCard 的 @Prop item 是深拷贝快照，改它不生效。
   * 必须在数据源"真身"上修改，克隆换引用（rev+1 进入列表键）驱动重渲染。
   * 同一 rpid 可能同时存在于主列表、楼中楼列表和楼中楼根节点，逐处各改一次（它们各自渲染）。
   * 核心 mutate/克隆逻辑在 ReplyMutation 模块，这里负责把克隆写回页面状态。
   */
  mutate(rpid: number, mutate: (target: ReplyItem) => void): ReplyItem | null {
    let found: ReplyItem | null = null;
    let mainChanged: boolean = false;
    let threadChanged: boolean = false;
    let rootChanged: boolean = false;
    const mainSource: BasicDataSource<ReplyItem> = this.access.getMainSource();
    const main: ReplyCloneResult | null = mutateReplyInArray(mainSource.getAll(), rpid, mutate);
    if (main !== null) {
      found = main.clone;
      mainSource.updateItem(main.index, main.clone);
      mainChanged = true;
    }
    const threadList: Array<ReplyItem> = this.access.getThreadReplies();
    const thread: ReplyCloneResult | null = mutateReplyInArray(threadList, rpid, mutate);
    if (thread !== null) {
      if (found === null) found = thread.clone;
      threadList[thread.index] = thread.clone;
      this.access.setThreadReplies(threadList.slice());
      threadChanged = true;
    }
    if (this.access.getThreadRoot().rpid === rpid) {
      const next: ReplyItem = mutatedReplyClone(this.access.getThreadRoot(), mutate);
      if (found === null) found = next;
      this.access.setThreadRoot(next);
      rootChanged = true;
    }
    this.access.bumpVersion();
    if (this.access.onAfterMutate !== undefined) {
      this.access.onAfterMutate(rpid, mainChanged, threadChanged, rootChanged, found !== null);
    }
    return found;
  }

  /**
   * 给服务端下发的评论盖单调递增 rev（高于历史上交付过的所有值，也高于数据源现存值）。
   *
   * ReplyCard 的镜像守卫只接受 rev 严格更大的更新；而解析出的新条目 rev 恒为 0，
   * 一条评论被本地点过赞（mirrorRev 已推进）后，同会话内任何服务端真值刷新
   * （换排序重载、重试、分页合并）都会被守卫拒之门外，表现为点赞态错乱、
   * 与服务端脱节。盖高 rev 后：新交付必然通过守卫刷新镜像（服务端是权威），
   * 旧代过期快照（rev 更低）依然被拒；本地乐观推进从新基点继续 lockstep。
   */
  private stampServerRevs(items: Array<ReplyItem>): Array<ReplyItem> {
    if (items.length === 0) return items;
    let base: number = this.deliveredRevCeiling;
    const mainSource: BasicDataSource<ReplyItem> = this.access.getMainSource();
    const existing: Array<ReplyItem> = mainSource.getAll();
    for (let i: number = 0; i < existing.length; i++) {
      if (existing[i].rev > base) base = existing[i].rev;
    }
    const thread: Array<ReplyItem> = this.access.getThreadReplies();
    for (let i: number = 0; i < thread.length; i++) {
      if (thread[i].rev > base) base = thread[i].rev;
    }
    if (this.access.getThreadRoot().rev > base) base = this.access.getThreadRoot().rev;
    for (let i: number = 0; i < items.length; i++) {
      items[i].rev = base + 1 + i;
    }
    this.deliveredRevCeiling = base + items.length;
    return items;
  }

  /**
   * 评论分享：离屏渲染分享卡 → 截成 PNG → 系统分享面板（对齐 B 站"评论分享成图片"）。 */
  share(item: ReplyItem): void {
    if (this.shareCardBusy) return;
    this.shareCardBusy = true;
    this.access.toast('正在生成分享图片…');
    const link: string = this.access.buildShareLink(item);
    const host: common.UIAbilityContext | undefined =
      this.access.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    // 显式收窄后再交给页面钩子校验（番剧需要 hostContext 等），编译器要求非可选类型。
    if (host === undefined || !this.access.ensureShareContext(host)) {
      this.shareCardBusy = false;
      return;
    }
    const context: common.UIAbilityContext = host;
    const uiContext: UIContext = this.access.getUIContext();
    (async () => {
      this.shareCardItem = item;
      this.shareCardQr = await makeReplyQr(link);
      const pixelMap: image.PixelMap = await makeReplyShareSnapshot(uiContext,
        (): void => { this.access.renderShareCard(); });
      await sharePixelMapAsImage(context, pixelMap, 'reply_share_' + String(item.rpid));
    })().catch((e: Object) => {
      this.access.onShareFailed(item, link, e);
    }).finally(() => {
      // 截图 PixelMap 已在 sharePixelMapAsImage 内释放；二维码只服务本次渲染，一并回收。
      this.releaseShareCard();
      this.shareCardBusy = false;
    });
  }

  /** 释放分享卡二维码并复位；分享流程结束/页面销毁时调用，防止 PixelMap 滞留。 */
  releaseShareCard(): void {
    if (this.shareCardQr !== null) {
      try {
        this.shareCardQr.release();
      } catch (e) {
        // 已释放的二维码忽略。
      }
      this.shareCardQr = null;
    }
  }

  /** 离屏分享卡当前待截内容（页面 @Builder 读取；字段在截图前一次性赋值）。 */
  shareItem(): ReplyItem {
    return this.shareCardItem;
  }

  shareQr(): image.PixelMap | null {
    return this.shareCardQr;
  }

  /** 打开楼中楼：写入根节点与初始预览楼层，并复位游标与续拉标记。 */
  beginThread(root: ReplyItem, initialReplies: Array<ReplyItem>): void {
    this.access.setThreadRoot(root);
    this.access.setThreadReplies(initialReplies);
    this.threadCursor = '';
    this.access.setThreadHasMore(true);
  }

  /** 只更新楼中楼根节点（不动列表与游标）：定向回复/同步主列表计数时使用。 */
  updateThreadRoot(root: ReplyItem): void {
    this.access.setThreadRoot(root);
  }

  /** 作废在途楼中楼请求并复位 loading（关闭面板时调用）。 */
  cancelThread(): void {
    this.threadEpoch.invalidate();
    this.access.setThreadLoading(false);
  }

  /** 页面离场：作废主评论与楼中楼的全部在途请求。 */
  dispose(): void {
    this.repliesEpoch.invalidate();
    this.threadEpoch.invalidate();
    this.access.setThreadLoading(false);
  }

  /** 复位主评论分页（游标清空、允许续拉），配合 load(true) 重新拉首屏。 */
  resetMainPaging(): void {
    this.replyCursor = '';
    this.access.setRepliesHasMore(true);
  }

  /** 清空主评论（换集等）：游标、续拉标记、数据源与计数一起复位。 */
  clearMainReplies(): void {
    this.replyCursor = '';
    this.access.setRepliesHasMore(true);
    this.access.getMainSource().clear();
    this.access.setRepliesCount(0);
  }

  /** 复位楼中楼分页（发送失败回退整表刷新时使用）。 */
  resetThreadPaging(): void {
    this.threadCursor = '';
    this.access.setThreadHasMore(true);
  }

  /** 最近一次主评论请求是否为 reset（加载失败 footer/重试按钮据此选择 reset 或翻页）。 */
  getRepliesRetryReset(): boolean {
    return this.repliesRetryReset;
  }

  /** 当前主评论游标（视频页预取日志使用）。 */
  getReplyCursor(): string {
    return this.replyCursor;
  }
}
