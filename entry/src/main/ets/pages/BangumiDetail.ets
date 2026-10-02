/**
 * 番剧/影视（PGC）详情页：封面氛围头部（海报 + 评分 + 追番）+ 选集 + 简介 + 评论。
 * 入口：动态流 PGC 卡片。评论区复用动态详情的组装方式（type=1，oid 为当前集 aid）。
 * 集选择与 PGC 参数由 BangumiEpisodeCatalog 定义，选集展示与追番动作独立于评论编排。
 */
import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppNavStack, BangumiDetailParam, NAV_BANGUMI_DETAIL, NAV_LOGIN, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { BangumiEpisode, BangumiSeason, ReplyItem } from '../model/Models';
import { biliImageThumbnail } from '../common/ImageUrl';
import { Immersive } from '../common/Immersive';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { BackButton, BackButtonVariant } from '../components/BackButton';
import { ReplyCard } from '../components/reply/ReplyCard';
import { ReplyComposer } from '../components/reply/ReplyComposer';
import { ReplyThreadPanel } from '../components/reply/ReplyThreadPanel';
import { RepliesController } from '../components/reply/RepliesController';
import { MainRepliesState, ReplySubject, ThreadRepliesState } from '../components/reply/ReplyState';
import { ReplyShareController } from '../components/reply/ReplyShareController';
import { ReplyShareCard } from '../components/reply/ReplyShareCard';
import { ReplySortChips } from '../components/reply/ReplySortChips';
import { UserStore } from '../services/auth/UserStore';
import { ReplyReactionHooks, runReplyDislike, runReplyLike } from '../common/ReplyMutation';
import { colorWithAlpha, formatCount } from '../common/Utils';
import { LayoutTokens } from '../common/LayoutTokens';
import { ReplySubmissionController, ReplySubmissionSnapshot } from '../components/reply/ReplySubmissionController';
import { BangumiEpisodeCatalog } from '../components/bangumi/BangumiEpisodeCatalog';
import { BangumiEpisodeSection } from '../components/bangumi/BangumiEpisodeSection';
import { BangumiFollowController, BangumiFollowState } from '../components/bangumi/BangumiFollowController';
import { BangumiDetailController, BangumiDetailStatus } from '../components/bangumi/BangumiDetailController';

@Component
export struct BangumiDetailPage {
  param: BangumiDetailParam = { seasonId: 0, epId: 0, title: '' };
  @State season: BangumiSeason = new BangumiSeason();
  @State loading: boolean = true;
  @State errorText: string = '';
  @State currentEpId: number = 0;
  @State followState: BangumiFollowState = new BangumiFollowState();
  @State showStatusPanel: boolean = false;
  @State viewportWidth: number = 360;
  // ===== 评论（挂在当前集 aid 上，type=1） =====
  /** 评论懒加载数据源（无限翻页必须虚拟化；主列表统一从这里读写）。 */
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
  private replySubmit: ReplySubmissionController = new ReplySubmissionController({
    isAlive: () => !this.destroyed,
    getTarget: () => ({ oid: this.replyOid(), type: 1, root: 0, parent: 0, scope: 'main', active: true }),
    getDraft: () => this.replyDraft,
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
    getTarget: () => ({ oid: this.replyOid(), type: 1, root: this.threadRoot.rpid,
      parent: this.threadTargetRpid, scope: 'thread', active: this.threadOpen }),
    getDraft: () => this.threadDraft,
    setSending: (sending: boolean) => this.threadSending = sending,
    toast: (message: string) => this.toast(message),
    onSuccess: (_snapshot: ReplySubmissionSnapshot, reply: ReplyItem | null, clearDraft: boolean) => {
      this.applySentThreadReply(reply, clearDraft);
    },
  });
  // ===== 回复详情（Sheet） =====
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
  @StorageProp('loginVersion') @Watch('onLoginVersionChanged') loginVersion: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private destroyed: boolean = false;
  private replyLikeBusy: Set<number> = new Set<number>();
  private scroller: Scroller = new Scroller();
  private follow: BangumiFollowController = new BangumiFollowController({
    getSeason: (): BangumiSeason => this.season,
    isDestroyed: (): boolean => this.destroyed,
    ensureLogin: (message: string): boolean => {
      if (UserStore.isLogin) return true;
      if (message.length > 0) this.toast(message);
      AppNavStack.pushPathByName(NAV_LOGIN, null);
      return false;
    },
    toast: (message: string): void => this.toast(message),
    publish: (state: BangumiFollowState): void => { this.followState = state; },
    closeStatusPanel: (): void => { this.showStatusPanel = false; },
  });
  /**
   * 评论编排控制器：列表与线程发布展示快照，分享导出独立拥有资源与取消会话。
   */
  private replies: RepliesController = new RepliesController({
    isDestroyed: () => this.destroyed,
    getSubject: (): ReplySubject => ({ oid: this.replyOid(), type: 1 }),
    publishMain: (state: MainRepliesState) => {
      this.replySortMode = state.sort;
      this.repliesLoading = state.loading;
      this.repliesCount = state.count;
      this.repliesHasMore = state.hasMore;
      this.replyVersion = state.version;
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
  }, { clearOnSort: true, video: false }, new ReplyShareController({
    isDestroyed: () => this.destroyed,
    getSubject: (): ReplySubject => ({ oid: this.replyOid(), type: 1 }),
    toast: (message: string) => this.toast(message),
    getUIContext: () => this.getUIContext(),
    buildShareLink: (item: ReplyItem): string =>
      'https://www.bilibili.com/bangumi/play/ep' + String(this.currentEpId) + '#reply' + String(item.rpid),
    renderShareCard: (): void => this.ReplyShareCardBuilder(),
    ensureShareContext: (_context: common.UIAbilityContext | undefined): boolean => true,
    onShareFailed: (item: ReplyItem, link: string, error: Object) => {
      this.toast('分享图片生成失败，请稍后重试');
    },
  }));

  private detailLoader: BangumiDetailController = new BangumiDetailController({
    isAlive: () => !this.destroyed,
    publish: (status: BangumiDetailStatus) => {
      this.loading = status.loading;
      this.errorText = status.error;
    },
    onLoaded: (season: BangumiSeason, preferredEpId: number) => {
      this.season = season;
      this.follow.initialize(season);
      this.currentEpId = BangumiEpisodeCatalog.pick(season, preferredEpId);
      this.replies.load(true).catch(() => {});
    },
  });

  aboutToAppear(): void {
    this.destroyed = false;
    this.replyLikeBusy = new Set<number>();
    this.replySubmit.reset();
    this.threadSubmit.reset();
    this.init().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.replySubmit.dispose();
    this.threadSubmit.dispose();
    this.replies.dispose();
    this.destroyed = true;
    this.follow.dispose();
    this.detailLoader.dispose();
  }

  /** 统一 toast：用 UIContext 版 PromptAction，避开全局 promptAction 的废弃告警。 */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // toast 失败不影响业务流程
    }
  }

  private async init(): Promise<void> {
    this.follow.dispose();
    await this.detailLoader.load(this.param.seasonId, this.param.epId);
  }

  onLoginVersionChanged(): void {
    if (this.destroyed) return;
    this.replyLikeBusy = new Set<number>();
    this.replySubmit.reset();
    this.closeReplyThread();
    this.replies.dispose();
    this.follow.dispose();
    const state: BangumiFollowState = new BangumiFollowState();
    state.favorites = this.season.favorites;
    this.followState = state;
    this.showStatusPanel = false;
    // 刷新账号追番状态时保留当前选集；旧账号详情不能再次 initialize 追番控制器。
    this.detailLoader.load(this.param.seasonId, this.currentEpId || this.param.epId).catch(() => {});
  }

  /** 评论 oid：当前集 aid；无剧集或未上线时为 0，评论区与输入框整体隐藏。 */
  private replyOid(): number {
    const ep: BangumiEpisode | null = BangumiEpisodeCatalog.current(this.season, this.currentEpId);
    return ep !== null ? ep.aid : 0;
  }

  /** 保留集 ID 与 CID，详情和换画质始终使用 PGC 鉴权取流。 */
  private playEpisode(ep: BangumiEpisode): void {
    if (ep.aid <= 0 && ep.bvid.length === 0) {
      this.toast('该集暂未上线');
      return;
    }
    // 切换当前集：高亮与评论区跟随，播放页返回后仍指向最近观看的一集。
    if (ep.epId !== this.currentEpId) {
      this.replySubmit.reset();
      this.closeReplyThread();
      this.currentEpId = ep.epId;
      this.replies.clearMainReplies();
      this.replies.load(true).catch(() => {
      });
    }
    const param: VideoDetailParam = BangumiEpisodeCatalog.playbackParam(this.season, ep);
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  // ===== 评论（组装方式同动态详情，编排在 RepliesController） =====
  private async likeReply(item: ReplyItem): Promise<void> {
    await runReplyLike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks());
  }

  private async dislikeReply(item: ReplyItem): Promise<void> {
    await runReplyDislike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.replies.mutate(rpid, mutate),
      this.replyReactionHooks());
  }

  private replyReactionHooks(): ReplyReactionHooks {
    const current: () => boolean = this.replies.captureGuard();
    return {
      ensureLogin: () => {
        if (UserStore.isLogin) return true;
        this.toast('请先登录后再操作');
        AppNavStack.pushPathByName(NAV_LOGIN, null);
        return false;
      },
      toast: (message: string) => this.toast(message),
      isDestroyed: () => !current(),
      resolveOid: () => this.replyOid(),
      resolveType: () => 1,
      clearDislikeOnLike: false,
    };
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

  /** 删除评论成功后的本地移除：数据源重建 + 计数同步。 */
  private removeReply(rpid: number): void {
    this.replies.removeMain(rpid);
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
      upMid: 0,
      qr: this.replies.sharing.shareQr(),
      page: this.replies.sharing.sharePage(),
      linkLabel: this.replies.sharing.shareLink(),
      sourceCover: this.season.poster.length > 0 ? this.season.poster : this.season.cover,
      sourceTitle: this.season.title,
      sourceUpName: '',
      scanHint: '长按扫码查看详情',
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
      focusId: 'bangumi_thread_reply_composer_editor',
      upMid: 0,
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

  private introMeta(): string {
    const parts: Array<string> = [];
    if (this.season.styles.length > 0) parts.push(this.season.styles);
    if (this.season.areas.length > 0) parts.push(this.season.areas);
    if (this.season.pubTimeShow.length > 0) parts.push(this.season.pubTimeShow);
    return parts.join(' · ');
  }

  // ===== 加载/错误态的简易头栏：返回键 + 入口带入的标题占位 =====
  @Builder
  StateHeader() {
    Row({ space: 8 }) {
      BackButton({})
      if (this.param.title.length > 0) {
        Text(this.param.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
    }
    .width('100%')
    .padding({ left: 10, right: 14, top: Immersive.statusBarHeight() + 4 })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 氛围头部：封面模糊铺底 + 海报 + 标题/评分/数据 + 追番按钮（做法同用户空间 banner） =====
  @Builder
  Header() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.season.cover.length > 0) {
        Image(biliImageThumbnail(this.season.cover, 480))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(36)
          .brightness(this.isDark ? 0.5 : 0.85)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [[this.accent, 0.0], [colorWithAlpha(this.accent, '66'), 1.0]],
          })
      }
      // 顶部压暗保证系统栏与返回键可读，底部渐变成页面底色与内容区衔接。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#73000000', 0.0], ['#00000000', 0.45], [this.isDark ? '#18191C' : '#F6F7F8', 1.0]],
        })
        .hitTestBehavior(HitTestMode.None)
      Column() {
        Row() {
          BackButton({ variant: BackButtonVariant.GLASS })
          Blank()
        }
        .width('100%')
        Blank()
        Row({ space: 12 }) {
          if (this.season.poster.length > 0) {
            Image(this.season.poster)
              .width(96)
              .aspectRatio(3 / 4)
              .objectFit(ImageFit.Cover)
              .borderRadius(8)
          }
          Column({ space: 5 }) {
            Text(this.season.title)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.season.subtitle.length > 0) {
              Text(this.season.subtitle)
                .fontSize(12)
                .fontColor('#E6FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (this.season.ratingScore > 0) {
              Row({ space: 6 }) {
                Text(this.season.ratingScore.toFixed(1))
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.accent)
                if (this.season.ratingCount > 0) {
                  Text(formatCount(this.season.ratingCount) + ' 人评分')
                    .fontSize(11)
                    .fontColor('#CCFFFFFF')
                }
              }
              .alignItems(VerticalAlign.Bottom)
            }
            Text(formatCount(this.season.views) + ' 播放 · ' + formatCount(this.followState.favorites) + ' ' + BangumiEpisodeCatalog.followLabel(this.season))
              .fontSize(12)
              .fontColor('#E6FFFFFF')
            Text((this.followState.followed ? '已' : '+ ') + BangumiEpisodeCatalog.followLabel(this.season))
              .fontSize(13)
              .fontColor('#FFFFFF')
              .padding({ left: 20, right: 20, top: 6, bottom: 6 })
              .borderRadius(17)
              .backgroundColor(this.followState.followed ? '#40FFFFFF' : this.accent)
              .margin({ top: 2 })
              .opacity(this.followState.busy ? 0.6 : 1)
              .onClick(() => {
                this.follow.toggle().catch(() => {
                });
              })
            .gesture(LongPressGesture({ repeat: false })
              .onAction(() => {
                this.showStatusPanel = true;
              }))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ left: 14, right: 14, top: Immersive.statusBarHeight() + 10, bottom: 18 })
    }
    .width('100%')
    .height(Immersive.statusBarHeight() + 224)
  }

  @Builder
  RelatedCell(item: BangumiSeason) {
    Row({ space: 8 }) {
      if (item.cover.length > 0) {
        Image(biliImageThumbnail(item.cover, 320))
          .width(100)
          .height(62)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
      }
      Column({ space: 3 }) {
        Text(item.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.subtitle.length > 0) {
          Text(item.subtitle)
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width(220)
    .padding(8)
    .borderRadius(10)
    .backgroundColor(this.isDark ? '#222429' : '#F1F3F5')
    .onClick(() => {
      const param: BangumiDetailParam = { seasonId: item.seasonId, epId: 0, title: item.title };
      AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
    })
  }

  @Builder
  RelatedSection() {
    if (this.season.relatedSeasons.length > 0) {
      Column({ space: 10 }) {
        Row() {
          Text('相关推荐')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        }
        .width('100%')
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.season.relatedSeasons, (item: BangumiSeason) => {
              this.RelatedCell(item)
            }, (item: BangumiSeason) => String(item.seasonId))
          }
          .padding({ right: 14 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        // Scroll 内容不足一屏时默认居中（官方默认 Center），横向列表应靠左。
        .align(Alignment.Start)
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 0, top: 14 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  IntroSection() {
    if (this.season.evaluate.length > 0 || this.season.actors.length > 0 || this.introMeta().length > 0) {
      Column({ space: 8 }) {
        Text('简介')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        if (this.introMeta().length > 0) {
          Text(this.introMeta())
            .fontSize(12)
            .fontColor('#9499A0')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.season.evaluate.length > 0) {
          Text(this.season.evaluate)
            .fontSize(13)
            .lineHeight(21)
            .fontColor(this.isDark ? '#D8D8DC' : '#303236')
        }
        if (this.season.actors.length > 0) {
          Text('演职人员：' + this.season.actors)
            .fontSize(12)
            .fontColor('#9499A0')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 16 })
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  CommentSection() {
    Column() {
      Row({ space: 8 }) {
        Text('评论')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        if (BangumiEpisodeCatalog.currentLabel(this.season, this.currentEpId).length > 0) {
          Text(BangumiEpisodeCatalog.currentLabel(this.season, this.currentEpId))
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(12)
            .fontColor('#9499A0')
        }
        if (this.season.reply > 0) {
          Text(formatCount(this.season.reply))
            .fontSize(12)
            .fontColor('#9499A0')
        }
        Blank()
        ReplySortChips({
          mode: this.replySortMode,
          onChange: (mode: number) => {
            this.replies.changeReplySort(mode);
          },
        })
      }
      .width('100%')
      .padding({ top: 16, bottom: 8 })
      if (this.replyOid() <= 0) {
        Text('本集暂不支持评论')
          .fontSize(12)
          .fontColor('#9499A0')
          .padding(18)
      } else if (this.repliesLoading && this.repliesCount === 0) {
        LoadingView({ loading: true, skeleton: 'comments' })
      } else if (this.repliesFailed) {
        Text('评论加载失败，点击重试')
          .fontSize(12)
          .fontColor('#9499A0')
          .padding(18)
          .onClick(() => this.replies.load(true).catch(() => {
          }))
      } else if (this.repliesCount === 0) {
        Text('暂时还没有评论')
          .fontSize(12)
          .fontColor('#9499A0')
          .padding(18)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FollowStatusPanel() {
    Column({ space: 10 }) {
      Text('标记状态')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDark ? '#F1F2F4' : '#18191C')
      Row({ space: 10 }) {
        ForEach([1, 2, 4], (status: number) => {
          Text(['想看', '在看', '', '看过'][status - 1] ?? '')
            .fontSize(13)
            .fontColor(this.followState.status === status ? '#FFFFFF' : (this.isDark ? '#D0D0D0' : '#5A5F66'))
            .padding({ left: 16, right: 16, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(this.followState.status === status ? this.accent : (this.isDark ? '#2C2D33' : '#F1F2F3'))
            .onClick(() => this.follow.setStatus(status))
        }, (status: number) => 'status-' + String(status))
      }
    }
    .padding(14)
    .borderRadius(14)
    .backgroundColor(this.isDark ? '#26272B' : '#FFFFFF')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
    Column() {
      if (this.loading) {
        this.StateHeader()
        LoadingView({ loading: true, skeleton: 'season' })
      } else if (this.errorText.length > 0) {
        this.StateHeader()
        LoadingView({
          loading: false,
          empty: false,
          errorText: this.errorText,
          onRetry: () => {
            this.init().catch(() => {
            });
          },
        })
      } else {
        List({ scroller: this.scroller }) {
          ListItem() {
            Column() {
              this.Header()
              BangumiEpisodeSection({
                season: this.season,
                currentEpId: this.currentEpId,
                viewportWidth: this.viewportWidth,
                onPlay: (episode: BangumiEpisode): void => this.playEpisode(episode),
              })
              this.RelatedSection()
              this.IntroSection()
              this.CommentSection()
            }
            .width('100%')
          }
          if (this.replyOid() > 0 && this.repliesCount > 0) {
            LazyForEach(this.replies.source, (reply: ReplyItem) => {
              ListItem() {
                ReplyCard({
                  item: reply,
                  showPreview: true,
                  version: this.replyVersion,
                  upMid: 0,
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
              }.padding({ left: 14, right: 14 })
            // 稳定 key：点赞视觉态由 ReplyCard 的 @State 镜像原地刷新，避免整卡重建闪烁。
            }, (reply: ReplyItem) => String(reply.rpid))
            ListItem() {
              LoadMoreFooter({
                loading: this.repliesLoading,
                hasMore: this.repliesHasMore || this.repliesMoreFailed,
                moreText: this.repliesMoreFailed ? '加载失败，点击重试' : '加载更多评论',
                endText: '没有更多评论了',
                fixedHeight: 46,
                onLoadMore: () => this.replies.load(this.repliesMoreFailed && this.replies.getRepliesRetryReset())
                  .catch(() => {}),
              })
            }.padding({ left: 14, right: 14 })
          }
          // 尾部留白：替代原 Scroll 内容底部内边距。
          ListItem() {
            Column().width('100%').height(Immersive.bottomInset() + 18)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .constraintSize({ maxWidth: LayoutTokens.pageMaxWidth })
        .alignSelf(ItemAlign.Center)
        .edgeEffect(EdgeEffect.None)
        .cachedCount(4)
        .scrollBar(BarState.Off)
        if (this.replyOid() > 0) {
          ReplyComposer({
            text: this.replyDraft,
            sending: this.replySending,
            showEmoteButton: false,
            onChange: (value: string) => {
              this.replySubmit.draftChanged();
              this.replyDraft = value;
            },
            onSend: () => this.sendReply(),
          })
            .padding({ bottom: Immersive.bottomInset() })
            .constraintSize({ maxWidth: LayoutTokens.pageMaxWidth })
            .alignSelf(ItemAlign.Center)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (!Number.isNaN(width) && width > 0) this.viewportWidth = width;
    })
    .bindSheet($$this.threadOpen, this.ThreadSheet(), {
      height: SheetSize.LARGE,
      keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
      dragBar: false,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: this.isDark ? '#18191C' : '#FFFFFF',
    })
    if (this.showStatusPanel) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#40000000')
        .onClick(() => {
          this.showStatusPanel = false;
        })
      Column() {
        this.FollowStatusPanel()
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: Immersive.bottomInset() + 24 })
      .zIndex(90)
    }
    }
    .width('100%')
    .height('100%')
  }
}
