import { LiveRoomItem } from '../model/LiveModels';
import { AppNavStack, LiveRoomParam, NAV_LIVE_ROOM } from '../common/AppRouter';

@Component
export struct LiveRoomCard {
  room: LiveRoomItem = new LiveRoomItem();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(this.room.cover)
          .width('100%')
          .aspectRatio(16 / 9)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
          .backgroundColor(this.isDark ? '#2A2C31' : '#E5E7EB')
          .alt($r('app.media.placeholder_cover'))
          .draggable(false)
        Column()
          .width('100%')
          .height(42)
          .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#99000000', 1]] })
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

      Text(this.room.title)
        .width('100%')
        .fontSize(14)
        .lineHeight(19)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
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
