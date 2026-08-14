/**
 * 信息流卡片（VideoCard / LiveRoomCard）的公共视觉件：
 * 封面图、底部渐变遮罩、标题文本。参数按引用（$$）传递，
 * 保证卡片 @Reusable 复用时新数据能驱动这些公共块刷新。
 */

export interface FeedCoverParam {
  cover: string;
  isDark: boolean;
}

export interface FeedMaskParam {
  height: number;
  bottomColor: string;
}

export interface FeedTitleParam {
  title: string;
  isDark: boolean;
}

/** 16:9 封面图（圆角 12 + 占位图 + 主题占位底色） */
@Builder
export function FeedCoverImage($$: FeedCoverParam) {
  Image($$.cover)
    .width('100%')
    .aspectRatio(16 / 9)
    .objectFit(ImageFit.Cover)
    .borderRadius(12)
    .backgroundColor($$.isDark ? '#2A2C31' : '#E5E7EB')
    .draggable(false)
    .alt($r('app.media.placeholder_cover'))
}

/** 底部渐变遮罩（上透下暗，保证底部数据可读） */
@Builder
export function FeedGradientMask($$: FeedMaskParam) {
  Column()
    .width('100%')
    .height($$.height)
    .linearGradient({
      angle: 180,
      colors: [['#00000000', 0.0], [$$.bottomColor, 1.0]],
    })
}

/** 卡片标题（14 号中粗，两行截断） */
@Builder
export function FeedCardTitle($$: FeedTitleParam) {
  Text($$.title)
    .width('100%')
    .fontSize(14)
    .lineHeight(19)
    .fontWeight(FontWeight.Medium)
    .fontColor($$.isDark ? '#E6E6E6' : '#18191C')
    .maxLines(2)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
}
