import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { YouTubeApi, YouTubeVideo } from '../api/YouTubeApi';
import { PageHeader } from '../components/PageHeader';
import { AppNavStack } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { RequestEpoch } from '../common/RequestEpoch';
import { youtubeFullscreenProbeHtml, youtubePlayerHtml, youtubePlaybackError,
  YOUTUBE_PLAYER_ORIGIN } from '../common/YouTubePlayerHtml';
import { AppTheme } from '../common/AppTheme';
import { MotionTokens } from '../common/MotionTokens';
import { RemoteAssetCache } from '../services/cache/RemoteAssetCache';

@Component
export struct YouTubeDetailPage {
  param: YouTubeVideo = new YouTubeVideo();
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('windowStatusBarHeight') statusInset: number = 0;
  @StorageProp('appInBackground') @Watch('onBackgroundChanged') inBackground: boolean = false;
  @StorageProp('youtubeFullscreenExitRequest') @Watch('onExitRequested') exitRequest: number = 0;
  @State video: YouTubeVideo = new YouTubeVideo();
  @State detailLoading: boolean = true;
  @State detailError: string = '';
  @State playerError: string = '';
  @State playerLoading: boolean = true;
  @State fullscreen: boolean = false;
  /** 播放器就绪前的海报：复用列表已经缓存的同一张封面，避免一块纯黑。 */
  @State coverUri: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private request: RequestEpoch = new RequestEpoch();
  private exitHandler: FullScreenExitHandler | null = null;
  private readyTimer: number = -1;
  private attached: boolean = false;
  private initialPageLoaded: boolean = false;

  aboutToAppear(): void {
    AppStorage.setOrCreate<boolean>('youtubePlayerFullscreen', false);
    this.video = this.param;
    this.primeCover();
    this.loadDetail();
  }

  /**
   * 海报图：与列表走同一条可配代理的缓存管线（ArkUI Image() 不读应用代理），
   * 命中磁盘时首帧就有；粘贴链接直接进详情时这里负责下载。
   */
  private primeCover(): void {
    const url: string = this.video.thumbnail;
    if (url.length === 0) return;
    const cached: string = RemoteAssetCache.cachedThumbnail(url);
    if (cached !== url) {
      this.coverUri = cached;
      return;
    }
    if (this.coverUri.length > 0) return;
    RemoteAssetCache.ensureThumbnail(url).then((local: string) => {
      if (local !== url && this.video.thumbnail === url) this.coverUri = local;
    }).catch(() => {
      // 拿不到海报不是致命问题：播放器该显示什么还显示什么。
    });
  }

  aboutToDisappear(): void {
    this.request.invalidate();
    AppStorage.setOrCreate<boolean>('youtubePlayerFullscreen', false);
    this.clearTimer();
    this.pause();
    try { this.controller.loadUrl('about:blank'); } catch (_) {}
    if (this.fullscreen) Immersive.setFullscreen(false);
    Immersive.setKeepScreenOn(false);
  }

  private clearTimer(): void {
    if (this.readyTimer >= 0) clearTimeout(this.readyTimer);
    this.readyTimer = -1;
  }

  private pause(): void {
    if (!this.attached) return;
    try { this.controller.runJavaScript('pauseVideo()').catch(() => {}); } catch (_) {}
    Immersive.setKeepScreenOn(false);
  }

  private onBackgroundChanged(): void { if (this.inBackground) this.pause(); }

  private async loadDetail(): Promise<void> {
    const token: number = this.request.next();
    this.detailLoading = true;
    this.detailError = '';
    try {
      const result: YouTubeVideo = await YouTubeApi.detail(this.param.id);
      if (this.request.isCurrent(token)) this.video = result;
      // 详情返回后再试一次：粘贴链接进详情时参数里没有封面。
      if (this.request.isCurrent(token)) this.primeCover();
    } catch (e) {
      if (this.request.isCurrent(token)) this.detailError = (e as Error).message || '详情加载失败';
    } finally {
      if (this.request.isCurrent(token)) this.detailLoading = false;
    }
  }

  private playerLoaded: boolean = false;

  private loadPlayer(): void {
    // 代理下发回调与 onControllerAttached 都可能触发加载；重复导航会白白打断播放器。
    // Web 组件刚挂上控制器时还不能接受 loadData，等 attached 置位后再导航。
    if (this.playerLoaded || !this.attached) return;
    this.playerLoaded = true;
    this.clearTimer();
    this.playerError = '';
    this.playerLoading = true;
    try {
      // ytPlayerProbe 是 QA 开关（默认关）：只加载一个全屏按钮页，用于验证全屏/返回联动。
      const probe: boolean = AppStorage.get<boolean>('ytPlayerProbe') === true;
      this.controller.loadData(probe ? youtubeFullscreenProbeHtml() : youtubePlayerHtml(this.param.id),
        'text/html', 'UTF-8', YOUTUBE_PLAYER_ORIGIN + '/');
    } catch (_) {
      this.playerLoaded = false;
      this.playerTitle('YT_NETWORK_ERROR');
      return;
    }
    this.readyTimer = setTimeout(() => {
      this.readyTimer = -1;
      this.playerLoading = false;
      this.playerError = '播放器加载较慢，请检查网络后重试';
    }, 25000);
  }

  /** 「重试播放」需要允许重新导航，因此先复位 loadPlayer 的去重标记。 */
  private retryPlayer(): void {
    this.playerLoaded = false;
    this.initialPageLoaded = false;
    this.loadPlayer();
  }

  private playerTitle(title: string): void {
    if (title === 'YT_READY' || title.startsWith('YT_STATE_')) {
      this.clearTimer();
      this.playerLoading = false;
      this.playerError = '';
      Immersive.setKeepScreenOn(title === 'YT_STATE_1' && !this.inBackground);
      if (this.inBackground) this.pause();
    }
    const error: string = youtubePlaybackError(title);
    if (error.length > 0) {
      this.clearTimer();
      this.playerLoading = false;
      this.playerError = error;
      Immersive.setKeepScreenOn(false);
    }
  }

  private async openYouTube(): Promise<void> {
    this.pause();
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.openLink('https://www.youtube.com/watch?v=' + this.param.id);
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开 YouTube，请检查浏览器' });
    }
  }

  private onExitRequested(): void {
    if (this.fullscreen && this.exitHandler !== null) this.exitHandler.exitFullScreen();
  }

  private back(): void {
    if (this.fullscreen && this.exitHandler !== null) this.exitHandler.exitFullScreen();
    else AppNavStack.pop();
  }

  build() {
    Column() {
      if (!this.fullscreen) PageHeader({ title: 'YouTube', onBack: () => this.back() })
      Stack() {
        Web({ src: 'about:blank', controller: this.controller })
        .id('youtube-player').width('100%').height('100%')
        .javaScriptAccess(true).domStorageAccess(true).mediaPlayGestureAccess(true)
        .backgroundColor('#000000')
        .onControllerAttached(() => { this.attached = true; this.loadPlayer(); })
        .onPageEnd((event) => {
          // 初始 about:blank 导航会晚于 onControllerAttached 到达，并把已经开始的
          // loadData 文档 abort 掉（ArkWeb 日志：ERR_ABORTED url:data:text/***）。
          // 因此这里必须复位去重标记后重新导航，否则播放器永远停在 about:blank。
          if (event.url === 'about:blank' && !this.initialPageLoaded) {
            this.initialPageLoaded = true;
            this.playerLoaded = false;
            this.loadPlayer();
          }
        })
        .onTitleReceive((event) => { this.playerTitle(event.title); })
        .onErrorReceive((event) => {
          if (event.request.isMainFrame()) this.playerTitle('YT_NETWORK_ERROR');
        })
        .onRenderExited(() => { this.playerTitle('YT_NETWORK_ERROR'); })
        .onFullScreenEnter((event) => {
          this.exitHandler = event.handler;
          this.fullscreen = true;
          AppStorage.setOrCreate<boolean>('youtubePlayerFullscreen', true);
          Immersive.setFullscreen(true);
        })
        .onFullScreenExit(() => {
          this.fullscreen = false;
          AppStorage.setOrCreate<boolean>('youtubePlayerFullscreen', false);
          this.exitHandler = null;
          Immersive.setFullscreen(false);
          Immersive.setBarIcons(this.isDark, this.isDark);
        })
        // 播放器就绪前用封面当海报：ArkWeb 起播要一两秒，纯黑块看起来像坏了。
        // 一旦播放器给出就绪/错误信号就撤掉，不挡住 YouTube 自己的界面。
        if (this.playerLoading && this.coverUri.length > 0) {
          Image(this.coverUri)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .backgroundColor('#000000')
            .hitTestBehavior(HitTestMode.None)
            .transition(MotionTokens.appear())
        }
      }
      .width('100%').height(this.fullscreen ? '100%' : 240)
      .backgroundColor('#000000')
      if (!this.fullscreen) {
        Scroll() {
          Column({ space: 16 }) {
            if (this.playerLoading) Text('正在连接 YouTube 播放器…').fontSize(13).fontColor('#888888')
            if (this.playerError.length > 0) {
              Text(this.playerError).fontSize(14).fontColor(this.isDark ? '#FFAAAA' : '#B3261E')
              // 次级按钮沿用 YouTube「我的」页的胶囊规格，不用系统默认蓝。
              Button('重试播放')
                .fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C')
                .height(36).padding({ left: 18, right: 18 }).borderRadius(18)
                .backgroundColor(this.isDark ? '#2B2D34' : '#F0F1F3')
                .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
                .onClick(() => this.retryPlayer())
            }
            Text(this.video.title || 'YouTube 视频').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
              .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            Text(this.video.channel).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
              .fontColor(this.isDark ? '#DDDDDD' : '#333333')
            Text([this.video.views, this.video.published, this.video.duration].filter((v: string) => v.length > 0).join(' · '))
              .fontSize(12).fontColor('#888888').width('100%')
            // 主按钮取 YouTube 侧强调色（与外壳搜索按钮同规格），系统默认蓝不属于任何一个平台。
            Button('在 YouTube 打开')
              .fontSize(14).fontColor('#FFFFFF')
              .height(36).padding({ left: 18, right: 18 }).borderRadius(18)
              .backgroundColor(AppTheme.DANGER)
              .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
              .onClick(() => this.openYouTube())
            if (this.detailLoading) LoadingProgress().width(24).height(24)
            if (this.detailError.length > 0) {
              Text('详情加载受限：' + this.detailError).fontSize(13).fontColor('#888888').width('100%')
              Button('重试详情')
                .fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C')
                .height(36).padding({ left: 18, right: 18 }).borderRadius(18)
                .backgroundColor(this.isDark ? '#2B2D34' : '#F0F1F3')
                .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
                .onClick(() => this.loadDetail())
            }
            if (this.video.description.length > 0) {
              Text(this.video.description).fontSize(14).lineHeight(22).width('100%')
                .copyOption(CopyOptions.LocalDevice).fontColor(this.isDark ? '#CCCCCC' : '#555555')
            }
          }.width('100%').padding(18).alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%')
      .padding({ top: this.fullscreen ? 0 : this.statusInset, bottom: this.fullscreen ? 0 : Immersive.bottomInset() })
      .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
