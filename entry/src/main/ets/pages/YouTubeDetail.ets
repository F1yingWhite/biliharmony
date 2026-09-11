import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { YouTubeApi, YouTubeVideo } from '../api/YouTubeApi';
import { PageHeader } from '../components/PageHeader';
import { AppNavStack } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { RequestEpoch } from '../common/RequestEpoch';
import { youtubePlayerHtml, youtubePlaybackError, YOUTUBE_PLAYER_ORIGIN } from '../common/YouTubePlayerHtml';

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
  private controller: webview.WebviewController = new webview.WebviewController();
  private request: RequestEpoch = new RequestEpoch();
  private exitHandler: FullScreenExitHandler | null = null;
  private readyTimer: number = -1;
  private attached: boolean = false;
  private initialPageLoaded: boolean = false;

  aboutToAppear(): void {
    AppStorage.setOrCreate<boolean>('youtubePlayerFullscreen', false);
    this.video = this.param;
    this.loadDetail();
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
    } catch (e) {
      if (this.request.isCurrent(token)) this.detailError = (e as Error).message || '详情加载失败';
    } finally {
      if (this.request.isCurrent(token)) this.detailLoading = false;
    }
  }

  private loadPlayer(): void {
    this.clearTimer();
    this.playerError = '';
    this.playerLoading = true;
    try {
      this.controller.loadData(youtubePlayerHtml(this.param.id), 'text/html', 'UTF-8', YOUTUBE_PLAYER_ORIGIN + '/');
    } catch (_) {
      this.playerTitle('YT_NETWORK_ERROR');
      return;
    }
    this.readyTimer = setTimeout(() => {
      this.readyTimer = -1;
      this.playerLoading = false;
      this.playerError = '播放器加载较慢，请检查网络后重试';
    }, 25000);
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
      Web({ src: 'about:blank', controller: this.controller })
        .id('youtube-player').width('100%').height(this.fullscreen ? '100%' : 240)
        .javaScriptAccess(true).domStorageAccess(true).mediaPlayGestureAccess(true)
        .backgroundColor('#000000')
        .onControllerAttached(() => { this.attached = true; this.loadPlayer(); })
        .onPageEnd((event) => {
          // 初始 about:blank 导航可能晚于 onControllerAttached，不能让它覆盖播放器文档。
          if (event.url === 'about:blank' && !this.initialPageLoaded) {
            this.initialPageLoaded = true;
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
      if (!this.fullscreen) {
        Scroll() {
          Column({ space: 16 }) {
            if (this.playerLoading) Text('正在连接 YouTube 播放器…').fontSize(13).fontColor('#888888')
            if (this.playerError.length > 0) {
              Text(this.playerError).fontSize(14).fontColor(this.isDark ? '#FFAAAA' : '#B3261E')
              Button('重试播放').onClick(() => this.loadPlayer())
            }
            Text(this.video.title || 'YouTube 视频').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
              .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
            Text(this.video.channel).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
              .fontColor(this.isDark ? '#DDDDDD' : '#333333')
            Text([this.video.views, this.video.published, this.video.duration].filter((v: string) => v.length > 0).join(' · '))
              .fontSize(12).fontColor('#888888').width('100%')
            Button('在 YouTube 打开').fontSize(14).onClick(() => this.openYouTube())
            if (this.detailLoading) LoadingProgress().width(24).height(24)
            if (this.detailError.length > 0) {
              Text('详情加载受限：' + this.detailError).fontSize(13).fontColor('#888888').width('100%')
              Button('重试详情').onClick(() => this.loadDetail())
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
