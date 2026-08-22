import { VideoChapter } from '../../api/BiliApi';
import { SponsorBlockSegment, sponsorBlockCategory } from '../../common/SponsorBlock';

/**
 * 播放器进度条与视频分段刻度。
 * 只负责展示/拖动，不拥有 seek 状态，避免与 AVPlayer 的串行 seek 状态机耦合。
 */
@Component
export struct PlayerProgressBar {
  @Prop value: number = 0;
  @Prop duration: number = 0;
  @Prop compact: boolean = false;
  @Prop chapters: Array<VideoChapter> = [];
  @Prop sponsorSegments: Array<SponsorBlockSegment> = [];
  onChange: (value: number, mode: SliderChangeMode) => void = () => {};
  /** Slider 节点在拖动中被替换时可能收不到 End，直接监听手指抬起/取消做保底。 */
  onInteractionEnd: () => void = () => {};

  @Builder
  ChapterTicks() {
    Row() {
      ForEach(this.chapters, (chapter: VideoChapter, index: number) => {
        Column()
          .height(8)
          .layoutWeight(Math.max(1, chapter.to - chapter.from))
          .border({
            width: { right: index < this.chapters.length - 1 ? 1.2 : 0 },
            color: '#D9FFFFFF',
          })
      }, (chapter: VideoChapter, index: number) => 'tick-' + String(chapter.from) + '-' + String(index))
    }
    .width('100%')
    .height(8)
    .padding({ left: 7, right: 7 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  SponsorMarks() {
    Stack({ alignContent: Alignment.Start }) {
      ForEach(this.sponsorSegments, (segment: SponsorBlockSegment, index: number) => {
        if (segment.actionType !== 'full' && this.duration > 0) {
          Row()
            .width((segment.actionType === 'poi' ? 0.45 :
              Math.max(0.25, (Math.min(this.duration, segment.end) - Math.max(0, segment.start)) /
                this.duration * 100)) + '%')
            .height(this.compact ? 3 : 4)
            .backgroundColor(sponsorBlockCategory(segment.category).color)
            .position({ x: (Math.max(0, Math.min(100, segment.start / this.duration * 100))) + '%' })
        }
      }, (segment: SponsorBlockSegment, index: number) => 'sponsor-' + segment.uuid + '-' + String(index))
    }
    .width('100%')
    .height(this.compact ? 3 : 4)
    .padding({ left: 7, right: 7 })
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.chapters.length > 1) this.ChapterTicks()
      Slider({
        value: this.value,
        min: 0,
        max: this.duration > 0 ? this.duration : 1,
        // 收起态仍使用细轨道；InSet 会在播放器越矮时反而显得更粗。
        style: SliderStyle.OutSet,
      })
        .id('qa_player_progress_slider')
        .width('100%')
        .height(this.compact ? 20 : 36)
        .blockSize(this.compact ? { width: 11, height: 11 } : { width: 14, height: 14 })
        .blockStyle({ type: SliderBlockType.IMAGE, image: $r('app.media.ic_progress_tv') })
        .selectedColor('#FB7299')
        .trackColor(this.compact ? '#55FFFFFF' : '#33FFFFFF')
        .onChange((next: number, mode: SliderChangeMode) => {
          this.onChange(next, mode);
        })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.onInteractionEnd();
          }
        })
      if (this.sponsorSegments.length > 0) this.SponsorMarks()
    }
    .layoutWeight(1)
    // 由 layoutWeight 吃掉中间剩余宽度，确保紧凑态的全屏键始终贴在最右侧。
    .height(this.compact ? 20 : 36)
  }
}
