/** 动态详情：首屏复用 feed 对象，随后从 detail 接口补齐正文、表情和评论 subject。 */
import { AppNavStack, DynamicDetailParam, NAV_LOGIN } from '../common/AppRouter';
import { DynamicItem, ReplyData, ReplyItem, ReplyPageData } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { DynCard } from '../views/DynamicView';
import { UserStore } from '../common/UserStore';
import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { ReplyCard } from '../components/ReplyCard';
import { ReplyComposer } from '../components/ReplyComposer';
import { ReplyThreadPanel } from '../components/ReplyThreadPanel';
import { ReplyShareCard, makeReplyQr, sharePixelMapAsImage } from '../components/ReplyShareCard';
import { ReplySortChips } from '../components/ReplySortChips';
import { LayoutTokens } from '../common/LayoutTokens';
import {
  ReplyCloneResult, ReplyReactionHooks, mutateReplyInArray, mutatedReplyClone, runReplyDislike, runReplyLike
} from '../common/ReplyMutation';

@Component
export struct DynamicDetailPage {
  param: DynamicDetailParam = { item: new DynamicItem(), focusComments: false };
  @State item: DynamicItem = new DynamicItem();
  @State loading: boolean = false;
  @State loadFailed: boolean = false;
  @State replies: Array<ReplyItem> = [];
  @State repliesLoading: boolean = false;
  @State repliesFailed: boolean = false;
  @State repliesHasMore: boolean = true;
  @State replySortMode: number = 3; // 3 最热，2 最新
  @State replyVersion: number = 0;
  @State replyDraft: string = '';
  @State replySending: boolean = false;
  @State threadOpen: boolean = false;
  @State threadRoot: ReplyItem = new ReplyItem();
  @State threadReplies: Array<ReplyItem> = [];
  @State threadLoading: boolean = false;
  @State threadHasMore: boolean = true;
  @State threadDraft: string = '';
  @State threadSending: boolean = false;
  @State threadTargetRpid: number = 0;
  @State threadTargetName: string = '';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private destroyed: boolean = false;
  private replyCursor: string = '';
  private replyLikeBusy: Set<number> = new Set<number>();
  private scroller: Scroller = new Scroller();
  private focusPerformed: boolean = false;
  private threadPage: number = 0;
  // 评论分享卡离屏渲染用的待截内容；只在生成分享图期间短暂赋值。
  private shareCardItem: ReplyItem = new ReplyItem();
  private shareCardQr: image.PixelMap | null = null;
  private shareCardBusy: boolean = false;

  private toast(message: string): void {
    try {
      this.toast(message);
    } catch (e) {
      // 页面销毁或窗口异常时忽略提示。
    }
  }

  aboutToAppear(): void {
    this.destroyed = false;
    this.item = this.param.item as DynamicItem;
    if (this.item.commentId > 0 && this.item.commentType > 0) {
      this.loadReplies(true).catch(() => {
      });
    }
    this.loadDetail().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
  }

  private async loadDetail(): Promise<void> {
    if (this.item.dynId.length === 0 || this.loading) return;
    this.loading = true;
    this.loadFailed = false;
    try {
      const detail: DynamicItem | null = await BiliApi.getDynamicDetail(this.item.dynId);
      if (!this.destroyed && detail !== null) {
        this.item = detail;
        if (this.replies.length === 0) await this.loadReplies(true);
      }
      if (!this.destroyed && detail === null) this.loadFailed = true;
    } catch (e) {
      if (!this.destroyed) this.loadFailed = true;
    } finally {
      if (!this.destroyed) this.loading = false;
    }
  }

  private async loadReplies(reset: boolean): Promise<void> {
    if (this.repliesLoading || this.item.commentId <= 0 || this.item.commentType <= 0 ||
      (!reset && !this.repliesHasMore)) return;
    this.repliesLoading = true;
    if (reset) this.repliesFailed = false;
    try {
      const data: ReplyData = await BiliApi.getReplies(this.item.commentId, this.item.commentType,
        reset ? '' : this.replyCursor, this.replySortMode);
      if (this.destroyed) return;
      this.replies = reset ? data.replies : this.replies.concat(data.replies);
      this.replyCursor = data.cursor;
      this.repliesHasMore = data.hasMore;
      if (this.param.focusComments === true && !this.focusPerformed) {
        this.focusPerformed = true;
        setTimeout(() => {
          if (!this.destroyed) this.scroller.scrollTo({ xOffset: 0, yOffset: 100000, animation: true });
        }, 80);
      }
    } catch (e) {
      if (!this.destroyed && this.replies.length === 0) this.repliesFailed = true;
    } finally {
      if (!this.destroyed) this.repliesLoading = false;
    }
  }

  /** 切换评论排序：清空列表与游标，重新拉第一页。 */
  private changeReplySort(mode: number): void {
    if (this.replySortMode === mode || this.repliesLoading) return;
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

  private openReplyThread(root: ReplyItem): void {
    this.threadRoot = root;
    this.threadReplies = root.replies.slice();
    this.threadPage = 0;
    this.threadHasMore = true;
    this.threadTargetRpid = root.rpid;
    this.threadTargetName = root.uname;
    this.threadDraft = '';
    this.threadOpen = true;
    this.loadThreadReplies(true).catch(() => {
    });
  }

  private async loadThreadReplies(reset: boolean): Promise<void> {
    if (this.threadLoading || this.threadRoot.rpid <= 0 || (!reset && !this.threadHasMore)) return;
    this.threadLoading = true;
    const page: number = reset ? 1 : this.threadPage + 1;
    try {
      const result: ReplyPageData = await BiliApi.getReplyReplies(this.item.commentId, this.item.commentType,
        this.threadRoot.rpid, page);
      if (this.destroyed || !this.threadOpen) return;
      const next: Array<ReplyItem> = reset ?
        (result.replies.length > 0 ? result.replies : this.threadReplies) :
        this.threadReplies.concat(result.replies);
      this.threadReplies = next;
      this.threadPage = page;
      this.threadHasMore = result.hasMore;
    } catch (e) {
      if (!this.destroyed) this.toast('回复加载失败，请稍后重试');
    } finally {
      if (!this.destroyed) this.threadLoading = false;
    }
  }

  private async sendThreadReply(): Promise<void> {
    const message: string = this.threadDraft.trim();
    if (message.length === 0 || this.threadSending || !UserStore.isLogin) return;
    this.threadSending = true;
    try {
      const parent: number = this.threadTargetRpid > 0 ? this.threadTargetRpid : this.threadRoot.rpid;
      const result: ActionResult = await BiliApi.addReply(this.item.commentId, this.item.commentType, message,
        this.threadRoot.rpid, parent);
      if (this.destroyed) return;
      if (!result.ok) {
        this.toast(result.message);
        return;
      }
      this.threadDraft = '';
      await this.loadThreadReplies(true);
    } finally {
      if (!this.destroyed) this.threadSending = false;
    }
  }

  private navigateFromThread(action: () => void): void {
    this.threadOpen = false;
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
      // checkImageStatus=true 等头像/附图在线图片解码完成再截图。
      const pixelMap: image.PixelMap = await uiContext.getComponentSnapshot()
        .createFromBuilder((): void => { this.ReplyShareCardBuilder(); }, 400, true);
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
      isDark: this.isDark,
      accent: '#FB7299',
      upMid: this.item.mid,
      onClose: () => this.threadOpen = false,
      onLike: (item: ReplyItem) => this.likeReply(item).catch(() => {
      }),
      onDislike: (item: ReplyItem) => this.dislikeReply(item).catch(() => {
      }),
      onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
      onSelectReply: (item: ReplyItem) => {
        this.threadTargetRpid = item.rpid;
        this.threadTargetName = item.uname;
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
      const result: ActionResult = await BiliApi.addReply(this.item.commentId, this.item.commentType, message);
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
    Column() {
      PageHeader({ title: '动态详情' })
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          DynCard({ item: this.item, embedded: true, detailMode: true })
          if (this.loading) {
            Row({ space: 8 }) {
              LoadingProgress().width(18).height(18).color('#FB7299')
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
          if (this.repliesLoading && this.replies.length === 0) {
            LoadingProgress().width(24).height(24).color('#FB7299').margin({ top: 18, bottom: 18 })
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
                isDark: this.isDark,
                accent: '#FB7299',
                upMid: this.item.mid,
                onLike: (item: ReplyItem) => this.likeReply(item).catch(() => {
                }),
                onDislike: (item: ReplyItem) => this.dislikeReply(item).catch(() => {
                }),
                onShare: (item: ReplyItem) => this.shareReplyAsImage(item),
                onOpenThread: (item: ReplyItem) => this.openReplyThread(item),
              })
            }, (reply: ReplyItem) => String(reply.rpid) + '_' + String(reply.rev))
            if (this.repliesHasMore) {
              Text(this.repliesLoading ? '加载中…' : '加载更多评论')
                .width('100%').height(46).textAlign(TextAlign.Center).fontSize(12).fontColor('#9499A0')
                .onClick(() => this.loadReplies(false).catch(() => {
                }))
            }
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10, bottom: Immersive.bottomInset() + 18 })
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
      .alignSelf(ItemAlign.Center)
      .scrollBar(BarState.Off)
      ReplyComposer({
        text: this.replyDraft,
        sending: this.replySending,
        showEmoteButton: false,
        isDark: this.isDark,
        accent: '#FB7299',
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
    .bindSheet($$this.threadOpen, this.ThreadSheet(), {
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: this.isDark ? '#18191C' : '#FFFFFF',
    })
  }
}
