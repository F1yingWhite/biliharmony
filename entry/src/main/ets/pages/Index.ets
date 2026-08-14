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
import { AppNavStack, NAV_SEARCH, NAV_VIDEO_DETAIL, NAV_LOGIN, NAV_USER_SPACE, NAV_MESSAGES, NAV_HISTORY, NAV_FAVORITES,
  NAV_LIVE_ROOM, NAV_IMAGE_VIEWER, VideoDetailParam, UserSpaceParam, LiveRoomParam, ImageViewerParam } from '../common/AppRouter';
import { SearchPage } from './Search';
import { MessagesPage } from './Messages';
import { FavoritesPage, HistoryPage } from './LibraryPages';
import { VideoDetailPage } from './VideoDetail';
import { LoginPage } from './Login';
import { UserSpacePage } from './UserSpace';
import { LiveRoomPage } from './LiveRoom';
import { ImageViewerPage } from './ImageViewer';
import { UserStore } from '../common/UserStore';
import { PlayerCommandBus } from '../common/PlayerCommandBus';

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
  @State currentTab: number = 0;
  @StorageProp('accentColor') @Watch('onThemeChanged') accent: string = '#FB7299';
  @StorageProp('isDarkMode') @Watch('onThemeChanged') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('glassLevel') glassLevel: number = 1;
  @StorageProp('headerFade') fade: number = 0;

  aboutToAppear(): void {
    this.syncBarColors();
    UserStore.ensureLoaded();
  }

  onPageShow(): void {
    this.syncBarColors();
  }

  onThemeChanged(): void {
    this.syncBarColors();
  }

  syncBarColors(): void {
    // 根页顶部为玻璃头栏：浅色背景配深色图标，深色模式配浅色图标
    Immersive.setBarIcons(this.isDark, this.isDark);
  }

  switchTab(index: number): void {
    this.currentTab = index;
    AppTheme.resetHeaderFade();
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
    } else if (name === NAV_VIDEO_DETAIL) {
      NavDestination() {
        if (Index.asVideoDetailParam(param) !== null) {
          VideoDetailPage({ param: param as VideoDetailParam })
        } else {
          this.InvalidParamContent()
        }
      }
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
          AppStorage.setOrCreate<boolean>('videoReplyThreadOpen', false);
          return true;
        }
        // 横屏播放器仍处于全屏时，侧滑/返回键只退出全屏，不把整个视频页出栈。
        if (AppStorage.get<boolean>('videoPlayerFullscreen') ?? false) {
          PlayerCommandBus.exitFullscreen();
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

  @Builder
  TabBarItem(index: number, label: string, icon: Resource, activeIcon: Resource) {
    Column({ space: 2 }) {
      Image(this.currentTab === index ? activeIcon : icon)
        .width(24)
        .height(24)
        .fillColor(this.currentTab === index ? this.accent : (this.isDark ? '#8A8A8E' : '#9499A0'))
      Text(label)
        .fontSize(10)
        .fontColor(this.currentTab === index ? this.accent : (this.isDark ? '#8A8A8E' : '#9499A0'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Navigation(AppNavStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 系统 Tabs：三个视图常驻保活，切换不丢滚动位置
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
        // 原生悬浮式 Dock 底栏 + 沉浸光感材质（API 26+；关闭玻璃时退化为实底背板）
        .barFloatingStyle({
          barSideMargin: 16,
          barBottomMargin: 16,
          systemMaterial: AppTheme.floatMaterial(this.glassOn, this.glassLevel),
        })
        // 深色模式给原生玻璃叠一层深色吸收底，避免系统材质在 Dock 上泛成白雾。
        .barBackgroundColor(this.glassOn ? (this.isDark ? '#B315161A' : '#00000000') : AppTheme.floatBg(this.isDark, false))
        .onChange(() => {
          AppTheme.resetHeaderFade();
        })

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
            .systemMaterial(AppTheme.floatMaterial(this.glassOn, this.glassLevel))
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
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
