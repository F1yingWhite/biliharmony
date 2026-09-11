import { LoadingSkeleton } from './LoadingSkeleton';
import { MotionTokens } from '../common/MotionTokens';

/** 通用加载、空态和错误状态；已知内容结构的页面传入 skeleton。 */
@Component
export struct LoadingView {
  @Prop loading: boolean = true;
  @Prop empty: boolean = false;
  @Prop emptyText: string = '暂无内容';
  @Prop errorText: string = '';
  @Prop retryText: string = '重新加载';
  @Prop skeleton: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  onRetry: () => void = () => {};

  build() {
    Column() {
      if (this.loading && this.skeleton.length > 0) {
        LoadingSkeleton({ layout: this.skeleton })
      } else if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(30).height(30).color(this.accent)
          Text('正在加载…').fontSize(12).fontColor(this.isDark ? '#A5AAB5' : '#7D8490')
        }
        .width('100%').padding({ top: 48, bottom: 48 })
        .accessibilityGroup(true).accessibilityText('正在加载内容')
      } else if (this.errorText.length > 0 || this.empty) {
        Column({ space: 12 }) {
          Image(this.errorText.length > 0 ? $r('app.media.bilix_error_2233') : $r('app.media.bilix_empty_2233'))
            .width(160).aspectRatio(560 / 316).objectFit(ImageFit.Contain)
          Text(this.errorText.length > 0 ? '暂时没能加载出来' : this.emptyText)
            .fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#E6E9EF' : '#434955').textAlign(TextAlign.Center)
          if (this.errorText.length > 0) {
            Text(this.errorText).fontSize(12).lineHeight(18)
              .fontColor(this.isDark ? '#A5AAB5' : '#7D8490').textAlign(TextAlign.Center)
            Button(this.retryText).height(40).fontSize(13).fontColor(this.accent)
              .backgroundColor(this.isDark ? '#252A34' : '#EEF0F5').borderRadius(20)
              .padding({ left: 24, right: 24 }).margin({ top: 4 })
              .onClick(() => this.onRetry())
          }
        }
        .width('100%').padding({ left: 28, right: 28, top: 40, bottom: 32 })
        .transition(MotionTokens.appear())
      }
    }.width('100%')
    .transition(MotionTokens.appear())
  }
}
