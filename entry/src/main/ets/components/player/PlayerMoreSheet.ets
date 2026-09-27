import { MotionTokens } from '../../common/MotionTokens';
/**
 * 播放器“⋮”展开页（对齐官方版式）：常用操作栏 + 设置卡（倍速/播放模式/定时关闭/后台听视频/字幕/弹幕设置/镜像翻转/清晰度/播放设置）+ 反馈卡（我不想看/举报）。投屏与播放反馈无可用公开接口，入口已移除。
 */
import { LocalVideoFilter } from '../../common/LocalVideoFilter';

@Component
export struct PlayerMoreSheet {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @Prop forceDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @Prop playbackRate: number = 1;
  @Prop playMode: number = 0;
  @Prop qualityLabel: string = '';
  @Prop qualityLoading: boolean = false;
  @Prop mirrorOn: boolean = false;
  @Prop timerMinutes: number = 0;
  @Prop chaptersCount: number = 0;
  @Prop sponsorOn: boolean = false;
  @Prop subtitleOn: boolean = false;
  @Prop backgroundPlaybackEnabled: boolean = false;
  @Prop downloadBusy: boolean = false;
  @Prop downloadProgress: number = -1;
  @Prop aid: number = 0;
  onSpeedChange: (rate: number) => void = () => {};
  onPlayModeChange: (mode: number) => void = () => {};
  onTimerChange: (minutes: number) => void = () => {};
  onMirrorChange: (next: boolean) => void = () => {};
  onQuality: () => void = () => {};
  onDmSettings: () => void = () => {};
  onChapters: () => void = () => {};
  onSubtitleToggle: (next: boolean) => void = () => {};
  onBackgroundPlaybackChange: (next: boolean) => void = () => {};
  onSponsorToggle: (next: boolean) => void = () => {};
  onSponsorSettings: () => void = () => {};
  onReportVideo: () => void = () => {};
  onPictureInPicture: () => void = () => {};
  onShare: () => void = () => {};
  onWatchLater: () => void = () => {};
  onCopyLink: () => void = () => {};
  onDownload: () => void = () => {};
  onStub: (message: string) => void = () => {};
  @State timerExpanded: boolean = false;

  private darkMode(): boolean {
    return this.forceDark || this.isDark;
  }

  private sheetBg(): string {
    return this.darkMode() ? '#18191C' : '#F5F6F7';
  }

  private cardBg(): string {
    return this.darkMode() ? '#26272B' : '#FFFFFF';
  }

  private titleColor(): string {
    return this.darkMode() ? '#F1F2F4' : '#18191C';
  }

  private subColor(): string {
    return this.darkMode() ? '#8A8F99' : '#9499A0';
  }

  private iconColor(): string {
    return this.darkMode() ? '#F1F2F4' : '#18191C';
  }

  private dividerColor(): string {
    return this.darkMode() ? '#33343A' : '#F0F1F3';
  }

  private squareBg(): string {
    return this.darkMode() ? '#2C2D33' : '#F3F4F6';
  }

  private speedRates(): number[] {
    return [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 3.5, 4];
  }

  private speedLabel(rate: number): string {
    return rate === 1 ? '1' : String(rate);
  }

  /** 「我不想看」：持久化 aid 黑名单，首页/相关推荐入列前过滤（本地实现，无服务端负反馈接口）。 */
  private hideThisVideo(): void {
    if (this.aid <= 0) {
      this.onStub('当前视频不支持该操作');
      return;
    }
    LocalVideoFilter.hide(this.aid).catch(() => {
      // 持久化失败保留提示；下一次启动该稿可能重新出现。
    });
    this.onStub('已加入「不想看」，将不再出现在首页与相关推荐');
  }

  private downloadLabel(): string {
    if (!this.downloadBusy) return '下载';
    return this.downloadProgress >= 0 ? '下载 ' + String(this.downloadProgress) + '%' : '准备中';
  }

  @Builder
  ShareSquare(icon: Resource, label: string, onTap: () => void) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Image(icon)
          .width(24)
          .height(24)
          .renderMode(ImageRenderMode.Template)
          .fillColor(this.iconColor())
      }
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor(this.squareBg())
      Text(label)
        .fontSize(11)
        .fontColor(this.iconColor())
        .margin({ top: 6 })
        .maxLines(1)
    }
    .width('20%')
    .accessibilityText(label)
    .onClick(() => onTap())
  }

  @Builder
  RowIcon(icon: Resource) {
    Image(icon)
      .width(19)
      .height(19)
      .renderMode(ImageRenderMode.Template)
      .fillColor(this.iconColor())
  }

  @Builder
  RowLabel(label: string) {
    Text(label)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.titleColor())
      .margin({ left: 11 })
  }

  @Builder
  Chevron() {
    Image($r('app.media.ic_arrow_right'))
      .width(13)
      .height(13)
      .renderMode(ImageRenderMode.Template)
      .fillColor(this.subColor())
  }

  @Builder
  InlineChip(label: string, selected: boolean, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(selected ? this.accent : this.subColor())
      .onClick(() => onTap())
  }

  // 倍速档位：选中为粉色并附下划线（对齐官方版式）。
  @Builder
  SpeedChip(label: string, selected: boolean, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(selected ? this.accent : this.subColor())
      .decoration({ type: selected ? TextDecorationType.Underline : TextDecorationType.None, color: this.accent })
      .onClick(() => onTap())
  }

  @Builder
  ChipSep() {
    Row()
      .width(0.6)
      .height(12)
      .backgroundColor(this.dividerColor())
      .margin({ left: 9, right: 9 })
  }

  @Builder
  TinySwitch(isOn: boolean, onTap: (next: boolean) => void) {
    Toggle({ type: ToggleType.Switch, isOn: isOn })
      .selectedColor(this.accent)
      .switchPointColor('#FFFFFF')
      .width(42)
      .height(24)
      .onChange((v: boolean): void => onTap(v))
  }

  build() {
    Column() {
      Row()
        .width(34)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.darkMode() ? '#3A3B41' : '#DADCE0')
        .margin({ top: 10 })
      Scroll() {
        Column({ space: 10 }) {
          Column({ space: 14 }) {
            // 每个入口对应独立动作；平台选择交给系统分享面板。
            Row() {
              this.ShareSquare($r('app.media.ic_share'), '分享', (): void => this.onShare())
              this.ShareSquare($r('app.media.ic_copy'), '复制链接', (): void => this.onCopyLink())
              this.ShareSquare($r('app.media.ic_watch_later'), '稍后再看', (): void => this.onWatchLater())
              this.ShareSquare($r('app.media.ic_download'), this.downloadLabel(), (): void => {
                if (!this.downloadBusy) this.onDownload();
              })
              this.ShareSquare($r('app.media.ic_share_pip'), '小窗播放', (): void => this.onPictureInPicture())
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 10, bottom: 2 })

          Column() {
            Row() {
              this.RowIcon($r('app.media.ic_speed_play'))
              this.RowLabel('倍速播放')
              Blank()
              Row({ space: 12 }) {
                ForEach(this.speedRates(), (rate: number) => {
                  this.SpeedChip(this.speedLabel(rate), this.playbackRate === rate, (): void => this.onSpeedChange(rate))
                }, (rate: number) => String(rate))
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_play_mode'))
              this.RowLabel('播放模式')
              Blank()
              Row({ space: 16 }) {
                this.InlineChip('自动连播', this.playMode === 0, (): void => this.onPlayModeChange(0))
                this.InlineChip('列表循环', this.playMode === 1, (): void => this.onPlayModeChange(1))
                this.InlineChip('单集循环', this.playMode === 2, (): void => this.onPlayModeChange(2))
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Column() {
              Row() {
                this.RowIcon($r('app.media.ic_timer_off'))
                this.RowLabel(this.timerMinutes > 0 ? '定时关闭 ' + this.timerMinutes + '分' : '定时关闭')
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(13)
                  .height(13)
                  .renderMode(ImageRenderMode.Template)
                  .fillColor(this.subColor())
                  .rotate({ angle: this.timerExpanded ? 90 : 0 })
                  .animation({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 13, bottom: this.timerExpanded ? 4 : 13 })
              .animation({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut })
              .onClick(() => {
                this.getUIContext().animateTo({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut }, () => {
                  this.timerExpanded = !this.timerExpanded;
                });
              })
              if (this.timerExpanded) {
                Row({ space: 16 }) {
                  this.InlineChip('15分', this.timerMinutes === 15, (): void => this.onTimerChange(15))
                  this.InlineChip('30分', this.timerMinutes === 30, (): void => this.onTimerChange(30))
                  this.InlineChip('45分', this.timerMinutes === 45, (): void => this.onTimerChange(45))
                  this.InlineChip('60分', this.timerMinutes === 60, (): void => this.onTimerChange(60))
                  this.InlineChip('关闭', this.timerMinutes === 0, (): void => this.onTimerChange(0))
                }
                .width('100%')
                .padding({ left: 16, right: 16, bottom: 13 })
                .margin({ left: 57 })
                .transition(this.reduceMotion ? MotionTokens.appear(true) : TransitionEffect.opacity(0.3).combine(
                  TransitionEffect.scale({ x: 1, y: 0, centerX: '0%', centerY: '0%' })))
              }
            }
            .width('100%')

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_headphone'))
              this.RowLabel('后台听视频')
              Blank()
              this.TinySwitch(this.backgroundPlaybackEnabled,
                (next: boolean): void => this.onBackgroundPlaybackChange(next))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_danmaku_settings'))
              this.RowLabel('弹幕设置')
              Blank()
              this.Chevron()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })
            .onClick(() => this.onDmSettings())

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_mirror_flip'))
              this.RowLabel('镜像翻转')
              Blank()
              this.TinySwitch(this.mirrorOn, (next: boolean): void => this.onMirrorChange(next))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_quality'))
              this.RowLabel('画质')
              Blank()
              Text(this.qualityLoading ? '切换中…' : this.qualityLabel)
                .fontSize(13)
                .fontColor(this.subColor())
                .margin({ right: 4 })
              this.Chevron()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })
            .onClick(() => this.onQuality())

            if (this.chaptersCount > 0) {
              Divider().strokeWidth(0.6).color(this.dividerColor())

              Row() {
                this.RowIcon($r('app.media.ic_play_settings'))
                this.RowLabel('分段视频')
                Blank()
                this.Chevron()
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 13, bottom: 13 })
              .onClick(() => this.onChapters())
            }

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_subtitle'))
              this.RowLabel('CC 字幕')
              Blank()
              this.TinySwitch(this.subtitleOn, (next: boolean): void => this.onSubtitleToggle(next))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_ad_skip'))
              Row() {
                this.RowLabel('空降助手')
                Blank()
                this.Chevron()
              }
              .layoutWeight(1)
              .onClick(() => this.onSponsorSettings())
              this.TinySwitch(this.sponsorOn, (next: boolean): void => this.onSponsorToggle(next))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardBg())

          Column() {
            Row() {
              this.RowIcon($r('app.media.ic_not_interested'))
              this.RowLabel('我不想看')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 15, bottom: 15 })
            .onClick(() => this.hideThisVideo())

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_report_flag'))
              this.RowLabel('举报')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 15, bottom: 15 })
            .onClick(() => this.onReportVideo())
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(this.cardBg())
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 18 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.sheetBg())
  }
}
