import { LiveRoomItem } from '../../model/LiveModels';
import { AppNavStack, LiveRoomParam, NAV_LIVE_ROOM } from '../../common/AppRouter';
import { biliImageThumbnail } from '../../common/ImageUrl';

/** 封面单元格约 40% 屏宽（~150vp）：按 VideoCard 双列卡 900w/180vp 的同款 ~5 倍密度出图。 */
const COVER_RENDER_WIDTH: number = 750;

/** 分区中的紧凑直播行：固定封面高度，给标题和主播保留独立空间。 */
@Reusable
@Component
export struct LiveRoomRow {
  @Prop room: LiveRoomItem = new LiveRoomItem();
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    this.room = params.room as LiveRoomItem;
  }

  build() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(this.room.cover.length > 0 ? biliImageThumbnail(this.room.cover, COVER_RENDER_WIDTH) :
          this.room.cover)
          .width('100%').height('100%').objectFit(ImageFit.Cover)
          .alt($r('app.media.placeholder_cover'))
          .syncLoad(false)
        Text(this.room.watched.length > 0 ? this.room.watched : '直播中')
          .fontSize(10).fontColor('#FFFFFF').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .backgroundColor('#99000000').borderRadius(6).margin(6)
      }.width('40%').height(78).borderRadius(10).clip(true)
        .backgroundColor(this.isDark ? '#333842' : '#E3E6EC')
      Column({ space: 7 }) {
        Text(this.room.title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#F2F2F4' : '#18191C').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.room.uname).fontSize(11).fontColor(this.isDark ? '#A5AAB5' : '#747B86')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.room.areaName).fontSize(10).fontColor(this.isDark ? '#A5AAB5' : '#747B86')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
      .onClick(() => {
        const param: LiveRoomParam = { roomId: this.room.roomId, uid: this.room.uid,
          title: this.room.title, uname: this.room.uname, face: this.room.face, cover: this.room.cover };
        AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
      })
  }
}
