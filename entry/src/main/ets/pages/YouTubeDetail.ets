import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { YouTubeApi, YouTubeComment, YouTubeCommentPage, YouTubeWatchPage, YouTubeVideo } from '../api/YouTubeApi';
import { PageHeader } from '../components/PageHeader';
import { AppNavStack, NAV_YOUTUBE_DETAIL } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { RequestEpoch } from '../common/RequestEpoch';
import { youtubeFullscreenProbeHtml, youtubePlayerHtml, youtubePlaybackError,
  YOUTUBE_PLAYER_ORIGIN } from '../common/YouTubePlayerHtml';
import { AppTheme } from '../common/AppTheme';
import { MotionTokens } from '../common/MotionTokens';
import { RemoteAssetCache } from '../services/cache/RemoteAssetCache';
import { systemShare } from '@kit.ShareKit';
import { pasteboard } from '@kit.BasicServicesKit';

/**
 * YouTube 视频详情页。
 *
 * 结构与哔哩哔哩详情页对齐（播放器 + 「简介 / 评论」双 Tab，相关推荐放在简介底部），
 * 但**不复用** B 站那套与 aid/bvid/弹幕/账号强耦合的组件：数据模型不同，
 * 复用会把 B 站回归风险抬高（见 docs/HANDOFF_MAC_2026-09-11.md 第四节）。
 *
 * 游客边界：只读公开数据。没有账号就没有点赞/投币/收藏/发评论，因此这里不摆这些入口，
 * 只保留「在 YouTube 打开」与系统分享之外的说明。
 */
@Component
export struct YouTubeDetailPage {
  param: YouTubeVideo = new YouTubeVideo();
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('windowStatusBarHeight') statusInset: number = 0;
  @StorageProp('appInBackground') @Watch('onBackgroundChanged') inBackground: boolean = false;
  @StorageProp('youtubeFullscreenExitRequest') @Watch('onExitRequested') exitRequest: number = 0;
  @State video: YouTubeVideo = new YouTubeVideo();
  @State related: Array<YouTubeVideo> = [];
  @State detailLoading: boolean = true;
  @State detailError: string = '';
  @State playerError: string = '';
  @State playerLoading: boolean = true;
  @State fullscreen: boolean = false;
  /** 播放器就绪前的海报：复用列表已经缓存的同一张封面，避免一块纯黑。 */
  @State coverUri: string = '';
  @State tab: number = 0;
  @State commentToken: string = '';
  @State commentTotal: string = '';
  @State comments: Array<YouTubeComment> = [];
  @State commentsLoading: boolean = false;
  @State commentsLoaded: boolean = false;
  @State commentsError: string = '';
  @State commentsMoreLoading: boolean = false;
  @State commentMoreError: string = '';
  /** 远程图片（相关推荐封面、频道头像、评论头像）→ 本地文件；Image() 不读应用代理。 */
  @State imageLocal: Map<string, string> = new Map<string, string>();
  private controller: webview.WebviewController = new webview.WebviewController();
  private request: RequestEpoch = new RequestEpoch();
  private commentRequest: RequestEpoch = new RequestEpoch();
  private commentScroller: Scroller = new Scroller();
  private exitHandler: FullScreenExitHandler | null = null;
  private readyTimer: number = -1;
  private attached: boolean = false;
  private initialPageLoaded: boolean = false;
  private playerLoaded: boolean = false;

  aboutToAppear(): void {
    AppStorage.setOrCreate<boolean>('youtubePlayerFullscreen', false);
    this.video = this.param;
    this.primeCover();
    this.loadDetail();
  }

  aboutToDisappear(): void {
    this.request.invalidate();
    this.commentRequest.invalidate();
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

  private onExitRequested(): void {
    if (this.fullscreen && this.exitHandler !== null) this.exitHandler.exitFullScreen();
  }

  private back(): void {
    if (this.fullscreen && this.exitHandler !== null) this.exitHandler.exitFullScreen();
    else AppNavStack.pop();
  }

  // ===== 图片：与列表同一条可配代理的缓存管线 =====

  /**
   * 海报图：ArkUI Image() 走系统网络栈，不读应用代理，因此统一先落盘再渲染。
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

  private localImage(url: string): string {
    if (url.length === 0) return url;
    const local: string | undefined = this.imageLocal.get(url);
    return local !== undefined && local.length > 0 ? local : url;
  }

  /** 两段式：先认磁盘命中，未命中的再经应用 HTTP 栈下载；同一 URL 只下一次。 */
  private primeImages(urls: Array<string>): void {
    const hits: Map<string, string> = new Map<string, string>();
    const pending: Array<string> = [];
    for (const url of urls) {
      if (url.length === 0 || this.imageLocal.has(url) || hits.has(url)) continue;
      const cached: string = RemoteAssetCache.cachedThumbnail(url);
      if (cached !== url) hits.set(url, cached);
      else pending.push(url);
    }
    if (hits.size > 0) {
      const merged: Map<string, string> = new Map<string, string>(this.imageLocal);
      hits.forEach((value: string, key: string) => merged.set(key, value));
      this.imageLocal = merged;
    }
    for (const url of pending) this.downloadImage(url);
  }

  private downloadImage(url: string): void {
    RemoteAssetCache.ensureThumbnail(url).then((local: string) => {
      if (local === url || this.imageLocal.get(url) === local) return;
      const next: Map<string, string> = new Map<string, string>(this.imageLocal);
      next.set(url, local);
      this.imageLocal = next;
    }).catch(() => {
      // 失败保持远端 URL，交给 Image 自己的占位逻辑。
    });
  }

  // ===== 数据 =====

  private async loadDetail(): Promise<void> {
    const token: number = this.request.next();
    this.detailLoading = true;
    this.detailError = '';
    try {
      const page: YouTubeWatchPage = await YouTubeApi.detailPage(this.param.id);
      if (!this.request.isCurrent(token)) return;
      this.video = page.video;
      this.related = page.related;
      this.commentToken = page.commentToken;
      this.primeCover();
      const urls: Array<string> = [];
      if (page.video.channelAvatar.length > 0) urls.push(page.video.channelAvatar);
      for (const item of page.related) urls.push(item.thumbnail);
      this.primeImages(urls);
      // 评论默认不抢先加载：用户不点「评论」就不发这次请求。
      if (this.tab === 1) this.ensureComments();
    } catch (e) {
      if (this.request.isCurrent(token)) this.detailError = (e as Error).message || '详情加载失败';
    } finally {
      if (this.request.isCurrent(token)) this.detailLoading = false;
    }
  }

  private commentTabLabel(): string {
    return this.commentTotal.length > 0 ? '评论 ' + this.commentTotal : '评论';
  }

  /** 首次切到评论 Tab 才请求，之后由失败重试或触底加载驱动。 */
  private ensureComments(): void {
    if (this.commentsLoaded || this.commentsLoading) return;
    if (this.commentToken.length === 0) {
      this.commentsLoaded = true;
      return;
    }
    this.loadComments();
  }

  private loadComments(): void {
    const token: number = this.commentRequest.next();
    this.commentsLoading = true;
    this.commentsError = '';
    this.comments = [];
    YouTubeApi.comments(this.commentToken).then((page: YouTubeCommentPage) => {
      if (!this.commentRequest.isCurrent(token)) return;
      this.comments = page.comments;
      this.commentToken = page.continuation;
      if (page.total.length > 0) this.commentTotal = page.total;
      this.commentsLoaded = true;
      const urls: Array<string> = [];
      for (const comment of page.comments) urls.push(comment.avatar);
      this.primeImages(urls);
    }).catch((e: Object) => {
      if (!this.commentRequest.isCurrent(token)) return;
      this.commentsError = (e as Error).message || '评论加载失败，请重试';
    }).finally(() => {
      if (this.commentRequest.isCurrent(token)) this.commentsLoading = false;
    });
  }

  /** 触底加载下一页评论；失败保留已有列表，只在底部提示。 */
  private loadMoreComments(): void {
    if (this.commentsLoading || this.commentsMoreLoading) return;
    if (this.commentMoreError.length > 0 || this.commentToken.length === 0) return;
    const request: number = this.commentRequest.next();
    const token: string = this.commentToken;
    this.commentsMoreLoading = true;
    YouTubeApi.comments(token).then((page: YouTubeCommentPage) => {
      if (!this.commentRequest.isCurrent(request)) return;
      const seen: Set<string> = new Set<string>();
      const merged: Array<YouTubeComment> = [];
      for (const comment of this.comments) {
        seen.add(comment.id);
        merged.push(comment);
      }
      for (const comment of page.comments) {
        if (seen.has(comment.id)) continue;
        seen.add(comment.id);
        merged.push(comment);
      }
      this.comments = merged;
      this.commentToken = page.continuation;
      const urls: Array<string> = [];
      for (const comment of page.comments) urls.push(comment.avatar);
      this.primeImages(urls);
    }).catch((e: Object) => {
      if (!this.commentRequest.isCurrent(request)) return;
      this.commentMoreError = (e as Error).message || '加载更多评论失败';
    }).finally(() => {
      if (this.commentRequest.isCurrent(request)) this.commentsMoreLoading = false;
    });
  }

  private openRelated(video: YouTubeVideo): void {
    AppNavStack.pushPathByName(NAV_YOUTUBE_DETAIL, video);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 组件销毁后调用会抛异常，忽略。
    }
  }

  private async openYouTube(): Promise<void> {
    this.pause();
    // 官方客户端/Premium 的离线下载是唯一合规的离线路径，这里只负责把用户送过去。
    const url: string = YouTubeApi.watchUrl(this.param.id);
    if (url.length === 0) {
      this.toast('视频链接无效');
      return;
    }
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.openLink(url);
    } catch (_) {
      this.toast('无法打开 YouTube，请检查浏览器');
    }
  }

  /** 系统分享：与 B 站详情页同一套 ShareKit，只分享规范链接与标题，不涉及媒体流。 */
  private shareVideo(): void {
    const url: string = YouTubeApi.watchUrl(this.param.id);
    if (url.length === 0) {
      this.toast('视频链接无效，无法分享');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      this.toast('无法打开系统分享');
      return;
    }
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: 'general.hyperlink',
      title: this.video.title.length > 0 ? this.video.title : 'YouTube 视频',
      content: url,
      description: this.video.channel,
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL }).catch((error: Error) => {
      this.toast('分享失败：' + error.message);
    });
  }

  private copyLink(): void {
    const url: string = YouTubeApi.watchUrl(this.param.id);
    if (url.length === 0) {
      this.toast('视频链接无效');
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast('链接已复制');
    }).catch(() => {
      this.toast('复制失败');
    });
  }

  // ===== 播放器 =====

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

  // ===== UI =====

  /** 标签规格与 B 站详情页 DetailToolbar 的 CompactDetailTab 一致，强调色换成 YouTube 红。 */
  @Builder
  CompactDetailTab(label: string, index: number) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(this.tab === index ? 15 : 14)
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? (this.isDark ? '#F1F2F3' : '#18191C') : '#9499A0')
        .animation({ duration: 140, curve: Curve.EaseOut })
      Row()
        .width(20).height(3).borderRadius(1.5)
        .backgroundColor(AppTheme.DANGER)
        .opacity(this.tab === index ? 1 : 0)
        .scale({ x: this.tab === index ? 1 : 0.35, y: 1 })
        .animation({ duration: 140, curve: Curve.EaseOut })
    }
    .height(40)
    .padding({ left: 9, right: 9 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.tab = index;
      if (index === 1) this.ensureComments();
    })
  }

  /** 频道行：对齐 B 站 UP 行（头像 + 名称 + 数据 + 右侧主按钮）。 */
  @Builder
  ChannelRow() {
    Row({ space: 10 }) {
      Image(this.video.channelAvatar.length > 0 ? this.localImage(this.video.channelAvatar) : $r('app.media.ic_youtube'))
        .width(40).height(40)
        .borderRadius(20)
        .objectFit(ImageFit.Cover)
        .backgroundColor(this.isDark ? '#2A2C31' : '#E5E7EB')
        .draggable(false)
        .syncLoad(false)
      Column({ space: 3 }) {
        Text(this.video.channel.length > 0 ? this.video.channel : 'YouTube 频道')
          .fontSize(15).fontWeight(FontWeight.Medium).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.isDark ? '#F1F2F3' : '#18191C')
        if (this.video.subscribers.length > 0) {
          Text(this.video.subscribers).fontSize(12).fontColor('#9499A0').maxLines(1)
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('在 YouTube 打开')
        .fontSize(12).fontColor('#FFFFFF')
        .height(32).padding({ left: 14, right: 14 })
        .borderRadius(16)
        .backgroundColor(AppTheme.DANGER)
        .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
        .onClick(() => this.openYouTube())
    }
    .width('100%').alignItems(VerticalAlign.Center)
  }

  /** 次级动作胶囊：与「我的」页说明按钮同规格；强调色只留给主按钮。 */
  @Builder
  QuietAction(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
      .height(32).padding({ left: 14, right: 14 })
      .borderRadius(16)
      .backgroundColor(this.isDark ? '#2B2D34' : '#F0F1F3')
      .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
      .onClick(action)
  }

  /** 相关推荐单行：与 B 站 RelatedVideoRow 同构（封面 120×68 + 标题两行 + 频道/数据）。 */
  @Builder
  RelatedRow(video: YouTubeVideo) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.localImage(video.thumbnail))
          .width(120).height(68)
          .objectFit(ImageFit.Cover)
          .borderRadius(6)
          .backgroundColor(this.isDark ? '#2A2C31' : '#E5E7EB')
          .draggable(false).syncLoad(false)
        if (video.duration.length > 0) {
          Text(video.duration)
            .fontSize(10).fontColor('#FFFFFF')
            .backgroundColor('#88000000')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(3).maxLines(1)
            .margin({ right: 4, bottom: 4 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(120).height(68).clip(true)
      Column({ space: 5 }) {
        Text(video.title)
          .fontSize(13).fontWeight(FontWeight.Medium).lineHeight(17)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Row({ space: 6 }) {
          Text(video.channel)
            .fontSize(11).fontColor('#9499A0').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (video.views.length > 0) {
            Text(video.views).fontSize(11).fontColor('#9499A0').maxLines(1)
          }
        }
        .width('100%').alignItems(VerticalAlign.Center)
      }
      .height(68).alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .onClick(() => this.openRelated(video))
  }

  /** 简介：频道行、标题、数据、简介正文、相关推荐（与 B 站详情页同序）。 */
  @Builder
  IntroTab() {
    Scroll() {
      Column({ space: 12 }) {
        this.ChannelRow()

        Text(this.video.title.length > 0 ? this.video.title : 'YouTube 视频')
          .fontSize(19).lineHeight(26).fontWeight(FontWeight.Bold).width('100%')
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')

        Text([this.video.views, this.video.published, this.video.duration]
          .filter((v: string) => v.length > 0).join(' · '))
          .fontSize(12).fontColor('#9499A0').width('100%')

        // 只放能闭环的动作：分享与复制链接。点赞/投币/收藏/发评论需要账号，不摆空按钮。
        Row({ space: 10 }) {
          this.QuietAction('分享', () => this.shareVideo())
          this.QuietAction('复制链接', () => this.copyLink())
        }
        .width('100%')

        if (this.detailLoading) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18).color(AppTheme.DANGER)
            Text('正在读取视频信息…').fontSize(12).fontColor('#9499A0')
          }.width('100%')
        }
        if (this.detailError.length > 0) {
          Text('详情加载受限：' + this.detailError).fontSize(13).width('100%')
            .fontColor(this.isDark ? '#FFAAAA' : '#B3261E')
          Button('重试详情')
            .fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .height(36).padding({ left: 18, right: 18 }).borderRadius(18)
            .backgroundColor(this.isDark ? '#2B2D34' : '#F0F1F3')
            .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
            .onClick(() => this.loadDetail())
        }

        if (this.video.description.length > 0) {
          Text('简介').fontSize(15).fontWeight(FontWeight.Bold).width('100%')
            .fontColor(this.isDark ? '#F1F2F3' : '#18191C')
          Text(this.video.description)
            .fontSize(14).lineHeight(22).width('100%')
            .copyOption(CopyOptions.LocalDevice)
            .fontColor(this.isDark ? '#CCCCCC' : '#555555')
        }

        if (this.related.length > 0) {
          Text('相关推荐').fontSize(15).fontWeight(FontWeight.Bold).width('100%')
            .fontColor(this.isDark ? '#F1F2F3' : '#18191C')
          Column({ space: 12 }) {
            ForEach(this.related, (item: YouTubeVideo) => {
              this.RelatedRow(item)
            }, (item: YouTubeVideo) => item.id)
          }.width('100%')
        }

        if (this.playerError.length > 0) {
          Text(this.playerError).fontSize(13).width('100%')
            .fontColor(this.isDark ? '#FFAAAA' : '#B3261E')
          Button('重试播放')
            .fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .height(36).padding({ left: 18, right: 18 }).borderRadius(18)
            .backgroundColor(this.isDark ? '#2B2D34' : '#F0F1F3')
            .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
            .onClick(() => this.retryPlayer())
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: this.dockInset() })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').height('100%')
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }

  /** 评论单条：头像 + 作者/时间 + 正文 + 点赞数（只读，无回复/点赞入口）。 */
  @Builder
  CommentRow(comment: YouTubeComment) {
    Row({ space: 10 }) {
      Image(comment.avatar.length > 0 ? this.localImage(comment.avatar) : $r('app.media.ic_tab_mine'))
        .width(34).height(34)
        .borderRadius(17)
        .objectFit(ImageFit.Cover)
        .backgroundColor(this.isDark ? '#2A2C31' : '#E5E7EB')
        .draggable(false).syncLoad(false)
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(comment.author).fontSize(12).fontColor('#9499A0')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (comment.published.length > 0) {
            Text(comment.published).fontSize(11).fontColor('#9499A0').maxLines(1)
          }
        }
        .width('100%').alignItems(VerticalAlign.Center)
        Text(comment.text)
          .fontSize(14).lineHeight(20).width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
        if (comment.likes.length > 0) {
          Text('赞 ' + comment.likes).fontSize(11).fontColor('#9499A0')
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Top)
  }

  /** 评论底部：加载中 / 失败重试 / 到底了。 */
  @Builder
  CommentFooter() {
    Row({ space: 8 }) {
      if (this.commentsMoreLoading) {
        LoadingProgress().width(20).height(20).color(AppTheme.DANGER)
        Text('正在加载更多评论…').fontSize(12).fontColor(this.isDark ? '#D0D0D0' : '#676B72')
      } else if (this.commentMoreError.length > 0) {
        Text(this.commentMoreError).fontSize(12).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .fontColor(this.isDark ? '#FFAAAA' : '#B3261E')
        Text('重试').fontSize(12).fontColor(AppTheme.DANGER)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.commentMoreError = '';
            this.loadMoreComments();
          })
      } else if (this.commentToken.length === 0 && this.comments.length > 0) {
        Text('—— 到底啦 ——').fontSize(12).fontColor('#9499A0')
      }
    }
    .width('100%').height(48).justifyContent(FlexAlign.Center)
  }

  @Builder
  CommentTab() {
    Column() {
      if (this.commentToken.length === 0 && !this.commentsLoaded && !this.commentsLoading) {
        // 拿不到 InnerTube 配置时这里如实说明，不去猜一个注定失败的请求。
        Column({ space: 10 }) {
          Text('暂时无法读取评论').fontSize(14).fontColor('#9499A0')
          Text('当前网络下 YouTube 没有下发评论入口').fontSize(12).fontColor('#9499A0')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.commentsLoading) {
        Column({ space: 12 }) {
          LoadingProgress().width(32).height(32).color(AppTheme.DANGER)
          Text('正在加载评论…').fontSize(13).fontColor('#9499A0')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.commentsError.length > 0) {
        Column({ space: 12 }) {
          Text(this.commentsError).fontSize(13).textAlign(TextAlign.Center)
            .fontColor(this.isDark ? '#CCCCCC' : '#666666')
          Button('重试')
            .fontSize(13).fontColor('#FFFFFF')
            .height(36).padding({ left: 18, right: 18 }).borderRadius(18)
            .backgroundColor(AppTheme.DANGER)
            .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
            .onClick(() => this.loadComments())
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.comments.length === 0) {
        Column({ space: 8 }) {
          Text('还没有评论').fontSize(14).fontColor('#9499A0')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0, scroller: this.commentScroller }) {
          ListItemGroup({ footer: this.CommentFooter() }) {
            ForEach(this.comments, (comment: YouTubeComment) => {
              ListItem() { this.CommentRow(comment) }
            }, (comment: YouTubeComment) => comment.id.length > 0 ? comment.id :
              comment.author + comment.published + comment.text.substring(0, 12))
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .contentEndOffset(this.dockInset())
        .onReachEnd(() => { this.loadMoreComments(); })
      }
    }
    .width('100%').height('100%')
  }

  /** 悬浮 Dock 占位：详情页在 Tab 内容底部留出与外壳一致的呼吸位。 */
  private dockInset(): number {
    return Immersive.bottomInset() + 32;
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
        // 标签行与 B 站详情页 DetailToolbar 同规格；右侧保留唯一的动作入口。
        Row({ space: 5 }) {
          this.CompactDetailTab('简介', 0)
          this.CompactDetailTab(this.commentTabLabel(), 1)
          Blank()
        }
        .width('100%').height(48)
        .padding({ left: 6, right: 10 })
        .alignItems(VerticalAlign.Center)

        // 用条件渲染而不是 Tabs 组件：Tabs 的 index 绑定会在页面状态更新（例如播放器
        // 25 秒超时提示）时被重建回默认页，实测会把用户已经切到的「评论」顶回「简介」。
        // 这里只有自定义标签行这一个切换入口，语义单一且不会自己跳回去。
        Column() {
          if (this.tab === 0) {
            this.IntroTab()
          } else {
            this.CommentTab()
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .padding({ top: this.fullscreen ? 0 : this.statusInset, bottom: this.fullscreen ? 0 : Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
  }
}
