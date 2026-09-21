import { BasicDataSource } from '../common/BasicDataSource';
/**
 * 番剧/影视（PGC）详情页：封面氛围头部（海报 + 评分 + 追番）+ 选集 + 简介 + 评论。
 * 入口：动态流 PGC 卡片。评论区复用动态详情的组装方式（type=1，oid 为当前集 aid）。
 */
import { LengthMetrics, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppNavStack, BangumiDetailParam, NAV_BANGUMI_DETAIL, NAV_LOGIN, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { BangumiEpisode, BangumiSeason, ReplyItem } from '../model/Models';
import { ActionResult } from '../api/BiliApi';
import { biliImageThumbnail } from '../common/ImageUrl';
import { BangumiApi } from '../api/BangumiApi';
import { Immersive } from '../common/Immersive';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { BackButton, BackButtonVariant } from '../components/BackButton';
import { ReplyCard } from '../components/reply/ReplyCard';
import { ReplyComposer } from '../components/reply/ReplyComposer';
import { ReplyThreadPanel } from '../components/reply/ReplyThreadPanel';
import { RepliesController } from '../components/reply/RepliesController';
import { ReplyShareCard } from '../components/reply/ReplyShareCard';
import { ReplySortChips } from '../components/reply/ReplySortChips';
import { UserStore } from '../services/auth/UserStore';
import { ReplyReactionHooks, runReplyDislike, runReplyLike } from '../common/ReplyMutation';
import { asNumber, asObject, colorWithAlpha, formatCount, formatDuration } from '../common/Utils';
import { LayoutTokens } from '../common/LayoutTokens';
import { CommentApi } from '../api/CommentApi';

@Component
export struct BangumiDetailPage {
  param: BangumiDetailParam = { seasonId: 0, epId: 0, title: '' };
  @State season: BangumiSeason = new BangumiSeason();
  @State loading: boolean = true;
  @State errorText: string = '';
  @State currentEpId: number = 0;
  @State followed: boolean = false;
  @State favorites: number = 0;
  @State followBusy: boolean = false;
  @State viewportWidth: number = 360;
  // ===== 评论（挂在当前集 aid 上，type=1） =====
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
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private destroyed: boolean = false;
  private replyLikeBusy: Set<number> = new Set<number>();
  private scroller: Scroller = new Scroller();
  /**
   * 评论编排控制器：游标/请求代际/分享卡临时状态都在控制器，@State 经下方闭包读写。
   * clearOnSort=true：切换评论排序时清空列表与游标，重新拉第一页。
   */
  private replies: RepliesController = new RepliesController({
    isDestroyed: (): boolean => this.destroyed,
    toast: (message: string): void => this.toast(message),
    getUIContext: (): UIContext => this.getUIContext(),
    resolveOid: (): number => this.replyOid(),
    resolveType: (): number => 1,
    canLoadReplies: (): boolean => true,
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
      'https://www.bilibili.com/bangumi/play/ep' + String(this.currentEpId) + '#reply' + String(item.rpid),
    renderShareCard: (): void => {
      this.ReplyShareCardBuilder();
    },
    // 番剧分享卡需要 hostContext 展示系统分享面板；拿不到时按失败提示收场。
    ensureShareContext: (context: common.UIAbilityContext | undefined): boolean => {
      if (context === undefined) {
        this.toast('分享图片生成失败，请稍后重试');
        return false;
      }
      return true;
    },
    onShareFailed: (_item: ReplyItem, _link: string, _error: Object): void => {
      this.toast('分享图片生成失败，请稍后重试');
    },
  }, true);

  aboutToAppear(): void {
    this.destroyed = false;
    this.init().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.replies.dispose();
    this.destroyed = true;
    this.replies.releaseShareCard();
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
    this.loading = true;
    this.errorText = '';
    try {
      const season: BangumiSeason | null = await BangumiApi.getSeason(this.param.seasonId, this.param.epId);
      if (this.destroyed) return;
      if (season === null) {
        this.errorText = '详情加载失败，请检查网络后重试';
        return;
      }
      this.season = season;
      this.followed = season.followed;
      this.favorites = season.favorites;
      // 定位当前集：优先入口参数 epId，否则第一集；评论区挂在当前集 aid 上。
      this.currentEpId = this.pickCurrentEpId(season);
      this.replies.load(true).catch(() => {
      });
    } catch (e) {
      if (!this.destroyed) this.errorText = '详情加载失败，请检查网络后重试';
    } finally {
      if (!this.destroyed) this.loading = false;
    }
  }

  private pickCurrentEpId(season: BangumiSeason): number {
    if (this.param.epId > 0) {
      for (let i: number = 0; i < season.episodes.length; i++) {
        if (season.episodes[i].epId === this.param.epId) return this.param.epId;
      }
    }
    return season.episodes.length > 0 ? season.episodes[0].epId : 0;
  }

  private currentEpisode(): BangumiEpisode | null {
    const episodes: Array<BangumiEpisode> = this.season.episodes;
    for (let i: number = 0; i < episodes.length; i++) {
      if (episodes[i].epId === this.currentEpId) return episodes[i];
    }
    return episodes.length > 0 ? episodes[0] : null;
  }

  /** 评论 oid：当前集 aid；无剧集或未上线时为 0，评论区与输入框整体隐藏。 */
  private replyOid(): number {
    const ep: BangumiEpisode | null = this.currentEpisode();
    return ep !== null ? ep.aid : 0;
  }

  private followLabel(): string {
    return this.season.seasonType === 1 || this.season.seasonType === 4 ? '追番' : '追剧';
  }

  private episodeUnit(): string {
    return this.season.seasonType === 1 || this.season.seasonType === 4 ? '话' : '集';
  }

  private currentEpLabel(): string {
    const ep: BangumiEpisode | null = this.currentEpisode();
    if (ep === null || ep.title.length === 0) return '';
    // title 是纯数字时展示"第 x 话"，PV/SP 等标签原样展示。
    return /^[0-9]+$/.test(ep.title) ? '第 ' + ep.title + ' ' + this.episodeUnit() : ep.title;
  }

  private episodeFullTitle(ep: BangumiEpisode): string {
    let label: string = this.season.title + ' ' + ep.title;
    if (ep.longTitle.length > 0) label += ' ' + ep.longTitle;
    return label;
  }

  /** 保留集 ID 与 CID，详情和换画质始终使用 PGC 鉴权取流。 */
  private playEpisode(ep: BangumiEpisode): void {
    if (ep.aid <= 0 && ep.bvid.length === 0) {
      this.toast('该集暂未上线');
      return;
    }
    // 切换当前集：高亮与评论区跟随，播放页返回后仍指向最近观看的一集。
    if (ep.epId !== this.currentEpId) {
      this.currentEpId = ep.epId;
      this.replies.clearMainReplies();
      this.replies.load(true).catch(() => {
      });
    }
    const param: VideoDetailParam = { bvid: ep.bvid, aid: ep.aid, title: this.episodeFullTitle(ep),
      epId: ep.epId, cid: ep.cid, cover: ep.cover };
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  private async toggleFollow(): Promise<void> {
    if (!UserStore.isLogin) {
      this.toast('请先登录后再' + this.followLabel());
      AppNavStack.pushPathByName(NAV_LOGIN, null);
      return;
    }
    if (this.followBusy || this.season.seasonId <= 0) return;
    this.followBusy = true;
    try {
      const result: ActionResult = await BangumiApi.setFollowed(this.season.seasonId, !this.followed);
      if (this.destroyed) return;
      this.toast(result.message);
      if (result.ok) {
        this.followed = !this.followed;
        this.favorites = Math.max(0, this.favorites + (this.followed ? 1 : -1));
      }
    } catch (e) {
      if (!this.destroyed) this.toast('网络异常，操作失败');
    } finally {
      if (!this.destroyed) this.followBusy = false;
    }
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
    return {
      ensureLogin: () => {
        if (UserStore.isLogin) return true;
        this.toast('请先登录后再操作');
        AppNavStack.pushPathByName(NAV_LOGIN, null);
        return false;
      },
      toast: (message: string) => this.toast(message),
      isDestroyed: () => this.destroyed,
      resolveOid: () => this.replyOid(),
      resolveType: () => 1,
      clearDislikeOnLike: false,
    };
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
    reply.oid = this.replyOid();
    reply.type = 1;
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
      const result: ActionResult = await CommentApi.addReply(this.replyOid(), 1, message,
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

  /** 删除评论成功后的本地移除：数据源重建 + 计数同步。 */
  private removeReply(rpid: number): void {
    const kept: Array<ReplyItem> = this.replySource.getAll().filter((x: ReplyItem) => x.rpid !== rpid);
    if (kept.length !== this.replySource.totalCount()) {
      this.replySource.reset(kept);
      this.repliesCount = kept.length;
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
      upMid: 0,
      qr: this.replies.shareQr(),
      linkLabel: 'bangumi/play/ep' + String(this.currentEpId),
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
      replies: this.threadReplies,
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
    const oid: number = this.replyOid();
    if (message.length === 0 || this.replySending || oid <= 0) return;
    if (!UserStore.isLogin) {
      this.toast('请先登录后再评论');
      AppNavStack.pushPathByName(NAV_LOGIN, null);
      return;
    }
    this.replySending = true;
    try {
      const result: ActionResult = await CommentApi.addReply(oid, 1, message);
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

  private introMeta(): string {
    const parts: Array<string> = [];
    if (this.season.styles.length > 0) parts.push(this.season.styles);
    if (this.season.areas.length > 0) parts.push(this.season.areas);
    if (this.season.pubTimeShow.length > 0) parts.push(this.season.pubTimeShow);
    return parts.join(' · ');
  }

  /** 选集格子宽度：手机双列，折叠屏/平板逐级加列。 */
  private episodeCellWidth(): number {
    const content: number = Math.min(this.viewportWidth, LayoutTokens.pageMaxWidth) - 28;
    const cols: number = this.viewportWidth >= 820 ? 4 : (this.viewportWidth >= 560 ? 3 : 2);
    return (content - 8 * (cols - 1)) / cols;
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
            Text(formatCount(this.season.views) + ' 播放 · ' + formatCount(this.favorites) + ' ' + this.followLabel())
              .fontSize(12)
              .fontColor('#E6FFFFFF')
            Text((this.followed ? '已' : '+ ') + this.followLabel())
              .fontSize(13)
              .fontColor('#FFFFFF')
              .padding({ left: 20, right: 20, top: 6, bottom: 6 })
              .borderRadius(17)
              .backgroundColor(this.followed ? '#40FFFFFF' : this.accent)
              .margin({ top: 2 })
              .opacity(this.followBusy ? 0.6 : 1)
              .onClick(() => {
                this.toggleFollow().catch(() => {
                });
              })
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
  EpisodeCell(ep: BangumiEpisode) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        // 占位底色：封面加载失败/未返回时保持格子形状
        Column()
          .width('100%')
          .aspectRatio(16 / 10)
          .borderRadius(6)
          .backgroundColor(this.isDark ? '#26272B' : '#E3E5E7')
        if (ep.cover.length > 0) {
          Image(biliImageThumbnail(ep.cover, 480))
            .width('100%')
            .aspectRatio(16 / 10)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
        }
        // 底部压暗渐变 + 集数/时长
        Column()
          .width('100%')
          .aspectRatio(16 / 10)
          .borderRadius(6)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.55], ['#73000000', 1.0]],
          })
          .hitTestBehavior(HitTestMode.None)
        Column() {
          Row() {
            Text(ep.title)
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Blank()
            if (ep.duration > 0) {
              Text(formatDuration(ep.duration))
                .fontSize(10)
                .fontColor('#FFFFFF')
            }
          }
          .width('100%')
          .padding({ left: 8, right: 8, bottom: 6 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.None)
        if (ep.badge.length > 0) {
          Text(ep.badge)
            .fontSize(9)
            .fontColor('#FFFFFF')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(this.accent)
            .margin(6)
        }
        // 当前集高亮描边
        Column()
          .width('100%')
          .aspectRatio(16 / 10)
          .borderRadius(6)
          .border({ width: ep.epId === this.currentEpId ? 1.5 : 0, color: this.accent, radius: 6 })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%').aspectRatio(16 / 10).clip(true)
      Text(ep.longTitle.length > 0 ? ep.longTitle : this.episodeFullTitle(ep))
        .fontSize(11)
        .fontColor(ep.epId === this.currentEpId ? this.accent : (this.isDark ? '#D8D8DC' : '#303236'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(this.episodeCellWidth())
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.playEpisode(ep);
    })
  }

  @Builder
  EpisodeSection() {
    if (this.season.episodes.length > 0) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('选集')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          if (this.season.total > 0) {
            Text('共 ' + String(this.season.total) + ' ' + this.episodeUnit())
              .fontSize(12)
              .fontColor('#9499A0')
          }
          if (this.season.newEpDesc.length > 0) {
            Text(this.season.newEpDesc)
              .layoutWeight(1)
              .fontSize(12)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(10) } }) {
          ForEach(this.season.episodes, (ep: BangumiEpisode) => {
            this.EpisodeCell(ep)
          }, (ep: BangumiEpisode) => String(ep.epId))
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14 })
      .alignItems(HorizontalAlign.Start)
    }
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
        if (this.currentEpLabel().length > 0) {
          Text(this.currentEpLabel())
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

  build() {
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
              this.EpisodeSection()
              this.RelatedSection()
              this.IntroSection()
              this.CommentSection()
            }
            .width('100%')
          }
          if (this.replyOid() > 0 && this.repliesCount > 0) {
            LazyForEach(this.replySource, (reply: ReplyItem) => {
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
                  onShare: (item: ReplyItem) => this.replies.share(item),
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
  }
}
