/**
 * 统一筛选/排序 chip：选中主题色填充白字，未选灰底。
 * selected 为 @Prop，父组件切换选中态时单 chip 刷新。
 */
@Component
export struct FilterChip {
  label: string = '';
  @Prop selected: boolean = false;
  /** 部分场景（搜索排序行）需要底部外边距与面板行距对齐 */
  bottomMargin: number = 0;
  onTap: () => void = () => {
  };
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  build() {
    Text(this.label)
      .fontSize(12)
      .fontColor(this.selected ? '#FFFFFF' : (this.isDark ? '#C6C7CB' : '#61666D'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.selected ? this.accent : (this.isDark ? '#2E3136' : '#ECEEF0'))
      .borderRadius(14)
      .margin({ right: 8, bottom: this.bottomMargin })
      .onClick(() => {
        this.onTap();
      })
  }
}
