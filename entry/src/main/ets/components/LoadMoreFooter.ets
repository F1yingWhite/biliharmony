/**
 * 统一分页 footer，三分支：
 * - loading：转圈（可配文案）
 * - hasMore 且 moreText 非空：可点击的「加载更多 / 继续加载」
 * - !hasMore：「到底啦」占位
 * height > 0 时使用固定高度（信息流触底自动加载场景），否则用上下 padding（点击加载场景）。
 */
import { MotionTokens } from '../common/MotionTokens';

@Component
export struct LoadMoreFooter {
  @Prop loading: boolean = false;
  @Prop hasMore: boolean = true;
  @Prop moreText: string = '加载更多';
  @Prop endText: string = '—— 到底啦 ——';
  @Prop loadingText: string = '';
  /** 固定高度；<= 0 时用 padTop/padBottom 撑开 */
  @Prop fixedHeight: number = 0;
  /** loading 文案用主题色（默认灰色） */
  accentLoadingText: boolean = false;
  fontSize: number = 12;
  spinnerSize: number = 20;
  padTop: number = 12;
  padBottom: number = 12;
  /** moreText 是否可点击触发 onLoadMore（触底自动加载的列表传 false） */
  clickable: boolean = true;
  onLoadMore: () => void = () => {
  };
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  @Builder
  Inner() {
    if (this.loading) {
      LoadingProgress()
        .width(this.spinnerSize)
        .height(this.spinnerSize)
        .color(this.accent)
      if (this.loadingText.length > 0) {
        Text(this.loadingText)
          .fontSize(this.fontSize)
          .fontColor(this.accentLoadingText ? this.accent : (this.isDark ? '#D0D0D0' : '#676B72'))
      }
    } else if (this.hasMore) {
      if (this.moreText.length > 0) {
        Text(this.moreText)
          .fontSize(this.fontSize)
          .fontColor(this.accent)
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .borderRadius(18)
          .stateStyles({ pressed: { opacity: 0.9 }, normal: { opacity: 1 } })
          .onClick(() => {
            if (this.clickable) {
              this.onLoadMore();
            }
          })
      }
    } else if (this.endText.length > 0) {
      Text(this.endText)
        .fontSize(this.fontSize)
        .fontColor('#9499A0')
        .transition(MotionTokens.appear())
    }
  }

  build() {
    if (this.fixedHeight > 0) {
      Row({ space: 8 }) {
        this.Inner()
      }
      .width('100%')
      .height(this.fixedHeight)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    } else {
      Row({ space: 8 }) {
        this.Inner()
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .padding({ top: this.padTop, bottom: this.padBottom })
    }
  }
}
