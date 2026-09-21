import { VideoChapter } from '../../api/BiliApi';
import { SponsorBlockSegment } from '../../common/SponsorBlock';
import { formatDuration } from '../../common/Utils';
import { PlayerProgressBar } from './PlayerProgressBar';
import { PlayerScrubController, PlayerScrubTarget } from './PlayerGestureOverlay';

@Component
export struct PlayerCompactControls {
  @Prop playing: boolean = false;
  @Prop progress: number = 0;
  @Prop duration: number = 0;
  /** 横滑快进的待落点：进度条跟手显示它，seek 完成后宿主清零回落真实进度。 */
  @State scrubPreview: number = -1;
  scrubCtl: PlayerScrubController | null = null;
  private scrubTarget: PlayerScrubTarget | null = null;

  aboutToAppear(): void {
    const ctl: PlayerScrubController | null = this.scrubCtl;
    if (ctl !== null) {
      this.scrubTarget = { showScrub: (value: number): void => { this.scrubPreview = value; } };
      ctl.attach(this.scrubTarget);
    }
  }

  aboutToDisappear(): void {
    const ctl: PlayerScrubController | null = this.scrubCtl;
    if (ctl !== null && this.scrubTarget !== null) {
      ctl.detach(this.scrubTarget);
      this.scrubTarget = null;
    }
  }

  private displayProgress(): number {
    return this.scrubPreview >= 0 ? this.scrubPreview : this.progress;
  }

  @Prop chapters: Array<VideoChapter> = [];
  @Prop sponsorSegments: Array<SponsorBlockSegment> = [];
  @Prop titleColor: string = '#FFFFFF';
  onBack: () => void = () => {};
  onHome: () => void = () => {};
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
          Image($r('app.media.ic_tab_home'))
            .width(42).height(42).padding(10)
            .renderMode(ImageRenderMode.Template).fillColor('#FFFFFF')
            .accessibilityText('返回主页').id('player-home-entry')
            .onClick(() => this.onHome())
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
          Text(formatDuration(this.displayProgress())).fontSize(10).fontColor(this.titleColor)
          PlayerProgressBar({
            value: this.displayProgress(),
            duration: this.duration,
            compact: true,
            chapters: this.chapters,
            sponsorSegments: this.sponsorSegments,
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
