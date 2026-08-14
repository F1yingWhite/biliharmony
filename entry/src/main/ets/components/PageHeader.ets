/**
 * 统一二级页头栏：返回键 + 可选中间内容（头像等）+ 标题 + 底部分隔线。
 * 标题为 @Prop，页内二级导航（会话/收藏夹）切换标题时同步刷新。
 */
import { AppNavStack } from '../common/AppRouter';
import { BackButton } from './BackButton';

@Component
export struct PageHeader {
  @Prop title: string = '';
  headerHeight: number = 48;
  padLeft: number = 8;
  /** 返回键触发区宽度 */
  backWidth: number = 34;
  showDivider: boolean = true;
  onBack: () => void = () => {
    AppNavStack.pop();
  };
  /** 返回键与标题之间的可选内容（如会话头像） */
  @BuilderParam middle: () => void = this.emptyMiddle;
  @StorageProp('isDarkMode') isDark: boolean = false;

  @Builder
  emptyMiddle() {
  }

  build() {
    Row({ space: 10 }) {
      BackButton({
        triggerWidth: this.backWidth,
        triggerHeight: this.headerHeight,
        fontSize: 28,
        nudgeY: 0,
        onBack: this.onBack,
      })
      this.middle()
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
    }
    .width('100%')
    .height(this.headerHeight)
    .padding({ left: this.padLeft, right: 14 })
    .border({ width: { bottom: this.showDivider ? 0.5 : 0 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }
}
