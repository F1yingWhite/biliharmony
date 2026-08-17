import { BiliEmote, BiliEmotePackage } from '../model/Models';
import { LayoutTokens } from '../common/LayoutTokens';
import { colorWithAlpha } from '../common/Utils';

/**
 * 评论表情键盘。每个表情包是一张可横向切换的页面，底部分类栏与页面下标双向同步。
 * 组件只负责呈现，草稿插入和当前页状态由业务页持有，便于视频/动态评论复用。
 */
@Component
export struct ReplyEmotePanel {
  @Prop packages: Array<BiliEmotePackage> = [];
  @Prop currentIndex: number = 0;
  @Prop loading: boolean = false;
  @Prop panelHeight: number = 300;
  @Prop screenWidth: number = 360;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onPackageChange: (index: number) => void = () => {};
  onSelect: (item: BiliEmote) => void = () => {};

  private contentHeight(): number {
    return Math.max(190, this.panelHeight - 44);
  }

  private emoteLabel(item: BiliEmote): string {
    let label: string = item.text.replace('[', '').replace(']', '').trim();
    const separator: number = label.lastIndexOf('_');
    if (separator >= 0 && separator < label.length - 1) label = label.substring(separator + 1);
    return label;
  }

  @Builder
  PackagePage(pkg: BiliEmotePackage) {
    Grid() {
      ForEach(pkg.emotes, (item: BiliEmote) => {
        GridItem() {
          Column({ space: 2 }) {
            Image(item.url)
              .width(item.size > 1 ? 56 : 50)
              .height(item.size > 1 ? 56 : 50)
              .objectFit(ImageFit.Contain)
            Text(this.emoteLabel(item))
              .fontSize(10)
              .lineHeight(12)
              .fontColor(this.isDark ? '#B7BAC1' : '#73777F')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width('100%')
          }
          .width('100%')
          // 不能让单个 GridItem 填满整个面板，否则隐式行高等于面板高度，
          // 视口中永远只看得到第一行。
          .height(84)
          .justifyContent(FlexAlign.Center)
          .onClick(() => this.onSelect(item))
        }
        .height(84)
      }, (item: BiliEmote) => item.text + item.url)
    }
    .width('100%')
    .height(this.contentHeight())
    .columnsTemplate(LayoutTokens.emoteColumnsTemplate(this.screenWidth))
    .rowsGap(4)
    .columnsGap(2)
    .padding({ left: 8, right: 8, top: 8, bottom: 4 })
    .scrollBar(BarState.Off)
    .cachedCount(3)
  }

  build() {
    Column() {
      if (this.loading) {
        Row() {
          LoadingProgress().width(24).height(24).color(this.accent)
        }
        .width('100%')
        .height(this.contentHeight())
        .justifyContent(FlexAlign.Center)
      } else if (this.packages.length === 0) {
        Text('暂无可用表情包')
          .fontSize(13)
          .fontColor('#9499A0')
          .width('100%')
          .height(this.contentHeight())
          .textAlign(TextAlign.Center)
      } else {
        Swiper() {
          ForEach(this.packages, (pkg: BiliEmotePackage) => {
            this.PackagePage(pkg)
          }, (pkg: BiliEmotePackage, index: number) => pkg.title + String(index))
        }
        .width('100%')
        .height(this.contentHeight())
        .index(this.currentIndex)
        .indicator(false)
        .loop(false)
        .cachedCount(1)
        .duration(260)
        .onChange((index: number) => this.onPackageChange(index))

        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.packages, (pkg: BiliEmotePackage, index: number) => {
              Row() {
                if (pkg.icon.length > 0) {
                  Image(pkg.icon).width(27).height(27).objectFit(ImageFit.Contain)
                } else {
                  Text(pkg.title)
                    .fontSize(11)
                    .fontColor(index === this.currentIndex ? this.accent : '#9499A0')
                }
              }
              .height(36)
              .padding({ left: 9, right: 9 })
              .borderRadius(8)
              .backgroundColor(index === this.currentIndex ? colorWithAlpha(this.accent, '18') : '#00000000')
              .onClick(() => this.onPackageChange(index))
            }, (pkg: BiliEmotePackage, index: number) => pkg.title + String(index))
          }
          .padding({ left: 8, right: 8 })
        }
        .width('100%')
        .height(44)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height(this.panelHeight)
    .backgroundColor(this.isDark ? '#232428' : '#F5F6F8')
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#E7E9EC' })
  }
}
