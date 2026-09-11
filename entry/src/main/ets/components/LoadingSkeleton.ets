import { LayoutTokens } from '../common/LayoutTokens';

/** 只在可见的首屏加载期间做轻微呼吸；整组共用动画，不为每一条占位启动计时器。 */
@Component
export struct LoadingSkeleton {
  @Prop layout: string = 'list';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State widthVp: number = 400;
  @State pulse: number = 1;
  private visible: boolean = false;

  private setVisible(visible: boolean): void {
    if (this.visible === visible) return;
    this.visible = visible;
    this.getUIContext().animateTo({ duration: 0 }, () => { this.pulse = 1; });
    if (visible) {
      // 三次柔和呼吸后静止，慢请求不让整页持续闪动。
      this.getUIContext().animateTo({ duration: 1000, iterations: 3, playMode: PlayMode.Alternate,
        curve: Curve.EaseInOut }, () => { this.pulse = 0.55; });
    }
  }

  aboutToDisappear(): void {
    this.visible = false;
  }

  @Builder
  Bar(width: Length, height: number = 12) {
    Row().width(width).height(height).borderRadius(height / 2)
      .backgroundColor(this.isDark ? '#383D47' : '#E3E6EC')
  }

  @Builder
  GridCard() {
    Column({ space: 10 }) {
      Row().width('100%').aspectRatio(4 / 3)
        .backgroundColor(this.isDark ? '#333842' : '#E3E6EC')
      Column({ space: 8 }) {
        this.Bar('92%', 13)
        this.Bar('72%', 13)
        this.Bar('44%', 10)
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 12, right: 12, bottom: 26 })
    }
    .layoutWeight(1).borderRadius(16).clip(true)
    .backgroundColor(this.isDark ? '#24272E' : '#FFFFFF')
  }

  @Builder
  PosterCard() {
    Column({ space: 6 }) {
      Row().width('100%').aspectRatio(0.7).borderRadius(8)
        .backgroundColor(this.isDark ? '#333842' : '#E3E6EC')
      Column({ space: 6 }) {
        this.Bar('95%', 12)
        this.Bar('70%', 12)
        this.Bar('60%', 10)
      }.width('100%').height(56).alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder
  ListRow() {
    Row({ space: 12 }) {
      Row().width(this.layout === 'comments' ? 38 : (this.layout === 'sessions' ? 48 : '40%'))
        .height(this.layout === 'comments' ? 38 : (this.layout === 'sessions' ? 48 : 78))
        .borderRadius(this.layout === 'comments' ? 19 : (this.layout === 'sessions' ? 24 : 10))
        .backgroundColor(this.isDark ? '#333842' : '#E3E6EC')
      Column({ space: 10 }) {
        this.Bar('88%', 13)
        this.Bar('65%', 12)
        if (this.layout !== 'sessions') this.Bar('42%', 10)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ top: 10, bottom: 10 })
  }

  @Builder
  MediaRow() {
    Row({ space: 10 }) {
      Row().width(84).height(112).borderRadius(6)
        .backgroundColor(this.isDark ? '#333842' : '#E3E6EC')
      Column({ space: 8 }) {
        this.Bar('88%', 14)
        this.Bar('25%', 11)
        this.Bar('65%', 11)
        this.Bar('96%', 11)
        this.Bar('72%', 11)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
  }

  @Builder
  SocialCard() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        this.Bar(38, 38)
        Column({ space: 8 }) {
          this.Bar(110, 12)
          this.Bar(64, 9)
        }.alignItems(HorizontalAlign.Start)
      }.width('100%')
      this.Bar('92%', 13)
      this.Bar('68%', 13)
      Row().width('100%').height(this.layout === 'detail' ? 72 : 180).borderRadius(12)
        .backgroundColor(this.isDark ? '#333842' : '#E3E6EC')
      Row() {
        this.Bar('20%', 10)
        Blank()
        this.Bar('20%', 10)
        Blank()
        this.Bar('20%', 10)
      }.width('100%')
    }.width('100%').padding(16).borderRadius(16)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.isDark ? '#24272E' : '#FFFFFF')
  }

  build() {
    Column({ space: this.layout === 'mediaList' ? 0 : (this.layout === 'grid' || this.layout === 'poster' ? 12 : 8) }) {
      if (this.layout === 'mediaList') {
        ForEach([0, 1, 2, 3, 4, 5], (row: number) => {
          this.MediaRow()
        }, (row: number) => String(row))
      } else if (this.layout === 'settings') {
        Row({ space: 12 }) {
          this.Bar(64, 64)
          Column({ space: 10 }) {
            this.Bar('60%', 16)
            this.Bar('85%', 12)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ top: 16, bottom: 24 })
        ForEach([0, 1], (group: number) => {
          Column({ space: 24 }) {
            this.Bar('85%', 16)
            this.Bar('70%', 16)
            this.Bar('80%', 16)
            this.Bar('65%', 16)
          }.width('100%').padding(20).borderRadius(12)
            .alignItems(HorizontalAlign.Start)
            .backgroundColor(this.isDark ? '#24272E' : '#FFFFFF')
        }, (group: number) => String(group))
      } else if (this.layout === 'profile' || this.layout === 'season') {
        Row().width('100%').height(this.layout === 'profile' ? 150 : 220).borderRadius(16)
          .backgroundColor(this.isDark ? '#333842' : '#E3E6EC')
        Row({ space: 12 }) {
          this.Bar(64, 64)
          Column({ space: 10 }) {
            this.Bar('75%', 16)
            this.Bar('50%', 12)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ top: 12, bottom: 12 })
        this.Bar('95%', 13)
        this.Bar('70%', 13)
        this.ListRow()
        this.ListRow()
      } else if (this.layout === 'poster') {
        ForEach([0, 1, 2], (row: number) => {
          Row({ space: 10 }) {
            this.PosterCard()
            this.PosterCard()
            this.PosterCard()
          }.width('100%')
        }, (row: number) => String(row))
      } else if (this.layout === 'grid') {
        ForEach([0, 1, 2], (row: number) => {
          Row({ space: 12 }) {
            ForEach([0, 1, 2, 3, 4].slice(0, LayoutTokens.feedColumns(this.widthVp)), (column: number) => {
              this.GridCard()
            }, (column: number) => String(column))
          }.width('100%')
        }, (row: number) => String(row))
      } else if (this.layout === 'social' || this.layout === 'detail') {
        this.SocialCard()
        if (this.layout === 'social') this.SocialCard()
      } else {
        ForEach([0, 1, 2, 3, 4, 5].slice(0, this.layout === 'comments' ? 3 : 6), (row: number) => {
          this.ListRow()
        }, (row: number) => String(row))
      }
    }
    .width('100%')
    .padding({ left: this.layout === 'mediaList' ? 0 : (this.layout === 'poster' ? 12 : (this.widthVp >= 600 ? 24 : 16)),
      right: this.layout === 'mediaList' ? 0 : (this.widthVp >= 600 ? 24 : 16),
      top: this.layout === 'poster' || this.layout === 'mediaList' ? 0 : 8, bottom: 16 })
    .opacity(this.pulse)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
    .accessibilityGroup(true)
    .accessibilityText('正在加载内容')
    .onAreaChange((previous: Area, current: Area) => {
      const width: number = Number(current.width);
      if (width > 0 && width !== this.widthVp) this.widthVp = width;
    })
    .onVisibleAreaChange([0], (visible: boolean) => this.setVisible(visible))
  }
}
