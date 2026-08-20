import { BiliEmote, BiliEmotePackage } from '../model/Models';
import { LayoutTokens } from '../common/LayoutTokens';
import { EmoteImageCache } from '../common/EmoteImageCache';
import { colorWithAlpha } from '../common/Utils';
import { Immersive } from '../common/Immersive';

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
  private tabScroller: ListScroller = new ListScroller();

  aboutToAppear(): void {
    this.primeCurrentPackage();
  }

  /** 底部导航手势区高度（vp）：表情面板贴窗口底缘渲染，分类条不内缩会与系统导航条抢点击。 */
  private bottomInset(): number {
    try {
      return Immersive.bottomInset();
    } catch (e) {
      return 0;
    }
  }

  onPackagesChanged(): void {
    this.primeCurrentPackage();
  }

  onCurrentIndexChanged(): void {
    // 切到别的包时只预取那个包，避免一次把上百张图全拉垮。
    this.primeCurrentPackage();
    // 滑页（或点 Tab）后把分类条滚动到选中项居中，选中态始终在可视范围内。
    this.scrollToActiveTab();
  }

  private scrollToActiveTab(): void {
    const index: number = this.currentIndex;
    if (index < 0 || index >= this.packages.length) return;
    // 延后一帧：目标 ListItem 可能刚随数据更新完成布局，立即滚动可能定位不到。
    setTimeout(() => {
      try {
        this.tabScroller.scrollToIndex(index, true, ScrollAlign.CENTER);
      } catch (e) {
        // 滚动失败不影响选中态展示。
      }
    }, 40);
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
    return Math.max(150, this.panelHeight - 44 - this.bottomInset());
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

        // 分类条用横向 List：可程序化 scrollToIndex，滑页后选中 Tab 自动滚到可见区居中；
        // 原 Scroll+Row 只能滚动内容、无法定位，选中项会留在视野外。
        List({ space: 4, scroller: this.tabScroller }) {
          ForEach(this.packages, (pkg: BiliEmotePackage, index: number) => {
            ListItem() {
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
            }
            .padding({ left: index === 0 ? 8 : 0, right: index === this.packages.length - 1 ? 8 : 0 })
          }, (pkg: BiliEmotePackage, index: number) => pkg.title + String(index))
        }
        .width('100%')
        .height(44)
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .alignListItem(ListItemAlign.Start)
      }
    }
    .width('100%')
    .height(this.panelHeight)
    // 底边内缩系统导航区：分类条离屏幕底缘留出可点空间，避免滑到最底部时误触返回/导航。
    .padding({ bottom: this.bottomInset() })
    .backgroundColor(this.isDark ? '#232428' : '#F5F6F8')
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#E7E9EC' })
  }
}
