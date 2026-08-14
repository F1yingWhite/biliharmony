/**
 * 视频详情页：沉浸式播放器 + 封面取色动态主题 + 简介/评论/相关
 */
import { promptAction, curves, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_IMAGE_VIEWER, NAV_LOGIN, NAV_VIDEO_DETAIL, NAV_USER_SPACE, ImageViewerParam,
  VideoDetailParam, UserSpaceParam } from '../common/AppRouter';
import { VideoDetail, VideoItem, ReplyItem, PlayUrlInfo, VideoPage, VideoQualityOption, VideoRelationState,
  BiliEmote, BiliEmotePackage, FavoriteFolderItem } from '../model/Models';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { PlayerView } from '../components/PlayerView';
import { LoadingView } from '../components/LoadingView';
import { ImageColor, ImagePalette } from '../common/ImageColor';
import { UserStore } from '../common/UserStore';
import { colorWithAlpha, formatCount, formatRelativeTime, formatDate, formatDuration } from '../common/Utils';
import { DecoratedAvatar, UserDecorationBanner } from '../components/UserDecorations';
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { PlayerCommandBus } from '../common/PlayerCommandBus';

@Component
export struct VideoDetailPage {
  @State loading: boolean = true;
  @State errorText: string = '';
  @State detail: VideoDetail = new VideoDetail();
  @State playUrl: string = '';
  @State playUrls: Array<string> = [];
  @State playAudioUrls: Array<string> = [];
  @State qualityOptions: Array<VideoQualityOption> = [];
  @State currentQuality: number = 0;
  @State currentCid: number = 0;
  @State currentPageIndex: number = 0;
  @State pageSwitchingCid: number = 0;
  @State playerSourceVersion: number = 0;
  @State related: Array<VideoItem> = [];
  @State replies: Array<ReplyItem> = [];
  @State replyCursor: string = '';
  @State replyHasMore: boolean = true;
  @State replyLoading: boolean = false;
  @State replyPrefetchCount: number = 0;
  // 回复详情是视频页内的二级导航状态；放入 AppStorage 供 NavDestination
  // 的系统返回/侧滑回调优先关闭，避免直接把整个视频页弹出。
  @StorageLink('videoReplyThreadOpen') @Watch('onReplyThreadStateChanged') replyThreadOpen: boolean = false;
  @State replyThreadRoot: ReplyItem = new ReplyItem();
  @State threadReplies: Array<ReplyItem> = [];
  @State threadPage: number = 0;
  @State threadHasMore: boolean = true;
  @State threadLoading: boolean = false;
  @State threadPrefetchCount: number = 0;
  @State replyTargetRpid: number = 0;
  @State replyTargetName: string = '';
  @State replyDraft: string = '';
  @State replySending: boolean = false;
  @State replySortMode: number = 3; // 3 热度，2 时间
  @State emotePackages: Array<BiliEmotePackage> = [];
  @State emotePackageIndex: number = 0;
  @State emotePanelOpen: boolean = false;
  @State emoteLoading: boolean = false;
  @State tab: number = 0; // 0 简介 / 1 评论 / 2 相关
  @State visualTab: number = 0; // 仅驱动标签颜色/下划线，不反向打断 Tabs 位移动画
  @State descExpanded: boolean = false;
  @State pageTint: string = '#FB7299';
  @State liked: boolean = false;
  @State coinCountByMe: number = 0;
  @State likeCount: number = 0;
  @State coinCount: number = 0;
  @State favoriteCount: number = 0;
  @State favorited: boolean = false;
  @State actionBusy: boolean = false;
  @State coinSheetOpen: boolean = false;
  @State coinChoice: number = 1;
  @State coinWithLike: boolean = true;
  @State following: boolean = false;
  @State followLoading: boolean = false;
  @State playerFullscreen: boolean = false;
  @State playerPlaying: boolean = false;
  @State playerCollapse: number = 0;
  @State danmakuOn: boolean = true;
  @State danmakuDraft: string = '';
  @State danmakuSending: boolean = false;
  @State localDanmakuText: string = '';
  @State localDanmakuToken: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('loginVersion') @Watch('onLoginVersionChanged') loginVersion: number = 0;
  param: VideoDetailParam = { bvid: '', aid: 0, title: '' };
  private bvid: string = '';
  private aid: number = 0;
  private tabsController: TabsController = new TabsController();
  private introScroller: Scroller = new Scroller();
  private replyScroller: Scroller = new Scroller();
  private threadScroller: Scroller = new Scroller();
  private videoProgressSeconds: number = 0;
  private contentGestureActive: boolean = false;
  private pageSwitchRequest: number = 0;
  private replyListSavedOffset: number = -1;

  onReplyThreadStateChanged(): void {
    if (!this.replyThreadOpen && this.replyListSavedOffset >= 0) {
      const restoreOffset: number = this.replyListSavedOffset;
      this.replyListSavedOffset = -1;
      // 等条件分支把主评论 List 重新挂回 Scroller 后，再恢复进入详情前的精确位置。
      setTimeout(() => {
        try {
          this.replyScroller.scrollTo({ xOffset: 0, yOffset: restoreOffset });
        } catch (e) {
        }
      }, 16);
    }
  }

  closeReplyThread(): void {
    if (this.replyThreadOpen) this.replyThreadOpen = false;
  }

  private playerHeight(): number {
    try {
      const screen: display.Display = display.getDefaultDisplaySync();
      const widthVp: number = px2vp(screen.width);
      const screenHeightVp: number = px2vp(screen.height);
      const usableHeight: number = Math.max(480,
        screenHeightVp - Immersive.statusBarHeight() - Immersive.bottomInset());
      // 至少保留常规横屏视频的控制空间；竖屏按原始比例增高，但最多占可用高度 68%，
      // 且在大屏设备上不超过 520vp，确保下方简介/评论仍然可操作。
      const regularHeight: number = widthVp * 9 / 16;
      const maximumHeight: number = Math.max(regularHeight, Math.min(520, usableHeight * 0.68));
      let videoWidth: number = this.detail.width;
      let videoHeight: number = this.detail.height;
      let videoRotate: number = this.detail.rotate;
      for (let i: number = 0; i < this.detail.pages.length; i++) {
        if (this.detail.pages[i].cid === this.currentCid && this.detail.pages[i].width > 0 &&
          this.detail.pages[i].height > 0) {
          videoWidth = this.detail.pages[i].width;
          videoHeight = this.detail.pages[i].height;
          videoRotate = this.detail.pages[i].rotate;
          break;
        }
      }
      if (Math.abs(videoRotate) % 180 !== 0) {
        const rotatedWidth: number = videoHeight;
        videoHeight = videoWidth;
        videoWidth = rotatedWidth;
      }
      if (videoWidth <= 0 || videoHeight <= 0) return regularHeight;
      const naturalHeight: number = widthVp * videoHeight / videoWidth;
      return Math.max(regularHeight, Math.min(maximumHeight, naturalHeight));
    } catch (e) {
      return 220;
    }
  }

  private minPlayerHeight(): number {
    // 播放和暂停共用稳定下限；暂停态由 PlayerView 保留蒙版和继续播放按钮。
    return 112;
  }

  private visiblePlayerHeight(): number {
    const base: number = this.playerHeight();
    return Math.max(this.minPlayerHeight(), base - this.playerCollapse);
  }

  onPlayerPlayingChange(playing: boolean): void {
    if (this.playerPlaying === playing) return;
    this.playerPlaying = playing;
  }

  expandPlayerForResume(): void {
    if (this.playerCollapse <= 0) return;
    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.playerCollapse = 0;
    });
  }

  onDetailScroll(offset: number): void {
    if (Math.abs(offset) < 0.1) return;
    const maxCollapse: number = Math.max(0, this.playerHeight() - this.minPlayerHeight());
    const next: number = Math.max(0, Math.min(maxCollapse, this.playerCollapse + offset));
    if (Math.abs(next - this.playerCollapse) > 0.1) this.playerCollapse = next;
  }

  /**
   * 评论列表的滚动增量先用于收放播放器；返回值才交给 List 消费。
   * 这样列表位于顶部时不会因为容器改高而丢失后续手势。
   */
  isScrollerAtTop(scroller: Scroller): boolean {
    try {
      return scroller.currentOffset().yOffset <= 0.5;
    } catch (e) {
      return true;
    }
  }

  onContentScrollFrame(offset: number, scroller: Scroller, state: ScrollState): number {
    // onScrollStart 在部分系统版本晚于首批 frame 回调，旧门闩会把整次手势漏掉。
    // Idle 代表非动画的程序化滚动；触摸拖动与惯性滚动则直接参与播放器联动。
    if (state === ScrollState.Idle) return offset;
    if (Math.abs(offset) < 0.1) return offset;
    const maxCollapse: number = Math.max(0, this.playerHeight() - this.minPlayerHeight());
    if (offset > 0 && this.playerCollapse < maxCollapse) {
      const consumed: number = Math.min(offset, maxCollapse - this.playerCollapse);
      this.playerCollapse += consumed;
      return offset - consumed;
    }
    if (offset < 0 && this.isScrollerAtTop(scroller) && this.playerCollapse > 0) {
      const consumed: number = Math.min(-offset, this.playerCollapse);
      this.playerCollapse -= consumed;
      return offset + consumed;
    }
    return offset;
  }

  aboutToAppear(): void {
    this.replyThreadOpen = false;
    this.bvid = this.param.bvid;
    this.aid = this.param.aid;
    this.init();
  }

  async init(): Promise<void> {
    this.loading = true;
    this.descExpanded = false;
    const detail: VideoDetail | null = await BiliApi.getVideoDetail(this.aid, this.bvid);
    if (detail === null) {
      this.loading = false;
      this.errorText = '视频不存在或已失效';
      return;
    }
    this.detail = detail;
    this.likeCount = detail.like;
    this.coinCount = detail.coin;
    this.favoriteCount = detail.favorite;

    // 封面取色仅用于本页播放区氛围光，不改全局主题色（主题色由用户自选）
    ImageColor.extract(detail.cover).then((palette: ImagePalette) => {
      this.pageTint = palette.dominant;
    });

    // 并行加载播放地址 / 相关 / 评论
    const cid: number = detail.cid > 0 ? detail.cid : (detail.pages.length > 0 ? detail.pages[0].cid : 0);
    this.currentCid = cid;
    this.currentPageIndex = 0;
    for (let i: number = 0; i < detail.pages.length; i++) {
      if (detail.pages[i].cid === cid) {
        this.currentPageIndex = i;
        break;
      }
    }
    BiliApi.getPlayUrl(detail.aid, detail.bvid, cid).then((info: PlayUrlInfo | null) => {
      if (info !== null) {
        this.playUrl = info.url;
        this.playUrls = info.urls;
        this.playAudioUrls = info.audioUrls;
        this.qualityOptions = info.qualities;
        this.currentQuality = info.quality;
      }
    });
    BiliApi.getRelated(detail.aid, detail.bvid).then((list: Array<VideoItem>) => {
      this.related = list;
    });
    this.loadReplies(true);
    if (UserStore.isLogin) {
      BiliApi.getVideoRelation(detail.aid, detail.bvid).then((relation: VideoRelationState | null) => {
        if (relation !== null) {
          this.liked = relation.liked;
          this.coinCountByMe = relation.coin;
          this.favorited = relation.favorite;
        }
      });
      this.loadFollowState();
      this.loadEmotes();
    }
    this.loading = false;
  }

  async loadEmotes(): Promise<void> {
    if (this.emoteLoading || this.emotePackages.length > 0 || !UserStore.isLogin) return;
    this.emoteLoading = true;
    this.emotePackages = await BiliApi.getUserEmotes('reply');
    this.emoteLoading = false;
    if (this.emotePackageIndex >= this.emotePackages.length) this.emotePackageIndex = 0;
  }

  openEmotePanel(): void {
    if (!this.ensureLogin()) return;
    this.emotePanelOpen = !this.emotePanelOpen;
    if (this.emotePanelOpen) this.loadEmotes();
  }

  insertEmote(item: BiliEmote): void {
    this.replyDraft += item.text;
  }

  seekFromReply(seconds: number): void {
    if (seconds < 0) return;
    PlayerCommandBus.seek(seconds);
    promptAction.showToast({ message: '已空降到 ' + formatDuration(seconds) });
  }

  openReplyVideo(part: ReplyRenderPart): void {
    if (part.bvid.length === 0 && part.aid <= 0) return;
    const param: VideoDetailParam = { bvid: part.bvid, aid: part.aid, title: part.text };
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  onReplyPartClick(part: ReplyRenderPart): void {
    if (part.seekSeconds >= 0) this.seekFromReply(part.seekSeconds);
    else this.openReplyVideo(part);
  }

  onLoginVersionChanged(): void {
    this.loadFollowState();
  }

  async loadFollowState(): Promise<void> {
    if (!UserStore.isLogin || this.detail.upMid <= 0) {
      this.following = false;
      this.followLoading = false;
      return;
    }
    this.followLoading = true;
    const attribute: number | null = await BiliApi.getUserRelation(this.detail.upMid);
    if (attribute !== null) {
      // 2 为已关注，6 为互相关注；128 是拉黑，不能误显示为已关注。
      this.following = attribute === 2 || attribute === 6;
    }
    this.followLoading = false;
  }

  async actionFollow(): Promise<void> {
    if (!this.ensureLogin() || this.followLoading || this.detail.upMid <= 0) return;
    if (UserStore.current !== null && UserStore.current.mid === this.detail.upMid) {
      promptAction.showToast({ message: '不能关注自己' });
      return;
    }
    const previous: boolean = this.following;
    const next: boolean = !previous;
    this.following = next;
    this.followLoading = true;
    const result: ActionResult = await BiliApi.modifyUserRelation(this.detail.upMid, next);
    this.followLoading = false;
    if (!result.ok) {
      this.following = previous;
      promptAction.showToast({ message: result.message });
      return;
    }
    promptAction.showToast({ message: next ? '关注成功' : '已取消关注' });
  }

  private ensureLogin(): boolean {
    if (UserStore.isLogin) return true;
    promptAction.showToast({ message: '请先登录后再操作' });
    AppNavStack.pushPathByName(NAV_LOGIN, null);
    return false;
  }

  async actionLike(): Promise<void> {
    if (!this.ensureLogin() || this.actionBusy) return;
    this.actionBusy = true;
    const next: boolean = !this.liked;
    const result: ActionResult = await BiliApi.likeVideo(this.detail.aid, this.detail.bvid, next);
    this.actionBusy = false;
    if (!result.ok) {
      promptAction.showToast({ message: result.message });
      return;
    }
    this.liked = next;
    this.likeCount = Math.max(0, this.likeCount + (next ? 1 : -1));
    promptAction.showToast({ message: next ? '点赞成功' : '已取消点赞' });
  }

  async actionFavorite(): Promise<void> {
    if (!this.ensureLogin() || this.actionBusy) return;
    this.actionBusy = true;
    const folders: Array<FavoriteFolderItem> = await BiliApi.getFavoriteFoldersForVideo(this.detail.aid);
    if (folders.length === 0) {
      this.actionBusy = false;
      promptAction.showToast({ message: '未找到可用的收藏夹' });
      return;
    }
    const selected: Array<number> = [];
    for (let i: number = 0; i < folders.length; i++) {
      if (folders[i].favorited) selected.push(folders[i].id);
    }
    const next: boolean = !this.favorited;
    const addIds: Array<number> = next ? [folders[0].id] : [];
    const deleteIds: Array<number> = next ? [] : selected;
    if (!next && deleteIds.length === 0) deleteIds.push(folders[0].id);
    const result: ActionResult = await BiliApi.modifyVideoFavorite(this.detail.aid, addIds, deleteIds);
    this.actionBusy = false;
    if (!result.ok) {
      promptAction.showToast({ message: result.message });
      return;
    }
    this.favorited = next;
    this.favoriteCount = Math.max(0, this.favoriteCount + (next ? 1 : -1));
    promptAction.showToast({ message: next ? '收藏成功' : '已取消收藏' });
  }

  async switchVideoPage(page: VideoPage, index: number): Promise<void> {
    if (page.cid <= 0 || page.cid === this.currentCid) return;
    const request: number = ++this.pageSwitchRequest;
    this.pageSwitchingCid = page.cid;
    const qn: number = this.currentQuality > 0 ? this.currentQuality : 127;
    const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(this.detail.aid, this.detail.bvid, page.cid, qn);
    if (request !== this.pageSwitchRequest) return;
    if (info === null || info.urls.length === 0) {
      this.pageSwitchingCid = 0;
      promptAction.showToast({ message: '该分 P 暂时无法播放' });
      return;
    }
    this.playUrl = info.url;
    this.playUrls = info.urls;
    this.playAudioUrls = info.audioUrls;
    this.qualityOptions = info.qualities;
    this.currentQuality = info.quality;
    this.currentCid = page.cid;
    this.currentPageIndex = index;
    this.pageSwitchingCid = 0;
    this.playerCollapse = 0;
    // 所有播放源属性先更新，最后递增版本号，让播放器一次性读取同一分 P 的完整数据。
    this.playerSourceVersion++;
  }

  openCoinSheet(): void {
    if (!this.ensureLogin()) return;
    if (this.coinCountByMe >= 2) {
      promptAction.showToast({ message: '这个视频已经投过 2 枚硬币了' });
      return;
    }
    this.coinChoice = this.coinCountByMe === 1 ? 1 : 2;
    this.coinSheetOpen = true;
  }

  async submitCoin(): Promise<void> {
    if (this.actionBusy) return;
    const available: number = Math.max(0, 2 - this.coinCountByMe);
    const multiply: number = Math.min(this.coinChoice, available);
    if (multiply <= 0) {
      this.coinSheetOpen = false;
      return;
    }
    this.actionBusy = true;
    const result: ActionResult = await BiliApi.coinVideo(this.detail.aid, this.detail.bvid, multiply, this.coinWithLike);
    this.actionBusy = false;
    if (!result.ok) {
      promptAction.showToast({ message: result.message });
      return;
    }
    this.coinCountByMe += multiply;
    this.coinCount += multiply;
    if (this.coinWithLike && !this.liked) {
      this.liked = true;
      this.likeCount++;
    }
    this.coinSheetOpen = false;
    promptAction.showToast({ message: '投币成功' });
  }

  actionShare(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      promptAction.showToast({ message: '无法打开系统分享' });
      return;
    }
    const url: string = 'https://www.bilibili.com/video/' + this.detail.bvid;
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: 'general.hyperlink',
      title: this.detail.title,
      content: url,
      description: this.detail.desc,
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL }).catch((error: Error) => {
      promptAction.showToast({ message: '分享失败：' + error.message });
    });
    if (UserStore.isLogin) {
      BiliApi.reportShare(this.detail.aid, this.detail.bvid);
    }
  }

  async loadReplies(reset: boolean): Promise<void> {
    if (this.replyLoading) {
      return;
    }
    this.replyLoading = true;
    if (reset) this.replyPrefetchCount = 0;
    const cursor: string = reset ? '' : this.replyCursor;
    const data = await BiliApi.getReplies(this.detail.aid, 1, cursor, this.replySortMode);
    this.replies = reset ? data.replies : this.mergeUniqueReplies(this.replies, data.replies);
    this.replyCursor = data.cursor;
    this.replyHasMore = data.hasMore;
    this.replyLoading = false;
    // 某些视频首页只返回置顶/精选的少量评论，自动继续取页直到首屏够用。
    if (this.replyHasMore && this.replies.length < 20 && this.replyPrefetchCount < 5) {
      this.replyPrefetchCount++;
      await this.loadReplies(false);
    }
  }

  changeReplySort(mode: number): void {
    if (this.replySortMode === mode || this.replyLoading) {
      return;
    }
    this.replySortMode = mode;
    this.replyCursor = '';
    this.replyHasMore = true;
    this.replies = [];
    this.replyListSavedOffset = -1;
    this.replyThreadOpen = false;
    this.loadReplies(true);
  }

  mergeUniqueReplies(base: Array<ReplyItem>, incoming: Array<ReplyItem>): Array<ReplyItem> {
    const ids: Set<number> = new Set<number>();
    const result: Array<ReplyItem> = [];
    for (let i: number = 0; i < base.length; i++) {
      ids.add(base[i].rpid);
      result.push(base[i]);
    }
    for (let i: number = 0; i < incoming.length; i++) {
      if (!ids.has(incoming[i].rpid)) {
        ids.add(incoming[i].rpid);
        result.push(incoming[i]);
      }
    }
    return result;
  }

  async openReplyThread(item: ReplyItem): Promise<void> {
    try {
      this.replyListSavedOffset = Math.max(0, this.replyScroller.currentOffset().yOffset);
    } catch (e) {
      this.replyListSavedOffset = 0;
    }
    this.replyThreadRoot = item;
    this.replyThreadOpen = true;
    this.threadReplies = item.replies;
    this.threadPage = 0;
    this.threadHasMore = true;
    this.threadPrefetchCount = 0;
    this.replyTargetRpid = item.rpid;
    this.replyTargetName = item.uname;
    // Scroller 会保留上一次回复详情的位置；新线程必须从原评论开始显示。
    setTimeout(() => {
      this.threadScroller.scrollToIndex(0, false, ScrollAlign.START);
    }, 0);
    await this.loadThreadReplies(true);
    setTimeout(() => {
      this.threadScroller.scrollToIndex(0, false, ScrollAlign.START);
    }, 0);
  }

  async loadThreadReplies(reset: boolean): Promise<void> {
    if (this.threadLoading || (!reset && !this.threadHasMore)) {
      return;
    }
    this.threadLoading = true;
    const page: number = reset ? 1 : this.threadPage + 1;
    const data = await BiliApi.getReplyReplies(this.detail.aid, 1, this.replyThreadRoot.rpid, page);
    this.threadReplies = reset ? this.mergeUniqueReplies([], data.replies) : this.mergeUniqueReplies(this.threadReplies, data.replies);
    this.threadPage = page;
    this.threadHasMore = data.hasMore;
    this.threadLoading = false;
    const target: number = Math.min(20, Math.max(1, this.replyThreadRoot.count));
    if (this.threadHasMore && this.threadReplies.length < target && this.threadPrefetchCount < 5) {
      this.threadPrefetchCount++;
      await this.loadThreadReplies(false);
    }
  }

  async sendReply(): Promise<void> {
    const content: string = this.replyDraft.trim();
    if (content.length === 0 || this.replySending || !this.ensureLogin()) return;
    this.replySending = true;
    const root: number = this.replyThreadOpen ? this.replyThreadRoot.rpid : 0;
    const parent: number = this.replyThreadOpen ?
      (this.replyTargetRpid > 0 ? this.replyTargetRpid : root) : 0;
    const result: ActionResult = await BiliApi.addReply(this.detail.aid, 1, content, root, parent);
    this.replySending = false;
    if (!result.ok) {
      promptAction.showToast({ message: result.message });
      return;
    }
    this.replyDraft = '';
    promptAction.showToast({ message: this.replyThreadOpen ? '回复成功' : '评论成功' });
    if (this.replyThreadOpen) {
      this.replyTargetRpid = this.replyThreadRoot.rpid;
      this.replyTargetName = this.replyThreadRoot.uname;
      this.threadReplies = [];
      this.threadPage = 0;
      this.threadHasMore = true;
      await this.loadThreadReplies(true);
    } else {
      this.replyCursor = '';
      this.replyHasMore = true;
      await this.loadReplies(true);
    }
  }

  async sendVideoDanmaku(): Promise<void> {
    const message: string = this.danmakuDraft.trim();
    if (message.length === 0 || this.danmakuSending || !this.ensureLogin()) return;
    this.danmakuSending = true;
    const result: ActionResult = await BiliApi.sendDanmaku(this.detail.aid, this.detail.bvid,
      this.currentCid, this.videoProgressSeconds, message);
    this.danmakuSending = false;
    if (!result.ok) {
      promptAction.showToast({ message: result.message });
      return;
    }
    this.danmakuDraft = '';
    this.localDanmakuText = message;
    this.localDanmakuToken++;
    if (!this.danmakuOn) this.danmakuOn = true;
    promptAction.showToast({ message: '弹幕发送成功' });
  }

  @Builder
  BackButton() {
    Row() {
      Text('‹')
        .fontSize(26)
        .fontColor('#FFFFFF')
        .translate({ y: -1 })
    }
    .width(34)
    .height(34)
    .borderRadius(17)
    .backgroundColor(this.glassOn ? '#66000000' : '#B3000000')
    .backdropBlur(this.glassOn ? 10 : 0)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.replyThreadOpen) {
        this.closeReplyThread();
      } else {
        PlayerCommandBus.stop();
        AppNavStack.pop();
      }
    })
  }

  // 互动操作项：官方图标 + 下方数值（分享/不喜欢显示文字），点击弹性动效
  @Builder
  ActionItem(icon: Resource, value: string, active: boolean, onTap: () => void) {
    ActionItemView({ icon: icon, value: value, active: active, busy: this.actionBusy, onTap: onTap })
  }

  @Builder
  IntroTab() {
    Scroll(this.introScroller) {
      Column({ space: 12 }) {
        // 标题
        Text(this.detail.title)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .width('100%')
          .lineHeight(24)
        // 数据行：播放 / 弹幕 / 发布日期 · 分区
        Row() {
          Image($r('app.media.ic_play'))
            .width(14)
            .height(14)
            .fillColor('#9499A0')
          Text(formatCount(this.detail.view))
            .fontSize(12)
            .fontColor('#9499A0')
            .margin({ left: 4 })
          Image($r('app.media.ic_danmaku_on'))
            .width(14)
            .height(14)
            .fillColor('#9499A0')
            .margin({ left: 10 })
          Text(formatCount(this.detail.danmaku))
            .fontSize(12)
            .fontColor('#9499A0')
            .margin({ left: 4 })
          Text(formatDate(this.detail.pubdate) + ' · ' + this.detail.tname)
            .fontSize(12)
            .fontColor('#9499A0')
            .margin({ left: 10 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 操作行：B 站风格素材 + 真实点赞/投币/分享状态。
        Row() {
          this.ActionItem($r('app.media.bilix_icon_like'), formatCount(this.likeCount), this.liked, () => {
            this.actionLike();
          })
          this.ActionItem($r('app.media.bilix_icon_coin'), formatCount(this.coinCount), this.coinCountByMe > 0, () => {
            this.openCoinSheet();
          })
          this.ActionItem($r('app.media.bilix_icon_fav'), formatCount(this.favoriteCount), this.favorited, () => {
            this.actionFavorite();
          })
          this.ActionItem($r('app.media.bilix_icon_share'), formatCount(this.detail.share), false, () => {
            this.actionShare();
          })
        }
        .width('100%')
        .border({ width: { top: 0.5, bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })

        // UP 主
        Row({ space: 10 }) {
          Row({ space: 10 }) {
            Stack({ alignContent: Alignment.Center }) {
              Circle()
                .width(42)
                .height(42)
                .fill(this.accent)
              Image(this.detail.upFace)
                .width(42)
                .height(42)
                .borderRadius(21)
                .objectFit(ImageFit.Cover)
                .clip(true)
            }
            .width(42)
            .height(42)
            Column({ space: 3 }) {
              Text(this.detail.upName)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
              Text(this.detail.upSign.length > 0 ? this.detail.upSign : 'UP主很神秘')
                .fontSize(11)
                .fontColor('#9499A0')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .layoutWeight(1)
          .onClick(() => {
            if (this.detail.upMid > 0) {
              PlayerCommandBus.stop();
              const param: UserSpaceParam = { mid: this.detail.upMid };
              AppNavStack.pushPathByName(NAV_USER_SPACE, param);
            }
          })
          Text(this.followLoading ? '处理中…' : (this.following ? '已关注' : '+ 关注'))
            .fontSize(13)
            .fontColor(this.following ? (this.isDark ? '#D0D0D4' : '#61666D') : '#FFFFFF')
            .backgroundColor(this.following ? (this.isDark ? '#333438' : '#EEF0F2') : this.accent)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(15)
            .enabled(!this.followLoading)
            .onClick(() => {
              this.actionFollow();
            })
        }
        .width('100%')

        // 简介
        Column({ space: 8 }) {
          Row() {
            Text('简介')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          }
          .width('100%')
          Text(this.detail.desc.length > 0 ? this.detail.desc : 'UP主没有填写简介')
            .fontSize(13)
            .fontColor(this.isDark ? '#B0B0B0' : '#5A5F66')
            .width('100%')
            .lineHeight(20)
            .maxLines(this.descExpanded ? 10000 : 8)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.detail.desc.length > 0) {
            Row() {
              Blank()
              Text(this.descExpanded ? '收起' : '展开全文')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.accent)
                .padding({ left: 8, right: 2, top: 4, bottom: 4 })
            }
            .width('100%')
            .onClick(() => {
              animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                this.descExpanded = !this.descExpanded;
              });
            })
          }
          // 分P
          if (this.detail.pages.length > 1) {
            Column() {
              ForEach(this.detail.pages, (page: VideoPage, index: number) => {
                Row() {
                  Text('P' + page.page + ' ' + page.part)
                    .fontSize(13)
                    .fontColor(this.isDark ? '#D0D0D0' : '#222222')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(page.cid === this.pageSwitchingCid ? '切换中…' : (page.cid === this.currentCid ? '播放中' : ''))
                    .fontSize(11)
                    .fontColor(this.accent)
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .backgroundColor(page.cid === this.currentCid ? colorWithAlpha(this.accent, '14') : '#00000000')
                .borderRadius(6)
                .onClick(() => {
                  this.switchVideoPage(page, index);
                })
              }, (page: VideoPage) => String(page.cid))
            }
            .width('100%')
            .padding({ left: 10, right: 10 })
            .borderRadius(8)
            .backgroundColor(this.isDark ? '#2A2C31' : '#F6F7F8')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 相关推荐跟随简介向下滚动，不再占用独立标签页。
        Column({ space: 4 }) {
          Text('相关推荐')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            .width('100%')
            .padding({ top: 6, bottom: 4 })
          if (this.related.length === 0) {
            Text('相关推荐加载中…')
              .fontSize(12)
              .fontColor('#9499A0')
              .width('100%')
              .padding({ top: 12, bottom: 12 })
          } else {
            ForEach(this.related, (item: VideoItem) => {
              this.RelatedRow(item)
            }, (item: VideoItem) => item.bvid + String(item.aid))
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(14)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .onScrollStart(() => {
      this.contentGestureActive = true;
    })
    .onScrollStop(() => {
      this.contentGestureActive = false;
    })
    .onScrollFrameBegin((offset: number, state: ScrollState) => {
      return { offsetRemain: this.onContentScrollFrame(offset, this.introScroller, state) };
    })
  }

  @Builder
  ReplyActionBar(item: ReplyItem) {
    Row({ space: 18 }) {
      Row({ space: 4 }) {
        Image($r('app.media.ic_like'))
          .width(17)
          .height(17)
          .fillColor('#9499A0')
        Text(item.like > 0 ? String(item.like) : '')
          .fontSize(11)
          .fontColor('#9499A0')
      }
      Image($r('app.media.ic_dislike'))
        .width(17)
        .height(17)
        .fillColor('#9499A0')
      Image($r('app.media.ic_share'))
        .width(17)
        .height(17)
        .fillColor('#9499A0')
      Image($r('app.media.ic_comment'))
        .width(17)
        .height(17)
        .fillColor('#9499A0')
      Blank()
      Image($r('app.media.ic_more'))
        .width(17)
        .height(17)
        .fillColor('#9499A0')
    }
    .width('100%')
    .height(30)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ReplyPreview(item: ReplyItem) {
    Column({ space: 5 }) {
      ForEach(item.replies.slice(0, 2), (reply: ReplyItem) => {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text(reply.uname + '：')
            .fontSize(12)
            .fontColor('#008AC5')
          ForEach(parseReplyContent(reply), (part: ReplyRenderPart) => {
            if (part.image.length > 0) {
              Image(part.image)
                .width(part.imageSize > 1 ? 32 : 20)
                .height(part.imageSize > 1 ? 32 : 20)
                .objectFit(ImageFit.Contain)
                .margin({ right: 2 })
            } else {
              Text(part.text)
                .fontSize(12)
                .lineHeight(18)
                .fontColor(part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ?
                  '#008AC5' : (this.isDark ? '#E6E6E6' : '#18191C'))
                .onClick(() => {
                  this.onReplyPartClick(part);
                })
            }
          }, (part: ReplyRenderPart) => part.key)
        }
        .width('100%')
      }, (reply: ReplyItem) => String(reply.rpid))
      Text('共 ' + item.count + ' 条回复  ›')
        .fontSize(12)
        .fontColor('#008AC5')
        .padding({ top: 2, bottom: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(4)
    .backgroundColor(this.isDark ? '#26272B' : '#F5F7F9')
  }

  @Builder
  ReplyItemRow(item: ReplyItem, showPreview: boolean) {
    Row({ space: 10 }) {
      DecoratedAvatar({
        face: item.avatar,
        pendant: item.pendant,
        avatarSize: 38,
        containerSize: 50,
      })
      .priorityGesture(
        TapGesture().onAction(() => {
          if (item.mid > 0) {
            PlayerCommandBus.stop();
            const param: UserSpaceParam = { mid: item.mid };
            AppNavStack.pushPathByName(NAV_USER_SPACE, param);
          }
        })
      )
      Column({ space: 5 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (item.cardBackground.length > 0) {
            UserDecorationBanner({
              imageUrl: item.cardBackground,
              numberText: item.cardNumber,
              numberColor: item.cardNumberColor.length > 0 ? item.cardNumberColor : '#FFFFFF',
              bannerHeight: 46,
            })
          }
          Row({ space: 6 }) {
            Text(item.uname)
              .fontSize(13)
              .fontColor(item.nameColor.length > 0 ? item.nameColor : (this.isDark ? '#D0D0D0' : '#61666D'))
              .maxLines(1)
            if (item.level > 0) {
              Text('LV' + item.level)
                .fontSize(9)
                .fontColor(this.accent)
                .border({ width: 0.5, color: this.accent, radius: 2 })
                .padding({ left: 2, right: 2 })
            }
            if (item.nameplate.length > 0) {
              Image(item.nameplate)
                .width(38)
                .height(16)
                .objectFit(ImageFit.Contain)
            }
          }
          .height(item.cardBackground.length > 0 ? 46 : 18)
          .padding({ left: item.cardBackground.length > 0 ? 8 : 0,
            right: item.cardBackground.length > 0 ? 78 : 0 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height(item.cardBackground.length > 0 ? 46 : 18)
        Text(formatRelativeTime(item.ctime) + (item.location.length > 0 ? '  ' + item.location : ''))
          .fontSize(10)
          .fontColor('#9499A0')
        if (this.replyThreadOpen && item.parentRpid > 0 &&
          item.parentRpid !== this.replyThreadRoot.rpid) {
          Text('回复 @' + this.threadParentName(item))
            .fontSize(11)
            .fontColor('#008AC5')
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor(this.isDark ? '#26343C' : '#EAF5FA')
        }
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(parseReplyContent(item), (part: ReplyRenderPart) => {
            if (part.image.length > 0) {
              Image(part.image)
                .width(part.imageSize > 1 ? 48 : 24)
                .height(part.imageSize > 1 ? 48 : 24)
                .objectFit(ImageFit.Contain)
                .margin({ right: 2 })
            } else {
              Text(part.text)
                .fontSize(15)
                .fontColor(part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ?
                  '#008AC5' : (this.isDark ? '#F0F0F0' : '#18191C'))
                .lineHeight(22)
                .onClick(() => {
                  this.onReplyPartClick(part);
                })
            }
          }, (part: ReplyRenderPart) => part.key)
        }
        .width('100%')
        if (item.pictures.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(item.pictures, (picture: string, index: number) => {
              Image(picture)
                .width(item.pictures.length === 1 ? 190 : 92)
                .height(item.pictures.length === 1 ? 150 : 92)
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .margin({ right: 5, bottom: 5 })
                .onClick(() => {
                  const viewer: ImageViewerParam = { images: item.pictures, initialIndex: index };
                  AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer);
                })
            }, (picture: string, index: number) => picture + String(index))
          }
          .width('100%')
        }
        this.ReplyActionBar(item)
        if (showPreview && item.count > 0) {
          this.ReplyPreview(item)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
    .onClick(() => {
      // 评论正文、头像旁空白处也能进入回复页，不再只能命中一小段“共 N 条回复”文字。
      if (showPreview && item.count > 0) this.openReplyThread(item);
      else if (this.replyThreadOpen) {
        this.replyTargetRpid = item.rpid;
        this.replyTargetName = item.uname;
      }
    })
  }

  threadParentName(item: ReplyItem): string {
    if (item.parentRpid === this.replyThreadRoot.rpid) return this.replyThreadRoot.uname;
    for (let i: number = 0; i < this.threadReplies.length; i++) {
      if (this.threadReplies[i].rpid === item.parentRpid) return this.threadReplies[i].uname;
    }
    return '上一条回复';
  }

  @Builder
  ReplySortBar() {
    Row({ space: 8 }) {
      Text('评论 ' + formatCount(this.detail.reply))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
      Text('按热度')
        .fontSize(12)
        .fontWeight(this.replySortMode === 3 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.replySortMode === 3 ? this.accent : '#9499A0')
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
        .onClick(() => {
          this.changeReplySort(3);
        })
      Text('/')
        .fontSize(11)
        .fontColor('#C5C8CE')
      Text('按时间')
        .fontSize(12)
        .fontWeight(this.replySortMode === 2 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.replySortMode === 2 ? this.accent : '#9499A0')
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
        .onClick(() => {
          this.changeReplySort(2);
        })
    }
    .width('100%')
    .height(42)
    .padding({ left: 14, right: 14 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  @Builder
  ReplyInputBar() {
    Row({ space: 10 }) {
      TextInput({
        placeholder: this.replyThreadOpen ? '回复 ' +
          (this.replyTargetName.length > 0 ? this.replyTargetName : this.replyThreadRoot.uname) : '发一条友善的评论',
        text: this.replyDraft,
      })
        .height(38)
        .fontSize(13)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .placeholderColor('#B8BCC3')
        .layoutWeight(1)
        .padding({ left: 14, right: 14 })
        .borderRadius(18)
        .backgroundColor(this.isDark ? '#292A2E' : '#F5F7F9')
        .onChange((value: string) => {
          this.replyDraft = value;
        })
        .onSubmit(() => {
          this.sendReply();
        })
      Text('☺')
        .fontSize(24)
        .fontColor(this.emotePanelOpen ? this.accent : '#9499A0')
        .width(32)
        .height(36)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.openEmotePanel();
        })
      Button(this.replySending ? '发送中' : '发送')
        .height(36)
        .fontSize(13)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accent)
        .borderRadius(18)
        .enabled(!this.replySending && this.replyDraft.trim().length > 0)
        .onClick(() => {
          this.sendReply();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  @Builder
  EmotePanel() {
    Column() {
      if (this.emoteLoading) {
        Row() {
          LoadingProgress().width(24).height(24).color(this.accent)
        }
        .width('100%').height(120).justifyContent(FlexAlign.Center)
      } else if (this.emotePackages.length === 0) {
        Text('暂无可用表情包')
          .fontSize(13).fontColor('#9499A0').width('100%').height(90).textAlign(TextAlign.Center)
      } else {
        Grid() {
          ForEach(this.emotePackages[this.emotePackageIndex].emotes, (item: BiliEmote) => {
            GridItem() {
              Column({ space: 2 }) {
                Image(item.url)
                  .width(item.size > 1 ? 46 : 34)
                  .height(item.size > 1 ? 46 : 34)
                  .objectFit(ImageFit.Contain)
                Text(item.text.replace('[', '').replace(']', ''))
                  .fontSize(8)
                  .fontColor('#9499A0')
                  .maxLines(1)
              }
              .width('100%').height('100%').justifyContent(FlexAlign.Center)
              .onClick(() => this.insertEmote(item))
            }
          }, (item: BiliEmote) => item.text + item.url)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
        .rowsGap(4)
        .height(158)
        .padding({ left: 8, right: 8 })
        .scrollBar(BarState.Off)
        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.emotePackages, (pkg: BiliEmotePackage, index: number) => {
              Row() {
                if (pkg.icon.length > 0) {
                  Image(pkg.icon).width(24).height(24).objectFit(ImageFit.Contain)
                } else {
                  Text(pkg.title).fontSize(11).fontColor(index === this.emotePackageIndex ? this.accent : '#9499A0')
                }
              }
              .height(34)
              .padding({ left: 8, right: 8 })
              .borderRadius(8)
              .backgroundColor(index === this.emotePackageIndex ? colorWithAlpha(this.accent, '18') : '#00000000')
              .onClick(() => this.emotePackageIndex = index)
            }, (pkg: BiliEmotePackage, index: number) => pkg.title + String(index))
          }
          .padding({ left: 8, right: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(38)
      }
    }
    .width('100%')
    .height(196)
    .backgroundColor(this.isDark ? '#232428' : '#FAFAFB')
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#E7E9EC' })
  }

  @Builder
  ReplyThreadView() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(25)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text('回复 ' + this.replyThreadRoot.count)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      .width('100%')
      .height(42)
      .padding({ left: 12, right: 12 })
      .onClick(() => {
        this.closeReplyThread();
      })
      List({ scroller: this.threadScroller }) {
        ListItem() {
          this.ReplyItemRow(this.replyThreadRoot, false)
        }
        ListItem() {
          Column() {
            Divider()
              .strokeWidth(0.5)
              .color(this.isDark ? '#3A3B40' : '#E3E5E7')
            Row({ space: 5 }) {
              Text('相关回复')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
              Text('共 ' + formatCount(this.replyThreadRoot.count) + ' 条')
                .fontSize(11)
                .fontColor('#9499A0')
            }
            .width('100%')
            .height(42)
          }
          .width('100%')
        }
        ForEach(this.threadReplies, (item: ReplyItem) => {
          ListItem() {
            this.ReplyItemRow(item, false)
          }
        }, (item: ReplyItem) => String(item.rpid))
        ListItem() {
          Row() {
            if (this.threadLoading) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(this.accent)
            } else if (this.threadHasMore) {
              Text('继续加载更多回复')
                .fontSize(12)
                .fontColor(this.accent)
            } else {
              Text('—— 回复到底啦 ——')
                .fontSize(12)
                .fontColor('#9499A0')
            }
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 12, bottom: 16 })
          .onClick(() => {
            if (this.threadHasMore && !this.threadLoading) this.loadThreadReplies(false);
          })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.Off)
      .onScrollStart(() => {
        this.contentGestureActive = true;
      })
      .onScrollStop(() => {
        this.contentGestureActive = false;
      })
      .onReachEnd(() => {
        this.loadThreadReplies(false);
      })
      .onScrollFrameBegin((offset: number, state: ScrollState) => {
        return { offsetRemain: this.onContentScrollFrame(offset, this.threadScroller, state) };
      })
      if (this.emotePanelOpen) this.EmotePanel()
      this.ReplyInputBar()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ReplyTab() {
    if (this.replyThreadOpen) {
      this.ReplyThreadView()
    } else {
      Column() {
        this.ReplySortBar()
        if (this.replies.length === 0) {
          LoadingView({
            loading: this.replyLoading,
            empty: !this.replyLoading,
            emptyText: '还没有评论，快来抢沙发～',
            onRetry: () => {
              this.loadReplies(true);
            },
          })
        } else {
          List({ scroller: this.replyScroller }) {
            ForEach(this.replies, (item: ReplyItem) => {
              ListItem() {
                this.ReplyItemRow(item, true)
              }
            }, (item: ReplyItem) => String(item.rpid))
            ListItem() {
              Row() {
                if (this.replyLoading) {
                  LoadingProgress()
                    .width(22)
                    .height(22)
                    .color(this.accent)
                } else if (!this.replyHasMore) {
                  Text('—— 评论到底啦 ——')
                    .fontSize(12)
                    .fontColor('#9499A0')
                } else {
                  Text('继续加载更多评论')
                    .fontSize(12)
                    .fontColor(this.accent)
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 12, bottom: 16 })
              .onClick(() => {
                if (this.replyHasMore && !this.replyLoading) this.loadReplies(false);
              })
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 12, right: 12 })
          .scrollBar(BarState.Off)
          .onScrollStart(() => {
            this.contentGestureActive = true;
          })
          .onScrollStop(() => {
            this.contentGestureActive = false;
          })
          .onScrollFrameBegin((offset: number, state: ScrollState) => {
            return { offsetRemain: this.onContentScrollFrame(offset, this.replyScroller, state) };
          })
          .onReachEnd(() => {
            if (this.replyHasMore) {
              this.loadReplies(false);
            }
          })
        }
        if (this.emotePanelOpen) this.EmotePanel()
        this.ReplyInputBar()
      }
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  RelatedRow(item: VideoItem) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(item.cover)
          .width(120)
          .height(68)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
        Text(formatDuration(item.duration))
          .fontSize(10)
          .fontColor('#FFFFFF')
          .backgroundColor('#88000000')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(3)
          .margin({ right: 4, bottom: 4 })
      }
      .width(120)
      .clip(true)
      Column({ space: 5 }) {
        Text(item.title)
          .fontSize(13)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(17)
        Row({ space: 8 }) {
          Text(item.upName)
            .fontSize(11)
            .fontColor('#9499A0')
            .maxLines(1)
            .layoutWeight(1)
          Row({ space: 3 }) {
            Image($r('app.media.ic_play'))
              .width(12).height(12).fillColor('#9499A0')
            Text(item.playText)
              .fontSize(10).fontColor('#9499A0')
          }
          Row({ space: 3 }) {
            Image($r('app.media.ic_comment'))
              .width(12).height(12).fillColor('#9499A0')
            Text(formatCount(item.reply))
              .fontSize(10).fontColor('#9499A0')
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
      AppNavStack.replacePathByName(NAV_VIDEO_DETAIL, param);
    })
  }

  @Builder
  RelatedTab() {
    Column() {
      Row() {
        Text('相关推荐')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 6 })

      if (this.related.length === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: '暂无相关视频',
          onRetry: () => {
            this.init();
          },
        })
      } else {
        List() {
          ForEach(this.related, (item: VideoItem) => {
            ListItem() {
              this.RelatedRow(item)
            }
          }, (item: VideoItem) => item.bvid + String(item.aid))
        }
        .width('100%')
        .height('100%')
        .padding({ left: 14, right: 14 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  // 自定义 tabBar：选中加粗 + 主题色 + 底部主题色短下划线
  @Builder
  DetailTabBar(label: string, index: number) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? this.accent : '#9499A0')
      Row()
        .width(22)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.tab === index ? this.accent : '#00000000')
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      // 由 TabsController 驱动，保留系统内容切换动画；直接写 index 会瞬切。
      this.tabsController.changeIndex(index);
      if (index === 0) this.replyThreadOpen = false;
    })
  }

  @Builder
  CompactDetailTab(label: string, index: number) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.visualTab === index ? this.accent : '#9499A0')
        .animation({ duration: 220, curve: Curve.EaseOut })
      Row()
        .width(18).height(2).borderRadius(1)
        .backgroundColor(this.accent)
        .opacity(this.visualTab === index ? 1 : 0)
        .scale({ x: this.visualTab === index ? 1 : 0.35, y: 1 })
        .animation({ duration: 220, curve: Curve.EaseOut })
    }
    .height(38)
    .padding({ left: 9, right: 9 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.tabsController.changeIndex(index);
      if (index === 0) this.replyThreadOpen = false;
    })
  }

  @Builder
  DetailToolbar() {
    Row({ space: 5 }) {
      this.CompactDetailTab('简介', 0)
      this.CompactDetailTab('评论 ' + formatCount(this.detail.reply), 1)
      Blank()
      Stack({ alignContent: Alignment.Center }) {
        Image(this.danmakuOn ? $r('app.media.ic_danmaku_on') : $r('app.media.ic_danmaku_off'))
          .width(20).height(20)
          .fillColor(this.danmakuOn ? this.accent : '#9499A0')
      }
      .width(32).height(32).borderRadius(16)
      .backgroundColor(this.isDark ? '#292B30' : '#F0F1F3')
      .onClick(() => this.danmakuOn = !this.danmakuOn)
      TextInput({ text: this.danmakuDraft, placeholder: '发弹幕' })
        .width(105).height(32)
        .fontSize(12)
        .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
        .placeholderColor('#9499A0')
        .backgroundColor(this.isDark ? '#292B30' : '#F0F1F3')
        .borderRadius(16)
        .padding({ left: 11, right: 8 })
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => {
          this.danmakuDraft = value;
        })
        .onSubmit(() => this.sendVideoDanmaku())
      Text(this.danmakuSending ? '发送中' : '发送')
        .fontSize(11)
        .fontColor(this.danmakuDraft.trim().length > 0 ? this.accent : '#9499A0')
        .onClick(() => this.sendVideoDanmaku())
    }
    .width('100%').height(42)
    .padding({ left: 6, right: 10 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }

  // 简介 / 评论：相关视频已并入简介底部。
  @Builder
  DetailTabs() {
    Tabs({ barPosition: BarPosition.Start, index: this.tab, controller: this.tabsController }) {
      TabContent() {
        this.IntroTab()
      }
      .tabBar('')
      TabContent() {
        this.ReplyTab()
      }
      .tabBar('')
    }
    .width('100%')
    .layoutWeight(1)
    .barHeight(0)
    .barMode(BarMode.Fixed)
    .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
    .animationMode(AnimationMode.CONTENT_FIRST)
    .animationDuration(320)
    .animationCurve(Curve.EaseInOut)
    .onAnimationStart((index: number, targetIndex: number, extraInfo: TabsAnimationEvent) => {
      // 只更新标签视觉状态；不能在这里改 Tabs 绑定 index，否则会中途强制跳页。
      this.visualTab = targetIndex;
      if (targetIndex === 0) this.replyThreadOpen = false;
    })
    .onChange((index: number) => {
      this.tab = index;
      this.visualTab = index;
      if (index === 0) this.replyThreadOpen = false;
    })
    .divider({ strokeWidth: 0 })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .clip(true)
  }

  @Builder
  CompactPlayerBar() {
    Row({ space: 8 }) {
      Blank()
      Image($r('app.media.bilix_logo_tv'))
        .width(26)
        .height(26)
        .fillColor('#FFFFFF')
      Text('立即播放')
        .fontSize(17)
        .fontColor('#FFFFFF')
      Blank()
      Image($r('app.media.ic_more'))
        .width(22)
        .height(22)
        .fillColor('#FFFFFF')
        .margin({ right: 16 })
    }
    .width('100%')
    .height(64)
    .backgroundColor('#0B0B0D')
    .onClick(() => {
      this.replyThreadOpen = false;
      this.tab = 0;
    })
  }

  @Builder
  CoinSheet() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          if (!this.actionBusy) this.coinSheetOpen = false;
        })
      Column({ space: 12 }) {
        Row() {
          Text('给 UP 主投硬币')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Blank()
          Image($r('app.media.ic_close'))
            .width(20)
            .height(20)
            .fillColor('#9499A0')
            .onClick(() => {
              if (!this.actionBusy) this.coinSheetOpen = false;
            })
        }
        .width('100%')
        Text('单个视频最多可投 2 枚，已投 ' + String(this.coinCountByMe) + ' 枚')
          .fontSize(12)
          .fontColor('#9499A0')
          .width('100%')
        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.bili_coin_box'))
              .width('100%')
              .height('100%')
            Image($r('app.media.bili_coin_one'))
              .width(64)
              .height(94)
              .objectFit(ImageFit.Contain)
          }
          .layoutWeight(1)
          .height(124)
          .padding(8)
          .borderRadius(14)
          .border({ width: this.coinChoice === 1 ? 2 : 0.5, color: this.coinChoice === 1 ? this.accent : '#33808080' })
          .backgroundColor(this.coinChoice === 1 ? colorWithAlpha(this.accent, '14') : '#0A808080')
          .onClick(() => {
            this.coinChoice = 1;
          })
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.bili_coin_box'))
              .width('100%')
              .height('100%')
            Image($r('app.media.bili_coin_two'))
              .width(88)
              .height(94)
              .objectFit(ImageFit.Contain)
          }
          .layoutWeight(1)
          .height(124)
          .padding(8)
          .borderRadius(14)
          .border({ width: this.coinChoice === 2 ? 2 : 0.5, color: this.coinChoice === 2 ? this.accent : '#33808080' })
          .backgroundColor(this.coinChoice === 2 ? colorWithAlpha(this.accent, '14') : '#0A808080')
          .onClick(() => {
            if (this.coinCountByMe === 0) this.coinChoice = 2;
          })
        }
        .width('100%')
        Row({ space: 8 }) {
          Checkbox({ name: 'coinLike', group: 'coin' })
            .width(20)
            .height(20)
            .select(this.coinWithLike)
            .selectedColor(this.accent)
            .onChange((checked: boolean) => {
              this.coinWithLike = checked;
            })
          Text('同时点赞视频')
            .fontSize(13)
            .fontColor(this.isDark ? '#D8D8DC' : '#5A5F66')
        }
        .width('100%')
        Button(this.actionBusy ? '投币中…' : '确认投币')
          .width('100%')
          .height(42)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .backgroundColor(this.accent)
          .borderRadius(21)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.submitCoin();
          })
      }
      .width(322)
      .padding({ left: 18, right: 18, top: 18, bottom: 18 })
      .borderRadius(20)
      .backgroundColor(this.isDark ? '#25262A' : '#FFFFFF')
      .shadow({ radius: 28, color: '#66000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 播放器始终保活。进入评论仅用黑色栏遮住并收起高度，避免切 Tab 时销毁 AVPlayer 导致暂停。
        Stack({ alignContent: Alignment.Center }) {
          if (this.playUrl.length > 0) {
            PlayerView({
              videoUrl: this.playUrl,
              videoUrls: this.playUrls,
              audioUrls: this.playAudioUrls,
              qualityOptions: this.qualityOptions,
              currentQuality: this.currentQuality,
              sourceVersion: this.playerSourceVersion,
              aid: this.detail.aid,
              bvid: this.bvid,
              cid: this.currentCid,
              videoTitle: this.detail.title,
              ownerName: this.detail.upName,
              ownerFace: this.detail.upFace,
              liked: this.liked,
              externalDanmakuOn: this.danmakuOn,
              localDanmakuText: this.localDanmakuText,
              localDanmakuToken: this.localDanmakuToken,
              compactMode: !this.playerFullscreen && this.visiblePlayerHeight() < 176,
              onFullscreenChange: (fullscreen: boolean) => {
                this.playerFullscreen = fullscreen;
              },
              onPlayingChange: (playing: boolean) => {
                this.onPlayerPlayingChange(playing);
              },
              onResumeRequest: () => {
                this.expandPlayerForResume();
              },
              onDanmakuChange: (enabled: boolean) => {
                this.danmakuOn = enabled;
              },
              onProgress: (seconds: number) => {
                this.videoProgressSeconds = seconds;
              },
              onLike: () => {
                this.actionLike();
              },
              onCoin: () => {
                this.openCoinSheet();
              },
              onShare: () => {
                this.actionShare();
              },
            })
          } else {
            Stack({ alignContent: Alignment.Center }) {
              Image(this.detail.cover)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .blur(18)
                .brightness(0.5)
              // 封面取色氛围光晕
              Column()
                .width('100%')
                .height('100%')
                .radialGradient({
                  center: ['50%', '40%'],
                  radius: '70%',
                  colors: [[colorWithAlpha(this.pageTint, '66'), 0.0], [colorWithAlpha(this.pageTint, '00'), 1.0]],
                })
              Column({ space: 8 }) {
                Image(this.detail.cover)
                  .width(140)
                  .aspectRatio(16 / 9)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(8)
                Text(this.playUrl.length === 0 && !this.loading ? '获取播放地址失败' : '加载播放地址中...')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
              }
            }
          }
        }
        .width('100%')
        .height(this.playerFullscreen ? '100%' : this.visiblePlayerHeight())
        .clip(true)
        .backgroundColor('#000000')

        // 信息区
        if (!this.playerFullscreen) {
          if (this.loading) {
            LoadingView({ loading: true })
          } else if (this.errorText.length > 0) {
            LoadingView({
              loading: false,
              empty: false,
              errorText: this.errorText,
              onRetry: () => {
                this.init();
              },
            })
          } else {
            Column() {
              this.DetailToolbar()
              this.DetailTabs()
            }
            .width('100%')
            .layoutWeight(1)
          }
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.playerFullscreen ? 0 : Immersive.statusBarHeight() })

      // 视频上方状态栏固定纯黑，避免封面倒影干扰。
      if (!this.playerFullscreen) {
        Column()
        .width('100%')
        .height(Immersive.statusBarHeight())
        .backgroundColor('#000000')
        .hitTestBehavior(HitTestMode.None)

        // 悬浮返回按钮
        Column() {
          this.BackButton()
        }
        .margin({ top: Immersive.statusBarHeight() + 8, left: 10 })
      }

      if (this.coinSheetOpen) {
        this.CoinSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}

/**
 * 互动操作项（点赞/投币/收藏等）：点击弹性缩放动效 + 主题色闪烁
 * 对齐 B 站"三连"的反馈手感（v1 无互动状态接口，仅本地动效 + toast）
 */
@Component
struct ActionItemView {
  @Prop icon: Resource = $r('app.media.bilix_icon_like');
  @Prop value: string = '';
  @Prop active: boolean = false;
  @Prop busy: boolean = false;
  onTap: () => void = () => {};
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State iconScale: number = 1;
  @State flash: boolean = false;

  build() {
    Column({ space: 4 }) {
      Image(this.icon)
        .width(22)
        .height(22)
        .fillColor((this.active || this.flash) ? this.accent : (this.isDark ? '#C8C8CC' : '#5A5F66'))
        .scale({ x: this.iconScale, y: this.iconScale })
      Text(this.value)
        .fontSize(11)
        .fontColor((this.active || this.flash) ? this.accent : (this.isDark ? '#C8C8CC' : '#5A5F66'))
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      if (this.busy) return;
      this.flash = true;
      animateTo({ curve: curves.springMotion(0.6, 0.8) }, () => {
        this.iconScale = 1.28;
      });
      setTimeout(() => {
        animateTo({ curve: curves.springMotion(0.6, 0.8) }, () => {
          this.iconScale = 1;
        });
      }, 120);
      setTimeout(() => {
        this.flash = false;
      }, 420);
      this.onTap();
    })
  }
}
