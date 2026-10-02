import { inputMethod } from '@kit.IMEKit';
import { curves } from '@kit.ArkUI';
import { YouTubeApi, YouTubeSearchFilter, YouTubeSearchFilterGroup,
  YouTubeVideo } from '../api/YouTubeApi';
import { AppNavStack, NAV_YOUTUBE_DETAIL, NAV_YOUTUBE_SAVED } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { PlatformStore } from '../common/PlatformStore';
import { AppTheme } from '../common/AppTheme';
import { Haptic } from '../common/Haptic';
import { MotionTokens } from '../common/MotionTokens';
import { LayoutTokens } from '../common/LayoutTokens';
import { YouTubeSearchController, YouTubeSearchState } from '../components/youtube/YouTubeSearchController';
import { YouTubeDiscoveryController, YouTubeDiscoveryState } from '../components/youtube/YouTubeDiscoveryController';
import { BasicDataSource } from '../common/BasicDataSource';

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
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('windowStatusBarHeight') statusInset: number = 0;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('headerFade') fade: number = 0;
  @State tab: number = 0;
  @State query: string = '';
  @State search: YouTubeSearchState = new YouTubeSearchState();
  @State discovery: YouTubeDiscoveryState = new YouTubeDiscoveryState();
  private searchCtl: YouTubeSearchController = new YouTubeSearchController(
    (state: YouTubeSearchState): void => { this.search = state; });
  private discoveryCtl: YouTubeDiscoveryController = new YouTubeDiscoveryController(
    (state: YouTubeDiscoveryState): void => { this.discovery = state; });
  private videosSource: BasicDataSource<YouTubeVideo> = this.searchCtl.source;
  @State accountSheet: boolean = false;
  /** 本地稍后观看数量：由 YouTubeWatchLaterStore 广播，返回本页时不会读到旧值。 */
  @StorageProp('youtubeWatchLaterCount') savedCount: number = 0;
  @StorageProp('youtubeHistoryCount') historyCount: number = 0;
  @State filterSheet: boolean = false;
  /** 双列/多列与左右内缩都随屏宽变化，与哔哩哔哩首页同一套 LayoutTokens 断点。 */
  @State viewportWidth: number = 360;
  /** Dock 激活色与弹跳比例：与主框架 FloatingTabs 取同一来源。 */
  @StorageProp('accentColor') accent: string = '#FB7299';
  @State tabScale: Array<number> = [1, 1, 1];
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.searchCtl.activate();
    this.discoveryCtl.activate();
  }

  aboutToDisappear(): void {
    this.searchCtl.dispose();
    this.discoveryCtl.dispose();
  }

  private scheduleSuggest(value: string): void { this.discoveryCtl.suggest(value); }
  private clearSuggestions(): void { this.discoveryCtl.clearSuggestions(); }
  private resetResults(): void {
    this.searchCtl.clear();
    this.discoveryCtl.submit('', false);
  }

  /** 平台切换：先让在途请求失效，再广播，避免旧结果写进新平台状态。 */
  private backToBili(): void {
    Haptic.light();
    this.searchCtl.dispose();
    this.discoveryCtl.dispose();
    PlatformStore.switchTo(PlatformStore.BILI);
  }

  private open(video: YouTubeVideo): void {
    AppNavStack.pushPathByName(NAV_YOUTUBE_DETAIL, video);
  }

  /** 输入是链接就直接进详情，否则作为关键词搜索。 */
  private submitSearch(): void {
    const query: string = this.query.trim();
    if (query.length === 0) return;
    this.clearSuggestions();
    try { inputMethod.getController().hideTextInput().catch(() => {}); } catch (_) {}
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_) {}
    const id: string = YouTubeApi.videoId(query);
    if (id.length > 0) {
      const video: YouTubeVideo = new YouTubeVideo();
      video.id = id;
      this.open(video);
      return;
    }
    // 只有真正发起的搜索词才进历史：粘链接直接进详情不算搜索。
    this.discoveryCtl.submit(query);
    this.runSearch(query);
  }

  private runSearch(query: string, filterParams: string = '', filterLabel: string = ''): void {
    this.discoveryCtl.submit(query, false);
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.searchCtl.search(query, filterParams, filterLabel);
  }

  private applyFilter(filter: YouTubeSearchFilter): void {
    Haptic.light();
    this.filterSheet = false;
    this.runSearch(this.search.searched, filter.params, filter.label);
  }

  private clearFilter(): void {
    Haptic.light();
    if (this.search.searched.length > 0) this.runSearch(this.search.searched);
  }

  private loadMore(): void { this.searchCtl.loadMore(); }

  private thumbnailOf(video: YouTubeVideo): string {
    return this.searchCtl.thumbnails.resolve(video.thumbnail);
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
          .onChange((value: string) => {
            this.query = value;
            // 清空输入回到"历史/探索"首页：与哔哩哔哩搜索页一致，否则历史再也进不去。
            if (value.trim().length === 0) this.resetResults();
            this.scheduleSuggest(value);
          })
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

  /**
   * 输入联想：与哔哩哔哩搜索页一样，只做"帮用户把词写完"，不做远端脚本。
   * 联想列表出现时占位在结果区上方，提交搜索立即收起。
   */
  @Builder
  Suggestions() {
    if (this.discovery.suggestions.length > 0) {
      Column() {
        ForEach(this.discovery.suggestions, (word: string, index: number) => {
          Row({ space: 8 }) {
            Image($r('app.media.ic_search'))
              .width(14).height(14).renderMode(ImageRenderMode.Template)
              .fillColor(this.isDark ? '#B4B6BE' : '#777B85')
            Text(word)
              .fontSize(14).maxLines(1).layoutWeight(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
          }
          .width('100%').height(44).padding({ left: 12, right: 12 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.query = word;
            this.submitSearch();
          })
          if (index < this.discovery.suggestions.length - 1) {
            Divider().strokeWidth(0.5).margin({ left: 34 })
              .color(this.isDark ? '#1FFFFFFF' : '#0F000000')
          }
        }, (word: string) => word)
      }
      .width('100%').borderRadius(12).clip(true)
      .backgroundColor(this.mineCardBg())
    }
  }

  /** 搜索历史：规格与哔哩哔哩搜索页 chips 一致（含单条删除与清空）。 */
  @Builder
  HistoryChips() {
    if (this.discovery.history.length > 0) {
      Column({ space: 8 }) {
        Row() {
          Text('搜索历史').fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          Blank()
          Text('清空').fontSize(12).fontColor('#9499A0')
            .onClick(() => {
              this.discoveryCtl.clearHistory();
            })
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.discovery.history, (word: string) => {
            Row({ space: 5 }) {
              Text(word)
                .fontSize(12).maxLines(1)
                .constraintSize({ maxWidth: 150 })
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(this.isDark ? '#E6E6E6' : '#454A50')
                .onClick(() => {
                  this.query = word;
                  this.submitSearch();
                })
              Image($r('app.media.ic_close'))
                .width(10).height(10).fillColor('#9499A0')
                .onClick(() => {
                  this.discoveryCtl.removeHistory(word);
                })
            }
            .padding({ left: 10, right: 8, top: 6, bottom: 6 })
            .margin({ right: 7, bottom: 7 })
            .borderRadius(15)
            .backgroundColor(this.isDark ? '#2E3136' : '#E9EBEE')
          }, (word: string) => word)
        }.width('100%')
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  /** 探索：分类 chips + 空态说明；有结果时与搜索 Tab 共用同一份结果。 */
  @Builder
  ExploreTab() {
    Column({ space: 14 }) {
      this.SearchField('explore')
      this.Suggestions()
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
      if (this.search.count > 0 && this.search.searched.length > 0) {
        Text('「' + this.search.searched + '」的结果').fontSize(13).width('100%')
          .fontColor(this.isDark ? '#C8C8CC' : '#5A5F66')
      }
      this.ResultArea()
    }.width('100%').layoutWeight(1)
    .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
      right: LayoutTokens.horizontalPadding(this.viewportWidth) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
  }

  /**
   * 结果列表底部：加载中 / 失败重试 / 到底了。
   * 尺寸与 LoadMoreFooter 同规格，但强调色取 YouTube 红（AppTheme.DANGER），
   * 不把哔哩哔哩的粉色带进 YouTube 外壳。
   */
  @Builder
  ResultFooter() {
    Row({ space: 8 }) {
      if (this.search.loadingMore) {
        LoadingProgress().width(20).height(20).color(AppTheme.DANGER)
        Text('正在加载更多…').fontSize(12).fontColor(this.isDark ? '#D0D0D0' : '#676B72')
      } else if (this.search.moreError.length > 0) {
        Text(this.search.moreError).fontSize(12).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .fontColor(this.isDark ? '#FFAAAA' : '#B3261E')
        Text('重试').fontSize(12).fontColor(AppTheme.DANGER)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .onClick(() => {
            this.searchCtl.loadMore(true);
          })
      } else if (this.search.continuation.length === 0) {
        Text('—— 到底啦 ——').fontSize(12).fontColor('#9499A0')
      }
    }
    .width('100%').height(48).justifyContent(FlexAlign.Center)
  }

  /**
   * 筛选条：与哔哩哔哩结果页的 chips 同一作用（点开面板选类型/时长/上传时间/功能/排序）。
   * 选中的筛选项显示成可取消的标签，避免用户忘了自己筛过什么。
   */
  @Builder
  FilterBar() {
    Row({ space: 8 }) {
      Text('筛选')
        .fontSize(12)
        .fontColor(this.search.filterLabel.length > 0 ? AppTheme.DANGER : (this.isDark ? '#E6E6E6' : '#454A50'))
        .height(30).padding({ left: 14, right: 14 })
        .borderRadius(15)
        .backgroundColor(this.isDark ? '#2B2D34' : '#EDEFF2')
        .onClick(() => { this.filterSheet = true; })
      if (this.search.filterLabel.length > 0) {
        Row({ space: 5 }) {
          Text(this.search.filterLabel).fontSize(12).fontColor(AppTheme.DANGER).maxLines(1)
          Image($r('app.media.ic_close')).width(10).height(10).fillColor(AppTheme.DANGER)
        }
        .height(30).padding({ left: 12, right: 10 })
        .borderRadius(15)
        .backgroundColor(this.isDark ? '#3A2A2C' : '#FDECEE')
        .onClick(() => this.clearFilter())
      }
      Blank()
    }
    .width('100%').height(38)
    .alignItems(VerticalAlign.Center)
  }

  /** 筛选面板：分组展示页面下发的筛选项，按下的那项用强调色标出。 */
  @Builder
  FilterSheet() {
    Scroll() {
      Column({ space: 14 }) {
        Text('搜索过滤条件').fontSize(17).fontWeight(FontWeight.Bold).width('100%')
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        ForEach(this.search.filterGroups, (group: YouTubeSearchFilterGroup) => {
          Column({ space: 8 }) {
            Text(group.title).fontSize(13).fontWeight(FontWeight.Medium).width('100%')
              .fontColor(this.isDark ? '#C8C8CC' : '#5A5F66')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(group.filters, (filter: YouTubeSearchFilter) => {
                Text(filter.label)
                  .fontSize(13)
                  .fontColor(filter.params === this.search.filterParams ?
                    '#FFFFFF' : (this.isDark ? '#E6E6E6' : '#18191C'))
                  .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                  .borderRadius(17)
                  .margin({ right: 8, bottom: 8 })
                  .backgroundColor(filter.params === this.search.filterParams ? AppTheme.DANGER :
                    (this.isDark ? '#2B2D34' : '#F0F1F3'))
                  .onClick(() => this.applyFilter(filter))
              }, (filter: YouTubeSearchFilter) => filter.params)
            }.width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (group: YouTubeSearchFilterGroup) => group.title)
      }
      .width('100%').padding(18).alignItems(HorizontalAlign.Start)
    }
    .width('100%').scrollBar(BarState.Off)
  }

  /** 搜索结果区：加载 / 错误 / 空 / 列表四态互斥，与哔哩哔哩三态写法一致。 */
  @Builder
  ResultArea() {
    // 筛选条放在四态之外：结果为空时也必须能取消筛选，否则用户会被自己筛进去出不来。
    if (this.search.filterGroups.length > 0 && !this.search.loading) this.FilterBar()
    if (this.search.loading) {
      Column({ space: 12 }) {
        LoadingProgress().width(36).height(36).color(AppTheme.DANGER)
        Text('正在搜索 YouTube…').fontColor(this.isDark ? '#AAAAAA' : '#666666')
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else if (this.search.error.length > 0) {
      Column({ space: 16 }) {
        Text(this.search.error).fontSize(15).fontColor(this.isDark ? '#CCCCCC' : '#666666').textAlign(TextAlign.Center)
        Button('重试').onClick(() => {
          if (this.search.searched.length > 0) {
            this.runSearch(this.search.searched, this.search.filterParams, this.search.filterLabel);
          }
        })
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    } else if (this.search.count > 0) {
      Column() {
        // 双列网格：与哔哩哔哩首页一致的 lanes 瀑布流布局与列间距。
        // LazyForEach 直接挂在滚动容器下：视口 + cachedCount 之外的行不创建，翻页/封面
        // 就绪只做单行通知，不再全量急切构建（同首页做法）。
        List({ space: LayoutTokens.feedGap, scroller: this.scroller }) {
        // footer 挂在 ListItemGroup 上：双列 lanes 下才能整宽居中（同首页做法）。
        ListItemGroup({ footer: this.ResultFooter() }) {
          LazyForEach(this.videosSource, (video: YouTubeVideo) => {
            ListItem() {
              YouTubeVideoCard({
                cover: this.thumbnailOf(video),
                title: video.title,
                channel: video.channel,
                views: video.views,
                duration: video.duration,
                published: video.published,
                onTap: (): void => { this.open(video); },
              })
            }
          }, (video: YouTubeVideo) => video.id)
        }
      }
        .layoutWeight(1).width('100%')
        .lanes(LayoutTokens.feedColumns(this.viewportWidth), LayoutTokens.feedGap)
        .cachedCount(3)
        // 悬浮 Dock 高 52 + 底边距 16，末端留白必须大于 68 才能完整露出末行（同首页）。
        .contentEndOffset(Immersive.bottomInset() + 76)
        .scrollBar(BarState.Off)
        .onDidScroll((offset: number) => AppTheme.updateHeaderFade(offset))
        .onReachEnd(() => { this.loadMore(); })
      }
      .width('100%').layoutWeight(1)
    } else {
      Column({ space: 12 }) {
        Text(this.search.searched.length > 0 ? '没有找到相关视频' : '探索 YouTube')
          .fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text(this.search.searched.length > 0 ? '换个关键词再试试' :
          '搜索感兴趣的内容，或粘贴视频链接开始观看')
          .fontSize(14).fontColor('#888888').textAlign(TextAlign.Center)
      }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  SearchTab() {
    Column({ space: 14 }) {
      this.SearchField('search')
      this.Suggestions()
      // 输入为空（首页态）时给历史；一有输入就交给联想与结果。
      if (this.query.trim().length === 0 && this.discovery.suggestions.length === 0) {
        this.HistoryChips()
      }
      this.ResultArea()
    }.width('100%').layoutWeight(1)
    .padding({ left: LayoutTokens.horizontalPadding(this.viewportWidth),
      right: LayoutTokens.horizontalPadding(this.viewportWidth) })
    .constraintSize({ maxWidth: LayoutTokens.feedMaxWidth })
    .alignSelf(ItemAlign.Center)
    .bindSheet($$this.filterSheet, this.FilterSheet(), {
      height: 420,
      dragBar: true,
      backgroundColor: this.isDark ? '#24272E' : '#FFFFFF',
    })
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
          Text('当前可用的是游客探索、搜索，以及本机的稍后观看与观看历史；订阅与播放列表需要账号，暂未开放。')
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
          // 稍后观看是本地列表，不需要账号，所以这里是真入口，不是「未解锁」。
          Column() {
            Row({ space: 14 }) {
              Text('稍后观看').fontSize(15).fontColor(AppTheme.onSurface()).layoutWeight(1)
              Text(this.savedCount > 0 ? String(this.savedCount) : '本机')
                .fontSize(12).fontColor('#9499A0')
              Image($r('app.media.ic_arrow_right')).width(18).height(18).fillColor('#C1C2C5')
            }
            .width('100%').height(48).padding({ left: 14, right: 14 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => { AppNavStack.pushPathByName(NAV_YOUTUBE_SAVED, null); })
            Divider().strokeWidth(0.5)
              .color(this.isDark ? '#1FFFFFFF' : '#0F000000')
              .margin({ left: 48, right: 14 })
          }.width('100%')
          // 观看历史同样是本机列表（打开详情即记录），也不需要账号。
          Column() {
            Row({ space: 14 }) {
              Text('观看历史').fontSize(15).fontColor(AppTheme.onSurface()).layoutWeight(1)
              Text(this.historyCount > 0 ? String(this.historyCount) : '本机')
                .fontSize(12).fontColor('#9499A0')
              Image($r('app.media.ic_arrow_right')).width(18).height(18).fillColor('#C1C2C5')
            }
            .width('100%').height(48).padding({ left: 14, right: 14 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => { AppNavStack.pushPathByName(NAV_YOUTUBE_SAVED, 'history'); })
            Divider().strokeWidth(0.5)
              .color(this.isDark ? '#1FFFFFFF' : '#0F000000')
              .margin({ left: 48, right: 14 })
          }.width('100%')
          ForEach(['订阅内容', '播放列表'], (label: string, index: number) => {
            Column() {
              Row({ space: 14 }) {
                Text(label).fontSize(15).fontColor('#9499A0').layoutWeight(1)
                Text('未解锁').fontSize(12).fontColor('#9499A0')
                Image($r('app.media.ic_arrow_right')).width(18).height(18).fillColor('#C1C2C5')
              }
              .width('100%').height(48).padding({ left: 14, right: 14 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.toast('连接 YouTube 账号后可用'); })
              if (index < 1) {
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
      .animationDuration(MotionTokens.duration(MotionTokens.navigation, this.reduceMotion))
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

/**
 * YouTube 结果卡片：视觉规格复刻哔哩哔哩首页卡片（components/video/VideoCard.ets 的
 * homeStyle 分支），保证两个平台观感一致——白色容器卡 + 圆角 16 + 阴影 8 + 按压缩放，
 * 封面 4:3 + 底部渐变遮罩，渐变行左侧数据 / 右侧时长，标题固定两行，底栏为作者行。
 *
 * 与哔哩哔哩的差异只来自数据本身，不来自设计：YouTube 无弹幕、无多P、无 UP 徽标，
 * 观看次数是本地化字符串（"8,537次观看"）而非数字，因此直接使用原始文案。
 *
 * 行数据用轻量 @Prop 字符串传入，跳转由调用方经 onTap 注入（同 VideoRowCard 的接口设计）。
 * @Reusable：结果列表走 LazyForEach 长列表，滚动时复用卡片实例，避免整卡重建。
 * 封面就绪态是行内局部 @State：单张封面解码完成只刷新本行，不再波及整个结果列表。
 */
@Reusable
@Component
struct YouTubeVideoCard {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  /** 封面显示源：本地缓存文件 URI 或远端 URL，由宿主构建行时经 thumbnailOf 解析。 */
  @Prop @Watch('onCoverChanged') cover: string = '';
  @Prop title: string = '';
  @Prop channel: string = '';
  /** 观看次数 / 时长 / 发布时间：本地化原始文案，空串不显示。 */
  @Prop views: string = '';
  @Prop duration: string = '';
  @Prop published: string = '';
  onTap: () => void = () => {
  };
  @StorageProp('isDarkMode') isDark: boolean = false;
  /** 封面已可显示：远端图等解码完成再淡入，本地缓存文件（file://）直接可见。 */
  @State coverShown: boolean = false;

  aboutToAppear(): void {
    this.coverShown = this.isLocalCover(this.cover);
  }

  aboutToReuse(params: Record<string, Object>): void {
    // 复用实例属性同步（@Prop 自动跟随，这里承接回调引用等非常量绑定）。
    const tap: Object | undefined = params['onTap'];
    if (typeof tap === 'function') {
      this.onTap = tap as () => void;
    }
  }

  private onCoverChanged(): void {
    // 换封面回到就绪判定：本地文件直接可见，远端图等解码完成后淡入。
    this.coverShown = this.isLocalCover(this.cover);
  }

  private isLocalCover(source: string): boolean {
    return source.startsWith('file://');
  }

  build() {
    Column() {
      // 封面：点击区是封面本身，与哔哩哔哩一致。
      Stack() {
        Image(this.cover)
          .width('100%')
          .aspectRatio(4 / 3)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.isDark ? '#2A2C31' : '#E5E7EB')
          .draggable(false)
          .syncLoad(false)
          // 封面淡入：解码完成前保持透明，完成后过渡出现（失败也收尾，不留空白卡）。
          .opacity(this.coverShown ? 1 : 0)
          .animation({ duration: MotionTokens.duration(MotionTokens.feedback, this.reduceMotion), curve: Curve.EaseOut })
          .onComplete(() => {
            if (!this.coverShown) this.coverShown = true;
          })
          .onError(() => {
            if (!this.coverShown) this.coverShown = true;
          })

        // 底部渐变行：左 = 观看次数，右 = 时长（对齐哔哩哔哩「播放/弹幕 ... 时长」层级）。
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%').height(40)
            .linearGradient({ angle: 180, colors: [['#00000000', 0.0], ['#A6000000', 1.0]] })
          Row({ space: 10 }) {
            if (this.views.length > 0) {
              Row({ space: 4 }) {
                Stack() {
                  Image($r('app.media.ic_play'))
                    .width(6).height(6)
                    .renderMode(ImageRenderMode.Template).fillColor('#FFFFFF')
                }
                .width(17).height(12).alignContent(Alignment.Center)
                .border({ width: 1, color: '#FFFFFF', radius: 3 })
                Text(this.views).fontSize(11).fontColor('#FFFFFF').maxLines(1)
              }.alignItems(VerticalAlign.Center)
            }
            Blank()
            if (this.duration.length > 0) {
              Text(this.duration).fontSize(11).fontColor('#FFFFFF').maxLines(1)
            }
          }
          .width('100%').height(32).padding({ left: 8, right: 8 })
          .alignItems(VerticalAlign.Center)
        }
        // 必须显式铺满：只给宽度的子节点会被父 Stack 垂直居中，
        // 结果观看数/时长那一行跑到封面正中间，而不是贴底。
        .width('100%').height('100%')
      }
      .width('100%')
      .aspectRatio(4 / 3)
      .clip(true)
      .onClick(() => {
        this.onTap();
      })

      // 标题：固定两行高度，卡片高度不随标题长短变化（同哔哩哔哩 50vp 规格）。
      Row() {
        Text(this.title)
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
      .onClick(() => {
        this.onTap();
      })

      // 作者行：哔哩哔哩此处是「UP 徽标 + 作者名」，YouTube 对应频道名 + 发布时间。
      Row({ space: 6 }) {
        Text(this.channel)
          .fontSize(11)
          .fontColor(this.isDark ? '#A5AAB5' : '#7D8490')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.published.length > 0) {
          Text(this.published)
            .fontSize(11)
            .fontColor(this.isDark ? '#8A8A8F' : '#9499A0')
            .maxLines(1)
        }
      }
      .width('100%')
      .height(32)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onTap();
      })
    }
    .width('100%')
    .padding({ bottom: 6 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.isDark ? '#24272E' : '#FFFFFF')
    .borderRadius(16)
    .clip(true)
    .shadow({ radius: 8, color: '#08000000', offsetX: 0, offsetY: 1 })
    .animation({ duration: MotionTokens.duration(MotionTokens.feedback, this.reduceMotion), curve: Curve.EaseOut })
    .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
  }
}
