import { VideoChapter } from '../../api/BiliApi';
import { formatDuration } from '../../common/Utils';
import { PlayerProgressBar } from './PlayerProgressBar';

@Component
export struct PlayerCompactControls {
  @Prop playing: boolean = false;
  @Prop progress: number = 0;
  @Prop duration: number = 0;
  @Prop chapters: Array<VideoChapter> = [];
  @Prop titleColor: string = '#FFFFFF';
  onBack: () => void = () => {};
  onPlay: () => void = () => {};
  onMore: () => void = () => {};
  onFullscreen: () => void = () => {};
  onProgressChange: (value: number, mode: SliderChangeMode) => void = () => {};
  onProgressInteractionEnd: () => void = () => {};

  @Builder
  IconButton(icon: Resource, iconSize: number, boxSize: number, circleBg: boolean, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      if (circleBg) {
        Circle().width(32).height(32).fill('#66000000')
      }
      Image(icon)
        .width(iconSize)
        .height(iconSize)
        .renderMode(ImageRenderMode.Template)
        .fillColor('#FFFFFF')
    }
    .width(boxSize)
    .height(boxSize)
    .onClick(() => onTap())
  }

  build() {
    if (!this.playing) {
      Stack({ alignContent: Alignment.Center }) {
        Column().width('100%').height('100%').backgroundColor('#CC0B0C10')
        Row() {
          this.IconButton($r('app.media.ic_back'), 24, 42, false, () => this.onBack())
          Blank()
          Row({ space: 9 }) {
            Image($r('app.media.ic_video_replay'))
              .width(31)
              .height(31)
              .renderMode(ImageRenderMode.Template)
              .fillColor('#F2FFFFFF')
            Text('立即播放')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#F2FFFFFF')
          }
          .height(48)
          .padding({ left: 8, right: 8 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => this.onPlay())
          Blank()
          this.IconButton($r('app.media.ic_more'), 22, 42, false, () => this.onMore())
        }
        .width('100%')
        .height('100%')
        .padding({ left: 6, right: 6 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')
    } else {
      Column() {
        Blank()
        Row({ space: 7 }) {
          this.IconButton($r('app.media.ic_pause'), 16, 36, true, () => this.onPlay())
          Text(formatDuration(this.progress)).fontSize(10).fontColor(this.titleColor)
          PlayerProgressBar({
            value: this.progress,
            duration: this.duration,
            compact: true,
            chapters: this.chapters,
            onChange: (value: number, mode: SliderChangeMode) => this.onProgressChange(value, mode),
            onInteractionEnd: () => this.onProgressInteractionEnd(),
          })
          this.IconButton($r('app.media.ic_fullscreen'), 20, 36, false, () => this.onFullscreen())
        }
        .width('100%')
        .height(44)
        .padding({ left: 8, right: 8, bottom: 4 })
      }
      .width('100%')
      .height('100%')
    }
  }
}
