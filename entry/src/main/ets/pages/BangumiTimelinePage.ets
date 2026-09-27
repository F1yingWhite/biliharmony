/**
 * 新番时间表：今天起未来一周番剧/国创开播安排，按天分组展示。
 * 数据源 pgc/web/timeline（types 1 番剧 / 4 国创），点击条目进番剧详情。
 */
import { RequestEpoch } from '../common/RequestEpoch';
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_BANGUMI_DETAIL, BangumiDetailParam } from '../common/AppRouter';
import { PageHeader } from '../components/PageHeader';
import { BangumiApi } from '../api/BangumiApi';
import { TimeLineEpisode, TimeLineDay } from '../model/Models';
import { LoadingView } from '../components/LoadingView';
import { biliImageThumbnail } from '../common/ImageUrl';
import { colorWithAlpha } from '../common/Utils';
import { common } from '@kit.AbilityKit';
import { AirReminderService } from '../services/notify/AirReminderService';

@Component
export struct BangumiTimelinePage {
  @State days: Array<TimeLineDay> = [];
  @State loading: boolean = true;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  /** 已登记开播提醒的 key 集合（key = air_seasonId_dayIdx_HHMM）。 */
  @State reminderKeys: Set<string> = new Set<string>();

  private requestEpoch: RequestEpoch = new RequestEpoch();

  private reminderKey(ep: TimeLineEpisode, dateTimestamp: number): string {
    return 'air_' + String(ep.seasonId) + '_' + String(dateTimestamp) + '_' + ep.pubTime;
  }

  private context(): common.UIAbilityContext | undefined {
    return this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
  }

  /** 进入页面时批量恢复提醒登记态（本地记录，无网络）。 */
  private async restoreReminders(): Promise<void> {
    const context: common.UIAbilityContext | undefined = this.context();
    if (context === undefined) return;
    const next: Set<string> = new Set<string>();
    for (let d: number = 0; d < this.days.length; d++) {
      for (let i: number = 0; i < this.days[d].episodes.length; i++) {
        const ep: TimeLineEpisode = this.days[d].episodes[i];
        if (await AirReminderService.isScheduled(context, this.reminderKey(ep, this.days[d].dateTimestamp))) {
          next.add(this.reminderKey(ep, this.days[d].dateTimestamp));
        }
      }
    }
    this.reminderKeys = next;
  }

  /** 提醒时间：优先用接口下发的日期时间戳（date_ts，秒），否则按今天 + pubTime。已过去返回 null。 */
  private reminderDate(pubTime: string, dateTimestamp: number): Date | null {
    const parts: Array<string> = pubTime.split(':');
    if (parts.length < 2) return null;
    const hour: number = Number(parts[0]);
    const minute: number = Number(parts[1]);
    if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
    const at: Date = new Date();
    if (dateTimestamp > 0) {
      const base: Date = new Date(dateTimestamp * 1000);
      at.setFullYear(base.getFullYear(), base.getMonth(), base.getDate());
    }
    at.setHours(hour, minute, 0, 0);
    return at.getTime() <= Date.now() ? null : at;
  }

  private toggleReminder(ep: TimeLineEpisode, dateTimestamp: number): void {
    const context: common.UIAbilityContext | undefined = this.context();
    if (context === undefined) return;
    const key: string = this.reminderKey(ep, dateTimestamp);
    if (this.reminderKeys.has(key)) {
      AirReminderService.cancel(context, key).then(() => {
        const next: Set<string> = new Set<string>(this.reminderKeys);
        next.delete(key);
        this.reminderKeys = next;
        this.toast('已取消开播提醒');
      }).catch(() => {
      });
      return;
    }
    const at: Date | null = this.reminderDate(ep.pubTime, dateTimestamp);
    if (at === null) {
      this.toast('该时间已过，无法设置提醒');
      return;
    }
    // 提前 5 分钟提醒，留出打开应用的时间。
    const fireAt: Date = new Date(at.getTime() - 5 * 60 * 1000);
    AirReminderService.schedule(context, key, ep.title,
      (ep.index.length > 0 ? ep.index + ' ' : '') + ep.pubTime + ' 开播', fireAt).then((ok: boolean) => {
      if (!ok) {
        this.toast('提醒设置失败，请检查系统通知权限');
        return;
      }
      const next: Set<string> = new Set<string>(this.reminderKeys);
      next.add(key);
      this.reminderKeys = next;
      this.toast('开播前 5 分钟将提醒你');
    }).catch(() => {
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // toast 失败忽略。
    }
  }

  aboutToDisappear(): void {
    this.requestEpoch.invalidate();
  }

  async aboutToAppear(): Promise<void> {
    this.loadTimeline().catch(() => {
    });
  }

  async loadTimeline(): Promise<void> {
    const epoch: number = this.requestEpoch.next();
    this.loading = true;
    this.errorText = '';
    try {
      // types=1 番剧 + types=4 国创 分别获取后按日期合并。
      const timelines: Array<Array<TimeLineDay>> = await Promise.all([
        BangumiApi.getTimeline(1, 0, 7), BangumiApi.getTimeline(4, 0, 7),
      ]);
      if (this.requestEpoch.isCurrent(epoch)) this.days = this.mergeDays(timelines[0], timelines[1]);
      this.restoreReminders().catch(() => {
      });
    } catch (e) {
      if (this.requestEpoch.isCurrent(epoch)) this.errorText = '时间表加载失败，请检查网络后重试';
    } finally {
      if (this.requestEpoch.isCurrent(epoch)) this.loading = false;
    }
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
          existing.isToday = existing.isToday || day.isToday;
          existing.dateTimestamp = existing.dateTimestamp || day.dateTimestamp;
          existing.episodes = existing.episodes.concat(day.episodes);
        } else {
          const merged: TimeLineDay = new TimeLineDay();
          merged.date = day.date;
          merged.dateTimestamp = day.dateTimestamp;
          merged.isToday = day.isToday;
          merged.dayOfWeek = day.dayOfWeek;
          merged.episodes = day.episodes.slice();
          map.set(day.date, merged);
        }
      }
    };
    feed(a);
    feed(b);
    const out: Array<TimeLineDay> = Array.from(map.values());
    out.sort((left: TimeLineDay, right: TimeLineDay) => left.dateTimestamp - right.dateTimestamp);
    for (let i: number = 0; i < out.length; i++) {
      out[i].episodes.sort((left: TimeLineEpisode, right: TimeLineEpisode) => left.pubTime.localeCompare(right.pubTime));
    }
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
        if (day.isToday) {
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
          BellRow({
            on: this.reminderKeys.has(this.reminderKey(ep, day.dateTimestamp)),
            onToggle: (): void => this.toggleReminder(ep, day.dateTimestamp),
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
          LoadingView({ loading: true, skeleton: 'list' })
        }
        .width('100%').layoutWeight(1)
      } else if (this.errorText.length > 0) {
        LoadingView({ loading: false, errorText: this.errorText,
          onRetry: () => this.loadTimeline().catch(() => {}) })
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
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}

@Component
struct BellRow {
  on: boolean = false;
  onToggle: () => void = () => {};
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  build() {
    Stack() {
      Image(this.on ? $r('app.media.ic_bell_fill') : $r('app.media.ic_notify_bell'))
        .width(20).height(20)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.on ? this.accent : (this.isDark ? '#8A8F99' : '#9499A0'))
    }
    .width(36).height(36)
    .alignContent(Alignment.Center)
    .borderRadius(18)
    .backgroundColor(this.on ? colorWithAlpha(this.accent, '1A') : '#00000000')
    .onClick(() => this.onToggle())
  }
}
