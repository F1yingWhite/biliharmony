/**
 * 我的追番/追剧列表页：展示登录用户已追的番剧与影视（pgc/web/follow/list）。
 * 顶部标签在「番剧 / 影视」间切换，竖向列表，点击进番剧详情。
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_BANGUMI_DETAIL, BangumiDetailParam } from '../common/AppRouter';
import { BangumiApi } from '../api/BangumiApi';
import { UserStore } from '../services/auth/UserStore';
import { WatchLaterSeasonItem } from '../model/Models';
import { LoadingView } from '../components/LoadingView';
import { PageHeader } from '../components/PageHeader';
import { BasicDataSource } from '../common/BasicDataSource';
import { LayoutTokens } from '../common/LayoutTokens';

@Component
export struct BangumiListPage {
  @State type: number = 1; // 1=番剧 2=影视
  @State loading: boolean = false;
  @State count: number = 0;
  @State errorText: string = '';
  @State page: number = 1;
  @State hasMore: boolean = false;
  @State listLoading: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private source: BasicDataSource<WatchLaterSeasonItem> = new BasicDataSource<WatchLaterSeasonItem>();

  aboutToAppear(): void {
    this.load(true).catch(() => {
    });
  }

  async load(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) {
      return;
    }
    this.loading = true;
    if (reset) this.errorText = '';
    try {
      await UserStore.ensureLoaded();
      const mid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      if (mid <= 0) {
        this.errorText = '请先登录后查看追番';
        return;
      }
      const pn: number = reset ? 1 : this.page + 1;
      const list: Array<WatchLaterSeasonItem> = await BangumiApi.getFollowList(this.type, pn, mid);
      if (list.length === 0 && reset) {
        this.errorText = '还没有追番，去番剧详情页点「+ 追番」吧';
      }
      if (reset) {
        this.source.reset(list);
        this.page = 1;
        this.hasMore = list.length >= 20;
      } else {
        this.source.append(list);
        this.page = pn;
        this.hasMore = list.length >= 20;
      }
      this.count = this.source.totalCount();
    } catch (e) {
      if (reset && this.source.isEmpty()) {
        this.errorText = '加载失败，点击重试';
      }
    } finally {
      this.loading = false;
    }
  }

  switchType(t: number): void {
    if (t === this.type || this.listLoading) {
      return;
    }
    this.type = t;
    this.listLoading = true;
    this.load(true).finally(() => {
      this.listLoading = false;
    });
  }

  @Builder
  TypeTab(label: string, value: number) {
    Text(label)
      .fontSize(15)
      .fontColor(this.type === value ? (this.isDark ? '#FFFFFF' : '#18191C') : '#9499A0')
      .fontWeight(this.type === value ? FontWeight.Bold : FontWeight.Normal)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .onClick(() => this.switchType(value))
  }

  build() {
    Column() {
      PageHeader({ title: '我的追番' })
      Row({ space: 4 }) {
        this.TypeTab('番剧', 1)
        this.TypeTab('影视', 2)
        Blank()
      }
      .width('100%')
      .padding({ left: 8 })
      .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })

      if (this.source.isEmpty() && this.loading) {
        LoadingView({ loading: true })
          .margin({ top: 60 })
      } else if (this.source.isEmpty() && this.errorText.length > 0) {
        LoadingView({
          loading: false,
          empty: this.errorText.length === 0 ? false : true,
          emptyText: this.errorText,
          onRetry: () => {
            this.load(true).catch(() => {
            });
          },
        })
          .margin({ top: 60 })
      } else {
        List() {
          LazyForEach(this.source, (item: WatchLaterSeasonItem) => {
            ListItem() {
              Row({ space: 11 }) {
                Stack({ alignContent: Alignment.BottomEnd }) {
                  Image(item.cover)
                    .width(132)
                    .height(74)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(7)
                  if (item.typeText.length > 0) {
                    Text(item.typeText)
                      .fontSize(9)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#99000000')
                      .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                      .borderRadius(3)
                      .margin({ right: 4, bottom: 4 })
                  }
                }
                .clip(true)
                Column({ space: 6 }) {
                  Text(item.title)
                    .fontSize(14)
                    .fontColor(this.isDark ? '#F0F0F2' : '#18191C')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.desc.length > 0 ? item.desc : item.newEpDesc)
                    .fontSize(11)
                    .fontColor('#9499A0')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.subText)
                    .fontSize(11)
                    .fontColor('#B0B3B8')
                    .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ top: 10, bottom: 10 })
              .onClick(() => {
                const param: BangumiDetailParam = {
                  seasonId: item.seasonId,
                  epId: 0,
                  title: item.title,
                };
                AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
              })
              // 与信息流卡片统一按压反馈
              .stateStyles({
                pressed: { opacity: 0.8 },
                normal: { opacity: 1 },
              })
            }
          }, (item: WatchLaterSeasonItem) => String(item.seasonId))
          ListItem() {
            Text(this.hasMore ? (this.loading ? '加载中…' : '加载更多') : '—— 到底啦 ——')
              .width('100%')
              .fontSize(12)
              .fontColor('#9499A0')
              .textAlign(TextAlign.Center)
              .padding({ top: 14, bottom: 14 })
              .onClick(() => {
                if (this.hasMore && !this.loading) {
                  this.load(false).catch(() => {
                  });
                }
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
        .alignSelf(ItemAlign.Center)
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .onReachEnd(() => {
          if (this.hasMore && !this.loading) {
            this.load(false).catch(() => {
            });
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#141519' : '#F6F7F9')
  }
}
