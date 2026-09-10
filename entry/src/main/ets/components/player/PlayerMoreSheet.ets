/**
 * 播放器“⋮”展开页（对齐官方版式）：分享宫格 + 设置卡（倍速/播放模式/定时关闭/后台听视频/字幕/弹幕设置/镜像翻转/清晰度/播放设置）+ 反馈卡（我不想看/举报/播放反馈）。
 */
@Component
export struct PlayerMoreSheet {
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

  private downloadLabel(): string {
    if (!this.downloadBusy) return '下载';
    return this.downloadProgress >= 0 ? '下载 ' + String(this.downloadProgress) + '%' : '准备中';
  }

  // plain=true 时图标为 currentColor 线稿：套 Template 渲染并跟随主题色；
  // 品牌彩色图标自带色值，不能加 fillColor（会把整图染成主题色）。
  // 图标槽固定 44 高，保证一行内文字标签纵向对齐（图标本体可更小）。
  @Builder
  ShareCircle(icon: Resource, label: string, plain: boolean, size: number, onTap: () => void) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (plain) {
          Image(icon)
            .width(size)
            .height(size)
            .renderMode(ImageRenderMode.Template)
            .fillColor(this.iconColor())
        } else {
          Image(icon)
            .width(size)
            .height(size)
        }
      }
      .width(44)
      .height(44)
      Text(label)
        .fontSize(11)
        .fontColor(this.iconColor())
        .margin({ top: 6 })
        .maxLines(1)
    }
    .width('16.666%')
    .onClick(() => onTap())
  }

  @Builder
  ShareSquare(icon: Resource, label: string, onTap: () => void) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Image(icon)
          .width(26)
          .height(26)
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
    .width('16.666%')
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
            // 六列随面板宽度伸缩，下行四项与上行对齐。
            Row() {
              this.ShareCircle($r('app.media.ic_share_wechat'), '微信', false, 44, (): void => this.onShare())
              this.ShareCircle($r('app.media.ic_share_pengyouquan'), '朋友圈', false, 44, (): void => this.onShare())
              this.ShareCircle($r('app.media.ic_share_qq'), 'QQ', false, 44, (): void => this.onShare())
              this.ShareCircle($r('app.media.ic_share_qzone'), 'QQ空间', false, 44, (): void => this.onShare())
              this.ShareCircle($r('app.media.ic_share_dynamic'), '动态', false, 44, (): void => this.onShare())
              this.ShareCircle($r('app.media.ic_share_link'), '复制链接', true, 26, (): void => this.onCopyLink())
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            Row() {
              this.ShareSquare($r('app.media.ic_watch_later'), '稍后再看', (): void => this.onWatchLater())
              this.ShareSquare($r('app.media.ic_share_cache'), this.downloadLabel(), (): void => {
                if (!this.downloadBusy) this.onDownload();
              })
              this.ShareSquare($r('app.media.ic_share_pip'), '小窗播放', (): void => this.onStub('功能暂未开放'))
              this.ShareSquare($r('app.media.ic_share_cast'), '投屏', (): void => this.onStub('功能暂未开放'))
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
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
                  .animation({ duration: 200, curve: Curve.EaseOut })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 13, bottom: this.timerExpanded ? 4 : 13 })
              .animation({ duration: 220, curve: Curve.EaseOut })
              .onClick(() => {
                this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
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
                .transition(TransitionEffect.opacity(0.3).combine(
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
            .onClick(() => this.onStub('功能暂未开放'))

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_report_flag'))
              this.RowLabel('举报')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 15, bottom: 15 })
            .onClick(() => this.onStub('功能暂未开放'))

            Divider().strokeWidth(0.6).color(this.dividerColor())

            Row() {
              this.RowIcon($r('app.media.ic_play_feedback'))
              this.RowLabel('播放反馈')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 15, bottom: 15 })
            .onClick(() => this.onStub('功能暂未开放'))
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
