import { MotionTokens } from '../../common/MotionTokens';
/**
 * 横向视频行卡片：封面（可带右下角徽标）+ 标题 + UP 主 + 可选第三行灰字。
 * compact = 搜索结果样式（130 宽封面 / 13 号标题 / 整行水平内边距）；
 * 非 compact = 历史/收藏样式（132 宽封面 / 14 号标题 / 无水平内边距）。
 * 跳转由调用方通过 onTap 注入，组件本身不感知路由参数。
 *
 * @Reusable：搜屏/历史/收藏/分区等 LazyForEach 长列表复用卡片，滚动时避免整卡重建。
 */
@Reusable
@Component
export struct VideoRowCard {
  @Prop cover: string = '';
  @Prop coverId: string = '';
  @Prop title: string = '';
  @Prop upName: string = '';
  /** 封面右下角徽标文案，空串不显示 */
  @Prop overlayText: string = '';
  /** 第三行灰字（观看时间 / 播放量），空串不显示 */
  @Prop extraText: string = '';
  @Prop compact: boolean = false;
  /** 非 compact 时标题与 UP 主行间距（历史 6 / 收藏 7） */
  @Prop contentSpace: number = 6;
  /** 深色模式下标题文字，各系列略有差异 */
  @Prop titleDarkColor: string = '#E6E6E6';
  onTap: () => void = () => {
  };
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    // 复用实例属性同步（@Prop 自动跟随，这里承接回调引用等非常量绑定）。
    const tap: Object | undefined = params['onTap'];
    if (typeof tap === 'function') {
      this.onTap = tap as () => void;
    }
  }

  build() {
    Row({ space: this.compact ? 10 : 11 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.cover)
          .width('100%')
          .aspectRatio(16 / 9)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.compact ? 6 : 7)
          // 历史/收藏/搜索结果等长列表中的封面异步解码（syncLoad=false），滚动不卡。
          .syncLoad(false)
          .backgroundColor(this.isDark ? '#2A2F39' : '#E5E8EE')
          .draggable(false)
        if (this.overlayText.length > 0) {
          Text(this.overlayText)
            .fontSize(this.compact ? 10 : 9)
            .fontColor('#FFFFFF')
            .backgroundColor(this.compact ? '#88000000' : '#99000000')
            .padding({ left: 4, right: 4, top: this.compact ? 1 : 2, bottom: this.compact ? 1 : 2 })
            .borderRadius(3)
            .margin(this.compact ? { right: 4, bottom: 4 } : { left: 4, right: 4, top: 4, bottom: 4 })
        }
      }
      .width(this.compact ? '43%' : 132)
      .id(this.coverId)
      .clip(true)
      Column({ space: this.compact ? 5 : this.contentSpace }) {
        if (this.compact) {
          Text(this.title)
            .fontSize(14)
            .fontColor(this.isDark ? this.titleDarkColor : '#18191C')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(19)
        } else {
          Text(this.title)
            .fontSize(14)
            .fontColor(this.isDark ? this.titleDarkColor : '#18191C')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(this.upName)
          .fontSize(11)
          .fontColor('#9499A0')
          .maxLines(1)
        if (this.extraText.length > 0) {
          Text(this.extraText)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(11)
            .fontColor('#B0B3B8')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    // 标题/UP 与封面上端对齐（Row 默认垂直居中会让文字偏下）
    .alignItems(VerticalAlign.Top)
    .padding({
      left: this.compact ? 14 : 0,
      right: this.compact ? 14 : 0,
      top: this.compact ? 8 : 10,
      bottom: this.compact ? 8 : 10,
    })
    .onClick(() => {
      this.onTap();
    })
    // 与 VideoCard 等卡片统一的按压反馈：按下轻微淡出，松开恢复。
    .animation({ duration: MotionTokens.feedback, curve: Curve.EaseOut })
    .stateStyles({
      pressed: {
        opacity: 0.9,
      },
      normal: {
        opacity: 1,
      },
    })
  }
}
