import { inputMethod } from '@kit.IMEKit';
import { curves } from '@kit.ArkUI';
import { YouTubeApi, YouTubeVideo } from '../api/YouTubeApi';
import { AppNavStack, NAV_YOUTUBE_DETAIL } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { RequestEpoch } from '../common/RequestEpoch';
import { PlatformStore } from '../common/PlatformStore';
import { AppTheme } from '../common/AppTheme';
import { Haptic } from '../common/Haptic';
import { MotionTokens } from '../common/MotionTokens';
import { LayoutTokens } from '../common/LayoutTokens';

/**
 * YouTube 平台外壳：与哔哩哔哩同级，而不是底部 Dock 的第 4 个 Tab。
 *
 * 结构对齐哔哩哔哩主框架（唯一平台来源 PlatformStore）：
 * - 自带玻璃头栏（同一套 AppTheme 材质与滚动淡出），保证风格一致；
 * - 底部用同一套系统 Tabs 悬浮 Dock（barFloatingStyle + systemMaterial），
 *   只是条目换成 YouTube 自己的（探索 / 搜索 / 我的）；
 * - 「我的」里提供返回哔哩哔哩的对称入口，不会进去出不来。
 *
 * 游客边界：探索与搜索只用公开网页结构，不需要账号；账号能力未接入前
 * 「我的」只做诚实说明，不放无法闭环的登录按钮。
 */

/** 探索页分类：点一下即用该关键词搜索，游客也能有内容可看，不伪造推荐流。 */
const YOUTUBE_CATEGORIES: Array<string> = ['音乐', '游戏', '科技', '电影', '综艺', '动画', '体育', '美食'];

@Component
export struct YouTubeView {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('windowStatusBarHeight') statusInset: number = 0;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('headerFade') fade: number = 0;
  @State tab: number = 0;
  @State query: string = '';
  @State searched: string = '';
  @State videos: Array<YouTubeVideo> = [];
  @State loading: boolean = false;
  @State error: string = '';
  @State accountSheet: boolean = false;
  /** 双列/多列与左右内缩都随屏宽变化，与哔哩哔哩首页同一套 LayoutTokens 断点。 */
  @State viewportWidth: number = 360;
  /** Dock 激活色与弹跳比例：与主框架 FloatingTabs 取同一来源。 */
  @StorageProp('accentColor') accent: string = '#FB7299';
  @State tabScale: Array<number> = [1, 1, 1];
  private request: RequestEpoch = new RequestEpoch();
  private scroller: Scroller = new Scroller();

  aboutToDisappear(): void {
    this.request.invalidate();
  }

  /** 平台切换：先让在途请求失效，再广播，避免旧结果写进新平台状态。 */
  private backToBili(): void {
    Haptic.light();
    this.request.invalidate();
    PlatformStore.switchTo(PlatformStore.BILI);
  }

  private open(video: YouTubeVideo): void {
    AppNavStack.pushPathByName(NAV_YOUTUBE_DETAIL, video);
  }

  /** 输入是链接就直接进详情，否则作为关键词搜索。 */
  private submitSearch(): void {
    const query: string = this.query.trim();
    if (query.length === 0) return;
    try { inputMethod.getController().hideTextInput().catch(() => {}); } catch (_) {}
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_) {}
    const id: string = YouTubeApi.videoId(query);
    if (id.length > 0) {
      const video: YouTubeVideo = new YouTubeVideo();
      video.id = id;
      this.open(video);
      return;
    }
    this.runSearch(query);
  }

  private runSearch(query: string): void {
    const token: number = this.request.next();
    this.loading = true;
    this.error = '';
    this.searched = query;
    this.videos = [];
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
    YouTubeApi.search(query).then((result: Array<YouTubeVideo>) => {
      if (!this.request.isCurrent(token)) return;
      this.videos = result;
    }).catch((e: Object) => {
      if (!this.request.isCurrent(token)) return;
      this.error = (e as Error).message || '搜索失败，请重试';
    }).finally(() => {
      if (this.request.isCurrent(token)) this.loading = false;
    });
  }

  /** 分类 chip：填入关键词并切到搜索 Tab 展示结果。 */
  private searchCategory(keyword: string): void {
    Haptic.light();
    this.query = keyword;
    this.tab = 1;
    this.runSearch(keyword);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 组件销毁后调用会抛异常，忽略。
    }
  }

  /** 悬浮 Dock 占用高度：Dock 52 + 底边距 16 + 系统导航条内缩，再留 16 呼吸位。 */
  private dockInset(): number {
    return 52 + Immersive.bottomInset() + 32;
  }

  /** 轻触 Dock：轻震 + 图标先缩后弹回（只有切到别的 Tab 才弹），与主框架一致。 */
  private tapDockItem(index: number): void {
    Haptic.light();
    if (this.tab === index) return;
    this.tabScale = this.tabScale.map((v: number, i: number) => (i === index ? 0.78 : v));
    const pending: number = index;
    setTimeout(() => {
      this.tabScale = this.tabScale.map((v: number, i: number) => (i === pending ? 1 : v));
    }, 30);
    // 自定义 tabBar 的 onClick 会拦截默认切换逻辑，必须显式驱动索引切换。
    this.tab = index;
  }

  /** 与 GlassHeaderBar 完全相同的淡出曲线，保证两个平台头栏滚动手感一致。 */
  private headerContentOpacity(): number {
    return 1 - Math.min(1, Math.max(0, this.fade / 0.85));
  }

  /** 分组卡片底色：与 MineView.groupBg() 同值，两个平台的「我的」页卡面一致。 */
  private mineCardBg(): string {
    return this.isDark ? '#26272B' : '#FFFFFF';
  }

  /**
   * 信息流卡片：视觉规格复刻哔哩哔哩首页卡片（components/video/VideoCard.ets 的 homeStyle 分支），
   * 保证两个平台观感一致——白色容器卡 + 圆角 16 + 阴影 8 + 按压缩放，
   * 封面 4:3 + 底部渐变遮罩，渐变行左侧数据 / 右侧时长，标题固定两行，底栏为作者行。
   *
   * 与哔哩哔哩的差异只来自数据本身，不来自设计：YouTube 无弹幕、无多P、无 UP 徽标，
   * 观看次数是本地化字符串（"8,537次观看"）而非数字，因此直接使用原始文案。
   */
  @Builder
  VideoCard(video: YouTubeVideo) {
    Column() {
      // 封面：点击区是封面本身，与哔哩哔哩一致。
      Stack() {
        Image(video.thumbnail)
          .width('100%')
          .aspectRatio(4 / 3)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.isDark ? '#2A2C31' : '#E5E7EB')
          .draggable(false)
          .syncLoad(false)

        // 底部渐变行：左 = 观看次数，右 = 时长（对齐哔哩哔哩「播放/弹幕 ... 时长」层级）。
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%').height(40)
            .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#A6000000', 1.0]] })
          Row({ space: 10 }) {
            if (video.views.length > 0) {
              Row({ space: 4 }) {
                Stack() {
                  Image($r('app.media.ic_play'))
                    .width(6).height(6)
                    .renderMode(ImageRenderMode.Template).fillColor('#FFFFFF')
                }
                .width(17).height(12).alignContent(Alignment.Center)
                .border({ width: 1, color: '#FFFFFF', radius: 3 })
                Text(video.views).fontSize(11).fontColor('#FFFFFF').maxLines(1)
              }.alignItems(VerticalAlign.Center)
            }
            Blank()
            if (video.duration.length > 0) {
              Text(video.duration).fontSize(11).fontColor('#FFFFFF').maxLines(1)
            }
          }
          .width('100%').height(32).padding({ left: 8, right: 8 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
      }
      .width('100%')
      .aspectRatio(4 / 3)
      .clip(true)
      .onClick(() => this.open(video))

      // 标题：固定两行高度，卡片高度不随标题长短变化（同哔哩哔哩 50vp 规格）。
      Row() {
        Text(video.title)
          .width('100%')
          .fontSize(14)
          .lineHeight(19)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(50)
      .alignItems(VerticalAlign.Top)
      .padding({ left: 12, right: 12, top: 10 })
      .onClick(() => this.open(video))

      // 作者行：哔哩哔哩此处是「UP 徽标 + 作者名」，YouTube 对应频道名 + 发布时间。
      Row({ space: 6 }) {
        Text(video.channel)
          .fontSize(11)
          .fontColor(this.isDark ? '#A5AAB5' : '#7D8490')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (video.published.length > 0) {
          Text(video.published)
            .fontSize(11)
            .fontColor(this.isDark ? '#8A8A8F' : '#9499A0')
            .maxLines(1)
        }
      }
      .width('100%')
      .height(32)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.open(video))
    }
    .width('100%')
    .padding({ bottom: 6 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.isDark ? '#24272E' : '#FFFFFF')
    .borderRadius(16)
    .clip(true)
    .shadow({ radius: 8, color: '#08000000', offsetX: 0, offsetY: 1 })
    .animation({ duration: MotionTokens.feedback, curve: Curve.EaseOut })
    .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
  }

  /**
   * 玻璃头栏：材质与几何规格复刻 components/GlassHeaderBar.ets，
   * 保证与哔哩哔哩首页同一观感——同一渐变光感层、同一 44vp 高度、
   * 同一胶囊圆角/描边/文字规格、同一滚动淡出曲线与位移。
   *
   * 差异只在内容语义：左侧是 YouTube 标识而非头像，右侧是回哔哩哔哩入口而非消息。
   */
  @Builder
  HeaderBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶部沉浸光感：状态栏处最强，向内容区连续衰减（与 GlassHeaderBar 同参数）。
      Column()
        .width('100%')
        .height(this.statusInset + 68)
        .linearGradient({
          angle: 180,
          colors: this.isDark ?
            [['#B8141418', 0.0], ['#66141418', 0.5], ['#00141418', 1.0]] :
            [['#B8FFFFFF', 0.0], ['#66FFFFFF', 0.5], ['#00FFFFFF', 1.0]],
        })
        .linearGradientBlur(28, {
          fractionStops: [[1.0, 0.0], [0.5, 0.5], [0.0, 1.0]],
          direction: GradientDirection.Bottom,
        })
        .hitTestBehavior(HitTestMode.None)

      Row({ space: 8 }) {
        // 与 GlassHeaderBar 同宽度的左侧图标位（那边是头像，这边是平台标识）。
        Image($r('app.media.ic_youtube'))
          .width(30).height(24).margin({ left: 3 })
          .opacity(this.headerContentOpacity())

        // 回哔哩哔哩：做成与搜索胶囊同规格的胶囊，而不是裸文字按钮。
        Row({ space: 6 }) {
          Image($r('app.media.ic_back'))
            .width(14).height(14).renderMode(ImageRenderMode.Template)
            .fillColor(this.isDark ? '#B4B6BE' : '#777B85')
          Text('哔哩哔哩')
            .fontSize(13).fontWeight(FontWeight.Normal)
            .fontColor(this.isDark ? '#B4B6BE' : '#777B85')
            .maxLines(1)
        }
        .height(36).layoutWeight(1).justifyContent(FlexAlign.Center)
        .padding({ left: 12, right: 12 })
        .borderRadius(18)
        .backgroundColor(this.glassOn ? (this.isDark ? '#AA292D36' : '#CCFFFFFF') :
          (this.isDark ? '#292B32' : '#EDEFF2'))
        .systemMaterial(AppTheme.floatMaterial(this.glassOn))
        .border({ width: 0.7, color: this.isDark ? '#22FFFFFF' : '#0D242833' })
        .opacity(this.headerContentOpacity())
        .translate({ y: -8 * this.fade })
        .accessibilityText('返回哔哩哔哩')
        .onClick(() => this.backToBili())

        // 右侧占位：与 GlassHeaderBar 的 40vp 操作位等宽，保证胶囊左右对称。
        Row().width(40).height(40)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: this.statusInset + 4, bottom: 8 })
      .hitTestBehavior(this.fade > 0.85 ? HitTestMode.None : HitTestMode.Default)
    }
    .width('100%')
    .height(this.statusInset + 44)
    .clip(false)
  }

  /** 搜索入口：输入框与「搜索」按钮都套用哔哩哔哩的胶囊规格（高 36/圆角 18/0.7 描边）。 */
  @Builder
  SearchField(idSuffix: string) {
    Row({ space: 8 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_search'))
          .width(16).height(16).renderMode(ImageRenderMode.Template)
          .fillColor(this.isDark ? '#B4B6BE' : '#777B85')
        TextInput({ placeholder: '搜索 YouTube 或粘贴视频链接', text: this.query })
          .id('youtube-search-input-' + idSuffix)
          .layoutWeight(1).height(36).padding(0).borderRadius(0)
          .backgroundColor(Color.Transparent)
          .placeholderColor(this.isDark ? '#B4B6BE' : '#777B85')
          .fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          .maxLength(500).enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => { this.query = value; })
          .onSubmit(() => { this.submitSearch(); })
      }
      .height(36).layoutWeight(1).padding({ left: 12, right: 12 })
      .borderRadius(18)
      .backgroundColor(this.glassOn ? (this.isDark ? '#AA292D36' : '#CCFFFFFF') :
        (this.isDark ? '#292B32' : '#EDEFF2'))
      .systemMaterial(AppTheme.floatMaterial(this.glassOn))
      .border({ width: 0.7, color: this.isDark ? '#22FFFFFF' : '#0D242833' })

      Text('搜索')
        .fontSize(13).fontColor('#FFFFFF')
        .height(36).padding({ left: 16, right: 16 })
        .borderRadius(18)
        .backgroundColor(AppTheme.DANGER)
        .id('youtube-search-button-' + idSuffix)
        .onClick(() => { this.submitSearch(); })
    }.width('100%')
  }

  /** 探索：分类 chips + 空态说明；有结果时与搜索 Tab 共用同一份结果。 */
  @Builder
  ExploreTab() {
    Column({ space: 14 }) {
      this.SearchField('explore')
      Text('热门分类').fontSize(13).fontWeight(FontWeight.Medium).width('100%')
        .fontColor(this.isDark ? '#C8C8CC' : '#5A5F66')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(YOUTUBE_CATEGORIES, (name: string) => {
          Text(name)
            .fontSize(14)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .borderRadius(18)
            .backgroundColor(this.isDark ? '#2B2D34' : '#FFFFFF')
            .margin({ right: 8, bottom: 8 })
            .onClick(() => this.searchCategory(name))
        }, (name: string) => name)
      }.width('100%')
      if (this.videos.length > 0 && this.searched.length > 0) {
        Text('「' + this.searched + '」的结果').fontSize(13).width('100%')
          .fontColor(this.isDark ? '#C8C8CC' : '#5A5F66')
      }
      this.ResultArea()
    }.width('100%').layoutWeight(1)
    .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
      right: LayoutTokens.horizontalPadding(this.viewportWidth) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
  }

  /** 搜索结果区：加载 / 错误 / 空 / 列表四态互斥，与哔哩哔哩三态写法一致。 */
  @Builder
  ResultArea() {
    if (this.loading) {
      Column({ space: 12 }) {
        LoadingProgress().width(36).height(36).color(AppTheme.DANGER)
        Text('正在搜索 YouTube…').fontColor(this.isDark ? '#AAAAAA' : '#666666')
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else if (this.error.length > 0) {
      Column({ space: 16 }) {
        Text(this.error).fontSize(15).fontColor(this.isDark ? '#CCCCCC' : '#666666').textAlign(TextAlign.Center)
        Button('重试').onClick(() => {
          if (this.searched.length > 0) this.runSearch(this.searched);
        })
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else if (this.videos.length > 0) {
      // 双列网格：与哔哩哔哩首页一致的 lanes 瀑布流布局与列间距。
      List({ space: LayoutTokens.feedGap, scroller: this.scroller }) {
        ForEach(this.videos, (video: YouTubeVideo) => {
          ListItem() { this.VideoCard(video) }
        }, (video: YouTubeVideo) => video.id)
        ListItem() {
          // 公开搜索页的翻页依赖 continuation token，尚未验证；
          // 先如实说明只展示首批，不假装还有更多。
          Text('已展示本次搜索结果，试试更具体的关键词')
            .fontSize(12).fontColor('#888888').width('100%').textAlign(TextAlign.Center)
            .padding({ top: 8 })
        }
      }
      .layoutWeight(1).width('100%')
      .lanes(LayoutTokens.feedColumns(this.viewportWidth), LayoutTokens.feedGap)
      // 悬浮 Dock 高 52 + 底边距 16，末端留白必须大于 68 才能完整露出末行（同首页）。
      .contentEndOffset(Immersive.bottomInset() + 76)
      .scrollBar(BarState.Off)
      .onDidScroll((offset: number) => AppTheme.updateHeaderFade(offset))
    } else {
      Column({ space: 12 }) {
        Text(this.searched.length > 0 ? '没有找到相关视频' : '探索 YouTube')
          .fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text(this.searched.length > 0 ? '换个关键词再试试' :
          '搜索感兴趣的内容，或粘贴视频链接开始观看')
          .fontSize(14).fontColor('#888888').textAlign(TextAlign.Center)
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  SearchTab() {
    Column({ space: 14 }) {
      this.SearchField('search')
      this.ResultArea()
    }.width('100%').layoutWeight(1)
    .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
      right: LayoutTokens.horizontalPadding(this.viewportWidth) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
  }

  /** 「我的」：账号能力未接入，只做诚实说明，不放无法闭环的登录按钮。 */
  @Builder
  MineTab() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 10 }) {
          Row({ space: 12 }) {
            Image($r('app.media.ic_youtube')).width(34).height(28)
            Column({ space: 4 }) {
              Text('未连接 YouTube 账号').fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.onSurface())
              Text('Google 账号未连接').fontSize(12).fontColor('#9499A0')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Center)
          Text('当前可用的是游客探索与搜索；观看历史、订阅与播放列表需要账号，暂未开放。')
            .fontSize(12).lineHeight(18).fontColor('#9499A0').width('100%')
          // 说明入口沿用哔哩哔哩「我的」页的胶囊按钮规格（圆角 18）。
          Text('了解如何连接')
            .fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .height(36).padding({ left: 16, right: 16 })
            .borderRadius(18)
            .backgroundColor(this.isDark ? '#2B2D34' : '#F0F1F3')
            .onClick(() => { this.accountSheet = true; })
        }
        .width('100%').padding(16).borderRadius(12)
        .backgroundColor(this.mineCardBg())
        .alignItems(HorizontalAlign.Start)

        Column() {
          ForEach(['观看历史', '稍后观看', '订阅内容', '播放列表'], (label: string, index: number) => {
            Column() {
              Row({ space: 14 }) {
                Text(label).fontSize(15).fontColor('#9499A0').layoutWeight(1)
                Text('未解锁').fontSize(12).fontColor('#9499A0')
                Image($r('app.media.ic_arrow_right')).width(18).height(18).fillColor('#C1C2C5')
              }
              .width('100%').height(48).padding({ left: 14, right: 14 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.toast('连接 YouTube 账号后可用'); })
              if (index < 3) {
                Divider().strokeWidth(0.5)
                  .color(this.isDark ? '#1FFFFFFF' : '#0F000000')
                  .margin({ left: 48, right: 14 })
              }
            }.width('100%')
          }, (label: string) => label)
        }
        .width('100%').borderRadius(12)
        .backgroundColor(this.mineCardBg())
        .clip(true)

        // 与「我的」页进入 YouTube 对称的回程入口：图标 + 文案 + 箭头，行规格同 MenuRow。
        Row({ space: 14 }) {
          Image($r('app.media.ic_back'))
            .width(20).height(20).renderMode(ImageRenderMode.Template)
            .fillColor(this.isDark ? '#C6C7CB' : '#61666D')
          Text('哔哩哔哩')
            .fontSize(15).fontColor(AppTheme.onSurface()).layoutWeight(1)
          Image($r('app.media.ic_arrow_right')).width(18).height(18).fillColor('#C1C2C5')
        }
        .width('100%').height(48).padding({ left: 14, right: 14 })
        .borderRadius(12)
        .backgroundColor(this.mineCardBg())
        .alignItems(VerticalAlign.Center)
        .onClick(() => this.backToBili())
      }
      .width('100%')
      .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
        right: LayoutTokens.horizontalPadding(this.viewportWidth), bottom: this.dockInset() })
      .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%').layoutWeight(1).scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .contentEndOffset(Immersive.bottomInset() + 76)
    .bindSheet($$this.accountSheet, this.AccountHelpSheet(), {
      height: 360,
      dragBar: true,
      backgroundColor: this.isDark ? '#24272E' : '#FFFFFF',
    })
  }

  @Builder
  AccountHelpSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Text('关于连接 Google 账号').fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C').width('100%')
        Text('· 鸿蒙系统不包含 Google 移动服务（GMS），Google 官方登录 SDK 没有鸿蒙版本。')
          .fontSize(14).lineHeight(22).width('100%')
          .fontColor(this.isDark ? '#CCCCCC' : '#555555')
        Text('· 出境易/卓易通是隔离的安卓运行环境，不向鸿蒙应用共享 Google 账号会话。')
          .fontSize(14).lineHeight(22).width('100%')
          .fontColor(this.isDark ? '#CCCCCC' : '#555555')
        Text('· Google 账号授权需要在外部浏览器完成，播放器内的登录则属于另一套机制，两者必须分别验证。')
          .fontSize(14).lineHeight(22).width('100%')
          .fontColor(this.isDark ? '#CCCCCC' : '#555555')
        Text('· 在确认可行方案之前，本应用不提供无法闭环的登录入口，也不会导出任何第三方凭据。')
          .fontSize(14).lineHeight(22).width('100%')
          .fontColor(this.isDark ? '#CCCCCC' : '#555555')
      }
      .width('100%').padding(20).alignItems(HorizontalAlign.Start)
    }
    .width('100%').scrollBar(BarState.Off)
  }

  build() {
    Column() {
      this.HeaderBar()
      // Dock 与主框架的 FloatingTabs 同构：同样用原生 Tabs + barFloatingStyle，
      // 因此玻璃材质、圆角、边距、动画全部由系统按同一套参数渲染，不存在手绘近似。
      Tabs({ barPosition: BarPosition.End, index: $$this.tab }) {
        TabContent() {
          this.ExploreTab()
        }
        .tabBar(this.DockItem(0, '探索', $r('app.media.ic_youtube_tab'), $r('app.media.ic_youtube_tab_fill')))
        .clip(false)

        TabContent() {
          this.SearchTab()
        }
        .tabBar(this.DockItem(1, '搜索', $r('app.media.ic_search'), $r('app.media.ic_search_fill')))
        .clip(false)

        TabContent() {
          this.MineTab()
        }
        .tabBar(this.DockItem(2, '我的', $r('app.media.ic_tab_mine'), $r('app.media.ic_tab_mine_fill')))
        .clip(false)
      }
      .layoutWeight(1)
      .width('100%')
      .barHeight(52)
      .barOverlap(true)
      // 与主框架一致：顶层平台内只通过 Dock 切换，不响应左右滑动。
      .scrollable(false)
      .barFloatingStyle({
        barSideMargin: 16,
        barBottomMargin: 16,
        systemMaterial: AppTheme.floatMaterial(this.glassOn),
      })
      // 深色模式给原生玻璃叠深色吸收底（同主框架：约 70% 透明度仍会泛白）。
      .barBackgroundColor(this.glassOn ? (this.isDark ? '#EA15161A' : '#00000000') :
        AppTheme.floatBg(this.isDark, false))
      .animationDuration(MotionTokens.navigation)
      .animationMode(AnimationMode.CONTENT_FIRST)
      .onChange(() => {
        AppTheme.resetHeaderFade();
      })
    }
    .width('100%').height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Number(newValue.width);
      if (!Number.isNaN(width) && width > 0) this.viewportWidth = width;
    })
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * Dock 条目：逐参数对齐主框架 FloatingTabs 的 TabBarItem——
   * 图标 24vp / 间距 2 / 激活态换实心图标 / 激活色走主题 accent /
   * 轻触时图标先缩到 0.78 再弹簧回弹。
   */
  @Builder
  DockItem(index: number, label: string, icon: Resource, activeIcon: Resource) {
    Column({ space: 2 }) {
      Image(this.tab === index ? activeIcon : icon)
        .width(24)
        .height(24)
        .fillColor(this.tab === index ? this.accent : (this.isDark ? '#8A8A8E' : '#9499A0'))
        .scale({ x: this.tabScale[index], y: this.tabScale[index] })
        .animation({ duration: 260, curve: curves.springMotion(0.35, 0.7) })
      Text(label)
        .fontSize(10)
        .fontColor(this.tab === index ? this.accent : (this.isDark ? '#8A8A8E' : '#9499A0'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.tapDockItem(index);
    })
  }
}
