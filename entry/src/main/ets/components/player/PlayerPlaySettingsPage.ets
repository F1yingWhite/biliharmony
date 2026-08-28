/**
 * 播放设置子页（对齐官方版式）：自动进入小窗 / 画质偏好 / 下载画质 / 视频或音频下载 / 缓存到网盘。
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

  build() {
    Column({ space: 10 }) {
      Column() {
        Row() {
          Text('自动进入小窗')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Blank()
          this.StubSwitch((): void => this.onStub('功能暂未开放'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })

        Divider().strokeWidth(0.6).color(this.dividerColor())

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

        Row() {
          Text('缓存到网盘')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Blank()
          this.StubSwitch((): void => this.onStub('功能暂未开放'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })

        Divider().strokeWidth(0.6).color(this.dividerColor())

        Row() {
          Text('缓存时自动进入小窗')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.titleColor())
          Blank()
          this.StubSwitch((): void => this.onStub('功能暂未开放'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      }
      .width('100%')
      .borderRadius(14)
      .backgroundColor(this.cardBg())
    }
    .width('100%')
  }
}
