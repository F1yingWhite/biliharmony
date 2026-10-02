import { RelationUserItem } from '../../model/Models';
import { AppNavStack, NAV_LIVE_ROOM, NAV_USER_SPACE, LiveRoomParam, UserSpaceParam } from '../../common/AppRouter';
import { Haptic } from '../../common/Haptic';

@Component
export struct DynamicFollowStrip {
  @Prop followed: Array<RelationUserItem> = [];
  @Prop liveRooms: Map<number, number> = new Map<number, number>();
  @StorageProp('isDarkMode') isDark: boolean = false;

  /** 关注栏 UP「直播中」角标点击：直达直播间。 */
  private openLiveRoom(mid: number): void {
    const roomId: number | undefined = this.liveRooms.get(mid);
    if (roomId === undefined || roomId <= 0) return;
    Haptic.tap();
    const followee: RelationUserItem | undefined =
      this.followed.find((u: RelationUserItem) => u.mid === mid);
    const param: LiveRoomParam = {
      roomId: roomId,
      uid: mid,
      title: '',
      uname: followee !== undefined ? followee.uname : '',
      face: followee !== undefined ? followee.face : '',
      cover: '',
    };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  /** 顶部「关注 UP 主」横滑栏：第一条动态下展示关注对象，点击进用户空间；开播中的 UP 带红点。 */
  build() {
    List({ space: 14 }) {
      ForEach(this.followed, (u: RelationUserItem) => {
        ListItem() {
          Column({ space: 6 }) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Stack({ alignContent: Alignment.Center }) {
                Image(u.face.length > 0 ? u.face : $r('app.media.placeholder_avatar_noface'))
                  .width(46)
                  .height(46)
                  .borderRadius(23)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor(this.isDark ? '#33353A' : '#EEF0F2')
                  .syncLoad(false)
              }
              .width(47)
              .height(47)
              if (this.liveRooms.get(u.mid) !== undefined) {
                // 直播中角标：与 B 站 App 关注栏一致，点角标直达直播间。
                Text('直播中')
                  .fontSize(8)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#F53F3F')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .borderRadius(6)
                  .margin({ right: -2, top: -2 })
                  .priorityGesture(TapGesture().onAction(() => {
                    this.openLiveRoom(u.mid);
                  }))
              }
            }
            .width(47)
            .height(47)
            Text(u.uname)
              .fontSize(11)
              .fontColor(this.isDark ? '#C9C9CE' : '#61666D')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(62)
              .textAlign(TextAlign.Center)
          }
          .width(64)
          .onClick(() => {
            Haptic.tap();
            if (u.mid > 0) {
              const param: UserSpaceParam = { mid: u.mid };
              AppNavStack.pushPathByName(NAV_USER_SPACE, param);
            }
          })
          .stateStyles({
            pressed: { opacity: 0.6 },
            normal: { opacity: 1 },
          })
        }
      }, (u: RelationUserItem) => String(u.mid))
    }
    .listDirection(Axis.Horizontal)
    .width('100%')
    .height(84)
    .padding({ left: 4, right: 4 })
    .scrollBar(BarState.Off)
    .cachedCount(4)
  }

}
