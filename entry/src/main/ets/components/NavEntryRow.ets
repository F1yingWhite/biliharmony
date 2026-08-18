/**
 * 通用列表入口行：图标 + 标题 + 箭头（首页热门/分区/番剧/直播入口共用）。
 * 图标与标题一次传入（静态即可，无需响应式）；主题色/深色走 AppStorage。
 */
import { AppTheme } from '../common/AppTheme';
import { Haptic } from '../common/Haptic';

@Component
export struct NavEntryRow {
  /** 左侧图标资源 */
  icon: Resource = $r('app.media.ic_arrow_right');
  /** 中间标题 */
  title: string = '';
  /** 右侧是否显示箭头（某些入口无箭头） */
  showArrow: boolean = true;
  /** 点击回调 */
  onTap: () => void = () => {
  };
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  build() {
    Row({ space: 10 }) {
      Image(this.icon)
        .width(18)
        .height(18)
        .fillColor(this.accent)
      Text(this.title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
      Blank()
      if (this.showArrow) {
        Image($r('app.media.ic_arrow_right'))
          .width(14)
          .height(14)
          .fillColor('#9499A0')
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .borderRadius(12)
    .backgroundColor(AppTheme.surface())
    .onClick(() => {
      Haptic.light();
      this.onTap();
    })
  }
}