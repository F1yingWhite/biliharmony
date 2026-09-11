import { RequestEpoch } from '../common/RequestEpoch';
/**
 * 番剧/影视（PGC）详情页：封面氛围头部（海报 + 评分 + 追番）+ 选集 + 简介 + 评论。
 * 入口：动态流 PGC 卡片。评论区复用动态详情的组装方式（type=1，oid 为当前集 aid）。
 */
import { LengthMetrics, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { AppNavStack, BangumiDetailParam, NAV_BANGUMI_DETAIL, NAV_LOGIN, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { BangumiEpisode, BangumiSeason, ReplyData, ReplyItem } from '../model/Models';
import { ActionResult } from '../api/BiliApi';
import { BangumiApi } from '../api/BangumiApi';
import { Immersive } from '../common/Immersive';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { BackButton, BackButtonVariant } from '../components/BackButton';
import { ReplyCard } from '../components/reply/ReplyCard';
import { ReplyComposer } from '../components/reply/ReplyComposer';
import { ReplyThreadPanel } from '../components/reply/ReplyThreadPanel';
import { ReplyShareCard, makeReplyQr, makeReplyShareSnapshot,
  sharePixelMapAsImage } from '../components/reply/ReplyShareCard';
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
  @State replies: Array<ReplyItem> = [];
  @State repliesLoading: boolean = false;
  @State repliesFailed: boolean = false;
  @State repliesMoreFailed: boolean = false;
  private repliesRetryReset: boolean = false;
  private repliesEpoch: RequestEpoch = new RequestEpoch();
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
  private threadEpoch: RequestEpoch = new RequestEpoch();
  @State threadHasMore: boolean = true;
  @State threadDraft: string = '';
  @State threadSending: boolean = false;
  @State threadTargetRpid: number = 0;
  @State threadTargetName: string = '';
  @State threadFocusTick: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private destroyed: boolean = false;
  private replyCursor: string = '';
  private replyLikeBusy: Set<number> = new Set<number>();
  private scroller: Scroller = new Scroller();
  private threadCursor: string = '';
  // 评论分享卡离屏渲染用的待截内容；只在生成分享图期间短暂赋值。
  private shareCardItem: ReplyItem = new ReplyItem();
  private shareCardQr: image.PixelMap | null = null;
  private shareCardBusy: boolean = false;

  aboutToAppear(): void {
    this.destroyed = false;
    this.init().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.repliesEpoch.invalidate();
    this.threadEpoch.invalidate();
    this.threadLoading = false;
    this.destroyed = true;
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
      this.loadReplies(true).catch(() => {
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

  /** 点选集跳现有视频详情页播放。PGC 每集带独立 aid/bvid/cid，免费集走 x/player/playurl 即可取流；
   * 会员/付费集需要 /pgc/player/web/playurl 鉴权，本版本暂不支持，由视频详情页的错误态兜底提示。 */
  private playEpisode(ep: BangumiEpisode): void {
    if (ep.aid <= 0 && ep.bvid.length === 0) {
      this.toast('该集暂未上线');
      return;
    }
    // 切换当前集：高亮与评论区跟随，播放页返回后仍指向最近观看的一集。
    if (ep.epId !== this.currentEpId) {
      this.currentEpId = ep.epId;
      this.replyCursor = '';
      this.repliesHasMore = true;
      this.replies = [];
      this.loadReplies(true).catch(() => {
      });
    }
    const param: VideoDetailParam = { bvid: ep.bvid, aid: ep.aid, title: this.episodeFullTitle(ep) };
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

  // ===== 评论（组装方式同动态详情） =====
  private async loadReplies(reset: boolean): Promise<void> {
    if (this.destroyed || (!reset && (this.repliesLoading || !this.repliesHasMore))) return;
    const request: number = this.repliesEpoch.next();
    const oid: number = this.replyOid();
    if (oid <= 0) {
      this.repliesLoading = false;
      return;
    }
    this.repliesLoading = true;
    this.repliesMoreFailed = false;
    this.repliesRetryReset = reset;
    if (reset) this.repliesFailed = false;
    try {
      const data: ReplyData = await CommentApi.getReplies(oid, 1, reset ? '' : this.replyCursor, this.replySortMode);
      if (this.destroyed || !this.repliesEpoch.isCurrent(request)) return;
      this.replies = reset ? data.replies : this.replies.concat(data.replies);
      this.replyCursor = data.cursor;
      this.repliesHasMore = data.hasMore;
    } catch (e) {
      if (this.destroyed || !this.repliesEpoch.isCurrent(request)) return;
      if (this.replies.length === 0) this.repliesFailed = true;
      else this.repliesMoreFailed = true;
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
   */
  private mutateReplyItem(rpid: number, mutate: (target: ReplyItem) => void): ReplyItem | null {
    let found: ReplyItem | null = null;
    for (let i = 0; i < this.replies.length; i++) {
      if (this.replies[i].rpid === rpid) {
        found = this.replies[i];
        mutate(this.replies[i]);
        const next: ReplyItem = this.replies[i].clone();
        next.rev = this.replies[i].rev + 1;
        this.replies[i] = next;
        this.replies = this.replies.slice();
        break;
      }
    }
    for (let i = 0; i < this.threadReplies.length; i++) {
      if (this.threadReplies[i].rpid === rpid) {
        if (found === null) found = this.threadReplies[i];
        mutate(this.threadReplies[i]);
        const next: ReplyItem = this.threadReplies[i].clone();
        next.rev = this.threadReplies[i].rev + 1;
        this.threadReplies[i] = next;
        this.threadReplies = this.threadReplies.slice();
        break;
      }
    }
    if (this.threadRoot.rpid === rpid) {
      if (found === null) found = this.threadRoot;
      mutate(this.threadRoot);
      const next: ReplyItem = this.threadRoot.clone();
      next.rev = this.threadRoot.rev + 1;
      this.threadRoot = next;
    }
    this.replyVersion++;
    return found;
  }

  private async likeReply(item: ReplyItem): Promise<void> {
    await runReplyLike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.mutateReplyItem(rpid, mutate),
      this.replyReactionHooks());
  }

  private async dislikeReply(item: ReplyItem): Promise<void> {
    await runReplyDislike(item, this.replyLikeBusy,
      (rpid: number, mutate: (target: ReplyItem) => void) => this.mutateReplyItem(rpid, mutate),
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
    const oid: number = this.replyOid();
    if ((!reset && this.threadLoading) || this.threadRoot.rpid <= 0 || oid <= 0 || (!reset && !this.threadHasMore)) return;
    const epoch: number = this.threadEpoch.next();
    this.threadLoading = true;
    const root: number = this.threadRoot.rpid;
    const cursor: string = reset ? '' : this.threadCursor;
    try {
      const result: ReplyData = await CommentApi.getReplyReplies(oid, 1, root, cursor);
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
    const link: string = 'https://www.bilibili.com/bangumi/play/ep' + String(this.currentEpId) +
      '#reply' + String(item.rpid);
    const context: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      this.shareCardBusy = false;
      this.toast('分享图片生成失败，请稍后重试');
      return;
    }
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
      upMid: 0,
      qr: this.shareCardQr,
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
      this.replyCursor = '';
      this.repliesHasMore = true;
      await this.loadReplies(true);
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
        Image(this.season.cover)
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
          Image(ep.cover)
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
        Image(item.cover)
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
            this.changeReplySort(mode);
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
      } else if (this.repliesLoading && this.replies.length === 0) {
        LoadingView({ loading: true, skeleton: 'comments' })
      } else if (this.repliesFailed) {
        Text('评论加载失败，点击重试')
          .fontSize(12)
          .fontColor('#9499A0')
          .padding(18)
          .onClick(() => this.loadReplies(true).catch(() => {
          }))
      } else if (this.replies.length === 0) {
        Text('暂时还没有评论')
          .fontSize(12)
          .fontColor('#9499A0')
          .padding(18)
      } else {
        ForEach(this.replies, (reply: ReplyItem) => {
          ReplyCard({
            item: reply,
            showPreview: true,
            version: this.replyVersion,
            upMid: 0,
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
          moreText: this.repliesMoreFailed ? '加载失败，点击重试' : '加载更多评论',
          endText: '没有更多评论了',
          fixedHeight: 46,
          onLoadMore: () => this.loadReplies(this.repliesMoreFailed && this.repliesRetryReset).catch(() => {}),
        })
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
        Scroll(this.scroller) {
          Column() {
            this.Header()
            this.EpisodeSection()
            this.RelatedSection()
            this.IntroSection()
            this.CommentSection()
          }
          .width('100%')
          .padding({ bottom: Immersive.bottomInset() + 18 })
        }
        .width('100%')
        .layoutWeight(1)
        .constraintSize({ maxWidth: LayoutTokens.pageMaxWidth })
        .alignSelf(ItemAlign.Center)
        // Scroll 内容不足一屏时默认居中，内容应从顶部开始排。
        .align(Alignment.TopStart)
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
