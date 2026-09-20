import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { LoadingView } from '../components/LoadingView';
import { BasicDataSource } from '../common/BasicDataSource';
/** 动态详情：首屏复用 feed 对象，随后从 detail 接口补齐正文、表情和评论 subject。 */
import { AppNavStack, DynamicDetailParam, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  ImageViewerSrcRect, NAV_LOGIN } from '../common/AppRouter';
import { DynamicItem, ReplyItem } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
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
import { ReplyShareCard } from '../components/reply/ReplyShareCard';
import { ReplySortChips } from '../components/reply/ReplySortChips';
import { LayoutTokens } from '../common/LayoutTokens';
import { CommentApi } from '../api/CommentApi';
import { DynamicApi } from '../api/DynamicApi';
import { EmoteResolver } from '../common/EmoteResolver';
import { ReplyReactionHooks, runReplyDislike, runReplyLike } from '../common/ReplyMutation';
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
  /** 评论懒加载数据源（无限翻页必须虚拟化；主列表统一从这里读写）。 */
  private replySource: BasicDataSource<ReplyItem> = new BasicDataSource<ReplyItem>();
  /** 评论行数（数据源为普通属性，空态/加载态分支需要响应式计数）。 */
  @State repliesCount: number = 0;
  @State repliesLoading: boolean = false;
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
  private replyLikeBusy: Set<number> = new Set<number>();
  private scroller: Scroller = new Scroller();
  private focusPerformed: boolean = false;
  private commentsOffset: number = 0;
  /**
   * 评论编排控制器：游标/请求代际/分享卡临时状态都在控制器，@State 经下方闭包读写。
   * clearOnSort=false：切排序保留现有楼层直到新首屏返回，避免清空长列表使滚动位置和排序按钮跳动。
   */
  private replies: RepliesController = new RepliesController({
    isDestroyed: (): boolean => this.destroyed,
    toast: (message: string): void => this.toast(message),
    getUIContext: (): UIContext => this.getUIContext(),
    resolveOid: (): number => this.item.commentId,
    resolveType: (): number => this.item.commentType,
    canLoadReplies: (): boolean => this.item.commentId > 0 && this.item.commentType > 0,
    getMainSource: (): BasicDataSource<ReplyItem> => this.replySource,
    getSortMode: (): number => this.replySortMode,
    setSortMode: (value: number): void => {
      this.replySortMode = value;
    },
    getRepliesLoading: (): boolean => this.repliesLoading,
    setRepliesLoading: (value: boolean): void => {
      this.repliesLoading = value;
    },
    getRepliesHasMore: (): boolean => this.repliesHasMore,
    setRepliesHasMore: (value: boolean): void => {
      this.repliesHasMore = value;
    },
    getRepliesCount: (): number => this.repliesCount,
    setRepliesCount: (value: number): void => {
      this.repliesCount = value;
    },
    clearRepliesError: (reset: boolean): void => {
      this.repliesMoreFailed = false;
      if (reset) this.repliesFailed = false;
    },
    showRepliesError: (_reset: boolean, _cursor: string, _startedAt: number, _error: Object): void => {
      if (this.repliesCount === 0) this.repliesFailed = true;
      else this.repliesMoreFailed = true;
    },
    applyRepliesReset: (incoming: Array<ReplyItem>): void => {
      this.replySource.reset(incoming);
    },
    applyRepliesAppend: (incoming: Array<ReplyItem>): void => {
      this.replySource.append(incoming);
    },
    afterRepliesLoaded: async (_reset: boolean): Promise<void> => {
      if (this.param.focusComments === true && !this.focusPerformed) {
        this.focusPerformed = true;
        setTimeout(() => {
          if (!this.destroyed) this.scroller.scrollTo({ xOffset: 0, yOffset: this.commentsOffset, animation: true });
        }, 80);
      }
    },
    getThreadRoot: (): ReplyItem => this.threadRoot,
    setThreadRoot: (root: ReplyItem): void => {
      this.threadRoot = root;
    },
    getThreadReplies: (): Array<ReplyItem> => this.threadReplies,
    setThreadReplies: (list: Array<ReplyItem>): void => {
      this.threadReplies = list;
    },
    getThreadLoading: (): boolean => this.threadLoading,
    setThreadLoading: (value: boolean): void => {
      this.threadLoading = value;
    },
    getThreadHasMore: (): boolean => this.threadHasMore,
    setThreadHasMore: (value: boolean): void => {
      this.threadHasMore = value;
    },
    isThreadStale: (root: number, _oid: number): boolean => !this.threadOpen || this.threadRoot.rpid !== root,
    mergeThreadReplies: (current: Array<ReplyItem>, incoming: Array<ReplyItem>, reset: boolean): Array<ReplyItem> =>
      reset ? (incoming.length > 0 ? incoming : current) : current.concat(incoming),
    onThreadError: (_reset: boolean, _startedAt: number, _error: Object): void => {
      if (!this.destroyed) this.toast('回复加载失败，请稍后重试');
    },
    bumpVersion: (): void => {
      this.replyVersion++;
    },
    getVersion: (): number => this.replyVersion,
    buildShareLink: (item: ReplyItem): string =>
      'https://t.bilibili.com/' + this.item.dynId + '#reply' + String(item.rpid),
    renderShareCard: (): void => {
      this.ReplyShareCardBuilder();
    },
    ensureShareContext: (_context: common.UIAbilityContext | undefined): boolean => true,
    onShareFailed: (_item: ReplyItem, _link: string, _error: Object): void => {
      this.toast('分享图片生成失败，请稍后重试');
    },
  }, false);

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
      this.replies.load(true).catch(() => {
      });
    }
    this.loadDetail().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.replies.dispose();
    this.destroyed = true;
    this.replies.releaseShareCard();
  }

  private async loadDetail(): Promise<void> {
    if (this.item.dynId.length === 0 || this.loading) return;
    this.loading = true;
    this.loadFailed = false;
    try {
      const detail: DynamicItem | null = await DynamicApi.getDynamicDetail(this.item.dynId);
      if (!this.destroyed && detail !== null) {
        this.item = detail;
        if (this.repliesCount === 0 && !this.repliesLoading) await this.replies.load(true);
      }
      if (!this.destroyed && detail === null) this.loadFailed = true;
    } catch (e) {
      if (!this.destroyed) this.loadFailed = true;
    } finally {
      if (!this.destroyed) this.loading = false;
    }
  }

  /** 删除评论成功后的本地移除：数据源重建 + 计数同步。 */
  private removeReply(rpid: number): void {
    const kept: Array<ReplyItem> = this.replySource.getAll().filter((x: ReplyItem) => x.rpid !== rpid);
    if (kept.length !== this.replySource.totalCount()) {
      this.replySource.reset(kept);
      this.repliesCount = kept.length;
    }
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
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks(true));
  }

  private async dislikeReply(item: ReplyItem): Promise<void> {
    await runReplyDislike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks(false));
  }

  private closeReplyThread(): void {
    this.replies.cancelThread();
    this.threadOpen = false;
  }

  private openReplyThread(root: ReplyItem): void {
    let latest: ReplyItem = root;
    const current: Array<ReplyItem> = this.replySource.getAll();
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
        const current: Array<ReplyItem> = this.replySource.getAll();
        for (let i: number = 0; i < current.length; i++) {
          if (current[i].rpid === root.rpid) {
            this.replySource.updateItem(i, root);
            break;
          }
        }
        this.threadTargetRpid = root.rpid;
        this.threadTargetName = root.uname;
        this.toast('回复成功');
      } else {
        await this.replies.loadThread(true);
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

  /** 离屏分享卡内容；字段在截图前一次性赋值，渲染期间不变化。 */
  @Builder
  ReplyShareCardBuilder() {
    ReplyShareCard({
      item: this.replies.shareItem(),
      upMid: this.item.mid,
      qr: this.replies.shareQr(),
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
      onShare: (item: ReplyItem) => this.replies.share(item),
      onSelectReply: (item: ReplyItem) => {
        this.threadTargetRpid = item.rpid;
        this.threadTargetName = item.uname;
        this.threadFocusTick++;
      },
      onDeleted: (item: ReplyItem) => {
        this.threadReplies = this.threadReplies.filter((x: ReplyItem) => x.rpid !== item.rpid);
      },
      onLoadMore: () => this.replies.loadThread(false).catch(() => {
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
      this.replies.resetMainPaging();
      await this.replies.load(true);
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
          LazyForEach(this.replySource, (reply: ReplyItem) => {
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
                onShare: (item: ReplyItem) => this.replies.share(item),
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
