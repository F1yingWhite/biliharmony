/**
 * 新番时间表：近一周（前后各 6 天）番剧/国创开播安排，按天分组展示。
 * 数据源 pgc/web/timeline（types 1 番剧 / 4 国创），点击条目进番剧详情。
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_BANGUMI_DETAIL, BangumiDetailParam } from '../common/AppRouter';
import { PageHeader } from '../components/PageHeader';
import { BangumiApi } from '../api/BangumiApi';
import { TimeLineEpisode, TimeLineDay } from '../model/Models';
import { LoadingView } from '../components/LoadingView';
import { biliImageThumbnail } from '../common/ImageUrl';

@Component
export struct BangumiTimelinePage {
  @State days: Array<TimeLineDay> = [];
  @State loading: boolean = true;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  async aboutToAppear(): Promise<void> {
    this.loadTimeline().catch(() => {
    });
  }

  async loadTimeline(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      // types=1 番剧 + types=4 国创 分别获取后按日期合并。
      const bangumi: Array<TimeLineDay> = await BangumiApi.getTimeline(1, 0, 7);
      const guochuang: Array<TimeLineDay> = await BangumiApi.getTimeline(4, 0, 7);
      this.days = this.mergeDays(bangumi, guochuang);
    } catch (e) {
      this.errorText = '时间表加载失败，请检查网络后重试';
    } finally {
      this.loading = false;
    }
  }

  /** 本地日期（与接口 MM-DD 格式一致）。 */
  private todayLabel(): string {
    const d: Date = new Date();
    return String(d.getMonth() + 1) + '-' + String(d.getDate());
  }

  /** 按日期排序合并两档 types。 */
  private mergeDays(a: Array<TimeLineDay>, b: Array<TimeLineDay>): Array<TimeLineDay> {
    const map: Map<string, TimeLineDay> = new Map<string, TimeLineDay>();
    const feed = (list: Array<TimeLineDay>): void => {
      for (let i: number = 0; i < list.length; i++) {
        const day: TimeLineDay = list[i];
        if (day.date.length === 0) continue;
        const existing: TimeLineDay | undefined = map.get(day.date);
        if (existing !== undefined) {
          existing.episodes = existing.episodes.concat(day.episodes);
        } else {
          const merged: TimeLineDay = new TimeLineDay();
          merged.date = day.date;
          merged.dayOfWeek = day.dayOfWeek;
          merged.episodes = day.episodes.slice();
          map.set(day.date, merged);
        }
      }
    };
    feed(a);
    feed(b);
    const keys: Array<string> = Array.from(map.keys()).sort();
    const out: Array<TimeLineDay> = [];
    for (let i: number = 0; i < keys.length; i++) out.push(map.get(keys[i]) as TimeLineDay);
    return out;
  }

  @Builder
  DayGroup(day: TimeLineDay, index: number) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(day.dayOfWeekLabel())
          .fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Text(day.date)
          .fontSize(12).fontColor('#9499A0')
        if (day.date === this.todayLabel()) {
          Text('今天')
            .fontSize(10).fontColor('#FFFFFF').backgroundColor(this.accent)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 }).borderRadius(4)
        }
      }
      .width('100%')
      if (day.episodes.length === 0) {
        Text('暂无排班').fontSize(12).fontColor('#9499A0').padding({ top: 4, bottom: 4 })
      } else {
        ForEach(day.episodes, (ep: TimeLineEpisode) => {
          Row({ space: 10 }) {
            Stack({ alignContent: Alignment.BottomEnd }) {
              if (ep.cover.length > 0) {
                Image(biliImageThumbnail(ep.cover, 200))
                  .width(96).height(60).borderRadius(6).objectFit(ImageFit.Cover)
              } else {
                Rect().width(96).height(60).fill(this.isDark ? '#33353A' : '#EEF0F2').radius(6)
              }
              if (ep.seasonType === 1) {
                Text('番剧')
                  .fontSize(9).fontColor('#FFFFFF').backgroundColor('#FB7299')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 }).borderRadius(3)
                  .margin({ right: 2, bottom: 2 })
              }
            }
            Column({ space: 5 }) {
              Text(ep.title)
                .fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Row({ space: 8 }) {
                Text(ep.pubTime)
                  .fontSize(11).fontColor(this.accent).fontWeight(FontWeight.Medium)
                Text(ep.index.length > 0 ? ep.index : '')
                  .fontSize(11).fontColor('#9499A0')
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .onClick(() => {
            if (ep.seasonId > 0) {
              const param: BangumiDetailParam = { seasonId: ep.seasonId, epId: 0, title: ep.title };
              AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
            }
          })
        }, (ep: TimeLineEpisode) => String(ep.seasonId) + ep.pubTime)
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#303136' : '#ECEEF0' })
  }

  build() {
    Column() {
      PageHeader({ title: '新番时间表' })
      if (this.loading) {
        Column() {
          LoadingView({ loading: true })
        }
        .width('100%').layoutWeight(1)
      } else if (this.errorText.length > 0) {
        Column({ space: 10 }) {
          Text(this.errorText).fontSize(13).fontColor('#9499A0')
          Text('重试').fontSize(13).fontColor(this.accent)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .border({ width: 1, color: this.accent, radius: 14 })
            .onClick(() => this.loadTimeline().catch(() => {
            }))
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.days, (day: TimeLineDay, index: number) => {
            ListItem() { this.DayGroup(day, index) }
          }, (day: TimeLineDay) => day.date)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Off)
        .cachedCount(3)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
