/**
 * 排行榜页：全站排行 / 每周必看 / 入站必刷
 * 全站排行 ranking/v2(rid=0)；每周必看 popular/series 最新一期；入站必刷 popular/precious
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { BiliApi } from '../api/BiliApi';
import { PopularSeriesData, PopularSeriesItem, VideoItem } from '../model/Models';
import { LoadingView } from '../components/LoadingView';
import { PageHeader } from '../components/PageHeader';
import { VideoRowCard } from '../components/video/VideoRowCard';
import { BasicDataSource } from '../common/BasicDataSource';
import { LayoutTokens } from '../common/LayoutTokens';
import { SearchApi } from '../api/SearchApi';

@Component
export struct RankPage {
  @State tab: number = 0; // 0 全站排行 / 1 每周必看 / 2 入站必刷
  @State rankLoading: boolean = false;
  @State weeklyLoading: boolean = false;
  @State preciousLoading: boolean = false;
  @State rankCount: number = 0;
  @State weeklyCount: number = 0;
  @State preciousCount: number = 0;
  @State rankError: string = '';
  @State weeklyError: string = '';
  @State preciousError: string = '';
  /** 每周必看期次文案，如「第365期」 */
  @State weeklyLabel: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private rankSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private weeklySource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  private preciousSource: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();

  aboutToAppear(): void {
    this.loadRank().catch(() => {
    });
  }

  async loadRank(): Promise<void> {
    if (this.rankLoading) {
      return;
    }
    this.rankLoading = true;
    this.rankError = '';
    try {
      const list: Array<VideoItem> = await SearchApi.getRankVideos(0);
      this.rankSource.reset(list);
      this.rankCount = this.rankSource.totalCount();
      if (list.length === 0) {
        this.rankError = '排行榜加载失败，请检查网络后重试';
      }
    } catch (e) {
      if (this.rankSource.isEmpty()) {
        this.rankError = '排行榜加载失败，请检查网络后重试';
      }
    } finally {
      this.rankLoading = false;
    }
  }

  /** 每周必看：series/list 取最新一期 number，再由 series/one 拉该期视频。 */
  async loadWeekly(): Promise<void> {
    if (this.weeklyLoading) {
      return;
    }
    this.weeklyLoading = true;
    this.weeklyError = '';
    try {
      const series: Array<PopularSeriesItem> = await SearchApi.getPopularSeriesList();
      if (series.length === 0) {
        this.weeklyError = '每周必看加载失败，请检查网络后重试';
        return;
      }
      const data: PopularSeriesData = await SearchApi.getPopularSeriesOne(series[0].number);
      this.weeklyLabel = data.label.length > 0 ? data.label : series[0].name;
      this.weeklySource.reset(data.videos);
      this.weeklyCount = this.weeklySource.totalCount();
      if (data.videos.length === 0) {
        this.weeklyError = '每周必看加载失败，请检查网络后重试';
      }
    } catch (e) {
      if (this.weeklySource.isEmpty()) {
        this.weeklyError = '每周必看加载失败，请检查网络后重试';
      }
    } finally {
      this.weeklyLoading = false;
    }
  }

  async loadPrecious(): Promise<void> {
    if (this.preciousLoading) {
      return;
    }
    this.preciousLoading = true;
    this.preciousError = '';
    try {
      const list: Array<VideoItem> = await SearchApi.getPopularPrecious(1);
      this.preciousSource.reset(list);
      this.preciousCount = this.preciousSource.totalCount();
      if (list.length === 0) {
        this.preciousError = '入站必刷加载失败，请检查网络后重试';
      }
    } catch (e) {
      if (this.preciousSource.isEmpty()) {
        this.preciousError = '入站必刷加载失败，请检查网络后重试';
      }
    } finally {
      this.preciousLoading = false;
    }
  }

  onTabChanged(index: number): void {
    this.tab = index;
    // 切到未加载过的 Tab 时拉取首屏
    if (index === 0 && this.rankSource.isEmpty()) {
      this.loadRank().catch(() => {
      });
    } else if (index === 1 && this.weeklySource.isEmpty()) {
      this.loadWeekly().catch(() => {
      });
    } else if (index === 2 && this.preciousSource.isEmpty()) {
      this.loadPrecious().catch(() => {
      });
    }
  }

  // ===== 二级 Tab 栏（与搜索结果页同款文字 + 主题色下划线） =====
  @Builder
  RankTabBar(index: number, label: string) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(this.tab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.tab === index ? (this.isDark ? '#FFFFFF' : '#18191C') : '#9499A0')
      Text('')
        .width(18)
        .height(2.5)
        .borderRadius(1.5)
        .backgroundColor(this.tab === index ? this.accent : '#00000000')
    }
    .padding({ left: 18, right: 18, top: 6 })
    .animation({ duration: 180, curve: Curve.EaseOut })
  }

  // ===== 榜单行：排名序号徽标（前三名主题色）+ 视频行卡片 =====
  @Builder
  RankRow(item: VideoItem, index: number) {
    Row() {
      Text(String(index + 1))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(index < 3 ? this.accent : '#9499A0')
        .width(26)
        .textAlign(TextAlign.Center)
      Column() {
        VideoRowCard({
          cover: item.cover,
          title: item.title,
          upName: item.upName,
          overlayText: item.playText + ' · ' + item.danmakuText,
          extraText: item.tname,
          onTap: () => {
            const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
            AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
          },
        })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
  }

  // ===== Tab 内容：加载 / 错误 / 空态 + 榜单列表 =====
  // 注意：状态一律用闭包在 Builder 体内读取。@Builder 按值传参会生成静态快照，
  // 状态变化后不刷新（页面卡在加载态的根因）。
  @Builder
  RankTabContent(getLoading: () => boolean, getCount: () => number, getError: () => string,
    getHeaderText: () => string,
    source: BasicDataSource<VideoItem>, onRetry: () => void) {
    Column() {
      if (getLoading() && getCount() === 0) {
        LoadingView({ loading: true })
      } else if (getCount() === 0) {
        LoadingView({
          loading: false,
          empty: getError().length === 0,
          emptyText: '暂无榜单数据',
          errorText: getError(),
          onRetry: onRetry,
        })
      } else {
        List() {
          if (getHeaderText().length > 0) {
            ListItem() {
              Text(getHeaderText())
                .fontSize(12)
                .fontColor('#9499A0')
                .width('100%')
                .padding({ left: 14, right: 14, top: 10, bottom: 2 })
            }
          }
          LazyForEach(source, (item: VideoItem, index: number) => {
            ListItem() {
              this.RankRow(item, index)
            }
          }, (item: VideoItem, index: number) => item.bvid + String(item.aid) + '_' + String(index))
        }
        .width('100%')
        .height('100%')
        .cachedCount(5)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      PageHeader({ title: '排行榜' })
      Tabs({ barPosition: BarPosition.Start, index: $$this.tab }) {
        TabContent() {
          this.RankTabContent(() => this.rankLoading, () => this.rankCount, () => this.rankError, () => '',
            this.rankSource, () => {
              this.loadRank().catch(() => {
              });
            })
        }
        .tabBar(this.RankTabBar(0, '全站排行'))
        TabContent() {
          this.RankTabContent(() => this.weeklyLoading, () => this.weeklyCount, () => this.weeklyError,
            () => this.weeklyLabel.length > 0 ? '每周必看 · ' + this.weeklyLabel : '', this.weeklySource, () => {
              this.loadWeekly().catch(() => {
              });
            })
        }
        .tabBar(this.RankTabBar(1, '每周必看'))
        TabContent() {
          this.RankTabContent(() => this.preciousLoading, () => this.preciousCount, () => this.preciousError,
            () => '',
            this.preciousSource,
            () => {
              this.loadPrecious().catch(() => {
              });
            })
        }
        .tabBar(this.RankTabBar(2, '入站必刷'))
      }
      .barHeight(40)
      .divider(null)
      .animationDuration(200)
      .onChange((index: number) => {
        this.onTabChanged(index);
      })
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#F6F7F8')
    .constraintSize({ maxWidth: LayoutTokens.pageMaxWidth })
    .alignSelf(ItemAlign.Center)
  }
}
