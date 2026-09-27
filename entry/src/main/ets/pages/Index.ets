import { PreferencesPage } from './PreferencesPage';
import { NAV_APPEARANCE, NAV_PLAYBACK_SETTINGS } from '../common/AppRouter';
import { YouTubeView } from '../views/YouTubeView';
import { YouTubeDetailPage } from './YouTubeDetail';
import { YouTubeSavedPage } from './YouTubeSaved';
import { YouTubeVideo, YouTubeApi } from '../api/YouTubeApi';
import { NAV_YOUTUBE_DETAIL, NAV_YOUTUBE_SAVED } from '../common/AppRouter';
import { PlatformStore } from '../common/PlatformStore';
import { MotionTokens } from '../common/MotionTokens';
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
  NAV_WATCH_LATER, NAV_LIVE_ROOM, NAV_IMAGE_VIEWER, NAV_DYNAMIC_DETAIL, NAV_DOWNLOAD_CENTER,
  VideoDetailParam, UserSpaceParam, LiveRoomParam, NAV_NETWORK_PRIVACY,
  ImageViewerParam, DynamicDetailParam, NAV_RELATION_LIST, RelationListParam, NAV_BANGUMI_DETAIL,
  BangumiDetailParam, NAV_RANK, NAV_ARTICLE, ArticlePageParam, NAV_BANGUMI_LIST, NAV_BANGUMI_INDEX, NAV_ZONE,
  NAV_BLACK_LIST, NAV_LIVE_ZONE, NAV_FAV_SORT, NAV_BANGUMI_TIMELINE, HERO_NAV_TRANSITION_ACTIVE_KEY,
  HERO_NAV_TRANSITION_DURATION_KEY, HERO_NAV_TRANSITION_FINISH_REQUEST_KEY } from '../common/AppRouter';
import { SearchPage } from './Search';
import { FavSortParam } from '../common/AppRouter';
import { MessagesPage } from './Messages';
import { HistoryPage } from './library/HistoryPage';
import { WatchLaterPage } from './library/WatchLaterPage';
import { DownloadCenterPage } from './DownloadCenterPage';
import { NetworkPrivacyPage } from './NetworkPrivacyPage';
import { FavoritesPage } from './library/FavoritesPage';
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
import { UserStore } from '../services/auth/UserStore';
import { PlayerCommandBus } from '../common/PlayerCommandBus';
import { Haptic } from '../common/Haptic';
import { Handedness } from '../common/Handedness';
import { curves, display } from '@kit.ArkUI';
import { HdsTabs, DividerMode, hdsMaterial } from '@kit.UIDesignKit';

/** 悬浮 Dock 高度（vp）：与原生悬浮底栏同行（底边距屏幕 16vp）。 */
const DOCK_BAR_HEIGHT: number = 56;

/**
 * 底部悬浮 Dock：整组居中，宽度随屏宽收敛（上限 444vp）。
 */

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
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) @Watch('onMotionPreferenceChanged') reduceMotion: boolean = false;
  @State @Watch('onCurrentTabChanged') currentTab: number = 0;
  /** 宽屏分栏（实验性）：840vp 以上把推送目标页显示为右侧分栏；默认关闭保持 Stack。 */
  @StorageProp('wideSplitEnabled') wideSplitEnabled: boolean = false;
  @State windowWidthVp: number = 0;
  @StorageProp('accentColor') @Watch('onThemeChanged') accent: string = '#FB7299';
  @StorageProp('isDarkMode') @Watch('onThemeChanged') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  /** 顶层平台：哔哩哔哩 / YouTube 同级切换。切换时整块外壳替换，底栏各归其平台。 */
  @StorageProp(PlatformStore.KEY_PLATFORM) @Watch('onPlatformChanged') platform: string = PlatformStore.BILI;
  @State heroTransitionInputLocked: boolean = false;
  @State heroTransitionClock: number = 0;
  @StorageProp(HERO_NAV_TRANSITION_FINISH_REQUEST_KEY) @Watch('onHeroTransitionFinishRequested')
  heroTransitionFinishRequest: number = 0;
  private heroTransitionProxy: NavigationTransitionProxy | null = null;
  private heroTransitionToken: number = 0;
  @StorageProp('appInBackground') @Watch('onAppBackgroundChanged') appInBackground: boolean = false;
  /** 底部一行实测宽度（vp）：Dock 宽度随它收敛，窗口变化时由 onAreaChange 校准。 */
  @State dockRowWidth: number = 0;
  @StorageProp('pendingCardRevision') @Watch('consumeCardDeepLink') pendingCardRevision: number = 0;
  private cardNavigationReady: boolean = false;

  aboutToAppear(): void {
    this.onMotionPreferenceChanged();
    this.reapplyBarColors();
    UserStore.ensureLoaded();
    PlatformStore.init();
    Handedness.init();
    Handedness.setActive(!this.appInBackground);
    // 首帧先按显示宽度给 Dock 一行一个宽度初值，随后由 onAreaChange 用实测宽度校准。
    this.dockRowWidth = Index.displayWidthVp();
  }

  onAppBackgroundChanged(): void {
    Handedness.setActive(!this.appInBackground);
  }

  private onMotionPreferenceChanged(): void {
    if (this.reduceMotion) this.finishHeroNavTransition();
    AppNavStack.disableAnimation(this.reduceMotion);
  }

  aboutToDisappear(): void {
    Handedness.setActive(false);
  }

  onPageShow(): void {
    this.cardNavigationReady = true;
    this.consumeCardDeepLink();
    // 应用从后台回到前台也会触发根页 onPageShow，必须按导航栈顶重算而不是无条件套根页配色，
    // 否则播放页（黑底）上状态栏图标被刷成深色，看不清时间电量。
    this.reapplyBarColors();
  }

  /** 服务卡片「继续观看」深链：导航栈就绪后打开目标视频详情。 */
  private consumeCardDeepLink(): void {
    if (!this.cardNavigationReady) return;
    const bvid: string = AppStorage.get<string>('pendingCardBvid') ?? '';
    const aid: number = AppStorage.get<number>('pendingCardAid') ?? 0;
    if (bvid.length === 0 && aid <= 0) return;
    AppStorage.setOrCreate<string>('pendingCardBvid', '');
    AppStorage.setOrCreate<number>('pendingCardAid', 0);
    const param: VideoDetailParam = { bvid: bvid, aid: aid, title: '',
      cid: AppStorage.get<number>('pendingCardCid') ?? 0,
      epId: AppStorage.get<number>('pendingCardEpId') ?? 0,
      resumePosition: AppStorage.get<number>('pendingCardPosition') ?? 0 };
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
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

  private returnToHome(): void {
    PlayerCommandBus.stop();
    Immersive.setFullscreen(false);
    this.finishHeroNavTransition();
    AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, false);
    this.switchTab(0);
    // 根页位于 Navigation 内容区，不在路径栈中；一次清空避免中间视频页依次恢复播放。
    AppNavStack.clear(false);
    this.syncBarColors();
  }

  switchTab(index: number): void {
    this.currentTab = index;
    AppTheme.resetHeaderFade();
  }

  /**
   * 平台切换：整块外壳被替换，滚动淡出值必须复位，否则切回来头栏仍是收起态。
   * 系统栏图标按新平台的根页配色重算（YouTube 侧也是浅底玻璃头栏）。
   */
  private onPlatformChanged(): void {
    AppTheme.resetHeaderFade();
    this.reapplyBarColors();
  }

  /** 广播主 Tab 索引：「我的」页借此在切回时重算缓存大小（Tabs 保活不重走 aboutToAppear）。 */
  private onCurrentTabChanged(): void {
    // YouTube 激活时哔哩哔哩的 Tabs 没有宿主，广播会让宿主读到过期下标。
    if (this.platform === PlatformStore.YOUTUBE) return;
    AppStorage.setOrCreate('mainTabIndex', this.currentTab);
  }

  /**
   * 官方 Navigation 自定义内容转场：hero 期间同时保留 from/to 两页，由页面内的独立图片层负责移动。
   * 这取代“截一张首页图垫底”的办法，避免 push/pop 边界在真机上出现白帧或旧截图闪一下。
   */
  private finishHeroNavTransition(token?: number): void {
    if (token !== undefined && token !== this.heroTransitionToken) return;
    const proxy: NavigationTransitionProxy | null = this.heroTransitionProxy;
    this.heroTransitionProxy = null;
    AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, false);
    this.heroTransitionInputLocked = false;
    this.heroTransitionClock = 0;
    if (proxy === null) return;
    try {
      proxy.finishTransition();
    } catch (e) {
      // 系统超时已经提交转场时，重复完成会抛错；状态清理仍需保留。
    }
  }

  private onHeroTransitionFinishRequested(): void {
    this.finishHeroNavTransition();
  }

  private heroNavTransition(_from: NavContentInfo, _to: NavContentInfo,
    operation: NavigationOperation): NavigationAnimatedTransition | undefined {
    if (this.reduceMotion) return undefined;
    if (AppStorage.get<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY) !== true) return undefined;
    const duration: number = AppStorage.get<number>(HERO_NAV_TRANSITION_DURATION_KEY) ?? 360;
    // push 后目标页本身会阻断输入；pop 开始时来源页立即重新获得手势，必须额外冻结。
    this.heroTransitionInputLocked = operation === NavigationOperation.POP;
    let transitionToken: number = -1;
    return {
      timeout: duration + 240,
      onTransitionEnd: (_success: boolean): void => {
        if (transitionToken !== this.heroTransitionToken) return;
        this.heroTransitionProxy = null;
        this.heroTransitionToken++;
        AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, false);
        this.heroTransitionInputLocked = false;
        this.heroTransitionClock = 0;
      },
      transition: (proxy: NavigationTransitionProxy): void => {
        this.heroTransitionProxy = proxy;
        // 设置变更可能早于原生代理交付；迟到的转场也要立即收尾。
        if (this.reduceMotion) {
          this.finishHeroNavTransition();
          return;
        }
        const token: number = ++this.heroTransitionToken;
        transitionToken = token;
        this.heroTransitionClock = 0;
        // POP 时透明阻断层实际参与这段 UI 动画。即使页面自己的 onFinish 丢失，
        // UI 动画时钟仍会提交转场，不依赖单一 JS 定时器。
        this.getUIContext().animateTo({ duration: duration + 80, curve: Curve.Linear, onFinish: () => {
          this.finishHeroNavTransition(token);
        } }, () => {
          this.heroTransitionClock = 1;
        });
        setTimeout(() => {
          this.finishHeroNavTransition(token);
        }, duration + 120);
      },
    };
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
    if (name === NAV_APPEARANCE || name === NAV_PLAYBACK_SETTINGS) {
      NavDestination() {
        PreferencesPage({ playback: name === NAV_PLAYBACK_SETTINGS })
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_SEARCH) {
      NavDestination() {
        SearchPage()
      }
      .stdDestination(() => {
        Immersive.setBarIcons(this.isDark, this.isDark);
      }, () => {
        // 出栈回根页时没有页面级回调，提前恢复根页系统栏图标
        this.syncBarColors();
      })
      .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
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
    } else if (name === NAV_DOWNLOAD_CENTER) {
      NavDestination() {
        DownloadCenterPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_NETWORK_PRIVACY) {
      NavDestination() {
        NetworkPrivacyPage()
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_VIDEO_DETAIL) {
      NavDestination() {
        if (Index.asVideoDetailParam(param) !== null) {
          VideoDetailPage({ param: param as VideoDetailParam, onHome: () => this.returnToHome() })
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
        // 输入框或表情面板正在使用时，返回只收起输入态，不退出回复详情或视频页。
        if (AppStorage.get<boolean>('videoReplyComposerActive') ?? false) {
          const request: number = AppStorage.get<number>('videoReplyComposerCloseRequest') ?? 0;
          AppStorage.setOrCreate<number>('videoReplyComposerCloseRequest', request + 1);
          return true;
        }
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
        if (videoParam !== null && videoParam.mirrorHeroReturn !== false &&
          (videoParam.srcRect !== undefined || videoParam.cardRect !== undefined)) {
          AppStorage.setOrCreate<number>('videoDetailCloseTargetIndex', AppNavStack.size() - 1);
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
      // 看图页自己管理 hero、黑底和控件时序，容器不再额外做整页淡入淡出。
      .backgroundColor('#00000000')
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
      .backgroundColor('#00000000')
      .onBackPressed(() => {
        const dynamicParam: DynamicDetailParam | null = Index.asDynamicDetailParam(param);
        if (dynamicParam !== null && dynamicParam.srcRect !== undefined) {
          const request: number = AppStorage.get<number>('dynamicDetailCloseRequest') ?? 0;
          AppStorage.setOrCreate<number>('dynamicDetailCloseRequest', request + 1);
          return true;
        }
        return false;
      })
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
    } else if (name === NAV_YOUTUBE_SAVED) {
      NavDestination() {
        // 同一页两种模式：稍后观看 / 观看历史（都是本地列表）。
        YouTubeSavedPage({ mode: typeof param === 'string' && (param as string).length > 0 ?
          param as string : 'later' })
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
    } else if (name === NAV_YOUTUBE_DETAIL) {
      NavDestination() {
        if (param !== null && param !== undefined && YouTubeApi.validId((param as YouTubeVideo).id ?? '')) {
          YouTubeDetailPage({ param: param as YouTubeVideo })
        } else {
          this.InvalidParamContent()
        }
      }
      .stdDestination(() => Immersive.setBarIcons(this.isDark, this.isDark), () => this.syncBarColors())
      .onBackPressed(() => {
        if (AppStorage.get<boolean>('youtubePlayerFullscreen') ?? false) {
          const token: number = AppStorage.get<number>('youtubeFullscreenExitRequest') ?? 0;
          AppStorage.setOrCreate<number>('youtubeFullscreenExitRequest', token + 1);
          return true;
        }
        return false;
      })
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
  @State tabScale: Array<number> = [1, 1, 1, 1];

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
  TabBarItem(index: number, label: string, icon: Resource) {
    Column({ space: 2 }) {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.currentTab === index ? this.accent :
          (this.isDark ? '#D1D4DA' : '#62676D'))
        .scale({ x: this.tabScale[index], y: this.tabScale[index] })
        .animation({ duration: MotionTokens.duration(MotionTokens.navigation, this.reduceMotion),
          curve: this.reduceMotion ? Curve.Linear : curves.springMotion(0.35, 0.7) })
      Text(label)
        .fontSize(11)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTab === index ? (this.isDark ? '#F5F6F8' : '#24272E') :
          (this.isDark ? '#D1D4DA' : '#62676D'))
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
    // 原生 Tabs 保持三页生命周期与滚动位置，底栏独立渲染。
    Tabs({ barPosition: BarPosition.End, index: $$this.currentTab }) {
      TabContent() {
        HomeView().direction(Direction.Ltr)
      }
      .tabBar(this.TabBarItem(0, '首页', $r('app.media.ic_tab_home')))
      .clip(false)

      TabContent() {
        DynamicView().direction(Direction.Ltr)
      }
      .tabBar(this.TabBarItem(1, '动态', $r('app.media.ic_tab_dynamic')))
      .clip(false)

      TabContent() {
        MineView().direction(Direction.Ltr)
      }
      .tabBar(this.TabBarItem(2, '我的', $r('app.media.ic_tab_mine')))
      .clip(false)
    }
    .width('100%')
    .height('100%')
    .barHeight(0)
    .barOverlap(true)
    .scrollable(false)
    .animationDuration(MotionTokens.duration(MotionTokens.navigation, this.reduceMotion))
    .onChange((index: number): void => {
      this.currentTab = index;
      AppTheme.resetHeaderFade();
    })
  }

  @Builder
  PlainTabs() {
    Tabs({ barPosition: BarPosition.End, index: $$this.currentTab }) {
      TabContent() {
        HomeView()
      }
      .tabBar(this.TabBarItem(0, '首页', $r('app.media.ic_tab_home')))
      .clip(false)

      TabContent() {
        DynamicView()
      }
      .tabBar(this.TabBarItem(1, '动态', $r('app.media.ic_tab_dynamic')))
      .clip(false)

      TabContent() {
        MineView()
      }
      .tabBar(this.TabBarItem(2, '我的', $r('app.media.ic_tab_mine')))
      .clip(false)
    }
    .barHeight(52)
    .barOverlap(true)
    // 顶层首页/动态/我的只通过底部 Dock 切换，不响应左右滑动；
    // 左右滑动留给各页面内部的频道 Tabs（首页推荐/热门/直播，动态全部/视频/番剧）。
    .scrollable(false)
    .barBackgroundColor(AppTheme.floatBg(this.isDark, this.glassOn))
    .animationDuration(MotionTokens.duration(MotionTokens.navigation, this.reduceMotion))
    .animationMode(AnimationMode.CONTENT_FIRST)
    .onChange(() => {
      AppTheme.resetHeaderFade();
    })
  }

  /** 宽屏分栏是否生效：开关打开且实测窗口宽度 >= 840vp。 */
  private splitActive(): boolean {
    return this.wideSplitEnabled && this.windowWidthVp >= 840;
  }

  /** 显示宽度（vp）：Dock 一行的位移初值，避免首帧把搜索入口贴到错误一侧。 */
  private static displayWidthVp(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      return info.densityPixels > 0 ? info.width / info.densityPixels : 0;
    } catch (e) {
      return 0;
    }
  }

  private dockBarWidth(): number {
    // 三个条目的紧凑胶囊：不随屏宽拉满，上限 280vp。
    return Math.min(280, Math.max(0, this.dockRowWidth - 32));
  }

  @Builder
  DockNavigation() {
    HdsTabs({ barPosition: BarPosition.End, index: this.currentTab }) {
      TabContent() {}.tabBar(this.TabBarItem(0, '首页', $r('app.media.ic_tab_home')))
      TabContent() {}.tabBar(this.TabBarItem(1, '动态', $r('app.media.ic_tab_dynamic')))
      TabContent() {}.tabBar(this.TabBarItem(2, '我的', $r('app.media.ic_tab_mine')))
    }
    .width(this.dockBarWidth())
    .height(DOCK_BAR_HEIGHT)
    .clip(false)
    .barHeight(DOCK_BAR_HEIGHT)
    .divider({ mode: DividerMode.NONE })
    .barOverlap(true)
    .scrollable(false)
    .barFloatingStyle({
      barWidth: { smallWidth: this.dockBarWidth(), mediumWidth: this.dockBarWidth(), largeWidth: this.dockBarWidth() },
      barSideMargin: 0,
      barBottomMargin: 0,
      gradientMask: { maskColor: Color.Transparent, maskHeight: 0 },
      // 最薄档 IMMERSIVE：真玻璃质感，内容透过得清晰（对齐应用商店底栏）。
      systemMaterialEffect: {
        materialType: this.glassOn ? hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.NONE,
        // 最薄档：真玻璃质感，内容透过得清晰（对齐应用商店底栏）。
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
      },
    })
    .barBackgroundColor(this.glassOn ? Color.Transparent : AppTheme.floatBg(this.isDark, false))
    .onChange((index: number): void => { this.currentTab = index; })
  }

  /** 底部悬浮 Dock：真玻璃胶囊（不再垫背景模糊，内容直达 Dock 边缘）。 */
  @Builder
  DockSearchEntry() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column() {
        if (AppTheme.isImmersiveUiSupported()) {
          Column() {
            this.DockNavigation()
          }
          .width(this.dockBarWidth())
          // 浅色保持透明，避免白色底衬遮住原生沉浸光感的背景采样；深色沿用原有对比度底衬。
          .backgroundColor(this.glassOn && this.isDark ? '#CC101114' : Color.Transparent)
          .borderRadius(DOCK_BAR_HEIGHT / 2)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: 28 })
      .hitTestBehavior(HitTestMode.Transparent)
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        const width: number = Number(newValue.width);
        if (!Number.isNaN(width) && width > 0 && width !== this.dockRowWidth) {
          this.dockRowWidth = width;
        }
      })
    }
    .width('100%').height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .zIndex(4)
  }

  build() {
    Stack() {
      Navigation(AppNavStack) {
        Stack({ alignContent: Alignment.TopStart }) {
        if (this.platform === PlatformStore.YOUTUBE) {
          // YouTube 是同级平台：自带外壳，不使用哔哩哔哩的 Dock 与头栏。
          YouTubeView()
        } else {
        // 系统 Tabs：三个视图常驻保活，切换不丢滚动位置
        if (AppTheme.isImmersiveUiSupported()) {
          this.FloatingTabs()
        } else {
          this.PlainTabs()
        }

        // 玻璃头栏（上滑渐隐）
        GlassHeaderBar({
          backdropInContent: this.currentTab !== 2,
          onAvatarTap: () => {
            this.switchTab(2);
          },
        })
        .zIndex(3)

        // 底部悬浮 Dock：光感遮罩 + 居中导航胶囊（搜索走首页顶部胶囊，Dock 不再放搜索钮）。
        this.DockSearchEntry()
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
      .id('bili_main_navigation')
      .hideTitleBar(true)
      .mode(this.splitActive() ? NavigationMode.Split : NavigationMode.Stack)
      .navBarWidth('46%')
      .navDestination(this.PageMap)
      .customNavContentTransition((from: NavContentInfo, to: NavContentInfo, operation: NavigationOperation) =>
        this.heroNavTransition(from, to, operation))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        const width: number = Number(newValue.width);
        if (Number.isFinite(width) && width > 0 && width !== this.windowWidthVp) {
          this.windowWidthVp = width;
        }
      })

      if (this.heroTransitionInputLocked) {
        // Navigation 在 pop 开始后会立即让来源页重新成为输入目标；透明阻断层覆盖完整
        // 转场时段，防止用户快速上下滑让列表在图片飞行途中改变目标位置。
        Column()
          .width('100%')
          .height('100%')
          .opacity(1 - this.heroTransitionClock * 0.001)
          .hitTestBehavior(HitTestMode.Block)
          .zIndex(1000)
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
