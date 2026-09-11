import { RequestEpoch } from '../common/RequestEpoch';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
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
import { LiveRoomRow } from '../components/live/LiveRoomRow';
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
  @State zonesLoading: boolean = true;
  @State failed: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private roomSource: BasicDataSource<LiveRoomItem> = new BasicDataSource<LiveRoomItem>();

  private roomEpoch: RequestEpoch = new RequestEpoch();
  private zoneEpoch: RequestEpoch = new RequestEpoch();

  aboutToDisappear(): void {
    this.roomEpoch.invalidate();
    this.zoneEpoch.invalidate();
  }

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
    const epoch: number = this.zoneEpoch.next();
    this.zonesLoading = true;
    this.errorText = '';
    try {
      const zones: Array<LiveZone> = await LiveApi.getLiveZones();
      if (this.zoneEpoch.isCurrent(epoch)) this.zones = zones;
    } catch (e) {
      if (this.zoneEpoch.isCurrent(epoch)) this.errorText = '分区加载失败，请检查网络后重试';
    } finally {
      if (this.zoneEpoch.isCurrent(epoch)) this.zonesLoading = false;
    }
  }

  async loadRooms(reset: boolean): Promise<void> {
    if (this.zoneId <= 0 || this.loading || (!reset && !this.hasMore)) return;
    const epoch: number = this.roomEpoch.next();
    this.loading = true;
    this.errorText = '';
    this.failed = false;
    try {
      const pn: number = reset ? 1 : this.page + 1;
      const list: Array<LiveRoomItem> = await LiveApi.getLiveZoneRooms(this.zoneId, pn, 20);
      if (!this.roomEpoch.isCurrent(epoch)) return;
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
      if (!this.roomEpoch.isCurrent(epoch)) return;
      this.failed = true;
      this.errorText = '加载失败，请检查网络后重试';
    } finally {
      if (this.roomEpoch.isCurrent(epoch)) this.loading = false;
    }
  }

  selectZone(id: number): void {
    this.roomEpoch.invalidate();
    this.loading = false;
    Haptic.tap();
    this.zoneId = id;
    this.zoneName = this.findZoneName(id);
    this.roomSource.clear();
    this.hasMore = true;
    this.loadRooms(true).catch(() => {
    });
  }

  backToZones(): void {
    this.roomEpoch.invalidate();
    this.loading = false;
    this.failed = false;
    this.errorText = '';
    this.zoneId = -1;
    this.roomSource.clear();
  }

  @Builder
  ZoneGrid() {
    if (this.zones.length === 0) {
      LoadingView({ skeleton: 'sessions', loading: this.zonesLoading, empty: !this.zonesLoading && !this.errorText, emptyText: '暂无直播分区', errorText: this.errorText,
        onRetry: () => {
          this.loadZones().catch(() => {
          });
        } })

    } else {
      Scroll() {
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
        .padding({ left: 16, right: 16 })
        .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
        .alignSelf(ItemAlign.Center)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
        .align(Alignment.TopStart).padding({ top: 8 })
    }
  }

  @Builder
  ZoneRooms() {
    Column() {
      if (this.roomSource.isEmpty() && this.loading) {
        LoadingView({ skeleton: 'list', loading: true })
      } else if (this.roomSource.isEmpty() && this.errorText.length > 0) {
        LoadingView({ skeleton: 'list', loading: false, empty: !this.failed, emptyText: this.errorText, errorText: this.failed ? this.errorText : '', onRetry: () => {
          this.loadRooms(true).catch(() => {
          });
        } })

      } else {
        List() {
          LazyForEach(this.roomSource, (room: LiveRoomItem) => {
            ListItem() {
              LiveRoomRow({ room: room })
            }
          }, (room: LiveRoomItem) => String(room.roomId))
          ListItem() {
            LoadMoreFooter({ loading: this.loading, hasMore: this.hasMore,
              moreText: this.failed ? '加载失败 · 点击重试' : '加载更多',
              loadingText: '加载中…', fixedHeight: 48,
              onLoadMore: () => this.loadRooms(false) })
          }
        }
        .width('100%').layoutWeight(1)
        .padding({ left: 16, right: 16 })
        .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
        .alignSelf(ItemAlign.Center)
        .scrollBar(BarState.Off)
        .cachedCount(3)
        .onReachEnd(() => {
          if (this.hasMore && !this.loading && !this.failed) {
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
      PageHeader({ title: this.zoneId < 0 ? '直播分区' : this.zoneName,
        onBack: () => { if (this.zoneId > 0) this.backToZones(); else AppNavStack.pop(); } })
      if (this.zoneId < 0) {
        this.ZoneGrid()
      } else {
        this.ZoneRooms()
      }
    }
    .width('100%').height('100%')
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#141519' : '#F6F7F9')
  }
}
