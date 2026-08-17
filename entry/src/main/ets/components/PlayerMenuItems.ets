/**
 * 播放器“更多功能”菜单项：
 * 普通带箭头行和带 Switch 的开关行，供 PlayerView 菜单/抽屉复用。
 */
@Component
export struct PlayerMenuItem {
  @Prop icon: Resource | null = null;
  @Prop label: string = '';
  @Prop value: string = '';
  @StorageProp('isDarkMode') isDark: boolean = false;
  onTap: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      if (this.icon !== null) {
        Image(this.icon)
          .width(22)
          .height(22)
          .renderMode(ImageRenderMode.Template)
          .fillColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      Text(this.label)
        .fontSize(15)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(12)
          .fontColor(this.isDark ? '#B3FFFFFF' : '#9499A0')
      }
      Image($r('app.media.ic_arrow_right'))
        .width(18)
        .height(18)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.isDark ? '#8AFFFFFF' : '#8A8A8E')
    }
    .width('100%')
    .height(56)
    .padding({ left: 14, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.isDark ? '#26272B' : '#F5F7F9')
    .onClick(() => this.onTap())
  }
}

@Component
export struct PlayerToggleItem {
  @Prop icon: Resource | null = null;
  @Prop label: string = '';
  @Prop isOn: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onChange: (isOn: boolean) => void = (isOn: boolean) => {
  };

  build() {
    Row({ space: 12 }) {
      if (this.icon !== null) {
        Image(this.icon)
          .width(22)
          .height(22)
          .renderMode(ImageRenderMode.Template)
          .fillColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      Text(this.label)
        .fontSize(15)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(this.accent)
        .onChange((isOn: boolean) => this.onChange(isOn))
    }
    .width('100%')
    .height(56)
    .padding({ left: 14, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.isDark ? '#26272B' : '#F5F7F9')
  }
}

@Component
export struct PlayerSponsorItem {
  @Prop sponsorOn: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  onToggle: (enabled: boolean) => void = (enabled: boolean) => {
  };

  build() {
    Row({ space: 12 }) {
      Image($r('app.media.ic_hot'))
        .width(22)
        .height(22)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.isDark ? '#FFFFFF' : '#18191C')
      Text('广告空降')
        .fontSize(15)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
      Text(this.sponsorOn ? '已开启' : '已关闭')
        .fontSize(12)
        .fontColor(this.isDark ? '#B3FFFFFF' : '#9499A0')
      Image($r('app.media.ic_arrow_right'))
        .width(18)
        .height(18)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.isDark ? '#8AFFFFFF' : '#8A8A8E')
    }
    .width('100%')
    .height(56)
    .padding({ left: 14, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.isDark ? '#26272B' : '#F5F7F9')
    .onClick(() => this.onToggle(this.sponsorOn))
  }
}
