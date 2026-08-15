import { promptAction } from '@kit.ArkUI';
import { VideoChapter } from '../api/BiliApi';
import { formatDuration } from '../common/Utils';
import { VideoQualityOption } from '../model/Models';

/** 播放器底部设置面板。业务状态由 PlayerView 持有，本组件仅渲染并回传用户选择。 */
@Component
export struct PlayerSettingsPanel {
  @Prop which: number = 0;
  @Prop fullscreen: boolean = false;
  @Prop accent: string = '#FB7299';
  @Prop dmOpacity: number = 0.85;
  @Prop dmSpeed: number = 1;
  @Prop dmFontScale: number = 1.3;
  @Prop dmDensity: number = 18;
  @Prop blockScrollDm: boolean = false;
  @Prop blockTopDm: boolean = false;
  @Prop blockBottomDm: boolean = false;
  @Prop blockColorDm: boolean = false;
  @Prop qualityOptions: Array<VideoQualityOption> = [];
  @Prop activeQuality: number = 0;
  @Prop chapters: Array<VideoChapter> = [];
  @Prop currentTime: number = 0;
  @Prop playbackRate: number = 1;
  onResetDanmaku: () => void = () => {};
  onDmOpacityChange: (value: number) => void = () => {};
  onDmSpeedChange: (value: number) => void = () => {};
  onDmFontScaleChange: (value: number) => void = () => {};
  onDmDensityChange: (value: number) => void = () => {};
  onToggleDmBlock: (kind: string) => void = () => {};
  onQualityChange: (qn: number) => void = () => {};
  onChapterChange: (seconds: number) => void = () => {};
  onSpeedChange: (rate: number) => void = () => {};

  @Builder
  DmSliderRow(label: string, value: number, min: number, max: number, onChange: (value: number) => void) {
    Row({ space: 8 }) {
      Text(label).width(38).fontSize(11).fontColor('#E6FFFFFF')
      Slider({ value: value, min: min, max: max, step: (max - min) / 20, style: SliderStyle.InSet })
        .layoutWeight(1)
        .height(22)
        .blockColor('#FFFFFF')
        .selectedColor(this.accent)
        .trackColor('#40FFFFFF')
        .onChange((next: number) => onChange(next))
      Text(value.toFixed(value >= 6 ? 0 : 1))
        .width(28)
        .textAlign(TextAlign.End)
        .fontSize(10)
        .fontColor('#B3FFFFFF')
    }
    .width('100%')
    .height(27)
  }

  @Builder
  DmBlockChip(label: string, blocked: boolean, kind: string) {
    Text(label)
      .fontSize(11)
      .fontColor(blocked ? '#FFFFFF' : '#CCFFFFFF')
      .padding({ left: 9, right: 9, top: 5, bottom: 5 })
      .borderRadius(13)
      .backgroundColor(blocked ? this.accent : '#33FFFFFF')
      .onClick(() => this.onToggleDmBlock(kind))
  }

  @Builder
  SpeedChip(label: string, rate: number) {
    Text(label)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .fontSize(11)
      .fontColor(this.playbackRate === rate ? '#FFFFFF' : '#CCFFFFFF')
      .padding({ top: 8, bottom: 8 })
      .borderRadius(16)
      .backgroundColor(this.playbackRate === rate ? this.accent : '#33FFFFFF')
      .onClick(() => this.onSpeedChange(rate))
  }

  build() {
    Column({ space: this.which === 0 ? 2 : 8 }) {
      if (this.which === 0) {
        Row() {
          Text('弹幕设置').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Blank()
          Text('恢复默认').fontSize(11).fontColor('#CCFFFFFF').onClick(() => this.onResetDanmaku())
        }
        .width('100%')
        this.DmSliderRow('透明度', this.dmOpacity, 0.2, 1, (value: number) => this.onDmOpacityChange(value))
        this.DmSliderRow('速度', this.dmSpeed, 0.5, 2, (value: number) => this.onDmSpeedChange(value))
        this.DmSliderRow('字号', this.dmFontScale, 0.7, 1.8, (value: number) => this.onDmFontScaleChange(value))
        this.DmSliderRow('密度', this.dmDensity, 6, 30, (value: number) => this.onDmDensityChange(value))
        Row({ space: 6 }) {
          this.DmBlockChip('滚动', this.blockScrollDm, 'scroll')
          this.DmBlockChip('顶部', this.blockTopDm, 'top')
          this.DmBlockChip('底部', this.blockBottomDm, 'bottom')
          this.DmBlockChip('彩色', this.blockColorDm, 'color')
        }
        .width('100%')
      } else if (this.which === 1) {
        Row() {
          Text('清晰度').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          Blank()
          Text('灰色画质需要会员或当前片源未提供').fontSize(9).fontColor('#88FFFFFF')
        }
        .width('100%')
        Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, justifyContent: FlexAlign.Start }) {
          ForEach(this.qualityOptions, (option: VideoQualityOption) => {
            Text(option.label)
              .fontSize(12)
              .fontColor(option.available ? (option.qn === this.activeQuality ? '#FFFFFF' : '#CCFFFFFF') : '#66FFFFFF')
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .margin({ right: 8, bottom: 6 })
              .borderRadius(16)
              .backgroundColor(option.qn === this.activeQuality ? this.accent :
                (option.available ? '#33FFFFFF' : '#16FFFFFF'))
              .onClick(() => {
                if (option.available) this.onQualityChange(option.qn);
                else promptAction.showToast({ message: option.label + ' 需要相应会员权限，或当前视频未提供该轨道' });
              })
          }, (option: VideoQualityOption) => String(option.qn))
        }
        .width('100%')
      } else if (this.which === 2) {
        Text('视频分段 · 点击即可跳转').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').width('100%')
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
                    .fontColor(this.currentTime >= chapter.from && this.currentTime < chapter.to ? this.accent : '#FFFFFF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(formatDuration(chapter.from) + ' - ' + formatDuration(chapter.to))
                    .fontSize(10)
                    .fontColor('#A6FFFFFF')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .borderRadius(8)
              .backgroundColor(this.currentTime >= chapter.from && this.currentTime < chapter.to ? '#26FB7299' : '#1FFFFFFF')
              .onClick(() => this.onChapterChange(chapter.from))
            }
          }, (chapter: VideoChapter, index: number) => String(chapter.from) + '-' + String(index))
        }
        .width('100%')
        .height(this.fullscreen ? 230 : 180)
        .scrollBar(BarState.Off)
      } else {
        Text('播放速度').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF').width('100%')
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
    .width(this.fullscreen ? 420 : '100%')
    .padding({
      left: this.which <= 1 ? 16 : 14,
      right: this.which <= 1 ? 16 : 14,
      top: this.which === 0 ? 10 : 12,
      bottom: this.which === 3 ? 14 : 12,
    })
    .borderRadius({ topLeft: 16, topRight: 16 })
    .backgroundColor('#E81A1A1E')
    .backdropBlur(24)
    .border({ width: { top: this.which === 0 ? 0.5 : 0 }, color: '#33FFFFFF' })
    .align(Alignment.Bottom)
  }
}
