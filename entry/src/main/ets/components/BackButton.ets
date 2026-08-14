/**
 * 统一返回按钮。三种变体：
 * - TEXT：纯文字 ‹（跟随明暗主题，可通过 color 覆盖）
 * - GLASS：玻璃圆形（用户空间 banner 之上）
 * - DARK：黑底圆形（直播间等深色场景）
 */
import { AppNavStack } from '../common/AppRouter';

export enum BackButtonVariant {
  TEXT,
  GLASS,
  DARK,
}

@Component
export struct BackButton {
  variant: BackButtonVariant = BackButtonVariant.TEXT;
  /** TEXT 变体触发区尺寸 */
  triggerWidth: number = 32;
  triggerHeight: number = 32;
  /** TEXT 变体字号 */
  fontSize: number = 26;
  /** TEXT 变体颜色，空串 = 跟随明暗主题 */
  color: string = '';
  /** TEXT 变体基线微调（‹ 字形偏下时上移） */
  nudgeY: number = -1;
  onBack: () => void = () => {
    AppNavStack.pop();
  };
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;

  build() {
    if (this.variant === BackButtonVariant.GLASS) {
      Row() {
        Image($r('app.media.ic_back'))
          .width(18)
          .height(18)
          .fillColor('#FFFFFF')
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.glassOn ? '#66000000' : '#B3000000')
      .backdropBlur(this.glassOn ? 10 : 0)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onBack();
      })
    } else if (this.variant === BackButtonVariant.DARK) {
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_back'))
          .width(20)
          .height(20)
          .fillColor('#FFFFFF')
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor('#73000000')
      .onClick(() => {
        this.onBack();
      })
    } else {
      Row() {
        Text('‹')
          .fontSize(this.fontSize)
          .fontColor(this.color.length > 0 ? this.color : (this.isDark ? '#FFFFFF' : '#18191C'))
          .translate({ y: this.nudgeY })
      }
      .width(this.triggerWidth)
      .height(this.triggerHeight)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.onBack();
      })
    }
  }
}
