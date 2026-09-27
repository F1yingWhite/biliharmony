import { KeywordSpans } from '../KeywordSpans';
import { MotionTokens } from '../../common/MotionTokens';
import { LiveRoomItem } from '../../model/LiveModels';
import { AppNavStack, LiveRoomParam, NAV_LIVE_ROOM } from '../../common/AppRouter';
import { FeedCardTitle, FeedCoverImage, FeedGradientMask } from '../FeedCardParts';

@Reusable
@Component
export struct LiveRoomCard {
  @Prop highlightKeyword: string = '';
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
            .layoutWeight(1).textAlign(TextAlign.End)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
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
      .border({
        width: 0.6,
        color: this.isDark ? '#26FFFFFF' : '#1C000000',
      })
      .shadow({
        radius: 12,
        color: this.isDark ? '#59000000' : '#1F000000',
        offsetX: 0,
        offsetY: 4,
      })

      FeedCardTitle({ title: this.room.title, isDark: this.isDark, highlightKeyword: this.highlightKeyword })
      Row({ space: 6 }) {
        if (this.room.face.length > 0) {
          Image(this.room.face)
            .width(18)
            .height(18)
            .borderRadius(9)
            .objectFit(ImageFit.Cover)
        }
        Text() { KeywordSpans({ text: this.room.uname, keyword: this.highlightKeyword, isDark: this.isDark }) }
          .fontSize(11)
          .fontColor(this.isDark ? '#8A8A8E' : '#9499A0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .animation({ duration: MotionTokens.feedback, curve: Curve.EaseOut })
    .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
    .onClick(() => {
      const param: LiveRoomParam = {
        roomId: this.room.roomId, uid: this.room.uid, title: this.room.title,
        uname: this.room.uname, face: this.room.face, cover: this.room.cover,
      };
      AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
    })
  }
}
