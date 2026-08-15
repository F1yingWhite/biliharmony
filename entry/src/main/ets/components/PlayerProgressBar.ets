import { VideoChapter } from '../api/BiliApi';

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
  onChange: (value: number, mode: SliderChangeMode) => void = () => {};

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
        .width('100%')
        .height(this.compact ? 20 : 36)
        .blockSize(this.compact ? { width: 8, height: 8 } : undefined)
        .blockColor('#FFFFFF')
        .selectedColor('#FB7299')
        .trackColor(this.compact ? '#55FFFFFF' : '#33FFFFFF')
        .onChange((next: number, mode: SliderChangeMode) => {
          this.onChange(next, mode);
        })
    }
    .layoutWeight(1)
    // 小横幅只占合理比例，避免减少控制项后进度条吞掉整行剩余宽度。
    .constraintSize({ maxWidth: this.compact ? 190 : 10000 })
    .height(this.compact ? 20 : 36)
  }
}
