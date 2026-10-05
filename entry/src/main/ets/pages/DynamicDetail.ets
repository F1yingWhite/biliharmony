import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { LoadingView } from '../components/LoadingView';
/** 动态详情：首屏复用 feed 对象，随后从 detail 接口补齐正文、表情和评论 subject。 */
import { AppNavStack, DynamicDetailParam, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  HERO_NAV_TRANSITION_FINISH_REQUEST_KEY, ImageViewerSrcRect, NAV_LOGIN } from '../common/AppRouter';
import { MotionTokens } from '../common/MotionTokens';
import { DynamicItem, ReplyItem } from '../model/Models';
import { Immersive } from '../common/Immersive';
import { PageHeader } from '../components/PageHeader';
import { DynCard } from '../views/DynamicView';
import { UserStore } from '../services/auth/UserStore';
import { display, FrameCallback, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { safeToast } from '../common/Toast';
import { ReplyCard } from '../components/reply/ReplyCard';
import { ReplyComposer } from '../components/reply/ReplyComposer';
import { ReplyThreadPanel } from '../components/reply/ReplyThreadPanel';
import { RepliesController } from '../components/reply/RepliesController';
import { MainRepliesState, ReplySubject, ThreadRepliesState } from '../components/reply/ReplyState';
import { ReplyVoteCard } from '../model/reply/ReplyVoteModels';
import { ReplyVotePanel } from '../components/reply/ReplyVotePanel';
import { ReplyShareController } from '../components/reply/ReplyShareController';
import { ReplyShareCard } from '../components/reply/ReplyShareCard';
import { ReplySortChips } from '../components/reply/ReplySortChips';
import { LayoutTokens } from '../common/LayoutTokens';
import { ReplySubmissionController, ReplySubmissionSnapshot } from '../components/reply/ReplySubmissionController';
import { DynamicDetailController, DynamicDetailStatus } from '../components/dynamic/DynamicDetailController';
import { EmoteResolver } from '../common/EmoteResolver';
import { ReplyReactionHooks, runReplyDislike, runReplyLike } from '../common/ReplyMutation';
import { DynDraftImage } from '../common/DynImagePreparer';

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
  /** 评论懒加载数据源（无限翻页必须虚拟化；主列表统一从这里读写）。 */
  /** 评论行数（数据源为普通属性，空态/加载态分支需要响应式计数）。 */
  @State repliesCount: number = 0;
  @State repliesLoading: boolean = false;
  @State repliesFailed: boolean = false;
  @State repliesMoreFailed: boolean = false;
  @State repliesHasMore: boolean = true;
  @State replySortMode: number = 3; // 3 最热，2 最新
  @State replyVersion: number = 0;
  @State replyVoteCard: ReplyVoteCard | null = null;
  @State replyDraft: string = '';
  @State replyImages: Array<DynDraftImage> = [];
  @State replySending: boolean = false;
  private replySubmit: ReplySubmissionController = new ReplySubmissionController({
    isAlive: () => !this.destroyed,
    getTarget: () => ({ oid: this.item.commentId, type: this.item.commentType, root: 0, parent: 0, scope: 'main', active: true }),
    getDraft: () => this.replyDraft,
    setImages: (images: Array<DynDraftImage>) => this.replyImages = images,
    setSending: (sending: boolean) => this.replySending = sending,
    toast: (message: string) => this.toast(message),
    onSuccess: (_snapshot: ReplySubmissionSnapshot, _reply: ReplyItem | null, clearDraft: boolean) => {
      if (clearDraft) this.replyDraft = '';
      this.replies.resetMainPaging();
      this.replies.load(true).catch(() => {});
    },
  });
  private threadSubmit: ReplySubmissionController = new ReplySubmissionController({
    isAlive: () => !this.destroyed,
    getTarget: () => ({ oid: this.item.commentId, type: this.item.commentType, root: this.threadRoot.rpid,
      parent: this.threadTargetRpid, scope: 'thread', active: this.threadOpen }),
    getDraft: () => this.threadDraft,
    setSending: (sending: boolean) => this.threadSending = sending,
    toast: (message: string) => this.toast(message),
    onSuccess: (_snapshot: ReplySubmissionSnapshot, reply: ReplyItem | null, clearDraft: boolean) => {
      this.applySentThreadReply(reply, clearDraft);
    },
  });
  @State threadOpen: boolean = false;
  @State threadRoot: ReplyItem = new ReplyItem();
  @State threadReplies: Array<ReplyItem> = [];
  @State threadLoading: boolean = false;
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
  @StorageProp('loginVersion') @Watch('onLoginVersionChanged') loginVersion: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private destroyed: boolean = false;
  private replyLikeBusy: Set<number> = new Set<number>();
  private scroller: Scroller = new Scroller();
  private focusPerformed: boolean = false;
  private commentsOffset: number = 0;
  /**
   * 评论编排控制器：列表与线程发布展示快照，分享导出独立拥有资源与取消会话。
   */
  private replies: RepliesController = new RepliesController({
    isDestroyed: () => this.destroyed,
    getSubject: (): ReplySubject => ({ oid: this.item.commentId, type: this.item.commentType }),
    publishMain: (state: MainRepliesState) => {
      this.replySortMode = state.sort;
      this.repliesLoading = state.loading;
      this.repliesCount = state.count;
      this.repliesHasMore = state.hasMore;
      this.replyVersion = state.version;
      this.replyVoteCard = state.voteCard;
      this.repliesFailed = state.failed;
      this.repliesMoreFailed = state.moreFailed;
    },
    publishThread: (state: ThreadRepliesState) => {
      this.threadRoot = state.root;
      this.threadReplies = state.replies;
      this.threadLoading = state.loading;
      this.threadHasMore = state.hasMore;
      this.replyVersion = state.version;
    },
    onThreadError: () => this.toast('回复加载失败，请稍后重试'),
    afterMainLoaded: () => {
      if (this.param.focusComments !== true || this.focusPerformed) return;
      this.focusPerformed = true;
      const dynId: string = this.item.dynId;
      setTimeout(() => {
        if (!this.destroyed && this.item.dynId === dynId) this.scroller.scrollTo({ xOffset: 0,
          yOffset: this.commentsOffset, animation: !MotionTokens.isReduced() });
      }, 80);
    },
  }, { clearOnSort: false, video: false }, new ReplyShareController({
    isDestroyed: () => this.destroyed,
    getSubject: (): ReplySubject => ({ oid: this.item.commentId, type: this.item.commentType }),
    toast: (message: string) => this.toast(message),
    getUIContext: () => this.getUIContext(),
    buildShareLink: (item: ReplyItem): string =>
      'https://t.bilibili.com/' + this.item.dynId + '#reply' + String(item.rpid),
    renderShareCard: (): void => this.ReplyShareCardBuilder(),
    ensureShareContext: (_context: common.UIAbilityContext | undefined): boolean => true,
    onShareFailed: (item: ReplyItem, link: string, error: Object) => {
      this.toast('分享图片生成失败，请稍后重试');
    },
  }));

  private detailLoader: DynamicDetailController = new DynamicDetailController({
    isAlive: () => !this.destroyed,
    publish: (status: DynamicDetailStatus) => {
      this.loading = status.loading;
      this.loadFailed = status.failed;
    },
    onLoaded: (item: DynamicItem) => this.applyLoadedDynamic(item),
  });

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
    if (MotionTokens.isReduced()) { this.finishWithoutMotion(); return; }
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
    if (MotionTokens.isReduced()) { this.finishWithoutMotion(); return; }
    if (!this.entranceArmed || this.closing) return;
    this.entranceArmed = false;
    const target: ImageViewerSrcRect = this.targetCardRect();
    this.getUIContext().postFrameCallback(new DynamicHeroFrameCallback(() => {
      if (this.closing) return;
      if (MotionTokens.isReduced()) { this.finishWithoutMotion(); return; }
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

  private finishWithoutMotion(): void {
    this.entryFromRect = false;
    this.entranceArmed = false;
    this.heroVisible = false;
    this.contentOpacity = 1;
    AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, false);
    AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 0);
    const request: number = AppStorage.get<number>(HERO_NAV_TRANSITION_FINISH_REQUEST_KEY) ?? 0;
    AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_FINISH_REQUEST_KEY, request + 1);
  }

  private goBack(): void {
    if (this.closing) return;
    this.closing = true;
    if (MotionTokens.isReduced()) {
      this.finishWithoutMotion();
      AppNavStack.pop(false);
      return;
    }
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
        if (MotionTokens.isReduced()) {
          this.finishWithoutMotion();
          AppNavStack.pop(false);
          return;
        }
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
    this.replyLikeBusy = new Set<number>();
    this.replySubmit.reset();
    this.threadSubmit.reset();
    this.closing = false;
    this.entryFromRect = false;
    this.contentOpacity = 1;
    this.heroVisible = false;
    this.item = this.param.item as DynamicItem;
    this.focusPerformed = false;
    this.prepareEntrance();
    this.triggerEntrance();
    if (this.item.commentId > 0 && this.item.commentType > 0) {
      this.replies.load(true).catch(() => {
      });
    }
    this.loadDetail().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.replySubmit.dispose();
    this.threadSubmit.dispose();
    this.replies.dispose();
    this.destroyed = true;
    this.detailLoader.dispose();
  }

  private async loadDetail(): Promise<void> {
    await this.detailLoader.load(this.item.dynId);
  }

  private applyLoadedDynamic(item: DynamicItem): void {
    const subjectChanged: boolean = this.item.commentId !== item.commentId || this.item.commentType !== item.commentType;
    if (subjectChanged) {
      this.replySubmit.reset();
      this.closeReplyThread();
      this.replies.dispose();
      this.replies.clearMainReplies();
    }
    this.item = item;
    // detail 可能修正 feed 提供的评论 subject，不能继续展示旧 subject 的楼层。
    if (subjectChanged || (this.repliesCount === 0 && !this.repliesLoading)) {
      this.replies.load(true).catch(() => {});
    }
  }

  onLoginVersionChanged(): void {
    if (this.destroyed) return;
    this.replyLikeBusy = new Set<number>();
    this.replySubmit.reset();
    this.closeReplyThread();
    this.replies.dispose();
    this.replies.load(true).catch(() => {});
    this.loadDetail().catch(() => {});
  }

  /** 删除评论成功后的本地移除：数据源重建 + 计数同步。 */
  private removeReply(rpid: number): void {
    this.replies.removeMain(rpid);
  }

  private ensureReplyLogin(isLike: boolean): boolean {
    if (UserStore.isLogin) return true;
    this.toast(isLike ? '请先登录后再点赞' : '请先登录后再操作');
    AppNavStack.pushPathByName(NAV_LOGIN, null);
    return false;
  }

  private replyReactionHooks(isLike: boolean): ReplyReactionHooks {
    const current: () => boolean = this.replies.captureGuard();
    return {
      ensureLogin: () => this.ensureReplyLogin(isLike),
      toast: (message: string) => this.toast(message),
      isDestroyed: () => !current(),
      resolveOid: (item: ReplyItem) => item.oid > 0 ? item.oid : this.item.commentId,
      resolveType: (item: ReplyItem) => item.type > 0 ? item.type : this.item.commentType,
      clearDislikeOnLike: true,
    };
  }

  private async likeReply(item: ReplyItem): Promise<void> {
    await runReplyLike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks(true));
  }

  private async dislikeReply(item: ReplyItem): Promise<void> {
    await runReplyDislike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks(false));
  }

  private closeReplyThread(): void {
    this.threadSubmit.reset();
    this.replies.cancelThread();
    this.threadOpen = false;
  }

  private openReplyThread(root: ReplyItem): void {
    this.threadSubmit.reset();
    let latest: ReplyItem = root;
    const current: Array<ReplyItem> = this.replies.source.getAll();
    for (let i: number = 0; i < current.length; i++) {
      if (current[i].rpid === root.rpid) {
        latest = current[i];
        break;
      }
    }
    this.replies.beginThread(latest, latest.replies.slice());
    this.threadTargetRpid = latest.rpid;
    this.threadTargetName = latest.uname;
    this.threadDraft = '';
    this.threadOpen = true;
    this.replies.loadThread(true).catch(() => {
    });
  }

  private applySentThreadReply(sent: ReplyItem | null, clearDraft: boolean): void {
    if (clearDraft) {
      this.threadDraft = '';
      this.threadTargetRpid = this.threadRoot.rpid;
      this.threadTargetName = this.threadRoot.uname;
    }
    if (sent === null) {
      this.replies.loadThread(true).catch(() => {});
      return;
    }
    this.replies.addSentThread(sent);
  }

  private async sendThreadReply(): Promise<void> {
    await this.threadSubmit.send();
  }

  private navigateFromThread(action: () => void): void {
    this.closeReplyThread();
    setTimeout(() => {
      if (!this.destroyed) action();
    }, 260);
  }

  /** 离屏分享卡内容；字段在截图前一次性赋值，渲染期间不变化。 */
  @Builder
  ReplyShareCardBuilder() {
    ReplyShareCard({
      item: this.replies.sharing.shareItem(),
      upMid: this.item.mid,
      qr: this.replies.sharing.shareQr(),
      page: this.replies.sharing.sharePage(),
      linkLabel: this.replies.sharing.shareLink(),
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
      replies: $threadReplies,
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
      onShare: (item: ReplyItem) => this.replies.sharing.share(item).catch(() => {}),
      onSelectReply: (item: ReplyItem) => {
        this.threadSubmit.reset();
        this.threadTargetRpid = item.rpid;
        this.threadTargetName = item.uname;
        this.threadFocusTick++;
      },
      onDeleted: (item: ReplyItem) => {
        this.replies.removeThread(item.rpid);
      },
      onLoadMore: () => this.replies.loadThread(false).catch(() => {
      }),
      onDraftChange: (value: string) => {
        this.threadSubmit.draftChanged();
        this.threadDraft = value;
      },
      onSend: () => this.sendThreadReply().catch(() => {
      }),
      onNavigate: (action: () => void) => this.navigateFromThread(action),
    })
  }

  private async sendReply(): Promise<void> {
    if (this.replyDraft.trim().length === 0 || this.replySending) return;
    if (!UserStore.isLogin) {
      this.toast('请先登录后再评论');
      AppNavStack.pushPathByName(NAV_LOGIN, null);
      return;
    }
    await this.replySubmit.send();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      PageHeader({ title: '动态详情', onBack: () => this.goBack() })
      List({ space: 12, scroller: this.scroller }) {
        ListItem() {
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
              if (this.repliesLoading && this.repliesCount > 0) {
                LoadingProgress().width(16).height(16).color(this.accent).margin({ right: 8 })
              }
              ReplySortChips({
                mode: this.replySortMode,
                onChange: (mode: number) => {
                  this.replies.changeReplySort(mode);
                },
              })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .border({ width: { top: 0.5 }, color: this.isDark ? '#36383D' : '#E7E9EC' })
            .onAreaChange((_oldArea, area) => {
              this.commentsOffset = Math.max(0, Number(area.position.y));
            })
            if (this.replyVoteCard !== null) {
              ReplyVotePanel({
                vote: this.replyVoteCard,
                source: { oid: this.item.commentId, type: this.item.commentType, rpid: 0,
                  sourceKey: 'header:' + String(this.item.commentId) + ':' + String(this.item.commentType) },
              })
            }
            if (this.repliesMoreFailed && this.replies.getRepliesRetryReset() && this.repliesCount > 0) {
              Text('排序加载失败，当前保留原评论 · 点击重试')
                .fontSize(12).fontColor(this.accent).padding(8)
                .onClick(() => this.replies.load(true).catch(() => {}))
            }
            if (this.repliesLoading && this.repliesCount === 0) {
              LoadingView({ loading: true, skeleton: 'comments' })
            } else if (this.repliesFailed) {
              Text('评论加载失败，点击重试').fontSize(12).fontColor('#9499A0').padding(18)
                .onClick(() => this.replies.load(true).catch(() => {
                }))
            } else if (this.repliesCount === 0) {
              Text('暂时还没有评论').fontSize(12).fontColor('#9499A0').padding(18)
            }
          }
          .width('100%')
        }
        if (this.repliesCount > 0) {
          LazyForEach(this.replies.source, (reply: ReplyItem) => {
            ListItem() {
              ReplyCard({
                item: reply,
                showPreview: true,
                version: this.replyVersion,
                upMid: this.item.mid,
                onLike: (item: ReplyItem) => this.likeReply(item).catch(() => {
                }),
                onDislike: (item: ReplyItem) => this.dislikeReply(item).catch(() => {
                }),
                onShare: (item: ReplyItem) => this.replies.sharing.share(item).catch(() => {}),
                onOpenThread: (item: ReplyItem) => this.openReplyThread(item),
                // 主评论列表："回复"按钮 = 打开该评论的楼中楼面板（与 B 站一致）
                onSelectReply: (item: ReplyItem) => this.openReplyThread(item),
                onDeleted: (item: ReplyItem) => this.removeReply(item.rpid),
              })
            }
          // 稳定 key：点赞视觉态由 ReplyCard 的 @State 镜像原地刷新，避免整卡重建闪烁。
          }, (reply: ReplyItem) => String(reply.rpid))
          ListItem() {
            LoadMoreFooter({
              loading: this.repliesLoading,
              hasMore: this.repliesHasMore || this.repliesMoreFailed,
              moreText: this.repliesMoreFailed ? '评论加载失败 · 点击重试' : '加载更多评论',
              endText: '已显示全部评论',
              fixedHeight: 46,
              onLoadMore: () => this.replies.load(this.repliesMoreFailed && this.replies.getRepliesRetryReset())
                .catch(() => {}),
            })
          }
        }
        // 尾部留白：替代原 Scroll 内容底部内边距，最后一条评论可滚到输入栏上方。
        ListItem() {
          Column().width('100%').height(Immersive.bottomInset() + 18)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
      .alignSelf(ItemAlign.Center)
      .padding({ left: 10, right: 10 })
      .edgeEffect(EdgeEffect.None)
      .cachedCount(4)
      .scrollBar(BarState.Off)
      ReplyComposer({
        text: this.replyDraft,
        images: this.replyImages,
        submission: this.replySubmit,
        sending: this.replySending,
        showEmoteButton: false,
        onChange: (value: string) => {
          this.replySubmit.draftChanged();
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
