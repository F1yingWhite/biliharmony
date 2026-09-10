import { LiveApi } from '../../api/LiveApi';
import { FollowedLivePage, LiveRoomItem } from '../../model/LiveModels';
import { RequestEpoch } from '../../common/RequestEpoch';
import { UserStore } from '../../services/auth/UserStore';
import { AppNavStack, LiveRoomParam, NAV_LIVE_ROOM, NAV_LOGIN } from '../../common/AppRouter';

@Component
export struct FollowedLiveStrip {
  @Prop @Watch('refresh') refreshVersion: number = 0;
  @StorageProp('loginVersion') @Watch('refresh') loginVersion: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @State rooms: Array<LiveRoomItem> = [];
  @State loading: boolean = false;
  @State errorText: string = '';
  @State signedIn: boolean = false;
  @State liveCount: number = 0;
  @State hasMore: boolean = false;
  private page: number = 1;
  private epoch: RequestEpoch = new RequestEpoch();
  private destroyed: boolean = false;

  aboutToAppear(): void {
    this.destroyed = false;
    this.refresh();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.epoch.invalidate();
  }

  private refresh(): void {
    if (this.destroyed) return;
    this.load(true).catch(() => {});
  }

  private async load(reset: boolean): Promise<void> {
    if (this.destroyed || (!reset && (this.loading || !this.hasMore))) return;
    const token: number = this.epoch.next();
    this.loading = true;
    this.errorText = '';
    if (reset) {
      this.rooms = [];
      this.page = 1;
      this.liveCount = 0;
      this.hasMore = false;
    }
    try {
      await UserStore.ensureLoaded();
      if (!this.epoch.isCurrent(token)) return;
      this.signedIn = UserStore.isLogin;
      if (!this.signedIn) return;
      const result: FollowedLivePage = await LiveApi.getFollowedLiveRooms(this.page);
      if (!this.epoch.isCurrent(token)) return;
      const seen: Set<number> = new Set<number>(this.rooms.map((room: LiveRoomItem) => room.roomId));
      this.rooms = this.rooms.concat(result.rooms.filter((room: LiveRoomItem) => {
        if (seen.has(room.roomId)) return false;
        seen.add(room.roomId);
        return true;
      }));
      this.liveCount = result.liveCount;
      this.hasMore = result.hasMore && this.rooms.length < result.liveCount;
      this.page++;
    } catch (e) {
      if (this.epoch.isCurrent(token)) this.errorText = '关注直播加载失败，点击重试';
    } finally {
      if (this.epoch.isCurrent(token)) this.loading = false;
    }
  }

  private openRoom(room: LiveRoomItem): void {
    const param: LiveRoomParam = { roomId: room.roomId, uid: room.uid, title: room.title,
      uname: room.uname, face: room.face, cover: room.cover };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text('关注的直播').fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#EEEEF0' : '#18191C')
        Blank()
        if (this.signedIn && this.liveCount > 0) {
          Text(String(this.liveCount) + ' 人正在直播').fontSize(11).fontColor('#9499A0')
        }
      }.width('100%')
      if (this.rooms.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach(this.rooms, (room: LiveRoomItem) => {
              Column({ space: 5 }) {
                Stack({ alignContent: Alignment.Bottom }) {
                  Image(room.face || room.cover || $r('app.media.placeholder_avatar_noface'))
                    .width(48).height(48).borderRadius(24).objectFit(ImageFit.Cover)
                    .border({ width: 1.5, color: this.accent })
                  Text('直播中').fontSize(8).fontColor('#FFFFFF').backgroundColor(this.accent)
                    .padding({ left: 5, right: 5, top: 1, bottom: 1 }).borderRadius(5)
                }.height(52)
                Text(room.uname).fontSize(11).fontColor(this.isDark ? '#CACACE' : '#61666D')
                  .width('100%').textAlign(TextAlign.Center).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width(64).id('followed-live-' + String(room.roomId))
              .accessibilityText(room.uname + '，正在直播，' + room.title)
              .onClick(() => this.openRoom(room))
            }, (room: LiveRoomItem) => String(room.roomId))
            if (this.hasMore || this.errorText.length > 0) {
              Text(this.loading ? '加载中…' : (this.errorText.length > 0 ? '重试' : '更多'))
                .fontSize(11).fontColor(this.accent).width(52).height(72)
                .textAlign(TextAlign.Center).onClick(() => this.load(false).catch(() => {}))
            }
          }
        }.width('100%').align(Alignment.Start).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      } else if (this.loading) {
        Row({ space: 7 }) {
          LoadingProgress().width(18).height(18).color(this.accent)
          Text('正在加载关注直播…').fontSize(12).fontColor('#9499A0')
        }.width('100%').height(48)
      } else {
        Text(!this.signedIn ? '登录后查看关注的直播' : this.errorText ||
          (this.hasMore ? '继续加载关注直播' : '关注的主播暂未开播'))
          .fontSize(12).fontColor('#9499A0').width('100%').height(48)
          .onClick(() => {
            if (!this.signedIn) AppNavStack.pushPathByName(NAV_LOGIN, null);
            else this.load(!this.hasMore).catch(() => {});
          })
      }
    }.width('100%').padding({ left: 4, right: 4, top: 8, bottom: 12 })
  }
}
