/**
 * 首页视图：推荐（app 端接口）+ 热门，双列瀑布流、下拉刷新、触底加载
 */
import { VideoItem } from '../model/Models';
import { BiliApi } from '../api/BiliApi';
import { VideoCard } from '../components/VideoCard';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { UserStore } from '../common/UserStore';
import { BasicDataSource } from '../common/BasicDataSource';
import { LiveRoomItem } from '../model/LiveModels';
import { LiveRoomCard } from '../components/LiveRoomCard';
import { NavEntryRow } from '../components/NavEntryRow';
import { LayoutTokens } from '../common/LayoutTokens';
import { AppNavStack, NAV_RANK, NAV_ZONE, NAV_BANGUMI_INDEX, NAV_LIVE_ZONE } from '../common/AppRouter';
import { FeedApi } from '../api/FeedApi';
import { LiveApi } from '../api/LiveApi';
import { Haptic } from '../common/Haptic';

/** 悬浮频道切换条：单独订阅 headerFade，滚动逐帧淡出时不再带动整个 HomeView 重建。 */
@Component
struct FloatingSubTabs {
  @StorageProp('headerFade') fade: number = 0;
  @BuilderParam content: () => void;

  build() {
    Row() {
      this.content()
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 10, right: 10 })
    .margin({ top: Immersive.statusBarHeight() + 50 })
    .opacity(1 - this.fade)
    .translate({ y: -12 * this.fade })
    .animation({ duration: 160, curve: Curve.EaseOut })
    .hitTestBehavior(this.fade > 0.9 ? HitTestMode.None : HitTestMode.Default)
  }
}

@Component
export struct HomeView {
  @State tab: number = 0; // 0 推荐 / 1 热门 / 2 直播
  @State visualTab: number = 0;
  @State refreshing: boolean = false;
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  @State viewportWidth: number = 360;
  @State loadingMore: boolean = false;
  // 每频道独立的分页游标 / 错误文案 / 到底标记，互不串台
  @State recIdx: number = 0;
  @State hotPage: number = 1;
  @State livePage: number = 1;
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
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVersion: number = 0;
  private tabsController: TabsController = new TabsController();
  private recScroller: Scroller = new Scroller();
  private hotScroller: Scroller = new Scroller();
  private liveScroller: Scroller = new Scroller();
  private recSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private hotSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private liveSource: BasicDataSource<LiveRoomItem> = new BasicDataSource<LiveRoomItem>();
  // 防重入：刷新 / 触底 / 切频道并发触发的重复请求直接丢弃
  private recFetching: boolean = false;
  private hotFetching: boolean = false;
  private liveFetching: boolean = false;
  private readonly refreshTriggerOffset: number = 56;

  async aboutToAppear(): Promise<void> {
    // 切到首页 Tab 时强制回到顶部状态，避免残留 fade 导致搜索栏和搜索球同时出现。
    AppTheme.resetHeaderFade();
    // 首屏必须等登录 Cookie 从 Preferences 恢复，否则会先缓存一页游客公共推荐。
    try {
      await UserStore.ensureLoaded();
      await this.loadRecommend(true);
    } catch (e) {
      if (this.recSource.isEmpty()) this.recError = '推荐加载失败，请检查网络后重试';
    }
  }

  async onLoginChanged(): Promise<void> {
    try {
      await UserStore.ensureLoaded();
      await this.loadRecommend(true);
    } catch (e) {
      if (this.recSource.isEmpty()) this.recError = '推荐加载失败，请检查网络后重试';
    }
  }

  /** 推荐卡 ⋮ 菜单-举报：原因选择后给反馈（Web 端无视频举报接口，本地提示）。 */
  private reportCard(item: VideoItem): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: '已提交举报，感谢反馈' });
    } catch (e) {
      // 弹 toast 失败忽略。
    }
  }

  /** 长按卡片「不感兴趣」：本地从对应信息流移除（本轮会话生效；Web 无服务端反馈接口）。 */
  private dislikeLocal(item: VideoItem, feedTab: number): void {
    const source: BasicDataSource<VideoItem> = feedTab === 0 ? this.recSource : this.hotSource;
    const key: number = item.aid;
    if (key <= 0) return;
    source.reset(source.getAll().filter((v: VideoItem) => v.aid !== key));
    try {
      this.getUIContext().getPromptAction().showToast({ message: '已不感兴趣，帮你减少了此类推荐' });
    } catch (e) {
      // 弹 toast 失败忽略。
    }
  }

  /** 追加前按 key 去重：B 站推荐/热门可能返回已在列表中的视频，避免 LazyForEach 重复 key。 */
  private dedupVideos(source: BasicDataSource<VideoItem>, incoming: Array<VideoItem>): Array<VideoItem> {
    const seen: Set<string> = new Set<string>();
    const base: Array<VideoItem> = source.getAll();
    for (let i: number = 0; i < base.length; i++) {
      seen.add(base[i].bvid.length > 0 ? base[i].bvid : 'a' + String(base[i].aid));
    }
    const out: Array<VideoItem> = [];
    for (let i: number = 0; i < incoming.length; i++) {
      const key: string = incoming[i].bvid.length > 0 ? incoming[i].bvid : 'a' + String(incoming[i].aid);
      if (!seen.has(key)) {
        seen.add(key);
        out.push(incoming[i]);
      }
    }
    return out;
  }

  private dedupLive(source: BasicDataSource<LiveRoomItem>, incoming: Array<LiveRoomItem>): Array<LiveRoomItem> {
    const seen: Set<number> = new Set<number>();
    const base: Array<LiveRoomItem> = source.getAll();
    for (let i: number = 0; i < base.length; i++) {
      seen.add(base[i].roomId);
    }
    const out: Array<LiveRoomItem> = [];
    for (let i: number = 0; i < incoming.length; i++) {
      if (!seen.has(incoming[i].roomId)) {
        seen.add(incoming[i].roomId);
        out.push(incoming[i]);
      }
    }
    return out;
  }

  async loadRecommend(reset: boolean): Promise<void> {
    if (this.recFetching || (!reset && !this.recHasMore)) {
      return;
    }
    this.recFetching = true;
    try {
      if (reset) {
        this.recIdx = 0;
        this.recHasMore = true;
      }
      this.recError = '';
      const idx: number = this.recIdx;
      const list: Array<VideoItem> = await FeedApi.getRecommend(idx);
      if (list.length === 0) {
        this.recHasMore = false;
        if (this.recSource.isEmpty()) {
          this.recError = '推荐接口请求失败，请检查网络后重试';
        }
        return;
      }
      this.recIdx = idx + list.length;
      if (reset) {
        this.recSource.reset(list);
      } else {
        this.recSource.append(this.dedupVideos(this.recSource, list));
      }
      this.recCount = this.recSource.totalCount();
    } catch (e) {
      if (this.recSource.isEmpty()) this.recError = '推荐加载失败，请检查网络后重试';
    } finally {
      this.recFetching = false;
    }
  }

  async loadHot(reset: boolean): Promise<void> {
    if (this.hotFetching || (!reset && !this.hotHasMore)) {
      return;
    }
    this.hotFetching = true;
    try {
      if (reset) {
        this.hotPage = 1;
        this.hotHasMore = true;
      }
      this.hotError = '';
      const pn: number = this.hotPage;
      const list: Array<VideoItem> = await FeedApi.getHot(pn, 20);
      if (list.length === 0) {
        this.hotHasMore = false;
        if (this.hotSource.isEmpty()) {
          this.hotError = '热门接口请求失败，请检查网络后重试';
        }
        return;
      }
      this.hotPage = pn + 1;
      if (list.length < 20) {
        this.hotHasMore = false;
      }
      if (reset) {
        this.hotSource.reset(list);
      } else {
        this.hotSource.append(this.dedupVideos(this.hotSource, list));
      }
      this.hotCount = this.hotSource.totalCount();
    } finally {
      this.hotFetching = false;
    }
  }

  async loadLive(reset: boolean): Promise<void> {
    if (this.liveFetching || (!reset && !this.liveHasMore)) {
      return;
    }
    this.liveFetching = true;
    try {
      if (reset) {
        this.livePage = 1;
        this.liveHasMore = true;
      }
      this.liveError = '';
      const page: number = this.livePage;
      const list: Array<LiveRoomItem> = await LiveApi.getLiveRooms(page, 20);
      if (list.length === 0) {
        this.liveHasMore = false;
        if (this.liveSource.isEmpty()) {
          this.liveError = '直播列表请求失败，请检查网络后重试';
        }
        return;
      }
      this.livePage = page + 1;
      if (list.length < 20) {
        this.liveHasMore = false;
      }
      if (reset) {
        this.liveSource.reset(list);
      } else {
        this.liveSource.append(this.dedupLive(this.liveSource, list));
      }
      this.liveCount = this.liveSource.totalCount();
    } finally {
      this.liveFetching = false;
    }
  }

  /** 按频道分发加载：三个频道的刷新/触底入口统一走这里。 */
  private loadChannel(feedTab: number, reset: boolean): Promise<void> {
    if (feedTab === 0) {
      return this.loadRecommend(reset);
    }
    if (feedTab === 1) {
      return this.loadHot(reset);
    }
    return this.loadLive(reset);
  }

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
    this.refreshing = true;
    this.loadChannel(feedTab, true)
      .catch(() => {
      })
      .finally(() => {
        this.refreshing = false;
      });
  }

  onReachEnd(feedTab: number): void {
    if (this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    this.loadChannel(feedTab, false)
      .catch(() => {
      })
      .finally(() => {
        this.loadingMore = false;
      });
  }

  @Builder
  SubTabItem(label: string, index: number) {
    Stack({ alignContent: Alignment.Center }) {
      Text(label)
        .fontSize(14)
        .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.visualTab === index ? this.accent : (this.isDark ? '#A8A8AC' : '#767B82'))
    }
    .width(62)
    .height(30)
    .borderRadius(15)
    .backgroundColor(this.visualTab === index ? this.accentBg() : '#00000000')
    .scale({ x: this.visualTab === index ? 1.0 : 1.0, y: this.visualTab === index ? 1.0 : 1.0 })
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      Haptic.light();
      this.switchTab(index);
    })
  }

  private accentBg(): string {
    // 选中项胶囊底色：用当前主题强调色加透明度，替代原来的硬编码品牌粉。
    return this.isDark ? '#33' + this.accent.substring(1) : '#1F' + this.accent.substring(1);
  }

  private switchTab(index: number): void {
    this.tabsController.changeIndex(index);
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
    Row({ space: 2 }) {
      this.SubTabItem('推荐', 0)
      this.SubTabItem('热门', 1)
      this.SubTabItem('直播', 2)
    }
    .width(196)
    .height(36)
    .padding(3)
    .borderRadius(18)
    .backgroundColor(this.glassOn ? '#00000000' : (this.isDark ? '#D9202125' : '#E8FFFFFF'))
    .systemMaterial(AppTheme.floatMaterial(this.glassOn))
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
      if (this.refreshStatus === RefreshStatus.Refresh || this.refreshing) {
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
    .margin({ top: Immersive.statusBarHeight() + 88 })
    // Done 等结束态不再显示；即使系统状态回调稍晚，请求完成后也立即消失。
    .opacity(this.refreshStatus === RefreshStatus.Refresh || this.refreshing ? 1 : 0)
    .animation({ duration: 120, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  VideoFeedFooter(feedTab: number) {
    LoadMoreFooter({
      loading: this.loadingMore,
      hasMore: this.channelHasMore(feedTab),
      moreText: '',
      endText: '—— 到底啦 ——',
      loadingText: '加载中…',
      fixedHeight: this.loadingMore || !this.channelHasMore(feedTab) ? 48 : 1,
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

  /** 热门频道顶部的排行榜入口：全站排行 / 每周必看 / 入站必刷。 */
  @Builder
  HotRankEntry() {
    NavEntryRow({
      icon: $r('app.media.ic_hot'),
      title: '排行榜',
      onTap: () => {
        AppNavStack.pushPathByName(NAV_RANK, null);
      },
    })
  }

  /** 热门频道顶部入口：分区频道（进分区排行浏览）。 */
  @Builder
  ZoneEntry() {
    NavEntryRow({
      icon: $r('app.media.ic_sort'),
      title: '分区频道',
      onTap: () => {
        AppNavStack.pushPathByName(NAV_ZONE, null);
      },
    })
  }

  /** 热门频道顶部入口：番剧索引（类型×状态聚合浏览）。 */
  @Builder
  BangumiEntry() {
    NavEntryRow({
      icon: $r('app.media.ic_favorite'),
      title: '番剧索引',
      onTap: () => {
        AppNavStack.pushPathByName(NAV_BANGUMI_INDEX, null);
      },
    })
  }

  @Builder
  LiveFooter() {
    LoadMoreFooter({
      loading: this.loadingMore,
      hasMore: this.liveHasMore,
      moreText: '',
      endText: '—— 到底啦 ——',
      loadingText: '加载中…',
      fixedHeight: this.loadingMore || !this.liveHasMore ? 48 : 1,
    })
  }

  @Builder
  VideoFeedList(feedTab: number) {
    List({ space: LayoutTokens.feedGap, scroller: feedTab === 0 ? this.recScroller : this.hotScroller }) {
      // 热门频道首个卡片为排行榜入口，随列表一起滚动。
      if (feedTab === 1) {
        ListItem() {
          this.HotRankEntry()
        }
        ListItem() {
          this.ZoneEntry()
        }
        ListItem() {
          this.BangumiEntry()
        }
      }
      // footer 挂在 ListItemGroup 上：双列 lanes 下保持整宽居中
      ListItemGroup({ footer: this.VideoFeedFooter(feedTab) }) {
        LazyForEach(feedTab === 0 ? this.recSource : this.hotSource, (item: VideoItem) => {
          ListItem() {
            VideoCard({
              video: item,
              idPrefix: 'home-' + String(feedTab) + '-',
              // 仅推荐频道：封面右上 ⋮ → 举报/不想看（不想看即长按同款的本地屏蔽）。
              showMore: feedTab === 0,
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
          .margin({ bottom: LayoutTokens.feedGap })
        }, (item: VideoItem) => item.bvid.length > 0 ? item.bvid : String(item.aid) + '_' + feedTab)
      }
    }
    .width('100%')
    .height('100%')
    .lanes(LayoutTokens.feedColumns(this.viewportWidth), LayoutTokens.feedGap)
    .cachedCount(3)
    // 首屏卡片默认位于搜索栏下方。这个间距属于可滚动内容，滚走后不会因头栏重新出现而顶动卡片。
    .contentStartOffset(Immersive.statusBarHeight() + 94)
    // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
    .contentEndOffset(Immersive.bottomInset() + 76)
    .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
      right: LayoutTokens.horizontalPadding(this.viewportWidth) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
    .scrollBar(BarState.Off)
    .onScroll((offset: number) => {
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
  LiveFeedList() {
    List({ space: LayoutTokens.feedGap, scroller: this.liveScroller }) {
      ListItem() {
        this.LiveZoneEntry()
      }
      LazyForEach(this.liveSource, (item: LiveRoomItem) => {
        ListItem() {
          LiveRoomCard({ room: item })
        }
      }, (item: LiveRoomItem) => String(item.roomId))
      ListItem() {
        LoadMoreFooter({
          loading: this.loadingMore,
          hasMore: this.liveHasMore,
          moreText: '',
          endText: '—— 到底啦 ——',
          loadingText: '加载中…',
          fixedHeight: this.loadingMore || !this.liveHasMore ? 48 : 1,
        })
      }
    }
    .width('100%').height('100%').lanes(LayoutTokens.feedColumns(this.viewportWidth), LayoutTokens.feedGap)
    .cachedCount(3)
    .contentStartOffset(Immersive.statusBarHeight() + 94)
    // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
    .contentEndOffset(Immersive.bottomInset() + 76)
    .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
      right: LayoutTokens.horizontalPadding(this.viewportWidth) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
    .scrollBar(BarState.Off)
    .onScroll((offset: number) => AppTheme.updateHeaderFade(offset))
    .onReachEnd(() => this.onReachEnd(2))
  }

  @Builder
  FeedPage(feedTab: number) {
    if (this.channelError(feedTab).length > 0 && this.channelEmpty(feedTab)) {
      LoadingView({
        loading: false,
        empty: false,
        errorText: this.channelError(feedTab),
        onRetry: () => {
          this.loadChannel(feedTab, true).catch(() => {
          });
        },
      })
      .margin({ top: 110 })
    } else if (this.channelEmpty(feedTab)) {
      LoadingView({ loading: true })
        .margin({ top: 110 })
    } else {
      Refresh({ refreshing: $$this.refreshing, builder: this.RefreshHeader() }) {
        if (feedTab === 2) this.LiveFeedList()
        else this.VideoFeedList(feedTab)
      }
      .refreshOffset(this.refreshTriggerOffset)
      .pullDownRatio(undefined)
      .onStateChange((status: RefreshStatus) => {
        if (this.tab === feedTab) {
          this.refreshStatus = status;
        }
      })
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
      .animationDuration(320)
      .animationCurve(Curve.EaseInOut)
      .onAnimationStart((index: number, targetIndex: number, extraInfo: TabsAnimationEvent) => {
        this.visualTab = targetIndex;
        AppTheme.resetHeaderFade();
      })
      .onChange((index: number) => {
        this.tab = index;
        this.visualTab = index;
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

      this.RefreshIndicator()

      // 紧凑悬浮频道切换：与搜索栏保持同一玻璃层级，不再用实色横条截断信息流。
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
