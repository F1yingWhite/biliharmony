import { VideoChapter } from '../../api/BiliApi';
import { chapterEnd, chapterIndexAt, chapterTitleAt } from './PlayerChapterSupport';
import { PlayerScrubController, PlayerScrubTarget } from './PlayerGestureOverlay';

/** 收起时按时间比例贴底显示分段文字；展开时显示当前章节与列表入口。 */
@Component
export struct PlayerChapterBar {
  @Prop chapters: Array<VideoChapter> = [];
  @Prop progress: number = 0;
  @Prop duration: number = 0;
  /** 横滑快进的待落点：章节条跟手显示它，seek 完成后宿主清零回落真实进度。 */
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

  @Prop controlsVisible: boolean = false;
  @Prop fullscreen: boolean = false;
  onSelect: (seconds: number) => void = () => {};
  onOpen: () => void = () => {};

  private start(chapter: VideoChapter): number {
    return this.duration > 0 ? Math.max(0, Math.min(100, chapter.from / this.duration * 100)) : 0;
  }

  private span(index: number): number {
    return this.duration > 0 ? Math.max(0, (chapterEnd(this.chapters, index, this.duration) /
      this.duration * 100) - this.start(this.chapters[index])) : 0;
  }

  build() {
    if (this.controlsVisible) {
      Row({ space: 6 }) {
        Text('章节').fontSize(11).fontColor('#DDFFFFFF')
        Text(chapterTitleAt(this.chapters, this.displayProgress(), this.duration) || '查看全部分段')
          .fontSize(12).fontColor('#FFFFFF').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: this.fullscreen ? 360 : 210 })
        Text('›').fontSize(20).fontColor('#FFFFFF')
      }
      .height(30).padding({ left: 12, right: 10 })
      .backgroundColor('#50000000').borderRadius(5)
      .id('player-current-chapter').accessibilityText('查看视频分段')
      .onClick(() => this.onOpen())
    } else {
      Stack({ alignContent: Alignment.BottomStart }) {
        ForEach(this.chapters, (chapter: VideoChapter, index: number) => {
          if (this.span(index) > 0) {
            Text(chapter.title)
              .fontSize(this.fullscreen ? 10 : 8).fontColor('#E6FFFFFF')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Clip })
              .textAlign(TextAlign.Center)
              .width(this.span(index) + '%').height(18)
              .padding({ left: 2, right: 2 })
              .backgroundColor(chapterIndexAt(this.chapters, this.displayProgress(), this.duration) === index ?
                '#45FFFFFF' : '#55000000')
              .border({ width: { right: 0.6 }, color: '#70FFFFFF' })
              .position({ x: this.start(chapter) + '%', y: 0 })
              .clip(true).id('player-chapter-segment-' + String(index))
              .accessibilityText(chapter.title + '，点击跳转')
              .onClick(() => this.onSelect(chapter.from))
          }
        }, (chapter: VideoChapter, index: number) => String(chapter.from) + '-' + String(index))
        Row().width(Math.max(0, Math.min(100, this.displayProgress() / Math.max(1, this.duration) * 100)) + '%')
          .height(1.5).backgroundColor('#FB7299').hitTestBehavior(HitTestMode.None)
      }.width('100%').height(18)
    }
  }
}
