import { LiveRoomItem } from '../model/LiveModels';
import { AppNavStack, LiveRoomParam, NAV_LIVE_ROOM } from '../common/AppRouter';
import { FeedCardTitle, FeedCoverImage, FeedGradientMask } from './FeedCardParts';

@Reusable
@Component
export struct LiveRoomCard {
  @Prop room: LiveRoomItem = new LiveRoomItem();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    this.room = params.room as LiveRoomItem;
  }

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        FeedCoverImage({ cover: this.room.cover, isDark: this.isDark })
        FeedGradientMask({ height: 42, bottomColor: '#99000000' })
        Row({ space: 5 }) {
          Image($r('app.media.ic_live'))
            .width(13)
            .height(13)
            .fillColor('#FFFFFF')
          Text(this.room.watched.length > 0 ? this.room.watched : '直播中')
            .fontSize(11)
            .fontColor('#FFFFFF')
          Blank()
          Text(this.room.areaName)
            .fontSize(10)
            .fontColor('#FFFFFF')
            .maxLines(1)
        }
        .width('100%')
        .padding({ left: 8, right: 8, bottom: 7 })
      }
      .width('100%')
      .clip(true)
      .borderRadius(12)

      FeedCardTitle({ title: this.room.title, isDark: this.isDark })
      Row({ space: 6 }) {
        if (this.room.face.length > 0) {
          Image(this.room.face)
            .width(18)
            .height(18)
            .borderRadius(9)
            .objectFit(ImageFit.Cover)
        }
        Text(this.room.uname)
          .fontSize(11)
          .fontColor(this.isDark ? '#8A8A8E' : '#9499A0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .stateStyles({ pressed: { opacity: 0.82 }, normal: { opacity: 1 } })
    .onClick(() => {
      const param: LiveRoomParam = {
        roomId: this.room.roomId, uid: this.room.uid, title: this.room.title,
        uname: this.room.uname, face: this.room.face, cover: this.room.cover,
      };
      AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
    })
  }
}
