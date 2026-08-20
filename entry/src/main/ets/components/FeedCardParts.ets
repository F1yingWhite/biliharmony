/**
 * 信息流卡片（VideoCard / LiveRoomCard）的公共视觉件：
 * 封面图、底部渐变遮罩、标题文本。参数按引用（$$）传递，
 * 保证卡片 @Reusable 复用时新数据能驱动这些公共块刷新。
 */
import { biliImageThumbnail } from '../common/ImageUrl';

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
  // 缩略图 URL（按双列卡宽 900w 出图）：信息流大批量卡片只拉几 KB~几十 KB 的 webp，
  // 相比原图（可能 1920px+ 的 jpg/png）显著省内存与 IO；@Reusable 复用时换 URL 依旧异步加载。
  Image($$.cover.length > 0 ? biliImageThumbnail($$.cover, 900) : $$.cover)
    .width('100%')
    // 对齐原生 B 站首页双列卡片的封面比例（16:9 太扁）。
    .aspectRatio(4 / 3)
    .objectFit(ImageFit.Cover)
    // 圆角由外层卡片容器 clip 承载，封面自身不再重复圆角（避免白底下露出圆角缝隙）。
    .backgroundColor($$.isDark ? '#2A2C31' : '#E5E7EB')
    .draggable(false)
    .alt($r('app.media.placeholder_cover'))
    // 异步图片解码：信息流滚动时避免阻塞主线程（SDK 该版本无 lazyLoading，syncLoad=false 即异步）。
    .syncLoad(false)
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
