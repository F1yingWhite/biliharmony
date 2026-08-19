import { BiliEmote, BiliEmotePackage } from '../model/Models';
import { LayoutTokens } from '../common/LayoutTokens';
import { EmoteImageCache } from '../common/EmoteImageCache';
import { colorWithAlpha } from '../common/Utils';

/**
 * 评论表情键盘。每个表情包是一张可横向切换的页面，底部分类栏与页面下标双向同步。
 * 组件只负责呈现，草稿插入和当前页状态由业务页持有，便于视频/动态评论复用。
 */
@Component
export struct ReplyEmotePanel {
  @Prop @Watch('onPackagesChanged') packages: Array<BiliEmotePackage> = [];
  /** 表情图本地缓存映射：网络 URL → cacheDir 内本地路径（离线可显示）。 */
  @State emoteLocal: Map<string, string> = new Map<string, string>();
  @Prop @Watch('onCurrentIndexChanged') currentIndex: number = 0;
  @Prop loading: boolean = false;
  @Prop panelHeight: number = 300;
  @Prop screenWidth: number = 360;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onPackageChange: (index: number) => void = () => {};
  onSelect: (item: BiliEmote) => void = () => {};

  aboutToAppear(): void {
    this.primeCurrentPackage();
  }

  onPackagesChanged(): void {
    this.primeCurrentPackage();
  }

  onCurrentIndexChanged(): void {
    // 切到别的包时只预取那个包，避免一次把上百张图全拉垮。
    this.primeCurrentPackage();
  }

  /** 预取当前正在看的那个表情包的图片（其余包等被切到再下载）。 */
  private primeCurrentPackage(): void {
    const index: number = this.currentIndex;
    if (index < 0 || index >= this.packages.length) return;
    const pkg: BiliEmotePackage = this.packages[index];
    if (pkg.icon.length > 0) this.primeOne(pkg.icon);
    for (let j: number = 0; j < pkg.emotes.length; j++) {
      const emote: BiliEmote = pkg.emotes[j];
      if (emote.url.length > 0) this.primeOne(emote.url);
      if (emote.gifUrl.length > 0) this.primeOne(emote.gifUrl);
    }
  }

  private primeOne(url: string): void {
    if (url.length === 0 || this.emoteLocal.has(url)) return;
    EmoteImageCache.ensure(url).then((local: string) => {
      if (local !== url) {
        this.emoteLocal.set(url, local);
      }
    }).catch(() => {
    });
  }

  private imageSrc(url: string): string {
    if (url.length === 0) return '';
    const local: string | undefined = this.emoteLocal.get(url);
    return local !== undefined && local.length > 0 ? local : url;
  }

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
            Image(this.imageSrc(item.gifUrl.length > 0 ? item.gifUrl : item.url))
              .width(item.size > 1 ? 72 : 50)
              .height(item.size > 1 ? 72 : 50)
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
                  Image(this.imageSrc(pkg.icon)).width(27).height(27).objectFit(ImageFit.Contain)
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
        // Scroll 内容不足一屏时默认居中，表情包条应靠左起始。
        .align(Alignment.Start)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height(this.panelHeight)
    .backgroundColor(this.isDark ? '#232428' : '#F5F6F8')
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#E7E9EC' })
  }
}
