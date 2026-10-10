import { MotionTokens } from '../common/MotionTokens';
import { AppRecoveryState, RecoveryViewState } from '../common/AppRecoveryState';
/**
 * 首页视图：推荐（app 端接口）+ 热门，双列瀑布流、下拉刷新、触底加载
 */
import { HomeFeedController, HomeFeedPhase, HomeFeedSnapshot, homeFeedPhase } from '../components/home/HomeFeedController';
import { VideoItem } from '../model/Models';
import { VideoCard } from '../components/video/VideoCard';
import { VideoReportDialog } from '../components/VideoReportDialog';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { UserStore } from '../services/auth/UserStore';
import { BasicDataSource } from '../common/BasicDataSource';
import { LiveRoomItem } from '../model/LiveModels';
import { FollowedLiveStrip } from '../components/live/FollowedLiveStrip';
import { LiveRoomCard } from '../components/live/LiveRoomCard';
import { NavEntryRow } from '../components/NavEntryRow';
import { LayoutTokens } from '../common/LayoutTokens';
import { AppNavStack, NAV_RANK, NAV_ZONE, NAV_BANGUMI_INDEX, NAV_LIVE_ZONE } from '../common/AppRouter';
import { Haptic } from '../common/Haptic';
import { Handedness } from '../common/Handedness';
import { HeaderBackdrop } from '../components/GlassHeaderBar';

/** 频道保持可见，搜索收起时上移；单独订阅滚动值，避免重建信息流。 */
@Component
struct FloatingSubTabs {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  @StorageProp(Handedness.KEY_SIDE) @Watch('onHandSideChanged') handSide: string = Handedness.RIGHT;
  @State handPosition: number = 0;
  private handLayoutMounted: boolean = false;

  aboutToAppear(): void {
    this.handPosition = this.handSide === Handedness.LEFT ? 1 : 0;
    this.handLayoutMounted = true;
  }

  aboutToDisappear(): void {
    this.handLayoutMounted = false;
  }

  onHandSideChanged(): void {
    if (!this.handLayoutMounted) return;
    this.getUIContext().animateTo({ duration: MotionTokens.duration(320, this.reduceMotion), curve: Curve.EaseInOut }, () => {
      this.handPosition = this.handSide === Handedness.LEFT ? 1 : 0;
    });
  }
  @StorageProp('windowStatusBarHeight') statusBarInset: number = 0;
  @StorageProp('headerFade') fade: number = 0;
  @BuilderParam content: () => void;

  build() {
    Row() {
      this.content()
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 20 + 44 * this.fade * this.handPosition,
      right: 20 + 44 * this.fade * (1 - this.handPosition) })
    .margin({ top: this.statusBarInset + 54 * (1 - this.fade) })
  }
}

@Component
export struct HomeView {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  @StorageProp('windowStatusBarHeight') statusBarInset: number = 0;
  @State tab: number = 0; // 0 推荐 / 1 热门 / 2 直播
  @State visualTab: number = 0;
  @State refreshingChannels: Array<boolean> = [false, false, false];
  @State viewportWidth: number = 360;
  @State loadingChannels: Array<boolean> = [false, false, false];
  @State channelPhases: Array<HomeFeedPhase> = [HomeFeedPhase.LOADING, HomeFeedPhase.LOADING, HomeFeedPhase.LOADING];
  // 每频道独立的分页游标 / 错误文案 / 到底标记，互不串台
  @State recError: string = '';
  @State hotError: string = '';
  @State liveError: string = '';
  @State recHasMore: boolean = true;
  @State hotHasMore: boolean = true;
  @State liveHasMore: boolean = true;
  // BasicDataSource 本身不是响应式对象；计数负责驱动“加载态 -> LazyForEach”条件切换。
  @State recCount: number = 0;
  @State hotCount: number = 0;
  @State liveCount: number = 0;
  @State followedLiveRefresh: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVersion: number = 0;
  // 推荐源切换（Web 个性化 / App 推流）：切换即重开会话重载首页。
  @StorageProp('recommendMode') @Watch('onRecommendModeChanged') recommendMode: string = 'web';
  private tabsController: TabsController = new TabsController();
  private recScroller: Scroller = new Scroller();
  private hotScroller: Scroller = new Scroller();
  private liveScroller: Scroller = new Scroller();
  private recoveryOffsets: Array<RecoveryViewState | undefined> = [undefined, undefined, undefined];
  private recoveryActive: boolean = false;
  private feed: HomeFeedController = new HomeFeedController((snapshot: HomeFeedSnapshot): void => {
    this.recCount = snapshot.channels[0].count;
    this.hotCount = snapshot.channels[1].count;
    this.liveCount = snapshot.channels[2].count;
    this.recError = snapshot.channels[0].error;
    this.hotError = snapshot.channels[1].error;
    this.liveError = snapshot.channels[2].error;
    this.recHasMore = snapshot.channels[0].hasMore;
    this.hotHasMore = snapshot.channels[1].hasMore;
    this.liveHasMore = snapshot.channels[2].hasMore;
    this.refreshingChannels = snapshot.channels.map((state): boolean => state.refreshing);
    this.loadingChannels = snapshot.channels.map((state): boolean => state.loading);
    this.channelPhases = snapshot.channels.map((state): HomeFeedPhase => homeFeedPhase(state));
    this.followedLiveRefresh = snapshot.followedLiveRefresh;
  });
  private recSource: BasicDataSource<VideoItem> = this.feed.recommend;
  private hotSource: BasicDataSource<VideoItem> = this.feed.hot;
  private liveSource: BasicDataSource<LiveRoomItem> = this.feed.live;
  private readonly refreshTriggerOffset: number = 56;
  // 竖向行距与双列横向槽距共用（用户反馈 12 偏松，收紧到 8）。
  private readonly homeGap: number = 8;
  private videoReportDialog: CustomDialogController | null = null;

  async aboutToAppear(): Promise<void> {
    this.recoveryActive = true;
    const restored: RecoveryViewState | undefined = AppRecoveryState.takeView('home');
    if (restored?.tab !== undefined && restored.tab >= 0 && restored.tab <= 2) {
      this.tab = restored.tab;
      this.visualTab = this.tab;
    }
    for (let index: number = 0; index < 3; index++) {
      this.recoveryOffsets[index] = AppRecoveryState.takeView('home:' + String(index));
    }
    AppRecoveryState.saveView('home', { tab: this.tab });
    AppTheme.resetHeaderFade();
    await this.feed.activate(this.tab);
  }

  aboutToDisappear(): void {
    for (let index: number = 0; index < 3; index++) this.saveFeedScroll(index);
    this.recoveryActive = false;
    this.recoveryOffsets = [undefined, undefined, undefined];
    this.feed.dispose();
    this.videoReportDialog?.close();
    this.videoReportDialog = null;
  }

  async onLoginChanged(): Promise<void> {
    this.recoveryOffsets = [undefined, undefined, undefined];
    await this.feed.accountChanged(this.tab);
  }
  private async onRecommendModeChanged(): Promise<void> {
    this.recoveryOffsets[0] = undefined;
    await this.feed.recommendModeChanged();
  }

  private feedScroller(index: number): Scroller {
    return index === 0 ? this.recScroller : (index === 1 ? this.hotScroller : this.liveScroller);
  }

  private saveFeedScroll(index: number): void {
    if (!this.recoveryActive || this.recoveryOffsets[index] !== undefined) return;
    try {
      const offset: OffsetResult = this.feedScroller(index).currentOffset();
      AppRecoveryState.saveView('home:' + String(index), { scrollX: offset.xOffset, scrollY: offset.yOffset });
    } catch (e) {
      // 未加载频道的 Scroller 尚未绑定，不覆盖其恢复记录。
    }
  }

  private restoreFeedScroll(index: number): void {
    const state: RecoveryViewState | undefined = this.recoveryOffsets[index];
    if (!this.recoveryActive || state === undefined || this.channelEmpty(index)) return;
    this.recoveryOffsets[index] = undefined;
    // 只恢复到已加载列表可用范围，超出部分由原生 Scroller clamp，不循环请求分页。
    try {
      this.feedScroller(index).scrollTo({ xOffset: state.scrollX ?? 0, yOffset: state.scrollY ?? 0, animation: false });
    } catch (e) {
      // 列表已解绑时保留正常页面，不让系统恢复失败阻断首页。
    }
  }

  /** 首页推荐和热门卡片共用视频举报表单。 */
  private reportCard(item: VideoItem): void {
    if (!UserStore.isLogin) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录后再举报' });
      return;
    }
    if (item.aid <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: '当前视频不支持举报' });
      return;
    }
    this.videoReportDialog?.close();
    this.videoReportDialog = new CustomDialogController({
      builder: VideoReportDialog({ aid: item.aid, title: item.title }),
      autoCancel: false,
      customStyle: true,
    });
    this.videoReportDialog.open();
  }

  /** 本地隐藏：从当前列表移除并写入持久化「不想看」，后续 feed 分页与相关推荐不再出现该稿。 */
  private dislikeLocal(item: VideoItem, feedTab: number): void {
    if (!this.feed.hide(item, feedTab)) return;
    try {
      this.getUIContext().getPromptAction().showToast({ message: '已隐藏该视频，将不再出现在首页与相关推荐' });
    } catch (e) {
      // 弹 toast 失败忽略。
    }
  }

  async loadRecommend(reset: boolean): Promise<void> { await this.feed.load(0, reset); }
  async loadHot(reset: boolean): Promise<void> { await this.feed.load(1, reset); }
  async loadLive(reset: boolean): Promise<void> { await this.feed.load(2, reset); }

  private channelError(feedTab: number): string {
    return feedTab === 0 ? this.recError : (feedTab === 1 ? this.hotError : this.liveError);
  }

  private channelHasMore(feedTab: number): boolean {
    return feedTab === 0 ? this.recHasMore : (feedTab === 1 ? this.hotHasMore : this.liveHasMore);
  }

  private channelEmpty(feedTab: number): boolean {
    return feedTab === 0 ? this.recCount === 0 : (feedTab === 1 ? this.hotCount === 0 : this.liveCount === 0);
  }

  onRefresh(feedTab: number): void {
    this.recoveryOffsets[feedTab] = undefined;
    this.feed.load(feedTab, true);
  }
  onReachEnd(feedTab: number): void { this.feed.load(feedTab, false); }
  private retryMore(feedTab: number): void { this.feed.retry(feedTab); }

  @Builder
  SubTabItem(label: string, index: number) {
    Button({ type: ButtonType.Normal }) {
    Stack({ alignContent: Alignment.Center }) {
      Text(label)
        .fontSize(17)
        .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.visualTab === index ? this.accent :
          (this.isDark ? '#C4C6CC' : '#494D54'))
    }
    .width(60)
    .height(35)
    .borderRadius(18)
    .backgroundColor(this.visualTab === index ? (this.isDark ? '#EE34363C' : '#F2FFFFFF') : Color.Transparent)
    // BewlyBewly 同款悬浮胶囊：选中片带柔和投影，与页面底色分层
    .shadow(this.visualTab === index ? {
      radius: 10, color: this.isDark ? '#40000000' : '#1E4A5568', offsetX: 0, offsetY: 2,
    } : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .animation({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut })
    }
    .width(60).height(44).padding(0).backgroundColor(Color.Transparent).borderRadius(22)
    .accessibilityGroup(true).accessibilityText(label)
    .accessibilitySelected(this.visualTab === index)
    .onClick(() => {
      Haptic.light();
      this.switchTab(index);
    })
  }

  private switchTab(index: number): void {
    // 点击频道即时换内容：直接改 index 绑定（不产生横向滑动动画），
    // 选中胶囊自身仍有 180ms 微动效；手势滑动切页才走 Tabs 的滑动动画。
    this.visualTab = index;
    this.tab = index;
    AppRecoveryState.saveView('home', { tab: index });
    if (index === 0 && this.recSource.isEmpty()) {
      this.loadRecommend(true).catch(() => {
      });
    } else if (index === 1 && this.hotSource.isEmpty()) {
      this.loadHot(true).catch(() => {
      });
    } else if (index === 2 && this.liveSource.isEmpty()) {
      this.loadLive(true).catch(() => {
      });
    }
  }

  @Builder
  SubTabs() {
    Row({ space: 4 }) {
      this.SubTabItem('推荐', 0)
      this.SubTabItem('热门', 1)
      this.SubTabItem('直播', 2)
      Blank()
      Row({ space: 4 }) {
        Image($r('app.media.ic_categories')).width(15).height(15)
          .fillColor(this.isDark ? '#B4B6BE' : '#737985')
        Text('分区').fontSize(12).fontColor(this.isDark ? '#B4B6BE' : '#737985')
      }
      .height(40)
      .padding({ left: 8, right: 4 })
      .accessibilityText('分区频道')
      .onClick(() => {
        Haptic.light();
        AppNavStack.pushPathByName(NAV_ZONE, null);
      })
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  RefreshHeader() {
    // Refresh 内部仅保留很短的手势占位；可见提示由外层悬浮绘制，
    // 这样提示位置不再决定需要下拉多远才能触发刷新。
    Blank()
    .width('100%')
    .height(1)
  }

  @Builder
  RefreshIndicator() {
    Row({ space: 8 }) {
      if (this.refreshingChannels[this.tab]) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.accent)
        Text('正在刷新…')
          .fontSize(12)
          .fontColor(this.isDark ? '#CACACE' : '#676B72')
      }
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    // 搜索栏和推荐/热门频道栏下方显示，但不参与 Refresh 的下拉距离计算。
    .margin({ top: this.statusBarInset + 88 })
    // Done 等结束态不再显示；即使系统状态回调稍晚，请求完成后也立即消失。
    .opacity(this.refreshingChannels[this.tab] ? 1 : 0)
    .animation({ duration: MotionTokens.duration(MotionTokens.feedback, this.reduceMotion), curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  VideoFeedFooter(feedTab: number) {
    LoadMoreFooter({
      loading: this.loadingChannels[feedTab],
      hasMore: this.channelHasMore(feedTab) || this.channelError(feedTab).length > 0,
      moreText: this.channelError(feedTab),
      endText: feedTab === 0 ? '' : '—— 到底啦 ——',
      loadingText: '加载中…',
      fixedHeight: 48,
      onLoadMore: () => this.retryMore(feedTab),
    })
  }

  @Builder
  RecFooter() {
    this.VideoFeedFooter(0)
  }

  @Builder
  HotFooter() {
    this.VideoFeedFooter(1)
  }

  @Builder
  LiveFooter() {
    Column() {
      if (this.liveCount === 0) {
        this.EmptyFeed(2)
      } else {
        LoadMoreFooter({
          loading: this.loadingChannels[2],
          hasMore: this.liveHasMore || this.liveError.length > 0,
          moreText: this.liveError,
          endText: '—— 到底啦 ——',
          loadingText: '加载中…',
          fixedHeight: this.loadingChannels[2] || !this.liveHasMore || this.liveError.length > 0 ? 48 : 1,
          onLoadMore: () => this.retryMore(2),
        })
      }
    }.width('100%')
  }

  @Builder
  DiscoveryEntry(icon: Resource, label: string, destination: string, tint: string) {
    Row({ space: 6 }) {
      Image(icon).width(17).height(17).fillColor(tint)
      Text(label).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.isDark ? '#E2E4EA' : '#434955')
    }
    .layoutWeight(1)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.isDark ? '#252830' : '#FFFFFF')
    .borderRadius(12)
    .onClick(() => {
      Haptic.light();
      AppNavStack.pushPathByName(destination, null);
    })
  }

  @Builder
  VideoFeedHeader(feedTab: number) {
    Column({ space: 12 }) {
      if (feedTab === 1) {
        Row({ space: 8 }) {
          this.DiscoveryEntry($r('app.media.ic_hot'), '排行榜', NAV_RANK, '#EF8858')
          this.DiscoveryEntry($r('app.media.ic_categories'), '分区频道', NAV_ZONE, '#6B97D4')
          this.DiscoveryEntry($r('app.media.ic_categories'), '番剧索引', NAV_BANGUMI_INDEX, this.accent)
        }.width('100%')
      }
    }
    .width('100%')
    .padding({ bottom: feedTab === 1 ? 14 : 0, left: 2, right: 2 })
  }

  @Builder
  VideoFeedList(feedTab: number) {
    List({ space: this.homeGap, scroller: feedTab === 0 ? this.recScroller : this.hotScroller }) {
      // footer 挂在 ListItemGroup 上：双列 lanes 下保持整宽居中
      ListItemGroup({ header: this.VideoFeedHeader(feedTab), footer: this.VideoFeedFooter(feedTab) }) {
        LazyForEach(feedTab === 0 ? this.recSource : this.hotSource, (item: VideoItem) => {
          ListItem() {
            VideoCard({
              video: item,
              idPrefix: 'home-' + String(feedTab) + '-',
              wholeCardTransition: true,
              homeStyle: true,
              // 首页卡片底栏 ⋮ → 举报/不想看（不想看即长按同款的本地屏蔽）。
              showMore: true,
              onReport: (v: VideoItem) => this.reportCard(v),
              onHide: (v: VideoItem) => this.dislikeLocal(v, feedTab),
            })
              // 长按卡片：不感兴趣（本地屏蔽该视频，本轮会话生效；Web 无服务端反馈接口）。
              .gesture(
                LongPressGesture({ repeat: false })
                  .onAction(() => this.dislikeLocal(item, feedTab))
              )
          }
          // ListItemGroup 内的 ListItem 不参与 List.space，行距靠卡片下 margin 撑出，
          // 与双列横向槽宽（lanes gutter）保持一致。
          .margin({ bottom: this.homeGap })
          .onVisibleAreaChange([0.5], (visible: boolean, ratio: number) => {
            if (feedTab === 0 && this.tab === 0 && visible && ratio >= 0.5) this.feed.exposure.remember([item]);
          })
        }, (item: VideoItem) => (item.aid > 0 ? String(item.aid) : item.bvid) + '_' + feedTab)
      }
    }
    .width('100%')
    .height('100%')
    .lanes(LayoutTokens.feedColumns(this.viewportWidth), this.homeGap)
    .cachedCount(3)
    // 首屏卡片默认位于搜索栏下方。这个间距属于可滚动内容，滚走后不会因头栏重新出现而顶动卡片。
    .contentStartOffset(this.statusBarInset + 106)
    // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
    .contentEndOffset(Immersive.bottomInset() + 76)
    .padding({ left: (this.viewportWidth >= 600 ? 24 : 16),
      right: (this.viewportWidth >= 600 ? 24 : 16) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
    .scrollBar(BarState.Off)
    .onAreaChange(() => this.restoreFeedScroll(feedTab))
    .onScrollStop(() => this.saveFeedScroll(feedTab))
    .onDidScroll((offset: number) => {
      AppTheme.updateHeaderFade(offset);
    })
    .onReachEnd(() => {
      this.onReachEnd(feedTab);
    })
  }

  /** 直播频道顶部入口：直播分区（按分区浏览直播间）。 */
  @Builder
  LiveZoneEntry() {
    NavEntryRow({
      icon: $r('app.media.ic_live'),
      title: '直播分区',
      onTap: () => {
        AppNavStack.pushPathByName(NAV_LIVE_ZONE, null);
      },
    })
  }

  @Builder
  LiveFeedHeader() {
    Column() {
      FollowedLiveStrip({ refreshVersion: this.followedLiveRefresh })
      this.LiveZoneEntry()
    }.width('100%')
  }

  @Builder
  LiveFeedList() {
    List({ space: this.homeGap, scroller: this.liveScroller }) {
      // Group 的 footer 跨越所有 lanes；普通 ListItem 的 100% 仅覆盖一列。
      ListItemGroup({ header: this.LiveFeedHeader(), footer: this.LiveFooter() }) {
        LazyForEach(this.liveSource, (item: LiveRoomItem) => {
          ListItem() {
            LiveRoomCard({ room: item })
          }.margin({ bottom: this.homeGap })
        }, (item: LiveRoomItem) => String(item.roomId))
      }
    }
    .width('100%').height('100%').lanes(LayoutTokens.feedColumns(this.viewportWidth), this.homeGap)
    .cachedCount(3)
    .contentStartOffset(this.statusBarInset + 106)
    // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
    .contentEndOffset(Immersive.bottomInset() + 76)
    .padding({ left: (this.viewportWidth >= 600 ? 24 : 16),
      right: (this.viewportWidth >= 600 ? 24 : 16) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
    .scrollBar(BarState.Off)
    .onAreaChange(() => this.restoreFeedScroll(2))
    .onScrollStop(() => this.saveFeedScroll(2))
    .onDidScroll((offset: number) => AppTheme.updateHeaderFade(offset))
    .onReachEnd(() => this.onReachEnd(2))
  }

  @Builder
  EmptyFeed(feedTab: number) {
    Column() {
      LoadingView({ skeleton: 'grid',
        loading: this.channelPhases[feedTab] === HomeFeedPhase.LOADING,
        empty: this.channelPhases[feedTab] === HomeFeedPhase.EMPTY,
        emptyText: feedTab === 2 ? '暂时没有直播内容' : '暂时没有可展示的视频',
        errorText: this.channelError(feedTab),
        onRetry: () => this.retryMore(feedTab) })
      if (this.channelPhases[feedTab] === HomeFeedPhase.EMPTY) {
        Button(this.channelHasMore(feedTab) ? '继续加载' : '重新加载')
          .height(40).fontSize(13).fontColor(this.accent)
          .backgroundColor(this.isDark ? '#252A34' : '#EEF0F5').borderRadius(20)
          .padding({ left: 24, right: 24 })
          .onClick(() => { this.feed.retryEmpty(feedTab); })
      }
    }.width('100%')
  }

  @Builder
  FeedPage(feedTab: number) {
    if (this.channelPhases[feedTab] === HomeFeedPhase.LOADING) {
      LoadingView({ loading: true, skeleton: 'grid' })
        .height('100%')
        .padding({ top: this.statusBarInset + 98 })
    } else if (feedTab === 2) {
      Refresh({ refreshing: this.refreshingChannels[2], builder: this.RefreshHeader() }) {
        this.LiveFeedList()
      }
      .refreshOffset(this.refreshTriggerOffset)
      .onRefreshing(() => this.onRefresh(2))
    } else if (this.channelEmpty(feedTab)) {
      Column() { this.EmptyFeed(feedTab) }
        .padding({ top: this.statusBarInset + 98 })
    } else {
      Refresh({ refreshing: this.refreshingChannels[feedTab], builder: this.RefreshHeader() }) {
        this.VideoFeedList(feedTab)
      }
      .refreshOffset(this.refreshTriggerOffset)
      .pullDownRatio(undefined)
      .onRefreshing(() => this.onRefresh(feedTab))
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 三个频道常驻并预缓存，相邻页由系统 Tabs 连续滑动，不再条件销毁后瞬间换页。
      Tabs({ index: this.tab, controller: this.tabsController }) {
        TabContent() { this.FeedPage(0) }.tabBar('')
        TabContent() { this.FeedPage(1) }.tabBar('')
        TabContent() { this.FeedPage(2) }.tabBar('')
      }
      .width('100%')
      .height('100%')
      .barHeight(0)
      .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
      .animationMode(AnimationMode.CONTENT_FIRST)
      .animationDuration(MotionTokens.duration(MotionTokens.content, this.reduceMotion))
      .animationCurve(Curve.EaseOut)
      .onAnimationStart((index: number, targetIndex: number, extraInfo: TabsAnimationEvent) => {
        this.visualTab = targetIndex;
        AppTheme.resetHeaderFade();
      })
      .onChange((index: number) => {
        this.tab = index;
        this.visualTab = index;
        AppRecoveryState.saveView('home', { tab: index });
        // 滑动切换时也要触发懒加载，避免热门/直播切过去是空白，必须再点一次才能出来。
        if (index === 0 && this.recSource.isEmpty()) {
          this.loadRecommend(true).catch(() => {
          });
        } else if (index === 1 && this.hotSource.isEmpty()) {
          this.loadHot(true).catch(() => {
          });
        } else if (index === 2 && this.liveSource.isEmpty()) {
          this.loadLive(true).catch(() => {
          });
        }
      })

      HeaderBackdrop()

      this.RefreshIndicator()

      // 频道导航随搜索收起上移，在惯用手一侧给常驻头像保留空间。
      // fade 订阅收敛在 FloatingSubTabs 内，滚动不触发 HomeView 本体重建。
      FloatingSubTabs() {
        this.SubTabs()
      }
    }
    .width('100%')
    .layoutWeight(1)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (!Number.isNaN(width) && width > 0) this.viewportWidth = width;
    })
  }
}
