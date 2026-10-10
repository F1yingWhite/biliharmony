import { HotPoint, VideoChapter } from '../../api/BiliApi';
import { SponsorBlockSegment, sponsorBlockCategory } from '../../common/SponsorBlock';
import { PlayerProgressController, PlayerProgressTarget } from './PlayerProgressController';

class PlayerRenderedProgress {
  value: number;

  constructor(value: number) {
    this.value = value;
  }
}

/**
 * 播放器进度条与视频分段刻度。
 * 只负责展示/拖动，不拥有 seek 状态，避免与 播放内核的串行 seek 状态机耦合。
 */
@Component
export struct PlayerProgressBar {
  @Prop @Watch('onValueChanged') value: number = 0;
  /** 横滑/滑块的待落点优先于真实样本；-1 表示没有预览。 */
  @Prop @Watch('onPreviewChanged') previewValue: number = -1;
  @Prop @Watch('onControlsVisibleChanged') controlsVisible: boolean = true;
  @Prop duration: number = 0;
  @Prop compact: boolean = false;
  @Prop chapters: Array<VideoChapter> = [];
  @Prop sponsorSegments: Array<SponsorBlockSegment> = [];
  @Prop @Watch('onHotPointsChanged') hotPoints: Array<HotPoint> = [];
  @State private hotPointMaximum: number = 0;
  @State private renderedProgress: PlayerRenderedProgress = new PlayerRenderedProgress(0);
  progressCtl: PlayerProgressController | null = null;
  private attachedController: PlayerProgressController | null = null;
  private progressTarget: PlayerProgressTarget | null = null;
  private latestSample: number = -1;
  private sliderInteracting: boolean = false;
  private appeared: boolean = false;
  private mounting: boolean = false;
  onChange: (value: number, mode: SliderChangeMode) => void = () => {};
  /** Slider 节点在拖动中被替换时可能收不到 End，直接监听手指抬起/取消做保底。 */
  onInteractionEnd: () => void = () => {};

  aboutToAppear(): void {
    if (this.appeared) return;
    this.onHotPointsChanged();
    this.appeared = true;
    this.mounting = true;
    this.latestSample = -1;
    this.sliderInteracting = false;
    this.renderedProgress = new PlayerRenderedProgress(this.previewValue >= 0 ? this.previewValue : this.value);
    const ctl: PlayerProgressController | null = this.progressCtl;
    if (ctl !== null) {
      this.attachedController = ctl;
      this.progressTarget = {
        updateProgress: (value: number, smooth: boolean): void => this.onProgressSample(value, smooth),
      };
      ctl.attach(this.progressTarget);
    }
    this.mounting = false;
  }

  aboutToDisappear(): void {
    this.appeared = false;
    this.mounting = false;
    const ctl: PlayerProgressController | null = this.attachedController;
    if (ctl !== null && this.progressTarget !== null) ctl.detach(this.progressTarget);
    this.attachedController = null;
    this.progressTarget = null;
    this.sliderInteracting = false;
  }

  onValueChanged(): void {
    // 有采样通道时 value 仅用于初次展示；秒级时间文字不能反拉滑块。
    if (this.latestSample < 0 && this.previewValue < 0 && !this.sliderInteracting) {
      this.showProgress(this.value, false);
    }
  }

  onPreviewChanged(): void {
    if (this.previewValue >= 0) this.showProgress(this.previewValue, false);
    else if (!this.sliderInteracting) this.showProgress(this.latestSample >= 0 ? this.latestSample : this.value, false);
  }

  onControlsVisibleChanged(): void {
    if (!this.controlsVisible) {
      this.sliderInteracting = false;
      return;
    }
    // 隐藏时只缓存样本；显示时一次对齐，不从离开前的旧时间开始动画。
    this.showProgress(this.previewValue >= 0 ? this.previewValue :
      (this.latestSample >= 0 ? this.latestSample : this.value), false);
  }

  private onProgressSample(value: number, smooth: boolean): void {
    if (!this.appeared) return;
    this.latestSample = value;
    if (this.previewValue < 0 && !this.sliderInteracting) this.showProgress(value, smooth);
  }

  private showProgress(value: number, smooth: boolean): void {
    if (!this.appeared || !this.controlsVisible || !Number.isFinite(value) || value < 0) return;
    // aboutToAppear 回放时原生 Slider 还未创建，初始化不得调用 animateTo。
    if (this.mounting) {
      this.renderedProgress = new PlayerRenderedProgress(value);
      return;
    }
    this.getUIContext().animateTo({ duration: smooth ? 150 : 0, curve: Curve.Linear }, () => {
      // 新对象让相同采样也请求控件更新；原生相同目标可能沿用已有动画。
      this.renderedProgress = new PlayerRenderedProgress(value);
    });
  }

  private handleSliderChange(value: number, mode: SliderChangeMode): void {
    this.sliderInteracting = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
    this.showProgress(value, false);
    this.onChange(value, mode);
  }

  private finishSliderInteraction(): void {
    this.sliderInteracting = false;
    this.onInteractionEnd();
    if (this.previewValue < 0) this.showProgress(this.latestSample >= 0 ? this.latestSample : this.value, false);
  }

  onHotPointsChanged(): void {
    // 热度数据更新时只扫描一次，进度逐帧刷新无需再为每个分段求最大值。
    let maximum: number = 0;
    for (let i: number = 0; i < this.hotPoints.length; i++) {
      const detail: number = this.hotPoints[i].detail;
      if (detail > maximum) maximum = detail;
    }
    this.hotPointMaximum = maximum;
  }

  private heatAlpha(point: HotPoint): number {
    if (this.hotPointMaximum <= 0) return 0.5;
    return 0.25 + 0.65 * Math.min(1, point.detail / this.hotPointMaximum);
  }

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

  @Builder
  HeatMarks() {
    // 高能分段：宽度按时间占比、透明度按热度归一，叠加在轨道上方（不挡手势）。
    Stack({ alignContent: Alignment.Start }) {
      ForEach(this.hotPoints, (point: HotPoint, index: number) => {
        if (this.duration > 0) {
          Row()
            .width(Math.max(0.3, (point.to - point.from) / this.duration * 100) + '%')
            .height(this.compact ? 3 : 4)
            .borderRadius(2)
            .backgroundColor('#FB7299')
            .opacity(this.heatAlpha(point))
            .position({ x: Math.max(0, Math.min(100, point.from / this.duration * 100)) + '%' })
        }
      }, (point: HotPoint, index: number) => 'heat-' + String(point.from) + '-' + String(index))
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
        value: this.renderedProgress.value,
        min: 0,
        max: this.duration > 0 ? this.duration : 1,
        step: 0.01,
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
          this.handleSliderChange(next, mode);
        })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.finishSliderInteraction();
          }
        })
      if (this.sponsorSegments.length > 0) this.SponsorMarks()
      if (this.hotPoints.length > 0) this.HeatMarks()
    }
    .layoutWeight(1)
    // 由 layoutWeight 吃掉中间剩余宽度，确保紧凑态的全屏键始终贴在最右侧。
    .height(this.compact ? 20 : 36)
  }
}
