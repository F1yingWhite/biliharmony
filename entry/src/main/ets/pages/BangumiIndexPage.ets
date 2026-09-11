/**
 * 番剧索引页：按类型（番剧/国创/电影/电视剧/纪录片）× 状态（全部/连载/完结）筛选的番剧聚合。
 * 数据源 pgc/season/index/result，点击条目进入番剧详情。
 */
import { RequestEpoch } from '../common/RequestEpoch';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_BANGUMI_DETAIL, NAV_BANGUMI_TIMELINE, BangumiDetailParam } from '../common/AppRouter';
import { BangumiApi } from '../api/BangumiApi';
import { BangumiIndexItem } from '../model/Models';
import { LoadingView } from '../components/LoadingView';
import { PageHeader } from '../components/PageHeader';
import { BasicDataSource } from '../common/BasicDataSource';
import { LayoutTokens } from '../common/LayoutTokens';
import { Haptic } from '../common/Haptic';
import { biliImageThumbnail } from '../common/ImageUrl';

interface BangumiTypeOption {
  label: string;
  value: number;
}

const BANGUMI_TYPES: Array<BangumiTypeOption> = [
  { label: '番剧', value: 1 },
  { label: '国创', value: 4 },
  { label: '电影', value: 2 },
  { label: '剧集', value: 5 },
  { label: '纪录片', value: 3 },
];

const FINISH_OPTIONS: Array<BangumiTypeOption> = [
  { label: '全部', value: -1 },
  { label: '连载中', value: 0 },
  { label: '已完结', value: 1 },
];

@Component
export struct BangumiIndexPage {
  @State type: number = 1;
  @State finish: number = -1;
  @State loading: boolean = false;
  @State page: number = 1;
  @State hasMore: boolean = true;
  @State moreFailed: boolean = false;
  @State errorText: string = '';
  @State failed: boolean = false;
  @State totalText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private source: BasicDataSource<BangumiIndexItem> = new BasicDataSource<BangumiIndexItem>();
  private requestEpoch: RequestEpoch = new RequestEpoch();
  private destroyed: boolean = false;

  aboutToAppear(): void {
    this.destroyed = false;
    this.load(true).catch(() => {});
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.requestEpoch.invalidate();
  }

  async load(reset: boolean): Promise<void> {
    if (this.destroyed || (!reset && (this.loading || !this.hasMore))) return;
    const epoch: number = this.requestEpoch.next();
    this.loading = true;
    this.failed = false;
    this.moreFailed = false;
    if (reset) {
      this.errorText = '';
      this.source.clear();
      this.totalText = '';
      this.page = 1;
      this.hasMore = true;
    }
    const pn: number = reset ? 1 : this.page + 1;
    try {
      const data = await BangumiApi.getIndex(this.type, this.finish, pn, 0);
      if (!this.requestEpoch.isCurrent(epoch)) return;
      if (reset) {
        this.source.reset(data.items);
        this.totalText = data.total > 0 ? '共 ' + String(data.total) + ' 部' : '';
        if (data.items.length === 0) this.errorText = '该筛选下暂无作品';
      } else {
        this.source.append(data.items);
      }
      this.page = pn;
      this.hasMore = data.hasNext && data.items.length > 0;
    } catch (e) {
      if (!this.requestEpoch.isCurrent(epoch)) return;
      if (reset) {
        this.failed = true;
        this.errorText = '加载失败，请检查网络后重试';
      } else {
        this.moreFailed = true;
      }
    } finally {
      if (this.requestEpoch.isCurrent(epoch)) this.loading = false;
    }
  }

  switchFilter(nextType: number, nextFinish: number): void {
    if (this.type === nextType && this.finish === nextFinish) return;
    this.type = nextType;
    this.finish = nextFinish;
    this.load(true).catch(() => {});
  }

  @Builder
  ResultFooter() {
    LoadMoreFooter({
      loading: this.loading,
      hasMore: this.hasMore,
      moreText: this.moreFailed ? '加载失败 · 点击重试' : '加载更多',
      endText: '已显示全部作品',
      fixedHeight: 44,
      onLoadMore: () => this.load(false).catch(() => {}),
    })
  }

  @Builder
  Chip(label: string, value: number, isType: boolean) {
    Text(label)
      .fontSize(13)
      .fontColor((isType ? this.type : this.finish) === value ? '#FFFFFF' : (this.isDark ? '#C9C9CE' : '#61666D'))
      .padding({ left: 13, right: 13, top: 6, bottom: 6 })
      .borderRadius(15)
      .backgroundColor((isType ? this.type : this.finish) === value ? this.accent : (this.isDark ? '#2A2C31' : '#F0F1F3'))
      .animation({ duration: 160, curve: Curve.EaseOut })
      .onClick(() => {
        Haptic.tap();
        this.switchFilter(isType ? value : this.type, isType ? this.finish : value);
      })
  }

  @Builder
  TypeRow() {
    Row({ space: 8 }) {
      ForEach(BANGUMI_TYPES, (o: BangumiTypeOption) => {
        this.Chip(o.label, o.value, true)
      }, (o: BangumiTypeOption) => 't' + o.label)
      Blank()
    }
    .width('100%')
  }

  @Builder
  FinishRow() {
    Row({ space: 8 }) {
      ForEach(FINISH_OPTIONS, (o: BangumiTypeOption) => {
        this.Chip(o.label, o.value, false)
      }, (o: BangumiTypeOption) => 'f' + o.label)
      Blank()
    }
    .width('100%')
  }

  @Builder
  CoverCard(item: BangumiIndexItem) {
    Column({ space: 6 }) {
      // 高度必须由外层 Stack 的 aspectRatio 给定：若只标在 Image 上，
      // 内层 height('100%') 的评分覆盖层会让 Stack 测量成列表可视高度，
      // 造成卡片上方一大片空白、封面被挤到底部。
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(item.cover.length > 0 ? biliImageThumbnail(item.cover, 300) : item.cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(8)
          .backgroundColor(this.isDark ? '#26272B' : '#EEF0F2')
          .syncLoad(false)
        if (item.badge.length > 0) {
          Text(item.badge)
            .fontSize(9)
            .fontColor('#FFFFFF')
            .backgroundColor(item.badgeBgColor)
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .borderRadius(3)
            .margin({ left: 6, bottom: 6 })
        }
        // 评分布章：Stack 子组件不能各自独立对齐（align 会被容器的 alignContent 覆盖），
        // 必须包一层等大覆盖 Stack 才能固定在右上角，否则会和左下角"大会员"徽标叠在一起。
        Stack({ alignContent: Alignment.TopEnd }) {
          if (item.score.length > 0 && item.score !== '0') {
            Text('★ ' + item.score)
              .fontSize(11)
              .fontColor('#FFFFFF')
              .backgroundColor('#66000000')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(4)
              .margin(6)
          }
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .aspectRatio(0.7)
      .clip(true)
      Text(item.title)
        .height(36).lineHeight(18)
        .fontSize(13)
        .fontColor(this.isDark ? '#F0F0F2' : '#18191C')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (item.indexShow.length > 0) {
        Text(item.indexShow)
          .height(14)
          .fontSize(10)
          .fontColor('#9499A0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      } else if (item.subTitle.length > 0) {
        Text(item.subTitle)
          .height(14)
          .fontSize(10)
          .fontColor('#9499A0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      } else {
        Text('').height(14)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      Haptic.tap();
      const param: BangumiDetailParam = { seasonId: item.seasonId, epId: 0, title: item.title };
      AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
    })
    .stateStyles({
      pressed: { opacity: 0.7 },
      normal: { opacity: 1 },
    })
  }

  @Builder
  TimelineEntry() {
    Row({ space: 4 }) {
      Image($r('app.media.ic_history'))
        .width(15).height(15)
        .fillColor(this.accent)
      Text('时间表')
        .fontSize(12).fontColor(this.accent)
    }
    .padding({ left: 16, right: 2, top: 8, bottom: 8 })
    .onClick(() => {
      AppNavStack.pushPathByName(NAV_BANGUMI_TIMELINE, null);
    })
  }

  build() {
    Column() {
      PageHeader({
        title: '番剧索引',
        trailing: (): void => {
          this.TimelineEntry()
        },
      })
      Column({ space: 8 }) {
        this.TypeRow()
        this.FinishRow()
        Row() {
          Text(this.totalText)
            .fontSize(10)
            .fontColor('#9499A0')
          Blank()
        }
        .width('100%')
        .height(16)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 4 })

      if (this.source.isEmpty() && this.loading) {
        LoadingView({ skeleton: 'poster', loading: true })

      } else if (this.source.isEmpty() && this.errorText.length > 0) {
        LoadingView({ skeleton: 'poster', loading: false, empty: !this.failed, emptyText: this.errorText, errorText: this.failed ? this.errorText : '', onRetry: () => {
          this.load(true).catch(() => {
          });
        } })

      } else {
        List({ space: 12 }) {
          ListItemGroup({ footer: this.ResultFooter(), space: 12 }) {
          LazyForEach(this.source, (item: BangumiIndexItem) => {
            ListItem() {
              this.CoverCard(item)
            }
          }, (item: BangumiIndexItem) => String(item.seasonId))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
        .alignSelf(ItemAlign.Center)
        .lanes(3, 10)
        .scrollBar(BarState.Off)
        .cachedCount(6)
        .onReachEnd(() => {
          if (this.hasMore && !this.loading && !this.moreFailed) {
            this.load(false).catch(() => {
            });
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#141519' : '#F6F7F9')
  }
}
