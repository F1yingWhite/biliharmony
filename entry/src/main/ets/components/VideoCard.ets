/**
 * 视频卡片（B 站风格）：封面 + 时长/播放/弹幕 + 标题 + UP
 * 带毛玻璃遮罩与渐变光感效果
 * @Reusable：LazyForEach 回收复用，数据通过 @Prop + aboutToReuse 刷新
 */
import { VideoItem } from '../model/Models';
import { formatDuration } from '../common/Utils';
import { AppNavStack, NAV_VIDEO_DETAIL, VideoDetailParam } from '../common/AppRouter';
import { Haptic } from '../common/Haptic';
import { FeedCardTitle, FeedCoverImage, FeedGradientMask } from './FeedCardParts';

@Reusable
@Component
export struct VideoCard {
  @Prop video: VideoItem = new VideoItem();
  /** 用户空间等紧凑网格隐藏 UP/分区行，复用同一封面和跳转逻辑。 */
  @Prop compact: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    this.video = params.video as VideoItem;
    this.compact = params.compact === true;
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
      // 卡片整体由外层白色卡片承载边界，封面自身不再描边/投影。
      .aspectRatio(16 / 9)

      // 标题（@Builder 不能链式修饰，用 Row 承载左右内缩）
      // 固定两行高度：卡片高度不随标题长短变化，双列网格每张卡片严格等大、间距一致。
      Row() {
        FeedCardTitle({ title: this.video.title, isDark: this.isDark })
      }
      .width('100%')
      .height(38)
      .alignItems(VerticalAlign.Top)
      .padding({ left: 10, right: 10 })

      // UP 主 + 推荐理由 / 分区
      if (!this.compact) {
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
        .height(18)
        .alignItems(VerticalAlign.Center)
        .padding({ left: 10, right: 10 })
      }
    }
    .width('100%')
    .padding({ bottom: 10 })
    .alignItems(HorizontalAlign.Start)
    // 白色卡片承载边界：封面通顶、文字区内缩，浅色白底/深色深灰底。
    .backgroundColor(this.isDark ? '#2B2D34' : '#FFFFFF')
    .borderRadius(12)
    .clip(true)
    .shadow({ radius: 10, color: this.isDark ? '#59000000' : '#14000000', offsetX: 0, offsetY: 3 })
    .stateStyles({
      pressed: {
        opacity: 0.85,
      },
      normal: {
        opacity: 1,
      },
    })
    .id('video-card-' + (this.video.bvid.length > 0 ? this.video.bvid : 'a' + String(this.video.aid)))
    .onClick(() => {
      Haptic.light();
      if (this.video.bvid.length > 0 || this.video.aid > 0) {
        const param: VideoDetailParam = { bvid: this.video.bvid, aid: this.video.aid, title: this.video.title };
        // 从卡片位置放大到全屏：记录卡片窗口矩形，详情页首帧压到矩形上再展开。
        // 根页面 push 无共享元素转场，且要关默认右滑动画（push 第三参 false）。
        try {
          const rect = this.getUIContext().getComponentUtils().getRectangleById(
            'video-card-' + (this.video.bvid.length > 0 ? this.video.bvid : 'a' + String(this.video.aid)));
          if (rect.size.width > 0 && rect.size.height > 0) {
            param.srcRect = {
              x: this.getUIContext().px2vp(rect.windowOffset.x),
              y: this.getUIContext().px2vp(rect.windowOffset.y),
              w: rect.size.width,
              h: rect.size.height,
            };
            AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param, false);
            return;
          }
        } catch (e) {
          // 取不到矩形则走默认转场。
        }
        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
      }
    })
  }
}
