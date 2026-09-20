/**
 * 视频详情页「相关推荐」单行：封面（时长/高互动角标）+ 标题 + UP/数据 + 右侧 ⋮。
 * 从 VideoDetail 页拆出；⋮ 弹窗状态挂在行内独立组件上（页面级共享 @State 会让所有行同时弹）。
 */
import { VideoItem } from '../../model/Models';
import { formatCount, formatDuration } from '../../common/Utils';
import { Haptic } from '../../common/Haptic';

@Reusable
@Component
export struct RelatedVideoRow {
  @Prop item: VideoItem = new VideoItem();
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onOpen: (item: VideoItem) => void = () => {};
  onReport: (item: VideoItem) => void = () => {};
  onHide: (item: VideoItem) => void = () => {};

  aboutToReuse(params: Record<string, Object>): void {
    this.item = params['item'] as VideoItem;
  }

  build() {
    Row({ space: 10 }) {
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Image(this.item.cover)
            .width(120)
            .height(68)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
          Row({ space: 4 }) {
            // 高互动角标固定在左下角，时长固定在右下角，二者共享一行不会重叠。
            if (this.item.coin >= 10000 || this.item.share >= 10000) {
              Text(this.item.coin >= 10000 ? formatCount(this.item.coin) + ' 投币' :
                formatCount(this.item.share) + ' 分享')
              .fontSize(9)
              .fontColor('#FFFFFF')
              .backgroundColor(this.accent)
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 62 })
            }
            Blank()
            if (this.item.duration > 0) {
              Text(formatDuration(this.item.duration))
                .fontSize(10)
                .fontColor('#FFFFFF')
                .backgroundColor('#88000000')
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .borderRadius(3)
                .maxLines(1)
            }
          }
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 4 })
          .alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.None)
        }
        .width(120)
        .height(68)
        .clip(true)
        // 文字列高度与封面一致：标题贴顶，UP/数据组沉底对齐卡片下缘。
        Column({ space: 5 }) {
          Text(this.item.title)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(17)
          Column({ space: 5 }) {
            Row({ space: 4 }) {
              Text('UP')
                .fontSize(8)
                .fontColor('#9499A0')
                .border({ width: 0.6, color: '#8E9399', radius: 2 })
                .padding({ left: 2, right: 2 })
              Text(this.item.upName)
                .fontSize(11)
                .fontColor('#9499A0')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Row({ space: 3 }) {
              Image($r('app.media.ic_play'))
                .width(11).height(11)
                .renderMode(ImageRenderMode.Template)
                .fillColor('#9499A0')
              Text(this.item.playText)
                .fontSize(10).fontColor('#9499A0')
              Row({ space: 3 }) {
                Image($r('app.media.ic_comment'))
                  .width(11).height(11)
                  .renderMode(ImageRenderMode.Template)
                  .fillColor('#9499A0')
                Text(formatCount(this.item.reply))
                  .fontSize(10).fontColor('#9499A0')
              }
              .margin({ left: 8 })
            }
            .alignItems(VerticalAlign.Center)
          }
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .height(68)
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .height(68)
      .alignItems(VerticalAlign.Top)
      .onClick(() => this.onOpen(this.item))
      // 最右竖三点：举报/不想看（每行独立弹窗状态，气泡朝上贴按钮），与卡片底部对齐
      RelatedMoreDot({
        onReport: () => this.onReport(this.item),
        onHide: () => this.onHide(this.item),
      })
    }
    .width('100%')
    // 标题/UP 与封面上端对齐（Row 默认垂直居中会让文字偏下）
    .alignItems(VerticalAlign.Top)
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#303238' : '#E7E9EC' })
  }
}
@Component
struct RelatedMoreDot {
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State open: boolean = false;
  onReport: () => void = () => {};
  onHide: () => void = () => {};

  build() {
    Column() {
      Blank()
      Image($r('app.media.ic_more'))
        .width(13)
        .height(13)
        .renderMode(ImageRenderMode.Template)
        .fillColor('#9499A0')
    }
    .height(68)
    .padding({ right: 2, left: 2, top: 6, bottom: 6 })
    .onClick(() => {
      Haptic.light();
      this.open = !this.open;
    })
    .bindPopup(this.open, {
      builder: this.menu(),
      placement: Placement.TopRight,
      popupColor: this.isDark ? '#2A2C31' : '#FFFFFF',
      backgroundBlurStyle: BlurStyle.NONE,
      radius: 12,
      shadow: { radius: 18, color: this.isDark ? '#8C000000' : '#33000000', offsetX: 0, offsetY: 4 },
      enableArrow: true,
      arrowPointPosition: ArrowPointPosition.END,
      offset: { x: 0, y: -4 },
      autoCancel: true,
    })
  }

  @Builder
  menu() {
    Column() {
      this.menuRow($r('app.media.ic_report_flag'), '举报', this.onReport)
      this.menuRow($r('app.media.bilix_icon_dislike'), '不想看', this.onHide)
    }
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  menuRow(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 8 }) {
      Image(icon)
        .width(16)
        .height(16)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.isDark ? '#C8C8CC' : '#5A5F66')
      Text(label)
        .fontSize(14)
        .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
    }
    .width(96)
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .onClick(() => {
      this.open = false;
      onTap();
    })
  }
}
