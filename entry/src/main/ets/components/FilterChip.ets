/**
 * 统一筛选/排序 chip：选中主题色填充并按亮度取文字色，未选灰底。
 * selected 为 @Prop，父组件切换选中态时单 chip 刷新。
 */
import { Haptic } from '../common/Haptic';
import { MotionTokens } from '../common/MotionTokens';
import { AppTheme } from '../common/AppTheme';

@Component
export struct FilterChip {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  label: string = '';
  @Prop selected: boolean = false;
  /** 部分场景（搜索排序行）需要底部外边距与面板行距对齐 */
  bottomMargin: number = 0;
  onTap: () => void = () => {
  };
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label)
      .fontSize(12)
      .fontColor(this.selected ? AppTheme.onAccent(this.accent) : (this.isDark ? '#C6C7CB' : '#61666D'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.selected ? this.accent : (this.isDark ? '#2E3136' : '#ECEEF0'))
      .borderRadius(14)
      .animation({ duration: MotionTokens.duration(MotionTokens.content, this.reduceMotion), curve: Curve.EaseOut })
    }
      .padding(0)
      .constraintSize({ minWidth: 44, minHeight: 44 })
      .backgroundColor(Color.Transparent)
      .borderRadius(22)
      .margin({ right: 8, bottom: this.bottomMargin })
      .accessibilityText(this.label)
      .accessibilitySelected(this.selected)
      .onClick(() => {
        Haptic.light();
        this.onTap();
      })
  }
}
