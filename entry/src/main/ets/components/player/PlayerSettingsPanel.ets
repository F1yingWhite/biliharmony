import { VideoChapter } from '../../api/BiliApi';
import { formatDuration } from '../../common/Utils';
import { SubtitleTrack, VideoQualityOption } from '../../model/Models';

/** 播放器底部设置面板。业务状态由 PlayerView 持有，本组件仅渲染并回传用户选择。 */
@Component
export struct PlayerSettingsPanel {
  @Prop which: number = 0;
  @Prop fullscreen: boolean = false;
  @Prop embedded: boolean = false;
  /** 直播播放器复用时只展示通用的密度、透明度、字号、速度和帧率。 */
  @Prop basicDanmakuOnly: boolean = false;
  @Prop forceDark: boolean = false;
  @Prop accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @Prop dmOpacity: number = 0.85;
  @Prop dmFrameRate: number = 60;
  @Prop dmSpeed: number = 1;
  @Prop dmFontScale: number = 1.0;
  @Prop dmDensity: number = 22;
  @Prop dmBlockLevel: number = 0;
  @Prop blockScrollDm: boolean = false;
  @Prop blockTopDm: boolean = false;
  @Prop blockBottomDm: boolean = false;
  @Prop blockColorDm: boolean = false;
  @Prop qualityOptions: Array<VideoQualityOption> = [];
  @Prop activeQuality: number = 0;
  @Prop chapters: Array<VideoChapter> = [];
  @Prop currentTime: number = 0;
  @Prop playbackRate: number = 1;
  @Prop subtitles: Array<SubtitleTrack> = [];
  @Prop subtitleIndex: number = -1;
  @Prop subtitleOn: boolean = false;
  @Prop dmFilterRulesCount: number = 0;
  onSubtitleChange: (index: number) => void = () => {};
  onDmFilterTap: () => void = () => {};
  onBlockAdvancedToggle: (next: boolean) => void = () => {};
  onResetDanmaku: () => void = () => {};
  onDmOpacityChange: (value: number) => void = () => {};
  onDmFrameRateChange: (value: number) => void = () => {};
  onDmSpeedChange: (value: number) => void = () => {};
  onDmFontScaleChange: (value: number) => void = () => {};
  onDmDensityChange: (value: number) => void = () => {};
  onDmBlockLevelChange: (value: number) => void = () => {};
  onToggleDmBlock: (kind: string) => void = () => {};
  onQualityChange: (qn: number) => void = () => {};
  onChapterChange: (seconds: number) => void = () => {};
  onSpeedChange: (rate: number) => void = () => {};

  private darkMode(): boolean {
    return this.forceDark || this.isDark;
  }

  private titleColor(): string {
    return this.darkMode() ? '#FFFFFF' : '#18191C';
  }

  private subColor(): string {
    return this.darkMode() ? '#CCFFFFFF' : '#5A5F66';
  }

  private hintColor(): string {
    return this.darkMode() ? '#88FFFFFF' : '#9499A0';
  }

  private trackColor(): string {
    return this.darkMode() ? '#40FFFFFF' : '#33FFFFFF';
  }

  private unselectedBg(): string {
    return this.darkMode() ? '#26272B' : '#F0F1F3';
  }

  private cardBg(): string {
    return this.darkMode() ? '#26272B' : '#FFFFFF';
  }

  private dividerColor(): string {
    return this.darkMode() ? '#33343A' : '#F0F1F3';
  }

  private sectionTitleColor(): string {
    return this.darkMode() ? '#F1F2F4' : '#18191C';
  }

  private speedText(v: number): string {
    if (v <= 0.75) return '较慢';
    if (v <= 1.25) return '正常';
    if (v <= 1.75) return '较快';
    return '很快';
  }

  private stubToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  // 注意：状态值必须用闭包在 Builder 体内读取，不能按值传参——
  // @Builder 按值传参会生成静态快照，状态变化后 UI 不刷新（滑条/按钮“没反应”的根因）。
  @Builder
  DmSliderRow(label: string, getValue: () => number, min: number, max: number, onChange: (value: number) => void) {
    Row({ space: 10 }) {
      Text(label).width(52).fontSize(13).fontColor(this.sectionTitleColor())
      Slider({ value: getValue(), min: min, max: max, step: (max - min) / 50, style: SliderStyle.InSet })
        .layoutWeight(1)
        .height(22)
        .blockColor('#FFFFFF')
        .selectedColor(this.accent)
        .trackColor(this.trackColor())
        .onChange((next: number) => onChange(next))
      Text(Math.round(getValue() * 100) + '%')
        .width(44)
        .textAlign(TextAlign.End)
        .fontSize(12)
        .fontColor(this.subColor())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
  }

  @Builder
  DmSpeedRow(getValue: () => number, onChange: (value: number) => void) {
    Row({ space: 10 }) {
      Text('弹幕速度').width(52).fontSize(13).fontColor(this.sectionTitleColor())
      Slider({ value: getValue(), min: 0.5, max: 2, step: 0.05, style: SliderStyle.InSet })
        .layoutWeight(1)
        .height(22)
        .blockColor('#FFFFFF')
        .selectedColor(this.accent)
        .trackColor(this.trackColor())
        .onChange((next: number) => onChange(next))
      Text(this.speedText(getValue()))
        .width(44)
        .textAlign(TextAlign.End)
        .fontSize(12)
        .fontColor(this.subColor())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
  }

  @Builder
  DmFrameRateRow(getValue: () => number, onChange: (value: number) => void) {
    Row({ space: 10 }) {
      Text('弹幕帧率').width(52).fontSize(13).fontColor(this.sectionTitleColor())
      Slider({ value: getValue(), min: 24, max: 120, step: 1, style: SliderStyle.InSet })
        .layoutWeight(1)
        .height(22)
        .blockColor('#FFFFFF')
        .selectedColor(this.accent)
        .trackColor(this.trackColor())
        .onChange((next: number) => onChange(Math.round(next)))
      Text(Math.round(getValue()) + ' FPS')
        .width(52)
        .textAlign(TextAlign.End)
        .fontSize(12)
        .fontColor(this.subColor())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 7, bottom: 7 })
  }

  @Builder
  DensityChip(label: string, value: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.dmDensity === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.dmDensity === value ? this.accent : this.sectionTitleColor())
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .onClick(() => this.onDmDensityChange(value))
  }

  @Builder
  DmTypeIcon(icon: Resource, label: string, active: boolean, onTap: () => void) {
    Column() {
      Image(icon)
        .width(27)
        .height(27)
        .renderMode(ImageRenderMode.Template)
        .fillColor(active ? this.accent : this.sectionTitleColor())
      Text(label)
        .fontSize(11)
        .fontColor(active ? this.accent : this.subColor())
        .margin({ top: 5 })
    }
    .layoutWeight(1)
    .onClick(() => onTap())
  }

  @Builder
  DmSwitchRow(label: string, sub: string, isOn: boolean, onTap: (next: boolean) => void) {
    Row() {
      Column({ space: 2 }) {
        Text(label).fontSize(14).fontColor(this.sectionTitleColor())
        if (sub.length > 0) {
          Text(sub).fontSize(11).fontColor(this.subColor())
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(this.accent)
        .switchPointColor('#FFFFFF')
        .width(42)
        .height(24)
        .onChange((v: boolean): void => onTap(v))
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
  }

  @Builder
  DmDivider() {
    Divider().strokeWidth(0.6).color(this.dividerColor())
  }

  @Builder
  SpeedChip(label: string, rate: number) {
    Text(label)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .fontSize(14)
      .fontWeight(this.playbackRate === rate ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.playbackRate === rate ? '#FFFFFF' : this.subColor())
      .padding({ top: 10, bottom: 10 })
      .borderRadius(18)
      .backgroundColor(this.playbackRate === rate ? this.accent : this.unselectedBg())
      .onClick(() => this.onSpeedChange(rate))
  }

  build() {
    Column({ space: this.which === 0 ? 2 : 8 }) {
      if (this.which === 0) {
        Text('弹幕设置')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.sectionTitleColor())
          .width('100%')
          .margin({ bottom: 8 })
        Column() {
          Row() {
            Text('弹幕密度').fontSize(13).fontColor(this.sectionTitleColor())
            Blank()
            this.DensityChip('正常', 22)
            this.DensityChip('较多', 27)
            this.DensityChip('重叠', 30)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          this.DmDivider()
          this.DmSliderRow('不透明度', () => this.dmOpacity, 0.2, 1, (value: number) => this.onDmOpacityChange(value))
          this.DmDivider()
          this.DmSliderRow('字体大小', () => this.dmFontScale, 0.7, 1.8, (value: number) => this.onDmFontScaleChange(value))
          this.DmDivider()
          this.DmSpeedRow(() => this.dmSpeed, (value: number) => this.onDmSpeedChange(value))
          this.DmDivider()
          this.DmFrameRateRow(() => this.dmFrameRate, (value: number) => this.onDmFrameRateChange(value))
        }
        .width('100%')
        .borderRadius(14)
        .backgroundColor(this.cardBg())
        .margin({ bottom: 14 })

        if (!this.basicDanmakuOnly) {
          Text('画面防挡')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.sectionTitleColor())
            .width('100%')
            .margin({ bottom: 8 })
          Column() {
            Text('按弹幕类型屏蔽')
              .fontSize(14)
              .fontColor(this.sectionTitleColor())
              .width('100%')
              .padding({ left: 14, right: 14, top: 13, bottom: 10 })
            Row() {
              this.DmTypeIcon($r('app.media.ic_dm_fixed'), '固定', this.blockTopDm, () => this.onToggleDmBlock('top'))
              this.DmTypeIcon($r('app.media.ic_dm_scroll'), '滚动', this.blockScrollDm, () => this.onToggleDmBlock('scroll'))
              this.DmTypeIcon($r('app.media.ic_dm_color'), '彩色', this.blockColorDm, () => this.onToggleDmBlock('color'))
              this.DmTypeIcon($r('app.media.ic_dm_advanced'), '高级', this.dmBlockLevel > 0,
                () => this.onBlockAdvancedToggle(this.dmBlockLevel <= 0))
              this.DmTypeIcon($r('app.media.ic_dm_count'), '计数', false, () => this.stubToast('功能暂未开放'))
            }
            .width('100%')
            .padding({ left: 10, right: 10, bottom: 14 })
            this.DmDivider()
            this.DmSwitchRow('重复弹幕隐藏', '大量内容相同的弹幕会被隐藏', false, (next: boolean): void => {
              if (next) this.stubToast('功能暂未开放');
            })
            this.DmDivider()
            this.DmSwitchRow('字幕防挡', '底部弹幕会被隐藏', this.blockBottomDm, (): void => {
              this.onToggleDmBlock('bottom');
            })
            this.DmDivider()
            this.DmSwitchRow('人像防挡', '人像不会被弹幕遮挡', false, (next: boolean): void => {
              if (next) this.stubToast('功能暂未开放');
            })
          }
          .width('100%')
          .borderRadius(14)
          .backgroundColor(this.cardBg())
          .padding({ left: 14, right: 14 })
          .margin({ bottom: 14 })

          Text('更多工具')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.sectionTitleColor())
            .width('100%')
            .margin({ bottom: 8 })
          Column() {
            this.DmSwitchRow('弹幕观看屏蔽词', '仅对我不展示特定弹幕', this.dmFilterRulesCount > 0, (): void => {
              this.onDmFilterTap();
            })
          }
          .width('100%')
          .borderRadius(14)
          .backgroundColor(this.cardBg())
          .padding({ left: 14, right: 14 })
        }

        Row() {
          Image($r('app.media.ic_refresh'))
            .width(14)
            .height(14)
            .renderMode(ImageRenderMode.Template)
            .fillColor(this.subColor())
          Text('重置弹幕设置')
            .fontSize(13)
            .fontColor(this.subColor())
            .margin({ left: 5 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 16, bottom: 4 })
        .onClick(() => this.onResetDanmaku())
      } else if (this.which === 1) {
        Row() {
          Text('清晰度').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.titleColor())
          Blank()
          Text('灰色画质需要会员或当前片源未提供').fontSize(9).fontColor(this.hintColor())
        }
        .width('100%')
        Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, justifyContent: FlexAlign.Start }) {
          ForEach(this.qualityOptions, (option: VideoQualityOption) => {
            Text(option.label)
              .fontSize(12)
              .fontColor(option.available ? (option.qn === this.activeQuality ? '#FFFFFF' : this.subColor()) : this.hintColor())
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .margin({ right: 8, bottom: 6 })
              .borderRadius(16)
              .backgroundColor(option.qn === this.activeQuality ? this.accent :
                (option.available ? this.unselectedBg() : this.unselectedBg()))
              .onClick(() => {
                if (option.available) this.onQualityChange(option.qn);
                else this.getUIContext().getPromptAction().showToast({ message: option.label + ' 需要相应会员权限，或当前视频未提供该轨道' });
              })
          }, (option: VideoQualityOption) => String(option.qn))
        }
        .width('100%')
      } else if (this.which === 2) {
        Text('视频分段 · 点击即可跳转').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.titleColor()).width('100%')
        List({ space: 6 }) {
          ForEach(this.chapters, (chapter: VideoChapter, index: number) => {
            ListItem() {
              Row({ space: 9 }) {
                if (chapter.image.length > 0) {
                  Image(chapter.image).width(64).height(36).objectFit(ImageFit.Cover).borderRadius(5)
                }
                Column({ space: 2 }) {
                  Text(chapter.title)
                    .fontSize(12)
                    .fontColor(this.currentTime >= chapter.from && this.currentTime < chapter.to ? this.accent : this.titleColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(formatDuration(chapter.from) + ' - ' + formatDuration(chapter.to))
                    .fontSize(10)
                    .fontColor(this.hintColor())
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .borderRadius(8)
              .backgroundColor(this.currentTime >= chapter.from && this.currentTime < chapter.to ? '#26FB7299' : this.unselectedBg())
              .onClick(() => this.onChapterChange(chapter.from))
            }
          }, (chapter: VideoChapter, index: number) => String(chapter.from) + '-' + String(index))
        }
        .width('100%')
        .height(this.embedded ? 'auto' : (this.fullscreen ? 230 : 180))
        .layoutWeight(this.embedded ? 1 : 0)
        .scrollBar(BarState.Off)
      } else if (this.which === 4) {
        Text('CC 字幕').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.titleColor()).width('100%')
        List({ space: 6 }) {
          ListItem() {
            Row({ space: 8 }) {
              Text('关闭')
                .fontSize(13)
                .fontColor(this.subtitleOn ? this.subColor() : this.titleColor())
                .layoutWeight(1)
              if (this.subtitleOn === false) {
                Text('✓')
                  .fontSize(13)
                  .fontColor(this.accent)
              }
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 9, bottom: 9 })
            .borderRadius(8)
            .backgroundColor(this.subtitleOn ? this.unselectedBg() : this.accent)
            .onClick(() => this.onSubtitleChange(-1))
          }
          ForEach(this.subtitles, (track: SubtitleTrack, index: number) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(track.lanDoc.length > 0 ? track.lanDoc : track.lan)
                  .fontSize(13)
                  .fontColor(this.subtitleIndex === index ? '#FFFFFF' : this.subColor())
                  .layoutWeight(1)
                if (this.subtitleIndex === index) {
                  Text('✓')
                    .fontSize(13)
                    .fontColor(this.accent)
                }
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 9, bottom: 9 })
              .borderRadius(8)
              .backgroundColor(this.subtitleIndex === index ? this.accent : this.unselectedBg())
              .onClick(() => this.onSubtitleChange(index))
            }
          }, (track: SubtitleTrack, index: number) => track.lan + String(index))
        }
        .width('100%')
        .height(this.embedded ? 'auto' : 180)
        .layoutWeight(this.embedded ? 1 : 0)
        .scrollBar(BarState.Off)
      } else {
        Text('播放速度').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.titleColor()).width('100%')
        Row({ space: 7 }) {
          this.SpeedChip('0.5x', 0.5)
          this.SpeedChip('0.75x', 0.75)
          this.SpeedChip('1x', 1)
          this.SpeedChip('1.25x', 1.25)
          this.SpeedChip('1.5x', 1.5)
          this.SpeedChip('2x', 2)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({
      left: this.which <= 1 ? 16 : 14,
      right: this.which <= 1 ? 16 : 14,
      top: this.which === 0 ? 10 : 12,
      bottom: this.which === 3 ? 14 : 12,
    })
    .borderRadius(this.embedded ? 0 : { topLeft: 16, topRight: 16 })
    .backgroundColor(this.embedded ? '#00000000' : (this.darkMode() ? '#18191C' : '#FFFFFF'))
    .backdropBlur(this.embedded ? 0 : 24)
    .border(this.embedded ? { width: 0 } :
      { width: { top: this.which === 0 ? 0.5 : 0 }, color: this.darkMode() ? '#333333' : '#EEEEEE' })
    .align(this.embedded ? Alignment.Top : Alignment.Bottom)
    .transition(this.embedded ? TransitionEffect.IDENTITY :
      TransitionEffect.asymmetric(
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: 24 }))
          .animation({ duration: 200, curve: Curve.EaseOut }),
        TransitionEffect.opacity(0).animation({ duration: 150, curve: Curve.EaseIn })))
  }
}
