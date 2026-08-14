/**
 * 首页视图：推荐（app 端接口）+ 热门，双列瀑布流、下拉刷新、触底加载
 */
import { VideoItem } from '../model/Models';
import { BiliApi } from '../api/BiliApi';
import { VideoCard } from '../components/VideoCard';
import { LoadingView } from '../components/LoadingView';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { UserStore } from '../common/UserStore';
import { LiveRoomItem } from '../model/LiveModels';
import { LiveRoomCard } from '../components/LiveRoomCard';

@Component
export struct HomeView {
  @State tab: number = 0; // 0 推荐 / 1 热门 / 2 直播
  @State visualTab: number = 0;
  @State recList: Array<VideoItem> = [];
  @State hotList: Array<VideoItem> = [];
  @State liveList: Array<LiveRoomItem> = [];
  @State loading: boolean = true;
  @State errorText: string = '';
  @State refreshing: boolean = false;
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  @State loadingMore: boolean = false;
  @State recIdx: number = 0;
  @State hotPage: number = 1;
  @State livePage: number = 1;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('glassLevel') glassLevel: number = 1;
  @StorageProp('headerFade') fade: number = 0;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVersion: number = 0;
  private tabsController: TabsController = new TabsController();
  private recScroller: Scroller = new Scroller();
  private hotScroller: Scroller = new Scroller();
  private liveScroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    // 首屏必须等登录 Cookie 从 Preferences 恢复，否则会先缓存一页游客公共推荐。
    await UserStore.ensureLoaded();
    await this.loadRecommend(true);
  }

  async onLoginChanged(): Promise<void> {
    this.loading = true;
    await UserStore.ensureLoaded();
    await this.loadRecommend(true);
  }

  async loadRecommend(reset: boolean): Promise<void> {
    if (reset) {
      this.recIdx = 0;
    }
    this.errorText = '';
    const idx: number = this.recIdx;
    const list: Array<VideoItem> = await BiliApi.getRecommend(idx);
    if (list.length === 0 && this.recList.length === 0) {
      this.loading = false;
      this.errorText = '推荐接口请求失败，请检查网络后重试';
      return;
    }
    this.recIdx = idx + list.length;
    this.recList = reset ? list : this.recList.concat(list);
    this.loading = false;
  }

  async loadHot(reset: boolean): Promise<void> {
    if (reset) {
      this.hotPage = 1;
    }
    this.errorText = '';
    const pn: number = this.hotPage;
    const list: Array<VideoItem> = await BiliApi.getHot(pn, 20);
    if (list.length === 0 && this.hotList.length === 0) {
      this.loading = false;
      this.errorText = '热门接口请求失败，请检查网络后重试';
      return;
    }
    this.hotPage = pn + 1;
    this.hotList = reset ? list : this.hotList.concat(list);
    this.loading = false;
  }

  async loadLive(reset: boolean): Promise<void> {
    if (reset) this.livePage = 1;
    this.errorText = '';
    const page: number = this.livePage;
    const list: Array<LiveRoomItem> = await BiliApi.getLiveRooms(page, 20);
    if (list.length === 0 && this.liveList.length === 0) {
      this.loading = false;
      this.errorText = '直播列表请求失败，请检查网络后重试';
      return;
    }
    this.livePage = page + 1;
    this.liveList = reset ? list : this.liveList.concat(list);
    this.loading = false;
  }

  onRefresh(feedTab: number): void {
    this.refreshing = true;
    if (feedTab === 0) {
      this.loadRecommend(true).finally(() => {
        this.refreshing = false;
      });
    } else if (feedTab === 1) {
      this.loadHot(true).finally(() => {
        this.refreshing = false;
      });
    } else {
      this.loadLive(true).finally(() => {
        this.refreshing = false;
      });
    }
  }

  onReachEnd(feedTab: number): void {
    if (this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    if (feedTab === 0) {
      this.loadRecommend(false).finally(() => {
        this.loadingMore = false;
      });
    } else if (feedTab === 1) {
      this.loadHot(false).finally(() => {
        this.loadingMore = false;
      });
    } else {
      this.loadLive(false).finally(() => {
        this.loadingMore = false;
      });
    }
  }

  @Builder
  SubTabItem(label: string, index: number, onSwitch: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Text(label)
        .fontSize(14)
        .fontWeight(this.visualTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.visualTab === index ? this.accent : (this.isDark ? '#A8A8AC' : '#767B82'))
    }
    .width(62)
    .height(30)
    .borderRadius(15)
    .backgroundColor(this.visualTab === index ? (this.isDark ? '#33FB7299' : '#1FFB7299') : '#00000000')
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      onSwitch();
    })
  }

  @Builder
  SubTabs() {
    Row({ space: 2 }) {
      this.SubTabItem('推荐', 0, () => {
        this.tabsController.changeIndex(0);
        if (this.recList.length === 0) {
          this.loadRecommend(true);
        }
      })
      this.SubTabItem('热门', 1, () => {
        this.tabsController.changeIndex(1);
        if (this.hotList.length === 0) {
          this.loadHot(true);
        }
      })
      this.SubTabItem('直播', 2, () => {
        this.tabsController.changeIndex(2);
        if (this.liveList.length === 0) {
          this.loadLive(true);
        }
      })
    }
    .width(196)
    .height(36)
    .padding(3)
    .borderRadius(18)
    .backgroundColor(this.isDark ? '#D9202125' : '#E8FFFFFF')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  RefreshHeader() {
    // Refresh 内部仅保留很短的手势占位；可见提示由外层悬浮绘制，
    // 这样提示位置不再决定需要下拉多远才能触发刷新。
    Blank()
    .width('100%')
    .height(52)
  }

  @Builder
  RefreshIndicator() {
    Row({ space: 8 }) {
      LoadingProgress()
        .width(22)
        .height(22)
        .color(this.accent)
      Text(this.refreshStatus === RefreshStatus.Refresh || this.refreshing ? '正在刷新…' :
        (this.refreshStatus === RefreshStatus.OverDrag ? '松开刷新' : '下拉刷新'))
        .fontSize(12)
        .fontColor(this.isDark ? '#CACACE' : '#676B72')
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    // 搜索栏和推荐/热门频道栏下方显示，但不参与 Refresh 的下拉距离计算。
    .margin({ top: Immersive.statusBarHeight() + 88 })
    // Done 等结束态不再显示；即使系统状态回调稍晚，请求完成后也立即消失。
    .opacity(this.refreshing || this.refreshStatus === RefreshStatus.Drag ||
      this.refreshStatus === RefreshStatus.OverDrag ? 1 : 0)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  LoadMoreFooter() {
    Row({ space: 8 }) {
      if (this.loadingMore) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(this.accent)
        Text('加载中…')
          .fontSize(12)
          .fontColor(this.isDark ? '#D0D0D0' : '#676B72')
      }
    }
    .width('100%')
    .height(this.loadingMore ? 48 : 1)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  VideoFeedList(feedTab: number) {
    List({ space: 10, scroller: feedTab === 0 ? this.recScroller : this.hotScroller }) {
      ListItemGroup({ footer: this.LoadMoreFooter() }) {
        ForEach(feedTab === 0 ? this.recList : this.hotList, (item: VideoItem) => {
          ListItem() {
            VideoCard({ video: item })
          }
        }, (item: VideoItem) => item.bvid.length > 0 ? item.bvid : String(item.aid) + '_' + feedTab)
      }
    }
    .width('100%')
    .height('100%')
    .lanes(2, 10)
    // 首屏卡片默认位于搜索栏下方。这个间距属于可滚动内容，滚走后不会因头栏重新出现而顶动卡片。
    .contentStartOffset(Immersive.statusBarHeight() + 94)
    .contentEndOffset(Immersive.bottomInset() + 56)
    .padding({ left: 10, right: 10 })
    .scrollBar(BarState.Off)
    .onScroll((offset: number) => {
      AppTheme.updateHeaderFade(offset);
    })
    .onReachEnd(() => {
      this.onReachEnd(feedTab);
    })
  }

  @Builder
  LiveFeedList() {
    List({ space: 10, scroller: this.liveScroller }) {
      ListItemGroup({ footer: this.LoadMoreFooter() }) {
        ForEach(this.liveList, (item: LiveRoomItem) => {
          ListItem() {
            LiveRoomCard({ room: item })
          }
        }, (item: LiveRoomItem) => String(item.roomId))
      }
    }
    .width('100%').height('100%').lanes(2, 10)
    .contentStartOffset(Immersive.statusBarHeight() + 94)
    .contentEndOffset(Immersive.bottomInset() + 56)
    .padding({ left: 10, right: 10 }).scrollBar(BarState.Off)
    .onScroll((offset: number) => AppTheme.updateHeaderFade(offset))
    .onReachEnd(() => this.onReachEnd(2))
  }

  @Builder
  FeedPage(feedTab: number) {
    if (this.errorText.length > 0 && (feedTab === 0 ? this.recList.length === 0 :
      (feedTab === 1 ? this.hotList.length === 0 : this.liveList.length === 0))) {
      LoadingView({
        loading: false,
        empty: false,
        errorText: this.errorText,
        onRetry: () => {
          if (feedTab === 0) this.loadRecommend(true);
          else if (feedTab === 1) this.loadHot(true);
          else this.loadLive(true);
        },
      })
      .margin({ top: 110 })
    } else if (feedTab === 0 && this.recList.length === 0 ||
      feedTab === 1 && this.hotList.length === 0 || feedTab === 2 && this.liveList.length === 0) {
      LoadingView({ loading: true })
        .margin({ top: 110 })
    } else {
      Refresh({ refreshing: $$this.refreshing, builder: this.RefreshHeader() }) {
        if (feedTab === 2) this.LiveFeedList()
        else this.VideoFeedList(feedTab)
      }
      .refreshOffset(48)
      .pullDownRatio(1)
      .onStateChange((status: RefreshStatus) => {
        if (this.tab === feedTab) this.refreshStatus = status;
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
      })

      this.RefreshIndicator()

      // 紧凑悬浮频道切换：与搜索栏保持同一玻璃层级，不再用实色横条截断信息流。
      Row() {
        this.SubTabs()
        Blank()
      }
      .width('100%')
      .padding({ left: 10, right: 10 })
      .margin({ top: Immersive.statusBarHeight() + 50 })
      .opacity(1 - this.fade)
      .translate({ y: -12 * this.fade })
      .animation({ duration: 160, curve: Curve.EaseOut })
      .hitTestBehavior(this.fade > 0.9 ? HitTestMode.None : HitTestMode.Default)
    }
    .width('100%')
    .layoutWeight(1)
  }
}
