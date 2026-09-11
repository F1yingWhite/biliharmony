import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { LoadingView } from '../components/LoadingView';
import { RequestEpoch } from '../common/RequestEpoch';
/** 动态详情：首屏复用 feed 对象，随后从 detail 接口补齐正文、表情和评论 subject。 */
import { AppNavStack, DynamicDetailParam, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  ImageViewerSrcRect, NAV_LOGIN } from '../common/AppRouter';
import { DynamicItem, ReplyData, ReplyItem } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { DynCard } from '../views/DynamicView';
import { UserStore } from '../services/auth/UserStore';
import { display, FrameCallback, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { safeToast } from '../common/Toast';
import { image } from '@kit.ImageKit';
import { ReplyCard } from '../components/reply/ReplyCard';
import { ReplyComposer } from '../components/reply/ReplyComposer';
import { ReplyThreadPanel } from '../components/reply/ReplyThreadPanel';
import { ReplyShareCard, makeReplyQr, makeReplyShareSnapshot,
  sharePixelMapAsImage } from '../components/reply/ReplyShareCard';
import { ReplySortChips } from '../components/reply/ReplySortChips';
import { LayoutTokens } from '../common/LayoutTokens';
import { CommentApi } from '../api/CommentApi';
import { DynamicApi } from '../api/DynamicApi';
import { EmoteResolver } from '../common/EmoteResolver';
import {
  ReplyCloneResult, ReplyReactionHooks, mutateReplyInArray, mutatedReplyClone, runReplyDislike, runReplyLike
} from '../common/ReplyMutation';
import { asNumber, asObject } from '../common/Utils';

class DynamicHeroFrameCallback extends FrameCallback {
  private task: () => void;

  constructor(task: () => void) {
    super();
    this.task = task;
  }

  onFrame(_frameTimeInNano: number): void {
    this.task();
  }
}

@Component
export struct DynamicDetailPage {
  param: DynamicDetailParam = { item: new DynamicItem(), focusComments: false };
  @State item: DynamicItem = new DynamicItem();
  @State loading: boolean = false;
  @State loadFailed: boolean = false;
  @State replies: Array<ReplyItem> = [];
  @State repliesLoading: boolean = false;
  private repliesEpoch: RequestEpoch = new RequestEpoch();
  private repliesRetryReset: boolean = false;
  @State repliesFailed: boolean = false;
  @State repliesMoreFailed: boolean = false;
  @State repliesHasMore: boolean = true;
  @State replySortMode: number = 3; // 3 最热，2 最新
  @State replyVersion: number = 0;
  @State replyDraft: string = '';
  @State replySending: boolean = false;
  @State threadOpen: boolean = false;
  @State threadRoot: ReplyItem = new ReplyItem();
  @State threadReplies: Array<ReplyItem> = [];
  @State threadLoading: boolean = false;
  private threadEpoch: RequestEpoch = new RequestEpoch();
  @State threadHasMore: boolean = true;
  @State threadDraft: string = '';
  @State threadSending: boolean = false;
  @State threadTargetRpid: number = 0;
  @State threadTargetName: string = '';
  @State threadFocusTick: number = 0;
  @State contentOpacity: number = 1;
  @State heroVisible: boolean = false;
  @State heroPageX: number = 0;
  @State heroPageY: number = 0;
  @State heroPageWidth: number = 0;
  @State heroPageHeight: number = 0;
  @State heroPageRadius: number = 0;
  @State heroCardX: number = 0;
  @State heroCardY: number = 0;
  @State heroCardWidth: number = 0;
  @State heroCardHeight: number = 0;
  private entryFromRect: boolean = false;
  private entranceArmed: boolean = false;
  private closing: boolean = false;
  private screenWidthVp: number = 0;
  private screenHeightVp: number = 0;
  @StorageProp('dynamicDetailCloseRequest') @Watch('onCloseRequested') closeRequest: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private destroyed: boolean = false;
  private replyCursor: string = '';
  private replyLikeBusy: Set<number> = new Set<number>();
  private scroller: Scroller = new Scroller();
  private focusPerformed: boolean = false;
  private commentsOffset: number = 0;
  private threadCursor: string = '';
  // 评论分享卡离屏渲染用的待截内容；只在生成分享图期间短暂赋值。
  private shareCardItem: ReplyItem = new ReplyItem();
  private shareCardQr: image.PixelMap | null = null;
  private shareCardBusy: boolean = false;

  private toast(message: string): void {
    safeToast(this.getUIContext(), message);
  }

  private targetCardRect(): ImageViewerSrcRect {
    return {
      x: 10,
      y: Immersive.statusBarHeight() + 48,
      w: Math.max(0, this.screenWidthVp - 20),
      h: this.param.srcRect !== undefined ? this.param.srcRect.h : 0,
    };
  }

  private prepareEntrance(): void {
    const rect: ImageViewerSrcRect | undefined = this.param.srcRect;
    if (rect === undefined || rect.w <= 0 || rect.h <= 0) return;
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      this.screenWidthVp = this.getUIContext().px2vp(screen.width);
      this.screenHeightVp = this.getUIContext().px2vp(screen.height);
    } catch (e) {
      return;
    }
    if (this.screenWidthVp <= 0 || this.screenHeightVp <= 0) return;
    this.entryFromRect = true;
    this.contentOpacity = 0;
    this.heroVisible = true;
    this.heroPageX = rect.x;
    this.heroPageY = rect.y;
    this.heroPageWidth = rect.w;
    this.heroPageHeight = rect.h;
    this.heroPageRadius = 10;
    this.heroCardX = rect.x;
    this.heroCardY = rect.y;
    this.heroCardWidth = rect.w;
    this.heroCardHeight = rect.h;
    this.entranceArmed = true;
  }

  private triggerEntrance(): void {
    if (!this.entranceArmed || this.closing) return;
    this.entranceArmed = false;
    const target: ImageViewerSrcRect = this.targetCardRect();
    this.getUIContext().postFrameCallback(new DynamicHeroFrameCallback(() => {
      if (this.closing) return;
      this.getUIContext().animateTo({ duration: 340, curve: Curve.EaseOut, onFinish: () => {
        this.heroVisible = false;
      } }, () => {
        this.heroPageX = 0;
        this.heroPageY = 0;
        this.heroPageWidth = this.screenWidthVp;
        this.heroPageHeight = this.screenHeightVp;
        this.heroPageRadius = 0;
        this.heroCardX = target.x;
        this.heroCardY = target.y;
        this.heroCardWidth = target.w;
        this.heroCardHeight = target.h;
      });
      this.getUIContext().animateTo({ duration: 180, delay: 130, curve: Curve.EaseOut }, () => {
        this.contentOpacity = 1;
      });
    }));
  }

  onCloseRequested(): void {
    this.goBack();
  }

  private goBack(): void {
    if (this.closing) return;
    this.closing = true;
    const rect: ImageViewerSrcRect | undefined = this.param.srcRect;
    if (this.entryFromRect && rect !== undefined) {
      const start: ImageViewerSrcRect = this.targetCardRect();
      this.heroPageX = 0;
      this.heroPageY = 0;
      this.heroPageWidth = this.screenWidthVp;
      this.heroPageHeight = this.screenHeightVp;
      this.heroPageRadius = 0;
      this.heroCardX = start.x;
      this.heroCardY = start.y;
      this.heroCardWidth = start.w;
      this.heroCardHeight = start.h;
      this.heroVisible = true;
      this.contentOpacity = 0;
      this.getUIContext().postFrameCallback(new DynamicHeroFrameCallback(() => {
        AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
        AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 380);
        AppNavStack.pop();
        this.getUIContext().animateTo({ duration: 340, curve: Curve.EaseOut }, () => {
          this.heroPageX = rect.x;
          this.heroPageY = rect.y;
          this.heroPageWidth = rect.w;
          this.heroPageHeight = rect.h;
          this.heroPageRadius = 10;
          this.heroCardX = rect.x;
          this.heroCardY = rect.y;
          this.heroCardWidth = rect.w;
          this.heroCardHeight = rect.h;
        });
      }));
      return;
    }
    AppNavStack.pop();
  }

  aboutToAppear(): void {
    EmoteResolver.ensureLoaded();
    this.destroyed = false;
    this.closing = false;
    this.entryFromRect = false;
    this.contentOpacity = 1;
    this.heroVisible = false;
    this.item = this.param.item as DynamicItem;
    this.prepareEntrance();
    this.triggerEntrance();
    if (this.item.commentId > 0 && this.item.commentType > 0) {
      this.loadReplies(true).catch(() => {
      });
    }
    this.loadDetail().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.repliesEpoch.invalidate();
    this.threadEpoch.invalidate();
    this.threadLoading = false;
    this.destroyed = true;
  }

  private async loadDetail(): Promise<void> {
    if (this.item.dynId.length === 0 || this.loading) return;
    this.loading = true;
    this.loadFailed = false;
    try {
      const detail: DynamicItem | null = await DynamicApi.getDynamicDetail(this.item.dynId);
      if (!this.destroyed && detail !== null) {
        this.item = detail;
        if (this.replies.length === 0 && !this.repliesLoading) await this.loadReplies(true);
      }
      if (!this.destroyed && detail === null) this.loadFailed = true;
    } catch (e) {
      if (!this.destroyed) this.loadFailed = true;
    } finally {
      if (!this.destroyed) this.loading = false;
    }
  }

  private async loadReplies(reset: boolean): Promise<void> {
    if (this.destroyed || this.item.commentId <= 0 || this.item.commentType <= 0 ||
      (!reset && (this.repliesLoading || !this.repliesHasMore))) return;
    const request: number = this.repliesEpoch.next();
    this.repliesRetryReset = reset;
    this.repliesLoading = true;
    this.repliesMoreFailed = false;
    if (reset) this.repliesFailed = false;
    try {
      const data: ReplyData = await CommentApi.getReplies(this.item.commentId, this.item.commentType,
        reset ? '' : this.replyCursor, this.replySortMode);
      if (this.destroyed || !this.repliesEpoch.isCurrent(request)) return;
      this.replies = reset ? data.replies : this.replies.concat(data.replies);
      this.replyCursor = data.cursor;
      this.repliesHasMore = data.hasMore;
      if (this.param.focusComments === true && !this.focusPerformed) {
        this.focusPerformed = true;
        setTimeout(() => {
          if (!this.destroyed) this.scroller.scrollTo({ xOffset: 0, yOffset: this.commentsOffset, animation: true });
        }, 80);
      }
    } catch (e) {
      if (!this.destroyed && this.repliesEpoch.isCurrent(request)) {
        if (this.replies.length === 0) this.repliesFailed = true;
        else this.repliesMoreFailed = true;
      }
    } finally {
      if (!this.destroyed && this.repliesEpoch.isCurrent(request)) this.repliesLoading = false;
    }
  }

  /** 切换评论排序：清空列表与游标，重新拉第一页。 */
  private changeReplySort(mode: number): void {
    if (this.replySortMode === mode || this.destroyed) return;
    this.replySortMode = mode;
    this.replyCursor = '';
    this.repliesHasMore = true;
    this.replies = [];
    this.loadReplies(true).catch(() => {
    });
  }

  /**
   * 评论项状态修改统一入口：ReplyCard 的 @Prop item 是深拷贝快照，改它不生效。
   * 必须在数据源"真身"上修改，克隆换引用（rev+1 进入列表键）驱动重渲染。
   * 核心 mutate/克隆逻辑在 ReplyMutation 模块，这里只负责把克隆写回本页 @State。
   */
  private mutateReplyItem(rpid: number, mutate: (target: ReplyItem) => void): ReplyItem | null {
    let found: ReplyItem | null = null;
    const main: ReplyCloneResult | null = mutateReplyInArray(this.replies, rpid, mutate);
    if (main !== null) {
      found = main.clone;
      this.replies[main.index] = main.clone;
      this.replies = this.replies.slice();
    }
    const thread: ReplyCloneResult | null = mutateReplyInArray(this.threadReplies, rpid, mutate);
    if (thread !== null) {
      if (found === null) found = thread.clone;
      this.threadReplies[thread.index] = thread.clone;
      this.threadReplies = this.threadReplies.slice();
    }
    if (this.threadRoot.rpid === rpid) {
      const next: ReplyItem = mutatedReplyClone(this.threadRoot, mutate);
      if (found === null) found = next;
      this.threadRoot = next;
    }
    this.replyVersion++;
    return found;
  }

  private ensureReplyLogin(isLike: boolean): boolean {
    if (UserStore.isLogin) return true;
    this.toast(isLike ? '请先登录后再点赞' : '请先登录后再操作');
    AppNavStack.pushPathByName(NAV_LOGIN, null);
    return false;
  }

  private replyReactionHooks(isLike: boolean): ReplyReactionHooks {
    return {
      ensureLogin: () => this.ensureReplyLogin(isLike),
      toast: (message: string) => this.toast(message),
      isDestroyed: () => this.destroyed,
      resolveOid: (item: ReplyItem) => item.oid > 0 ? item.oid : this.item.commentId,
      resolveType: (item: ReplyItem) => item.type > 0 ? item.type : this.item.commentType,
      clearDislikeOnLike: false,
    };
  }

  private async likeReply(item: ReplyItem): Promise<void> {
    await runReplyLike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.mutateReplyItem(rpid, mutate),
      this.replyReactionHooks(true));
  }

  private async dislikeReply(item: ReplyItem): Promise<void> {
    await runReplyDislike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.mutateReplyItem(rpid, mutate),
      this.replyReactionHooks(false));
  }

  private closeReplyThread(): void {
    this.threadEpoch.invalidate();
    this.threadLoading = false;
    this.threadOpen = false;
  }

  private openReplyThread(root: ReplyItem): void {
    let latest: ReplyItem = root;
    for (let i: number = 0; i < this.replies.length; i++) {
      if (this.replies[i].rpid === root.rpid) {
        latest = this.replies[i];
        break;
      }
    }
    this.threadRoot = latest;
    this.threadReplies = latest.replies.slice();
    this.threadCursor = '';
    this.threadHasMore = true;
    this.threadTargetRpid = latest.rpid;
    this.threadTargetName = latest.uname;
    this.threadDraft = '';
    this.threadOpen = true;
    this.loadThreadReplies(true).catch(() => {
    });
  }

  private async loadThreadReplies(reset: boolean): Promise<void> {
    if ((!reset && this.threadLoading) || this.threadRoot.rpid <= 0 || (!reset && !this.threadHasMore)) return;
    const epoch: number = this.threadEpoch.next();
    this.threadLoading = true;
    const root: number = this.threadRoot.rpid;
    const cursor: string = reset ? '' : this.threadCursor;
    try {
      const result: ReplyData = await CommentApi.getReplyReplies(this.item.commentId, this.item.commentType,
        root, cursor);
      if (this.destroyed || !this.threadOpen || !this.threadEpoch.isCurrent(epoch) ||
        this.threadRoot.rpid !== root) return;
      const next: Array<ReplyItem> = reset ?
        (result.replies.length > 0 ? result.replies : this.threadReplies) :
        this.threadReplies.concat(result.replies);
      this.threadReplies = next;
      this.threadCursor = result.cursor;
      this.threadHasMore = result.hasMore;
    } catch (e) {
      if (!this.threadEpoch.isCurrent(epoch)) return;
      if (!this.destroyed) this.toast('回复加载失败，请稍后重试');
    } finally {
      if (!this.destroyed && this.threadEpoch.isCurrent(epoch)) this.threadLoading = false;
    }
  }

  private sentThreadReply(result: ActionResult, message: string, parent: number): ReplyItem | null {
    const returned: ReplyItem = ReplyItem.from(asObject(result.data['reply']));
    const rpid: number = returned.rpid > 0 ? returned.rpid :
      asNumber(result.data['rpid'], asNumber(result.data['rpid_str'], 0));
    if (rpid <= 0) return null;
    const reply: ReplyItem = returned.rpid > 0 ? returned : new ReplyItem();
    const user = UserStore.current;
    reply.rpid = rpid;
    reply.oid = this.item.commentId;
    reply.type = this.item.commentType;
    reply.rootRpid = this.threadRoot.rpid;
    reply.parentRpid = parent;
    reply.dialogRpid = asNumber(result.data['dialog'], reply.dialogRpid);
    if (reply.mid <= 0 && user !== null) reply.mid = user.mid;
    if (reply.uname.length === 0) reply.uname = user !== null && user.uname.length > 0 ? user.uname : '我';
    if (reply.avatar.length === 0 && user !== null) reply.avatar = user.face;
    if (reply.level <= 0 && user !== null) reply.level = user.level;
    if (reply.content.length === 0) reply.content = message;
    if (reply.ctime <= 0) reply.ctime = Math.floor(Date.now() / 1000);
    return reply;
  }

  private async sendThreadReply(): Promise<void> {
    const message: string = this.threadDraft.trim();
    if (message.length === 0 || this.threadSending || !UserStore.isLogin) return;
    this.threadSending = true;
    try {
      const parent: number = this.threadTargetRpid > 0 ? this.threadTargetRpid : this.threadRoot.rpid;
      const result: ActionResult = await CommentApi.addReply(this.item.commentId, this.item.commentType, message,
        this.threadRoot.rpid, parent);
      if (this.destroyed) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.threadDraft = '';
      const sent: ReplyItem | null = this.sentThreadReply(result, message, parent);
      if (sent !== null) {
        this.threadReplies = [sent].concat(this.threadReplies.filter((item: ReplyItem) => item.rpid !== sent.rpid));
        const root: ReplyItem = this.threadRoot.clone();
        root.count++;
        root.replies = [sent].concat(root.replies.filter((item: ReplyItem) => item.rpid !== sent.rpid));
        this.threadRoot = root;
        for (let i: number = 0; i < this.replies.length; i++) {
          if (this.replies[i].rpid === root.rpid) this.replies[i] = root;
        }
        this.replies = this.replies.slice();
        this.threadTargetRpid = root.rpid;
        this.threadTargetName = root.uname;
        this.toast('回复成功');
      } else {
        await this.loadThreadReplies(true);
      }
    } finally {
      if (!this.destroyed) this.threadSending = false;
    }
  }

  private navigateFromThread(action: () => void): void {
    this.closeReplyThread();
    setTimeout(() => {
      if (!this.destroyed) action();
    }, 260);
  }

  /** 评论分享：离屏渲染分享卡 → 截成 PNG → 系统分享面板（对齐 B 站"评论分享成图片"）。 */
  private shareReplyAsImage(item: ReplyItem): void {
    if (this.shareCardBusy) return;
    this.shareCardBusy = true;
    this.toast('正在生成分享图片…');
    const link: string = 'https://t.bilibili.com/' + this.item.dynId + '#reply' + String(item.rpid);
    const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const uiContext: UIContext = this.getUIContext();
    (async () => {
      this.shareCardItem = item;
      this.shareCardQr = await makeReplyQr(link);
      const pixelMap: image.PixelMap = await makeReplyShareSnapshot(uiContext,
        (): void => { this.ReplyShareCardBuilder(); });
      await sharePixelMapAsImage(context, pixelMap, 'reply_share_' + String(item.rpid));
    })().catch(() => {
      this.toast('分享图片生成失败，请稍后重试');
    }).finally(() => {
      this.shareCardBusy = false;
    });
  }

  /** 离屏分享卡内容；字段在截图前一次性赋值，渲染期间不变化。 */
  @Builder
  ReplyShareCardBuilder() {
    ReplyShareCard({
      item: this.shareCardItem,
      upMid: this.item.mid,
      qr: this.shareCardQr,
      linkLabel: 't.bilibili.com/' + this.item.dynId,
      sourceCover: this.item.cover,
      sourceTitle: this.item.title.length > 0 ? this.item.title : this.item.content,
      sourceUpName: this.item.uname,
      scanHint: '长按扫码查看动态',
    })
  }

  @Builder
  ThreadSheet() {
    ReplyThreadPanel({
      root: this.threadRoot,
      replies: this.threadReplies,
      loading: this.threadLoading,
      hasMore: this.threadHasMore,
      version: this.replyVersion,
      draft: this.threadDraft,
      sending: this.threadSending,
      replyTargetName: this.threadTargetName,
      focusTick: this.threadFocusTick,
      focusId: 'dynamic_thread_reply_composer_editor',
      upMid: this.item.mid,
      onClose: () => this.closeReplyThread(),
      onLike: (item: ReplyItem) => this.likeReply(item).catch(() => {
      }),
      onDislike: (item: ReplyItem) => this.dislikeReply(item).catch(() => {
      }),
      onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
      onSelectReply: (item: ReplyItem) => {
        this.threadTargetRpid = item.rpid;
        this.threadTargetName = item.uname;
        this.threadFocusTick++;
      },
      onDeleted: (item: ReplyItem) => {
        this.threadReplies = this.threadReplies.filter((x: ReplyItem) => x.rpid !== item.rpid);
      },
      onLoadMore: () => this.loadThreadReplies(false).catch(() => {
      }),
      onDraftChange: (value: string) => this.threadDraft = value,
      onSend: () => this.sendThreadReply().catch(() => {
      }),
      onNavigate: (action: () => void) => this.navigateFromThread(action),
    })
  }

  private async sendReply(): Promise<void> {
    const message: string = this.replyDraft.trim();
    if (message.length === 0 || this.replySending) return;
    if (!UserStore.isLogin) {
      this.toast('请先登录后再评论');
      AppNavStack.pushPathByName(NAV_LOGIN, null);
      return;
    }
    this.replySending = true;
    try {
      const result: ActionResult = await CommentApi.addReply(this.item.commentId, this.item.commentType, message);
      if (this.destroyed) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.replyDraft = '';
      this.toast('评论成功');
      this.replyCursor = '';
      this.repliesHasMore = true;
      await this.loadReplies(true);
    } catch (e) {
      if (!this.destroyed) this.toast('网络异常，发送失败');
    } finally {
      if (!this.destroyed) this.replySending = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      PageHeader({ title: '动态详情', onBack: () => this.goBack() })
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          DynCard({ item: this.item, embedded: true, detailMode: true, idPrefix: 'dyndetail-' })
          if (this.loading) {
            Row({ space: 8 }) {
              LoadingProgress().width(18).height(18).color(this.accent)
              Text('正在补全动态内容…').fontSize(12).fontColor('#9499A0')
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          } else if (this.loadFailed) {
            Text('完整内容加载失败，点击重试')
              .fontSize(12)
              .fontColor('#9499A0')
              .padding(12)
              .onClick(() => this.loadDetail().catch(() => {
              }))
          }
          Row() {
            Text('相关回复共 ' + this.item.comment + ' 条')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isDark ? '#D8D8DC' : '#61666D')
            Blank()
            ReplySortChips({
              mode: this.replySortMode,
              onChange: (mode: number) => {
                this.changeReplySort(mode);
              },
            })
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })
          .border({ width: { top: 0.5 }, color: this.isDark ? '#36383D' : '#E7E9EC' })
          .onAreaChange((_oldArea, area) => {
            this.commentsOffset = Math.max(0, Number(area.position.y));
          })
          if (this.repliesLoading && this.replies.length === 0) {
            LoadingView({ loading: true, skeleton: 'comments' })
          } else if (this.repliesFailed) {
            Text('评论加载失败，点击重试').fontSize(12).fontColor('#9499A0').padding(18)
              .onClick(() => this.loadReplies(true).catch(() => {
              }))
          } else if (this.replies.length === 0) {
            Text('暂时还没有评论').fontSize(12).fontColor('#9499A0').padding(18)
          } else {
            ForEach(this.replies, (reply: ReplyItem) => {
              ReplyCard({
                item: reply,
                showPreview: true,
                version: this.replyVersion,
                upMid: this.item.mid,
                onLike: (item: ReplyItem) => this.likeReply(item).catch(() => {
                }),
                onDislike: (item: ReplyItem) => this.dislikeReply(item).catch(() => {
                }),
                onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
                onOpenThread: (item: ReplyItem) => this.openReplyThread(item),
                // 主评论列表："回复"按钮 = 打开该评论的楼中楼面板（与 B 站一致）
                onSelectReply: (item: ReplyItem) => this.openReplyThread(item),
                onDeleted: (item: ReplyItem) => {
                  this.replies = this.replies.filter((x: ReplyItem) => x.rpid !== item.rpid);
                },
              })
            // 稳定 key：点赞视觉态由 ReplyCard 的 @State 镜像原地刷新，避免整卡重建闪烁。
            }, (reply: ReplyItem) => String(reply.rpid))
            LoadMoreFooter({
              loading: this.repliesLoading,
              hasMore: this.repliesHasMore || this.repliesMoreFailed,
              moreText: this.repliesMoreFailed ? '评论加载失败 · 点击重试' : '加载更多评论',
              endText: '已显示全部评论',
              fixedHeight: 46,
              onLoadMore: () => this.loadReplies(this.repliesMoreFailed && this.repliesRetryReset).catch(() => {}),
            })
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: Immersive.bottomInset() + 18 })
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
      .alignSelf(ItemAlign.Center)
      // Scroll 内容不足一屏时默认垂直居中（官方默认 Center），详情内容应从顶部开始排。
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      ReplyComposer({
        text: this.replyDraft,
        sending: this.replySending,
        showEmoteButton: false,
        onChange: (value: string) => {
          this.replyDraft = value;
        },
        onSend: () => this.sendReply(),
      })
      .padding({ bottom: Immersive.bottomInset() })
      .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
      .alignSelf(ItemAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ top: Immersive.statusBarHeight() })
      .backgroundColor(this.isDark ? '#18191C' : '#F4F6F8')
      .opacity(this.contentOpacity)
      .bindSheet($$this.threadOpen, this.ThreadSheet(), {
        height: SheetSize.LARGE,
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
        dragBar: false,
        showClose: false,
        radius: { topLeft: 18, topRight: 18 },
        backgroundColor: this.isDark ? '#18191C' : '#FFFFFF',
      })

      if (this.heroVisible) {
        Column()
          .width(this.heroPageWidth)
          .height(this.heroPageHeight)
          .position({ x: this.heroPageX, y: this.heroPageY })
          .borderRadius(this.heroPageRadius)
          .backgroundColor(this.isDark ? '#18191C' : '#F4F6F8')
          .clip(true)
          .hitTestBehavior(HitTestMode.None)
        Stack({ alignContent: Alignment.TopStart }) {
          DynCard({ item: this.item, embedded: true, detailMode: true, idPrefix: 'dyndetail-hero-' })
        }
        .width(this.heroCardWidth)
        .height(this.heroCardHeight)
        .position({ x: this.heroCardX, y: this.heroCardY })
        .clip(true)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#00000000')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
