import { VideoChapter } from '../api/BiliApi';
import { formatDuration } from '../common/Utils';
import { PlayerProgressBar } from './PlayerProgressBar';

/** 普通/横屏播放器底部控制条，状态切换通过回调交给 PlayerView。 */
@Component
export struct PlayerBottomControls {
  @Prop fullscreen: boolean = false;
  @Prop playing: boolean = false;
  @Prop danmakuOn: boolean = true;
  @Prop sponsorEnabled: boolean = true;
  @Prop chapters: Array<VideoChapter> = [];
  @Prop progress: number = 0;
  @Prop duration: number = 0;
  @Prop qualityLoading: boolean = false;
  @Prop qualityLabel: string = '';
  @Prop playbackRate: number = 1;
  @Prop showQualitySettings: boolean = false;
  @Prop showChapterSettings: boolean = false;
  @Prop showSpeedSettings: boolean = false;
  /** 横屏底栏中间的弹幕输入（竖屏输入在页面头栏，不走这里） */
  @Prop dmDraft: string = '';
  @Prop dmSending: boolean = false;
  onPlay: () => void = () => {};
  onDanmaku: () => void = () => {};
  onDanmakuSettings: () => void = () => {};
  onSponsor: () => void = () => {};
  onChapter: () => void = () => {};
  onQuality: () => void = () => {};
  onSpeed: () => void = () => {};
  onFullscreen: () => void = () => {};
  onProgressChange: (value: number, mode: SliderChangeMode) => void = () => {};
  onDmDraftChange: (value: string) => void = () => {};
  onDmSend: () => void = () => {};

  @Builder
  IconButton(icon: Resource, size: number, width: number, color: ResourceColor, onClick: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Image(icon).width(size).height(size).renderMode(ImageRenderMode.Template).fillColor(color)
    }
    .width(width)
    .height(34)
    .onClick(() => onClick())
  }

  build() {
    if (this.fullscreen) {
      // 横屏：保留完整控制条，中间为弹幕输入区
      Column({ space: 6 }) {
        Row({ space: 10 }) {
          Text(formatDuration(this.progress)).fontSize(11).fontColor('#FFFFFF')
          PlayerProgressBar({
            value: this.progress,
            duration: this.duration,
            compact: false,
            chapters: this.chapters,
            onChange: (value: number, mode: SliderChangeMode) => this.onProgressChange(value, mode),
          })
          Text(formatDuration(this.duration)).fontSize(11).fontColor('#FFFFFF')
        }
        .width('100%')
        Row({ space: 8 }) {
          this.IconButton(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'), 25, 38, '#FFFFFF',
            () => this.onPlay())
          this.IconButton(this.danmakuOn ? $r('app.media.ic_danmaku_on') : $r('app.media.ic_danmaku_off'), 23, 36,
            this.danmakuOn ? '#FB7299' : '#99FFFFFF', () => this.onDanmaku())
          this.IconButton($r('app.media.ic_danmaku_settings'), 21, 34, '#FFFFFF', () => this.onDanmakuSettings())
          // 横屏底栏中段的弹幕输入胶囊，对齐官方客户端横屏形态
          TextInput({ text: this.dmDraft, placeholder: this.dmSending ? '发送中…' : '发个弹幕吧~' })
            .height(30)
            .layoutWeight(1)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .placeholderColor('#80FFFFFF')
            .backgroundColor('#33FFFFFF')
            .borderRadius(15)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => this.onDmDraftChange(value))
            .onSubmit(() => this.onDmSend())
          Text('空降')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.sponsorEnabled ? '#FFFFFF' : '#99FFFFFF')
            .padding({ left: 8, right: 8, top: 7, bottom: 7 })
            .borderRadius(14)
            .backgroundColor(this.sponsorEnabled ? '#B3FB7299' : '#26000000')
            .onClick(() => this.onSponsor())
          if (this.chapters.length > 0) {
            Text('分段 ' + this.chapters.length)
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .padding({ left: 8, right: 8, top: 7, bottom: 7 })
              .borderRadius(14)
              .backgroundColor(this.showChapterSettings ? '#66FFFFFF' : '#26000000')
              .onClick(() => this.onChapter())
          }
          Text(this.qualityLoading ? '切换中' : this.qualityLabel)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .padding({ left: 8, right: 8, top: 7, bottom: 7 })
            .onClick(() => this.onQuality())
          Text(this.playbackRate === 1 ? '倍速' : this.playbackRate.toFixed(this.playbackRate % 1 === 0 ? 0 : 2) + 'x')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .padding({ left: 8, right: 8, top: 7, bottom: 7 })
            .onClick(() => this.onSpeed())
          this.IconButton($r('app.media.ic_fullscreen_exit'), 23, 36, '#FFFFFF', () => this.onFullscreen())
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 8 })
    } else {
      // 竖屏：播放/暂停钉在进度条最左、全屏钉在最右，清晰度/倍速/空降等收进右上角 ⋮ 菜单。
      Row({ space: 8 }) {
        this.IconButton(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'), 22, 34, '#FFFFFF',
          () => this.onPlay())
        Text(formatDuration(this.progress)).fontSize(11).fontColor('#FFFFFF')
        PlayerProgressBar({
          value: this.progress,
          duration: this.duration,
          compact: false,
          chapters: this.chapters,
          onChange: (value: number, mode: SliderChangeMode) => this.onProgressChange(value, mode),
        })
        Text(formatDuration(this.duration)).fontSize(11).fontColor('#FFFFFF')
        this.IconButton($r('app.media.ic_fullscreen'), 22, 34, '#FFFFFF', () => this.onFullscreen())
      }
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 8 })
    }
  }
}
