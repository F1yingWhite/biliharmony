/**
 * 主界面：HarmonyOS 7 沉浸光感风格
 * - Navigation 根：Search / VideoDetail / Login 以 NavDestination 入栈
 * - 顶部玻璃头栏（小电视 + 主题色光晕）悬浮，上滑渐隐进状态栏
 * - 底部系统 Tabs 沉浸光感模糊背板，内容从背板下方透出
 */
import { HomeView } from '../views/HomeView';
import { DynamicView } from '../views/DynamicView';
import { MineView } from '../views/MineView';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { GlassHeaderBar } from '../components/GlassHeaderBar';
import { AppNavStack, APP_ROOT_SNAPSHOT_ID, NAV_SEARCH, NAV_VIDEO_DETAIL, NAV_LOGIN, NAV_USER_SPACE, NAV_MESSAGES,
  NAV_HISTORY, NAV_FAVORITES,
  NAV_WATCH_LATER, NAV_LIVE_ROOM, NAV_IMAGE_VIEWER, NAV_DYNAMIC_DETAIL, VideoDetailParam, UserSpaceParam, LiveRoomParam,
  ImageViewerParam, DynamicDetailParam, NAV_RELATION_LIST, RelationListParam, NAV_BANGUMI_DETAIL,
  BangumiDetailParam, NAV_RANK, NAV_ARTICLE, ArticlePageParam, NAV_BANGUMI_LIST, NAV_BANGUMI_INDEX, NAV_ZONE,
  NAV_BLACK_LIST, NAV_LIVE_ZONE, NAV_FAV_SORT, NAV_BANGUMI_TIMELINE } from '../common/AppRouter';
import { SearchPage } from './Search';
import { FavSortParam } from '../common/AppRouter';
import { MessagesPage } from './Messages';
import { FavoritesPage, HistoryPage, WatchLaterPage } from './LibraryPages';
import { BangumiListPage } from './BangumiListPage';
import { BangumiIndexPage } from './BangumiIndexPage';
import { BangumiTimelinePage } from './BangumiTimelinePage';
import { ZoneChannelPage } from './ZoneChannelPage';
import { BlackListPage } from './BlackListPage';
import { LiveZonePage } from './LiveZonePage';
import { FavoriteFolderSortPage } from './FavoriteFolderSortPage';
import { VideoDetailPage } from './VideoDetail';
import { LoginPage } from './Login';
import { UserSpacePage } from './UserSpace';
import { LiveRoomPage } from './LiveRoom';
import { ImageViewerPage } from './ImageViewer';
import { DynamicDetailPage } from './DynamicDetail';
import { RelationListPage } from './RelationList';
import { BangumiDetailPage } from './BangumiDetail';
import { RankPage } from './RankPage';
import { ArticlePage } from './ArticlePage';
import { UserStore } from '../common/UserStore';
import { PlayerCommandBus } from '../common/PlayerCommandBus';
import { Haptic } from '../common/Haptic';
import { curves } from '@kit.ArkUI';

/** NavDestination 公共修饰：隐藏标题栏 + 页面显示/消失回调（各页面回调体不变，消除 8 分支重复）。 */
@Extend(NavDestination)
function stdDestination(onShownCb: () => void, onWillDisappearCb: () => void) {
  .hideTitleBar(true)
  .onShown(() => {
    onShownCb();
  })
  .onWillDisappear(() => {
    onWillDisappearCb();
  })
}

@Entry
@Component
struct Index {
  @State @Watch('onCurrentTabChanged') currentTab: number = 0;
  @StorageProp('accentColor') @Watch('onThemeChanged') accent: string = '#FB7299';
  @StorageProp('isDarkMode') @Watch('onThemeChanged') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('headerFade') fade: number = 0;

  aboutToAppear(): void {
    this.reapplyBarColors();
    UserStore.ensureLoaded();
  }

  onPageShow(): void {
    // 应用从后台回到前台也会触发根页 onPageShow，必须按导航栈顶重算而不是无条件套根页配色，
    // 否则播放页（黑底）上状态栏图标被刷成深色，看不清时间电量。
    this.reapplyBarColors();
  }

  onThemeChanged(): void {
    this.reapplyBarColors();
  }

  /** 恢复为根页配色。二级页 onWillDisappear 预恢复用（出栈回根页没有页面级回调）。 */
  syncBarColors(): void {
    // 根页顶部为玻璃头栏：浅色背景配深色图标，深色模式配浅色图标
    Immersive.setBarIcons(this.isDark, this.isDark);
  }

  /** 按导航栈顶页面重算系统栏图标深浅：栈顶为深色顶部页面（播放器/直播/看图/用户空间 banner）时保持浅色图标。 */
  private reapplyBarColors(): void {
    const names: Array<string> = AppNavStack.getAllPathName();
    const top: string = names.length > 0 ? names[names.length - 1] : '';
    if (top === NAV_VIDEO_DETAIL || top === NAV_LIVE_ROOM || top === NAV_IMAGE_VIEWER) {
      Immersive.setBarIcons(true, true);
      return;
    }
    if (top === NAV_USER_SPACE || top === NAV_BANGUMI_DETAIL) {
      Immersive.setBarIcons(true, this.isDark);
      return;
    }
    this.syncBarColors();
  }

  switchTab(index: number): void {
    this.currentTab = index;
    AppTheme.resetHeaderFade();
  }

  /** 广播主 Tab 索引：「我的」页借此在切回时重算缓存大小（Tabs 保活不重走 aboutToAppear）。 */
  private onCurrentTabChanged(): void {
    AppStorage.setOrCreate('mainTabIndex', this.currentTab);
  }

  /** 路由参数守卫：非法参数返回 null，页面渲染为空态而不是裸强转崩溃。 */
  private static asVideoDetailParam(param: Object): VideoDetailParam | null {
    const p: VideoDetailParam = param as VideoDetailParam;
    if (p === null || p === undefined) {
      return null;
    }
    if (typeof p.bvid !== 'string' || typeof p.aid !== 'number' || typeof p.title !== 'string') {
      return null;
    }
    if (p.bvid.length === 0 && p.aid <= 0) {
      return null;
    }
    return p;
  }

  private static asUserSpaceParam(param: Object): UserSpaceParam | null {
    const p: UserSpaceParam = param as UserSpaceParam;
    if (p === null || p === undefined || typeof p.mid !== 'number' || p.mid <= 0) {
      return null;
    }
    return p;
  }

  private static asLiveRoomParam(param: Object): LiveRoomParam | null {
    const p: LiveRoomParam = param as LiveRoomParam;
    if (p === null || p === undefined || typeof p.roomId !== 'number' || p.roomId <= 0) {
      return null;
    }
    return p;
  }

  private static asImageViewerParam(param: Object): ImageViewerParam | null {
    const p: ImageViewerParam = param as ImageViewerParam;
    if (p === null || p === undefined || !Array.isArray(p.images) || p.images.length === 0) {
      return null;
    }
    return p;
  }

  private static asDynamicDetailParam(param: Object): DynamicDetailParam | null {
    const p: DynamicDetailParam = param as DynamicDetailParam;
    if (p === null || p === undefined || p.item === null || p.item === undefined) return null;
    return p;
  }

  private static asRelationListParam(param: Object): RelationListParam | null {
    const p: RelationListParam = param as RelationListParam;
    if (p === null || p === undefined || typeof p.mid !== 'number' || p.mid <= 0 ||
      (p.mode !== 'following' && p.mode !== 'follower')) return null;
    return p;
  }

  private static asBangumiDetailParam(param: Object): BangumiDetailParam | null {
    const p: BangumiDetailParam = param as BangumiDetailParam;
    if (p === null || p === undefined) {
      return null;
    }
    if (typeof p.seasonId !== 'number' || typeof p.epId !== 'number' || typeof p.title !== 'string') {
      return null;
    }
    if (p.seasonId <= 0 && p.epId <= 0) {
      return null;
    }
    return p;
  }

  @Builder
  InvalidParamContent() {
    Column() {
      Text('页面参数无效，请返回重试')
        .fontSize(14)
        .fontColor('#9499A0')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  PageMap(name: string, param: Object) {
    if (name === NAV_SEARCH) {
      NavDestination() {
        SearchPage()
      }
      .stdDestination(() => {
        Immersive.setBarIcons(this.isDark, this.isDark);
      }, () => {
        // 出栈回根页时没有页面级回调，提前恢复根页系统栏图标
        this.syncBarColors();
      })
    } else if (name === NAV_MESSAGES) {
      NavDestination() {
        MessagesPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
      .onBackPressed(() => {
        // 私信详情是页内二级导航：侧滑/返回键先回会话列表，不直接弹回首页。
        if (AppStorage.get<boolean>('messageThreadOpen') ?? false) {
          AppStorage.setOrCreate<boolean>('messageThreadOpen', false);
          return true;
        }
        return false;
      })
    } else if (name === NAV_HISTORY) {
      NavDestination() {
        HistoryPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_FAVORITES) {
      NavDestination() {
        FavoritesPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_WATCH_LATER) {
      NavDestination() {
        WatchLaterPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_VIDEO_DETAIL) {
      NavDestination() {
        if (Index.asVideoDetailParam(param) !== null) {
          VideoDetailPage({ param: param as VideoDetailParam })
        } else {
          this.InvalidParamContent()
        }
      }
      // 透明底：卡片放大入场期间透出下层页面（页面内自带底色层，入场结束即不透明）。
      .backgroundColor('#00000000')
      .stdDestination(() => {
        // 顶部为播放器黑底 → 状态栏透明 + 浅色图标
        Immersive.setBarIcons(true, true);
      }, () => {
        PlayerCommandBus.stop();
        this.syncBarColors();
      })
      .onBackPressed(() => {
        // 评论回复详情是视频页内二级状态：系统返回键和侧滑都先退出回复详情。
        if (AppStorage.get<boolean>('videoReplyThreadOpen') ?? false) {
          const request: number = AppStorage.get<number>('videoReplyThreadCloseRequest') ?? 0;
          AppStorage.setOrCreate<number>('videoReplyThreadCloseRequest', request + 1);
          return true;
        }
        // 横屏播放器仍处于全屏时，侧滑/返回键只退出全屏，不把整个视频页出栈。
        if (AppStorage.get<boolean>('videoPlayerFullscreen') ?? false) {
          PlayerCommandBus.exitFullscreen();
          return true;
        }
        // 卡片放大入场：返回/侧滑同样走页面"缩回卡片"收合动画（与看图页同机制）。
        const videoParam = Index.asVideoDetailParam(param);
        if (videoParam !== null && videoParam.srcRect !== undefined) {
          const request: number = AppStorage.get<number>('videoDetailCloseRequest') ?? 0;
          AppStorage.setOrCreate<number>('videoDetailCloseRequest', request + 1);
          return true;
        }
        return false;
      })
    } else if (name === NAV_LIVE_ROOM) {
      NavDestination() {
        if (Index.asLiveRoomParam(param) !== null) {
          LiveRoomPage({ param: param as LiveRoomParam })
        } else {
          this.InvalidParamContent()
        }
      }
      .stdDestination(() => Immersive.setBarIcons(true, true), () => this.syncBarColors())
      .onBackPressed(() => {
        if (AppStorage.get<boolean>('livePlayerFullscreen') ?? false) {
          const token: number = AppStorage.get<number>('livePlayerExitRequest') ?? 0;
          AppStorage.setOrCreate<number>('livePlayerExitRequest', token + 1);
          return true;
        }
        return false;
      })
    } else if (name === NAV_IMAGE_VIEWER) {
      NavDestination() {
        if (Index.asImageViewerParam(param) !== null) {
          ImageViewerPage({ param: param as ImageViewerParam })
        } else {
          this.InvalidParamContent()
        }
      }
      .stdDestination(() => Immersive.setBarIcons(true, true), () => this.syncBarColors())
      // 看图页：容器背景透明，转场期间透出源页面；黑底由页面内 bgOpacity 渐显（见 ImageViewer.ets）
      .backgroundColor('#00000000')
      // 默认转场已由 push/pop(false) 关闭，这里用淡入淡出衬托共享元素飞行
      .transition(TransitionEffect.OPACITY)
      .onBackPressed(() => {
        // 看图页拦截系统返回/侧滑，交给页面做"缩回缩略图"的收合动画。
        const request: number = AppStorage.get<number>('imageViewerCloseRequest') ?? 0;
        AppStorage.setOrCreate<number>('imageViewerCloseRequest', request + 1);
        return true;
      })
    } else if (name === NAV_DYNAMIC_DETAIL) {
      NavDestination() {
        if (Index.asDynamicDetailParam(param) !== null) {
          DynamicDetailPage({ param: param as DynamicDetailParam })
        } else {
          this.InvalidParamContent()
        }
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_RELATION_LIST) {
      NavDestination() {
        if (Index.asRelationListParam(param) !== null) {
          RelationListPage({ param: param as RelationListParam })
        } else {
          this.InvalidParamContent()
        }
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_BANGUMI_DETAIL) {
      NavDestination() {
        if (Index.asBangumiDetailParam(param) !== null) {
          BangumiDetailPage({ param: param as BangumiDetailParam })
        } else {
          this.InvalidParamContent()
        }
      }
      .stdDestination(() => {
        // 顶部为封面氛围图 → 状态栏图标浅色
        Immersive.setBarIcons(true, this.isDark);
      }, () => {
        this.syncBarColors();
      })
    } else if (name === NAV_RANK) {
      NavDestination() {
        RankPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_ARTICLE) {
      NavDestination() {
        ArticlePage({ param: param as ArticlePageParam })
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_BANGUMI_LIST) {
      NavDestination() {
        BangumiListPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_BANGUMI_INDEX) {
      NavDestination() {
        BangumiIndexPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_BANGUMI_TIMELINE) {
      NavDestination() {
        BangumiTimelinePage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_ZONE) {
      NavDestination() {
        ZoneChannelPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_BLACK_LIST) {
      NavDestination() {
        BlackListPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_LIVE_ZONE) {
      NavDestination() {
        LiveZonePage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_FAV_SORT) {
      NavDestination() {
        FavoriteFolderSortPage({ param: (param as FavSortParam) })
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_LOGIN) {
      NavDestination() {
        LoginPage()
      }
      .stdDestination(() => {
        Immersive.setBarIcons(this.isDark, this.isDark);
      }, () => {
        this.syncBarColors();
      })
    } else if (name === NAV_USER_SPACE) {
      NavDestination() {
        if (Index.asUserSpaceParam(param) !== null) {
          UserSpacePage({ param: param as UserSpaceParam })
        } else {
          this.InvalidParamContent()
        }
      }
      .stdDestination(() => {
        // 顶部为 banner 氛围图 → 状态栏图标浅色
        Immersive.setBarIcons(true, this.isDark);
      }, () => {
        this.syncBarColors();
      })
    }
  }

  /** 底部导航图标选中弹跳动效比例（0/1/2 对首页/动态/我的）。 */
  @State tabScale: Array<number> = [1, 1, 1];

  /** 轻触底部导航：轻震 + 图标先缩后弹回（只有切到别的 Tab 才弹）。 */
  private tapTabItem(index: number): void {
    Haptic.light();
    if (this.currentTab === index) return;
    this.tabScale = this.tabScale.map((v: number, i: number) => (i === index ? 0.78 : v));
    const pending: number = index;
    setTimeout(() => {
      this.tabScale = this.tabScale.map((v: number, i: number) => (i === pending ? 1 : v));
    }, 30);
    // 自定义 tabBar 的 onClick 会拦截默认切换逻辑，必须显式驱动索引切换。
    this.currentTab = index;
  }

  @Builder
  TabBarItem(index: number, label: string, icon: Resource, activeIcon: Resource) {
    Column({ space: 2 }) {
      Image(this.currentTab === index ? activeIcon : icon)
        .width(24)
        .height(24)
        .fillColor(this.currentTab === index ? this.accent : (this.isDark ? '#8A8A8E' : '#9499A0'))
        .scale({ x: this.tabScale[index], y: this.tabScale[index] })
        .animation({ duration: 260, curve: curves.springMotion(0.35, 0.7) })
      Text(label)
        .fontSize(10)
        .fontColor(this.currentTab === index ? this.accent : (this.isDark ? '#8A8A8E' : '#9499A0'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.tapTabItem(index);
    })
  }

  @Builder
  FloatingTabs() {
    Tabs({ barPosition: BarPosition.End, index: $$this.currentTab }) {
      TabContent() {
        HomeView()
      }
      .tabBar(this.TabBarItem(0, '首页', $r('app.media.ic_tab_home'), $r('app.media.ic_tab_home_fill')))
      .clip(false)

      TabContent() {
        DynamicView()
      }
      .tabBar(this.TabBarItem(1, '动态', $r('app.media.ic_tab_dynamic'), $r('app.media.ic_tab_dynamic_fill')))
      .clip(false)

      TabContent() {
        MineView()
      }
      .tabBar(this.TabBarItem(2, '我的', $r('app.media.ic_tab_mine'), $r('app.media.ic_tab_mine_fill')))
      .clip(false)
    }
    .barHeight(52)
    .barOverlap(true)
    // 顶层首页/动态/我的只通过底部 Dock 切换，不响应左右滑动；
    // 左右滑动留给各页面内部的频道 Tabs（首页推荐/热门/直播，动态全部/视频/番剧）。
    .scrollable(false)
    // 原生悬浮式 Dock 底栏 + 沉浸光感材质（API 26+；低版本时退化为实底背板）
    .barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: 16,
      systemMaterial: AppTheme.floatMaterial(this.glassOn),
    })
    // 深色模式给原生玻璃叠一层深色吸收底：透明度必须足够高才能压住
    // 系统材质在深色下的白雾（实测 ~70% 仍泛白，Dock 整条变浅灰）。
    .barBackgroundColor(this.glassOn ? (this.isDark ? '#EA15161A' : '#00000000') : AppTheme.floatBg(this.isDark, false))
    .animationDuration(320)
    .animationMode(AnimationMode.CONTENT_FIRST)
    .onChange(() => {
      AppTheme.resetHeaderFade();
    })
  }

  @Builder
  PlainTabs() {
    Tabs({ barPosition: BarPosition.End, index: $$this.currentTab }) {
      TabContent() {
        HomeView()
      }
      .tabBar(this.TabBarItem(0, '首页', $r('app.media.ic_tab_home'), $r('app.media.ic_tab_home_fill')))
      .clip(false)

      TabContent() {
        DynamicView()
      }
      .tabBar(this.TabBarItem(1, '动态', $r('app.media.ic_tab_dynamic'), $r('app.media.ic_tab_dynamic_fill')))
      .clip(false)

      TabContent() {
        MineView()
      }
      .tabBar(this.TabBarItem(2, '我的', $r('app.media.ic_tab_mine'), $r('app.media.ic_tab_mine_fill')))
      .clip(false)
    }
    .barHeight(52)
    .barOverlap(true)
    // 顶层首页/动态/我的只通过底部 Dock 切换，不响应左右滑动；
    // 左右滑动留给各页面内部的频道 Tabs（首页推荐/热门/直播，动态全部/视频/番剧）。
    .scrollable(false)
    .barBackgroundColor(AppTheme.floatBg(this.isDark, this.glassOn))
    .animationDuration(320)
    .animationMode(AnimationMode.CONTENT_FIRST)
    .onChange(() => {
      AppTheme.resetHeaderFade();
    })
  }

  @Builder
  SearchFloat() {
    Row() {
      Blank()
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_search'))
          .width(18)
          .height(18)
          .fillColor(this.accent)
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(this.glassOn ? '#00000000' : AppTheme.floatBg(this.isDark, false))
      .systemMaterial(AppTheme.floatMaterial(this.glassOn))
      .shadow({ radius: 8, color: this.isDark ? '#59000000' : '#1A000000', offsetX: 0, offsetY: 2 })
      .opacity(this.fade)
      .scale({ x: 0.6 + 0.4 * this.fade, y: 0.6 + 0.4 * this.fade })
      .onClick(() => {
        AppNavStack.pushPathByName(NAV_SEARCH, null);
      })
    }
    .width('100%')
    .height(40)
    .padding({ right: 14 })
    .margin({ top: Immersive.statusBarHeight() + 6 })
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(4)
  }

  @Builder
  SearchPlain() {
    Row() {
      Blank()
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_search'))
          .width(18)
          .height(18)
          .fillColor(this.accent)
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(AppTheme.floatBg(this.isDark, this.glassOn))
      .shadow({ radius: 8, color: this.isDark ? '#59000000' : '#1A000000', offsetX: 0, offsetY: 2 })
      .opacity(this.fade)
      .scale({ x: 0.6 + 0.4 * this.fade, y: 0.6 + 0.4 * this.fade })
      .onClick(() => {
        AppNavStack.pushPathByName(NAV_SEARCH, null);
      })
    }
    .width('100%')
    .height(40)
    .padding({ right: 14 })
    .margin({ top: Immersive.statusBarHeight() + 6 })
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(4)
  }

  build() {
    Navigation(AppNavStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 系统 Tabs：三个视图常驻保活，切换不丢滚动位置
        if (AppTheme.isImmersiveUiSupported()) {
          this.FloatingTabs()
        } else {
          this.PlainTabs()
        }

        // 玻璃头栏（上滑渐隐）
        GlassHeaderBar({
          onAvatarTap: () => {
            this.switchTab(2);
          },
        })
        .zIndex(3)

        // 头栏收起后的悬浮搜索球（右上角，对齐华为设置的折叠形态：头栏淡出 → 搜索球淡入）
        // 只有真正开始显示时才创建节点；透明度为 0 的可点击节点会抢走消息按钮的事件。
        if (this.fade > 0.05) {
          if (AppTheme.isImmersiveUiSupported()) {
            this.SearchFloat()
          } else {
            this.SearchPlain()
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      // hero 转场底衬：根页被二级页 push 覆盖后不再渲染，push 前截此组件做目标页最底层
      .id(APP_ROOT_SNAPSHOT_ID)
    }
    .width('100%')
    .height('100%')
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
