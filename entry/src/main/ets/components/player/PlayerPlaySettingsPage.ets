/**
 * 播放设置子页（对齐官方版式）：画质偏好 / 下载画质 / 视频或音频下载（下载任务在下载中心管理）。
 */
@Component
export struct PlayerPlaySettingsPage {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @Prop forceDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @Prop qualityPref: number = 0;
  @Prop downloadQualityLabel: string = '';
  @Prop downloadBusy: boolean = false;
  @Prop downloadProgress: number = -1;
  onQualityPrefChange: (pref: number) => void = () => {};
  onDownloadQuality: () => void = () => {};
  onDownload: () => void = () => {};
  onStub: (message: string) => void = () => {};

  private darkMode(): boolean {
    return this.forceDark || this.isDark;
  }

  private titleColor(): string {
    return this.darkMode() ? '#F1F2F4' : '#18191C';
  }

  private subColor(): string {
    return this.darkMode() ? '#8A8F99' : '#9499A0';
  }

  private cardBg(): string {
    return this.darkMode() ? '#26272B' : '#FFFFFF';
  }

  private dividerColor(): string {
    return this.darkMode() ? '#33343A' : '#F0F1F3';
  }

  private chipBg(): string {
    return this.darkMode() ? '#2C2D33' : '#F3F4F6';
  }

  private prefLabels(): string[] {
    return ['自动', '高码率', '高清高码', '智能省流'];
  }

  @Builder
  PrefChip(label: string, index: number) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.qualityPref === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.qualityPref === index ? this.accent : this.subColor())
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .margin({ left: 2 })
      .borderRadius(15)
      .onClick(() => this.onQualityPrefChange(index))
  }

  @Builder
  StubSwitch(onTap: () => void) {
    Toggle({ type: ToggleType.Switch, isOn: false })
      .selectedColor(this.accent)
      .switchPointColor('#FFFFFF')
      .width(42)
      .height(24)
      .onChange((v: boolean): void => {
        if (v) onTap();
      })
  }

  @StorageProp('pgcSkipIntroSeconds') @Watch('onSkipIntroChanged') skipIntroSeconds: number = 0;
  @State skipIntroTick: number = 0;

  private onSkipIntroChanged(): void {
    this.skipIntroTick++;
  }

  private skipIntroLabel(seconds: number): string {
    return seconds <= 0 ? '关闭' : String(seconds) + ' 秒';
  }

  private setSkipIntro(seconds: number): void {
    AppStorage.setOrCreate<number>('pgcSkipIntroSeconds', seconds);
    try {
      this.getUIContext().getPromptAction().showToast({
        message: seconds > 0 ? '番剧将自动跳过前 ' + String(seconds) + ' 秒片头' : '已关闭自动跳过片头',
      });
    } catch (e) {
      // toast 失败忽略。
    }
  }

  build() {
    Column({ space: 10 }) {
      Column() {
        Row() {
          Text('番剧跳过片头')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Blank()
          Row({ space: 6 }) {
            ForEach([0, 15, 30, 90], (seconds: number) => {
              Text(this.skipIntroLabel(seconds))
                .fontSize(12)
                .fontColor(this.skipIntroSeconds === seconds ? '#FFFFFF' : this.subColor())
                .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .borderRadius(12)
                .backgroundColor(this.skipIntroSeconds === seconds ? this.accent : this.cardBg())
                .onClick(() => this.setSkipIntro(seconds))
            }, (seconds: number) => 'skip-' + String(seconds) + '-' + String(this.skipIntroTick))
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })

        Divider().strokeWidth(0.6).color(this.dividerColor())
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor(this.cardBg())

      Column() {

        Row() {
          Text('画质偏好')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Blank()
          Row() {
            ForEach(this.prefLabels(), (label: string, index: number) => {
              this.PrefChip(label, index)
            }, (label: string): string => label)
          }
          .backgroundColor(this.chipBg())
          .borderRadius(17)
          .padding({ top: 2, bottom: 2 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor(this.cardBg())

      Column() {
        Row() {
          Text('下载画质')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Blank()
          Text(this.downloadQualityLabel.length > 0 ? this.downloadQualityLabel : '1080P')
            .fontSize(13)
            .fontColor(this.subColor())
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(13)
            .backgroundColor(this.chipBg())
            .margin({ right: 4 })
          Image($r('app.media.ic_arrow_right'))
            .width(13)
            .height(13)
            .renderMode(ImageRenderMode.Template)
            .fillColor(this.subColor())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          if (!this.downloadBusy) this.onDownloadQuality();
        })

        Divider().strokeWidth(0.6).color(this.dividerColor())

        Row() {
          Text('下载视频或音频')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Blank()
          if (this.downloadBusy) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(this.accent)
            Text(this.downloadProgress >= 0 ? String(this.downloadProgress) + '%' : '准备中')
              .fontSize(13)
              .fontColor(this.subColor())
              .margin({ left: 7 })
          } else {
            Text('选择格式')
              .fontSize(13)
              .fontColor(this.accent)
            Image($r('app.media.ic_arrow_right'))
              .width(13)
              .height(13)
              .renderMode(ImageRenderMode.Template)
              .fillColor(this.subColor())
              .margin({ left: 4 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .onClick(() => {
          if (!this.downloadBusy) this.onDownload();
        })

        Divider().strokeWidth(0.6).color(this.dividerColor())

      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor(this.cardBg())
    }
    .width('100%')
  }
}
