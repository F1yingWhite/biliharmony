/**
 * 视频卡片（B 站风格）：封面 + 时长/播放/弹幕 + 标题 + UP
 * 带毛玻璃遮罩与渐变光感效果
 * @Reusable：LazyForEach 回收复用，数据通过 @Prop + aboutToReuse 刷新
 */
import { VideoItem } from '../model/Models';
import { formatDuration } from '../common/Utils';
import { AppNavStack, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { FeedCardTitle, FeedCoverImage, FeedGradientMask } from './FeedCardParts';

@Reusable
@Component
export struct VideoCard {
  @Prop video: VideoItem = new VideoItem();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    this.video = params.video as VideoItem;
  }

  build() {
    Column({ space: 6 }) {
      // 封面
      Stack() {
        FeedCoverImage({ cover: this.video.cover, isDark: this.isDark })
        // 覆盖层：上 = 多P标识，下 = 数据条（左播放/弹幕，右时长，同一行垂直居中保证对齐）
        Column() {
          Row() {
            Text('多P · ' + this.video.videos)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .backgroundColor('#99000000')
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .borderRadius(4)
              .visibility(this.video.videos > 1 ? Visibility.Visible : Visibility.None)
          }
          .width('100%')
          .padding({ left: 6, top: 6 })

          Blank()

          Stack({ alignContent: Alignment.BottomStart }) {
            FeedGradientMask({ height: 36, bottomColor: '#73000000' })
            Row({ space: 8 }) {
              Row({ space: 3 }) {
                Image($r('app.media.ic_play'))
                  .width(11)
                  .height(11)
                  .fillColor('#FFFFFF')
                Text(this.video.playText)
                  .fontSize(11)
                  .fontColor('#FFFFFF')
                  .maxLines(1)
                  .shadow({ radius: 2, color: '#66000000', offsetX: 0, offsetY: 1 })
              }
              .alignItems(VerticalAlign.Center)
              Row({ space: 3 }) {
                Image($r('app.media.ic_danmaku_on'))
                  .width(11)
                  .height(11)
                  .fillColor('#FFFFFF')
                Text(this.video.danmakuText)
                  .fontSize(11)
                  .fontColor('#FFFFFF')
                  .maxLines(1)
                  .shadow({ radius: 2, color: '#66000000', offsetX: 0, offsetY: 1 })
              }
              .alignItems(VerticalAlign.Center)
              Blank()
              Text(formatDuration(this.video.duration))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .backgroundColor('#99000000')
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .borderRadius(4)
                .visibility(this.video.duration > 0 ? Visibility.Visible : Visibility.None)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 8, right: 6, bottom: 6 })
          }
          .width('100%')
        }
        .width('100%')
        // 与封面同高：百分比高度会顶满 List 卡片槽位，改用相同宽高比
        .aspectRatio(16 / 9)
      }
      .width('100%')
      .clip(true)
      .borderRadius(12)
      .shadow({ radius: 12, color: this.isDark ? '#59000000' : '#1F000000', offsetX: 0, offsetY: 4 })

      // 标题
      FeedCardTitle({ title: this.video.title, isDark: this.isDark })

      // UP 主 + 推荐理由 / 分区
      Row({ space: 6 }) {
        Text(this.video.upName)
          .fontSize(11)
          .fontColor(this.isDark ? '#8a8a8a' : '#9499A0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.video.rcmdReason.length > 0 ? this.video.rcmdReason : this.video.tname)
          .fontSize(10)
          .fontColor(this.accent)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .border({ width: 0.5, color: this.accent, radius: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '48%' })
          .visibility(this.video.rcmdReason.length > 0 || this.video.tname.length > 0 ? Visibility.Visible : Visibility.None)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .stateStyles({
      pressed: {
        opacity: 0.85,
      },
      normal: {
        opacity: 1,
      },
    })
    .onClick(() => {
      if (this.video.bvid.length > 0 || this.video.aid > 0) {
        const param: VideoDetailParam = { bvid: this.video.bvid, aid: this.video.aid, title: this.video.title };
        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
      }
    })
  }
}
