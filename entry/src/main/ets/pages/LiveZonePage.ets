/**
 * 直播分区页：展示直播一级分类（网游/手游/单机…），点进分区浏览在线直播间。
 * 数据源 room/v1/Area/getList + xlive/web-interface/v1/second/getList。
 */
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_LIVE_ROOM, LiveRoomParam } from '../common/AppRouter';
import { BiliApi } from '../api/BiliApi';
import { LiveRoomItem, LiveZone } from '../model/LiveModels';
import { LoadingView } from '../components/LoadingView';
import { PageHeader } from '../components/PageHeader';
import { LiveRoomCard } from '../components/LiveRoomCard';
import { BasicDataSource } from '../common/BasicDataSource';
import { LayoutTokens } from '../common/LayoutTokens';
import { colorWithAlpha } from '../common/Utils';
import { Haptic } from '../common/Haptic';
import { LiveApi } from '../api/LiveApi';

@Component
export struct LiveZonePage {
  /** 分区网格（-1 显示分区列表；>0 显示该分区直播间）。 */
  @State zoneId: number = -1;
  @State zoneName: string = '';
  @State zones: Array<LiveZone> = [];
  @State loading: boolean = false;
  @State page: number = 1;
  @State hasMore: boolean = true;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private roomSource: BasicDataSource<LiveRoomItem> = new BasicDataSource<LiveRoomItem>();

  aboutToAppear(): void {
    this.loadZones().catch(() => {
    });
  }

  private findZoneName(id: number): string {
    for (let i: number = 0; i < this.zones.length; i++) {
      if (this.zones[i].id === id) return this.zones[i].name;
    }
    return '直播';
  }

  async loadZones(): Promise<void> {
    try {
      this.zones = await LiveApi.getLiveZones();
    } catch (e) {
      this.errorText = '分区加载失败，请检查网络后重试';
    }
  }

  async loadRooms(reset: boolean): Promise<void> {
    if (this.loading || (!reset && !this.hasMore)) return;
    this.loading = true;
    if (reset) this.errorText = '';
    try {
      const pn: number = reset ? 1 : this.page + 1;
      const list: Array<LiveRoomItem> = await LiveApi.getLiveZoneRooms(this.zoneId, pn, 20);
      if (list.length === 0 && reset) {
        this.errorText = '该分区暂无直播';
      }
      if (reset) {
        this.roomSource.reset(list);
        this.page = 1;
      } else {
        this.roomSource.append(list);
        this.page = pn;
      }
      this.hasMore = list.length >= 20;
      if (this.roomSource.isEmpty() && this.errorText.length === 0) {
        this.hasMore = false;
      }
    } catch (e) {
      if (this.roomSource.isEmpty()) this.errorText = '加载失败，请检查网络后重试';
    } finally {
      this.loading = false;
    }
  }

  selectZone(id: number): void {
    Haptic.tap();
    this.zoneId = id;
    this.zoneName = this.findZoneName(id);
    this.roomSource.clear();
    this.hasMore = true;
    this.loadRooms(true).catch(() => {
    });
  }

  backToZones(): void {
    this.zoneId = -1;
    this.roomSource.clear();
  }

  @Builder
  ZoneGrid() {
    if (this.zones.length === 0) {
      LoadingView({ loading: !this.errorText, empty: this.errorText.length > 0, emptyText: this.errorText,
        onRetry: () => {
          this.loadZones().catch(() => {
          });
        } })
        .margin({ top: 60 })
    } else {
      Column({ space: 2 }) {
        ForEach(this.zones, (zone: LiveZone) => {
          Row({ space: 14 }) {
            Stack({ alignContent: Alignment.Center }) {
              Circle().width(38).height(38).fill(colorWithAlpha(this.accent, '22'))
              Text(zone.name.substring(0, 1))
                .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.accent)
            }
            .width(48)
            Text(zone.name)
              .fontSize(15).fontColor(this.isDark ? '#F0F0F2' : '#18191C')
            Blank()
            Text('›').fontSize(18).fontColor('#9499A0')
          }
          .width('100%')
          .height(54)
          .padding({ left: 14, right: 14 })
          .borderRadius(10)
          .backgroundColor(this.isDark ? '#26272B' : '#FFFFFF')
          .onClick(() => this.selectZone(zone.id))
          .animation({ duration: 120 })
        }, (zone: LiveZone) => String(zone.id))
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
      .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
      .alignSelf(ItemAlign.Center)
    }
  }

  @Builder
  ZoneRooms() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(24)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .onClick(() => this.backToZones())
        Text(this.zoneName + ' 分区')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      .width('100%').height(48).padding({ left: 12, right: 12 })

      if (this.roomSource.isEmpty() && this.loading) {
        LoadingView({ loading: true }).margin({ top: 60 })
      } else if (this.roomSource.isEmpty() && this.errorText.length > 0) {
        LoadingView({ loading: false, empty: true, emptyText: this.errorText, onRetry: () => {
          this.loadRooms(true).catch(() => {
          });
        } })
          .margin({ top: 60 })
      } else {
        List() {
          LazyForEach(this.roomSource, (room: LiveRoomItem) => {
            ListItem() {
              LiveRoomCard({ room: room })
            }
          }, (room: LiveRoomItem) => String(room.roomId))
          ListItem() {
            Text(this.hasMore ? (this.loading ? '加载中…' : '加载更多') : '—— 到底啦 ——')
              .width('100%').fontSize(12).fontColor('#9499A0').textAlign(TextAlign.Center)
              .padding({ top: 12, bottom: 12 })
              .onClick(() => {
                if (this.hasMore && !this.loading) {
                  this.loadRooms(false).catch(() => {
                  });
                }
              })
          }
        }
        .width('100%').layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
        .alignSelf(ItemAlign.Center)
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .onReachEnd(() => {
          if (this.hasMore && !this.loading) {
            this.loadRooms(false).catch(() => {
            });
          }
        })
      }
    }
    .width('100%').height('100%')
  }

  build() {
    Column() {
      PageHeader({ title: this.zoneId < 0 ? '直播分区' : this.zoneName })
      if (this.zoneId < 0) {
        this.ZoneGrid()
      } else {
        this.ZoneRooms()
      }
    }
    .width('100%').height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#141519' : '#F6F7F9')
  }
}