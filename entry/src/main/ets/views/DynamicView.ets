import { MotionTokens } from '../common/MotionTokens';
import { DynamicItem } from '../model/Models';
import { AppNavStack, NAV_LOGIN } from '../common/AppRouter';
import { UserStore } from '../services/auth/UserStore';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { BasicDataSource } from '../common/BasicDataSource';
import { LayoutTokens } from '../common/LayoutTokens';
import { Haptic } from '../common/Haptic';
import { HeaderBackdrop } from '../components/GlassHeaderBar';
import { Handedness } from '../common/Handedness';
import { EmoteResolver } from '../common/EmoteResolver';
import { DynCard } from '../components/dynamic/DynCard';
import { DynamicFollowController, DynamicFollowState } from '../components/dynamic/DynamicFollowController';
import { DynamicFollowStrip } from '../components/dynamic/DynamicFollowStrip';
import { DynamicComposerController } from '../components/dynamic/DynamicComposerController';
import { DynamicComposer } from '../components/dynamic/DynamicComposer';
import { DynamicFeedController, DynamicFeedState } from '../components/dynamic/DynamicFeedController';
export { DynCard } from '../components/dynamic/DynCard';

@Component
export struct DynamicView {
  /** hostMid > 0 时展示指定用户的公开动态；否则展示当前账号的关注动态。 */
  @Prop hostMid: number = 0;
  /** 嵌入用户空间时不占用主页顶部和 Dock 的安全偏移。 */
  @Prop embedded: boolean = false;
  @State loading: boolean = true;
  @State login: boolean = false;
  @State dynType: string = 'all';
  @State dynTab: number = 0;
  @State refreshing: boolean = false;
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  private refreshOperation: number = 0;
  // 发布动态（纯文字 / 图文）面板状态
  @State showComposer: boolean = false;
  private composer: DynamicComposerController = new DynamicComposerController(() => {
    this.showComposer = false;
    this.loadFeed(true);
  }, (message: string) => {
    try { this.getUIContext().getPromptAction().showToast({ message: message }); } catch (e) {}
  });
  // 发布气泡（悬浮入口）：随惯用手换边。必须是本页 @Builder 而非自定义组件——
  // 自定义组件的包装节点是 HitTestMode.Default，全屏容器会拦截整个动态列表的滑动与点击。
  @StorageProp(Handedness.KEY_SIDE) @Watch('onComposeHandSideChanged') composeHandSide: string = Handedness.RIGHT;
  @State composeHandPosition: number = 0;
  @State composeContainerWidth: number = 0;
  @State following: DynamicFollowState = new DynamicFollowState();
  private follow: DynamicFollowController = new DynamicFollowController(
    (state: DynamicFollowState) => { this.following = state; });
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  @StorageProp('headerFade') fade: number = 0;
  /** 惯用手侧：分类胶囊上滑让位的方向依据（左手头像在左，胶囊向右让位）。 */
  @StorageProp(Handedness.KEY_SIDE) handSide: string = Handedness.RIGHT;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVer: number = 0;
  private dynTabsController: TabsController = new TabsController();
  private dynTypes: Array<string> = ['all', 'video', 'pgc', 'article'];
  @State feedStates: Array<DynamicFeedState> = [new DynamicFeedState(), new DynamicFeedState(),
    new DynamicFeedState(), new DynamicFeedState()];
  private feed: DynamicFeedController = new DynamicFeedController(() => this.hostMid,
    (states: Array<DynamicFeedState>) => { this.feedStates = states; });
  private initializing: boolean = false;
  private active: boolean = true;
  private lifecycle: number = 0;
  /** 初始化期间收到登录广播时补跑一次，避免 Tabs 保活页面永久停在旧登录态。 */
  private initPending: boolean = false;

  onLoginChanged(): void {
    // 登录/登出广播：重载动态流（Tabs 保活，aboutToAppear 不会再触发）
    // 关注列表与直播角标属于账号数据，切换账号时必须清空并重新拉取。
    this.composer.reset();
    this.showComposer = false;
    this.follow.reset();
    this.feed.reset();
    this.refreshOperation++;
    this.refreshing = false;
    this.refreshStatus = RefreshStatus.Inactive;
    this.init().catch(() => {
    });
  }

  aboutToAppear(): void {
    this.active = true;
    this.lifecycle++;
    EmoteResolver.ensureLoaded();
    // 切到动态 Tab 时强制回到顶部状态，避免残留 fade 导致搜索栏和搜索球同时出现。
    AppTheme.resetHeaderFade();
    this.composeHandPosition = this.composeHandSide === Handedness.LEFT ? 1 : 0;
    this.init().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.active = false;
    this.lifecycle++;
    this.initPending = false;
    this.refreshOperation++;
    this.refreshing = false;
    this.refreshStatus = RefreshStatus.Inactive;
    this.feed.cancel();
    this.follow.cancel();
    this.composer.detach();
    this.composer.reset();
  }

  /** 惯用手切换：只驱动气泡位移动画，不触发动态列表刷新。 */
  private onComposeHandSideChanged(): void {
    this.getUIContext().animateTo({ duration: MotionTokens.duration(MotionTokens.navigation, this.reduceMotion),
      curve: Curve.EaseInOut }, () => {
      this.composeHandPosition = this.composeHandSide === Handedness.LEFT ? 1 : 0;
    });
  }

  async init(): Promise<void> {
    if (!this.active) return;
    // aboutToAppear 与登录广播可能同时触发，防重入
    if (this.initializing) {
      this.initPending = true;
      return;
    }
    this.initializing = true;
    this.initPending = false;
    const lifecycle: number = this.lifecycle;
    try {
      this.loading = true;
      if (this.hostMid <= 0 && !UserStore.isLogin) {
        await UserStore.ensureLoaded();
      }
      if (!this.active || lifecycle !== this.lifecycle) return;
      this.login = this.hostMid > 0 || UserStore.isLogin;
      if (this.login) {
        // 只有主页关注流展示 UP 横滑栏；用户空间内嵌版与指定用户动态都不需要。
        if (this.hostMid <= 0 && !this.embedded) {
          this.follow.load();
        }
        await this.loadFeed(true);
      }
    } catch (e) {
      if (this.active && lifecycle === this.lifecycle) {
        this.feed.setInitialError('动态加载失败，请检查登录状态或网络后重试');
      }
    } finally {
      if (this.active && lifecycle === this.lifecycle) this.loading = false;
      this.initializing = false;
      if (this.active && this.initPending) {
        this.initPending = false;
        this.init().catch(() => {
        });
      }
    }
  }

  async loadFeed(reset: boolean): Promise<void> {
    await this.feed.load(reset);
  }

  private recoverFeed(): void {
    const state: DynamicFeedState = this.feed.state();
    if (state.needsLogin) AppNavStack.pushPathByName(NAV_LOGIN, null);
    else if (state.count === 0) this.init();
    else this.loadFeed(state.moreFailed && state.retryReset);
  }

  private onRefresh(): void {
    const operation: number = ++this.refreshOperation;
    this.refreshing = true;
    this.loadFeed(true)
      .catch(() => {
      })
      .finally(() => {
        if (operation === this.refreshOperation) this.refreshing = false;
      });
  }

  @Builder
  DynRefreshHeader() {
    // 与首页同一套骨架：Refresh 内部只放一个空白占位，可见提示由外层悬浮绘制。
    Blank()
      .width('100%')
      .height(1)
  }

  @Builder
  DynRefreshIndicator() {
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
    // 与首页 RefreshIndicator 完全同位置。
    .margin({ top: this.embedded ? 0 : Immersive.statusBarHeight() + 88 })
    .opacity(this.refreshStatus === RefreshStatus.Refresh || this.refreshing ? 1 : 0)
    .animation({ duration: MotionTokens.duration(MotionTokens.feedback, this.reduceMotion), curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }

  private tapVibrate(): void {
    Haptic.tap();
  }

  private changeDynType(type: string): void {
    if (this.dynType === type) return;
    this.refreshOperation++;
    this.refreshing = false;
    this.refreshStatus = RefreshStatus.Inactive;
    this.dynType = type;
    this.feed.select(type);
  }

  private pageSource(tabIdx: number): BasicDataSource<DynamicItem> {
    return this.feed.source(this.dynTypes[tabIdx] ?? 'all');
  }

  private pageState(tabIdx: number): DynamicFeedState {
    return this.feedStates[tabIdx] ?? this.feedStates[0];
  }

  private isActivePage(tabIdx: number): boolean {
    return this.dynTypes[tabIdx] === this.dynType;
  }

  @Builder
  DynTypeChip(label: string, type: string) {
    Stack({ alignContent: Alignment.Center }) {
      Text(label)
        .fontSize(14)
        .fontWeight(this.dynType === type ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.dynType === type ? this.accent :
          (this.isDark ? '#C4C6CC' : '#494D54'))
    }
    .width(62)
    .height(30)
    .borderRadius(15)
    .backgroundColor(this.dynType === type ? (this.isDark ? '#34363C' : '#FFFFFF') : Color.Transparent)
    .animation({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut })
    .onClick(() => {
      this.tapVibrate();
      const index: number = this.dynTypes.indexOf(type);
      if (index >= 0) {
        // 直接改 $$ 双向绑定的 index：点击分类即时换内容（无横向滑动动画）。
        this.dynTab = index;
      }
      this.changeDynType(type);
    })
  }

  @Builder
  DynTypeFilter() {
    Row({ space: 2 }) {
      this.DynTypeChip('全部', 'all')
      this.DynTypeChip('视频', 'video')
      this.DynTypeChip('番剧', 'pgc')
      this.DynTypeChip('专栏', 'article')
    }
    .width(260)
    .height(36)
    .padding(3)
    .borderRadius(18)
    .backgroundColor(this.glassOn ? '#00000000' : (this.isDark ? '#D9202125' : '#E8FFFFFF'))
    // 上滑收起：垂直上移 + 向头像反方向平移让位（与首页频道胶囊同一套规则，静止时居中）。
    .margin({
      top: this.embedded ? 4 : Immersive.statusBarHeight() + 54 * (1 - this.fade),
      left: (!this.embedded && this.handSide === Handedness.LEFT) ? 44 * this.fade : 0,
      right: (!this.embedded && this.handSide !== Handedness.LEFT) ? 44 * this.fade : 0
    })
  }

  @Builder
  LoginPrompt() {
    Column({ space: 14 }) {
      Text('( ゜- ゜)')
        .fontSize(40)
        .fontColor('#CCCCCC')
      Text('登录后即可查看关注动态')
        .fontSize(14)
        .fontColor('#9499A0')
      Button('去登录')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accent)
        .borderRadius(20)
        .padding({ left: 32, right: 32 })
        .onClick(() => {
          AppNavStack.pushPathByName(NAV_LOGIN, null);
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 发布动态悬浮入口。外层容器 hitTestBehavior(None)：自身不参与命中测试、不阻塞列表，
   * 仅按钮子节点可点击（与 HeaderBackdrop 同款覆盖层语义）。
   */
  @Builder
  ComposeOverlay() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_comment'))
          .width(22).height(22).fillColor('#FFFFFF')
      }
      .width(48).height(48).borderRadius(24)
      .backgroundColor(this.accent)
      .shadow({ radius: 12, color: '#66FB7299', offsetY: 3 })
      // 48vp 按钮，两侧各留 16vp；保持同一节点，点击区域随位移一起移动。
      .translate({ x: -Math.max(0, this.composeContainerWidth - 80) * this.composeHandPosition })
      .id('dynamic-compose-entry')
      .accessibilityText('发布动态')
      .onClick(() => {
        this.showComposer = true;
      })
      .stateStyles({
        pressed: { opacity: 0.85 },
        normal: { opacity: 1 },
      })
    }
    .width('100%').height('100%')
    .padding({ left: 16, right: 16, bottom: Immersive.bottomInset() + 88 })
    .onAreaChange((_old: Area, area: Area) => {
      this.composeContainerWidth = Number(area.width);
    })
    .hitTestBehavior(HitTestMode.None)
    .zIndex(50)
  }

  /** 动态图片 id 前缀基座：主页动态 tab 与用户空间内嵌实例可能同屏共存，按场景+hostMid 区分。 */
  private cardIdPrefix(tabIdx: number): string {
    return (this.embedded ? 'dyn-e' + String(this.hostMid) : 'dyn-h') + '-' + String(tabIdx) + '-';
  }

  @Builder
  DynBody(tabIdx: number) {
    if (this.loading && this.pageState(tabIdx).count === 0) {
      LoadingView({ skeleton: 'social', loading: true })
        .margin({ top: this.embedded ? 4 : Immersive.statusBarHeight() + 86 })
    } else if (!this.login) {
      this.LoginPrompt()
    } else if (this.pageState(tabIdx).count === 0) {
      LoadingView({ skeleton: 'social',
        loading: this.pageState(tabIdx).loading,
        empty: this.pageState(tabIdx).loading ? false : this.pageState(tabIdx).errorText.length === 0,
        emptyText: this.hostMid > 0 ? '该用户暂时没有发布动态' :
          (this.dynTypes[tabIdx] === 'all' ? '暂时没有动态，去关注一些UP主吧' : '该分类下暂无动态'),
        errorText: this.pageState(tabIdx).errorText,
        retryText: this.pageState(tabIdx).needsLogin ? '去登录' : '重新加载',
        onRetry: () => { if (this.isActivePage(tabIdx)) this.recoverFeed(); },
      })
      .margin({ top: this.embedded ? 4 : Immersive.statusBarHeight() + 86 })
    } else {
      Refresh({ refreshing: this.isActivePage(tabIdx) && this.refreshing, builder: this.DynRefreshHeader() }) {
        List({ space: 10 }) {
          if (this.following.followed.length > 0 && !this.embedded && this.hostMid <= 0) {
            ListItem() {
              Column({ space: 8 }) {
                Row({ space: 6 }) {
                  Text('关注')
                    .fontSize(12)
                    .fontColor('#9499A0')
                  Text(this.following.followed.length + ' 位')
                    .fontSize(11)
                    .fontColor('#B0B3B8')
                  Blank()
                }
                .width('100%')
                .padding({ left: 2, right: 2 })
                DynamicFollowStrip({ followed: this.following.followed, liveRooms: this.following.liveRooms })
              }
              .width('100%')
              .padding({ top: 10, bottom: 2 })
            }
          }
          LazyForEach(this.pageSource(tabIdx), (item: DynamicItem) => {
            ListItem() {
              // 主页底部 Tabs 里的动态流（Navigation 根页面）走 push + srcRect 矩形放大看图。
              // onLikeResult 闭包只引用父级 this，按 dynId 回写数据源，复用不捕获过期索引。
              DynCard({ item: item, embedded: this.embedded, sharedImageTransition: this.embedded,
                idPrefix: this.cardIdPrefix(tabIdx),
                onLikeResult: (dynId: string, liked: boolean, count: number) => {
                  this.feed.updateLike(dynId, liked, count);
                } })
            }
          }, (item: DynamicItem) => item.dynId)
          ListItem() {
            LoadMoreFooter({
              loading: this.pageState(tabIdx).loading,
              hasMore: this.pageState(tabIdx).hasMore || this.pageState(tabIdx).moreFailed,
              moreText: this.pageState(tabIdx).needsLogin ? '登录已失效，去登录' :
                (this.pageState(tabIdx).moreFailed ? '加载失败，点击重试' : '继续加载动态'),
              endText: '—— 动态到底啦 ——',
              fixedHeight: 52,
              spinnerSize: 22,
              clickable: true,
              onLoadMore: () => { if (this.isActivePage(tabIdx)) this.recoverFeed(); },
            })
          }
        }
        .width('100%')
        .height('100%')
        .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
        .alignSelf(ItemAlign.Center)
        .cachedCount(3)
        // 与首页对齐：非内嵌时列表从玻璃头栏下方开始，滚动时内容可直接顶到最上方。
        .contentStartOffset(this.embedded ? 4 : Immersive.statusBarHeight() + 94)
        // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
        .contentEndOffset(this.embedded ? 16 : Immersive.bottomInset() + 76)
        .padding({ left: LayoutTokens.phonePadding, right: LayoutTokens.phonePadding })
        .scrollBar(BarState.Off)
        .nestedScroll({
          scrollForward: this.embedded ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_ONLY,
          scrollBackward: this.embedded ? NestedScrollMode.SELF_FIRST : NestedScrollMode.SELF_ONLY,
        })
        .onDidScroll((offset: number) => {
          if (this.isActivePage(tabIdx) && !this.embedded) AppTheme.updateHeaderFade(offset);
        })
        .onReachEnd(() => {
          if (this.isActivePage(tabIdx) && !this.pageState(tabIdx).moreFailed) this.loadFeed(false);
        })
      }
      .refreshOffset(56)
      .pullDownRatio(undefined)
      .onStateChange((status: RefreshStatus) => {
        if (this.isActivePage(tabIdx)) this.refreshStatus = status;
      })
      .onRefreshing(() => { if (this.isActivePage(tabIdx)) this.onRefresh(); })
    }
  }

  @Builder
  DynComposerSheet() {
    DynamicComposer({ controller: this.composer, onClose: () => { this.showComposer = false; } })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 动态分类 Tabs：左右滑动在 全部/视频/番剧/专栏 之间切换，与首页推荐/热门/直播一致。
      // 内嵌模式（用户空间"动态"页）禁用内层横向滑动：让外层"主页/动态/投稿"Tabs 收到手势，
      // 避免两层横向 Tabs 抢手势导致从中间页滑不出去；分类切换在独立动态页内仍可用。
      Tabs({ index: $$this.dynTab, controller: this.dynTabsController }) {
        TabContent() { this.DynBody(0) }.tabBar('')
        TabContent() { this.DynBody(1) }.tabBar('')
        TabContent() { this.DynBody(2) }.tabBar('')
        TabContent() { this.DynBody(3) }.tabBar('')
      }
      .width('100%')
      .height('100%')
      .scrollable(!this.embedded)
      .barHeight(0)
      .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
      .animationMode(AnimationMode.CONTENT_FIRST)
      .animationDuration(MotionTokens.duration(MotionTokens.content, this.reduceMotion))
      .animationCurve(Curve.EaseOut)
      .onChange((index: number) => {
        this.dynTab = index;
        const type: string | undefined = this.dynTypes[index];
        if (type !== undefined && type !== this.dynType) this.changeDynType(type);
      })

      if (!this.embedded && this.hostMid <= 0) {
        HeaderBackdrop()
      }

      this.DynRefreshIndicator()

      if (this.login && this.hostMid <= 0) {
        this.DynTypeFilter()
      }

      // 发布入口随惯用手平滑换边，保持位于 Dock 上方。
      if (this.login && this.hostMid <= 0 && this.embedded === false) {
        this.ComposeOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .bindSheet($$this.showComposer, this.DynComposerSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: this.isDark ? '#1E2024' : '#FFFFFF',
    })
  }
}
