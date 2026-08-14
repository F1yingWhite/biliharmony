/**
 * 动态视图：关注动态 feed（需登录）
 */
import { DynamicItem, DynamicPageData, BiliEmote } from '../model/Models';
import { AppNavStack, NAV_IMAGE_VIEWER, NAV_LOGIN, NAV_VIDEO_DETAIL, NAV_USER_SPACE, ImageViewerParam,
  VideoDetailParam, UserSpaceParam } from '../common/AppRouter';
import { BiliApi } from '../api/BiliApi';
import { UserStore } from '../common/UserStore';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { formatRelativeTime } from '../common/Utils';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { BasicDataSource } from '../common/BasicDataSource';
import { DecoratedAvatar, UserDecorationBanner } from '../components/UserDecorations';

class DynamicContentPart {
  text: string = '';
  image: string = '';
  key: string = '';
}

// 表情拆分结果按动态 id 缓存（内容不可变），避免每次 build 重算 O(内容×表情数) 扫描。
const DYN_PARTS_CACHE_LIMIT: number = 100;
const dynPartsCache: Map<string, Array<DynamicContentPart>> = new Map<string, Array<DynamicContentPart>>();

function contentPartsOf(item: DynamicItem): Array<DynamicContentPart> {
  const cached: Array<DynamicContentPart> | undefined = dynPartsCache.get(item.dynId);
  if (cached !== undefined) {
    return cached;
  }
  const result: Array<DynamicContentPart> = [];
  let rest: string = item.content;
  let keyIndex: number = 0;
  while (rest.length > 0) {
    let foundAt: number = rest.length;
    let found: BiliEmote | null = null;
    for (let i: number = 0; i < item.emotes.length; i++) {
      const at: number = rest.indexOf(item.emotes[i].text);
      if (at >= 0 && at < foundAt) { foundAt = at; found = item.emotes[i]; }
    }
    if (found === null) {
      const part: DynamicContentPart = new DynamicContentPart();
      part.text = rest; part.key = item.dynId + '-t' + String(keyIndex++); result.push(part); break;
    }
    if (foundAt > 0) {
      const part: DynamicContentPart = new DynamicContentPart();
      part.text = rest.substring(0, foundAt); part.key = item.dynId + '-t' + String(keyIndex++); result.push(part);
    }
    const emotePart: DynamicContentPart = new DynamicContentPart();
    emotePart.image = found.url; emotePart.key = item.dynId + '-e' + String(keyIndex++); result.push(emotePart);
    rest = rest.substring(foundAt + found.text.length);
  }
  if (dynPartsCache.size >= DYN_PARTS_CACHE_LIMIT) {
    const oldest: IteratorResult<string> = dynPartsCache.keys().next();
    if (!oldest.done) {
      dynPartsCache.delete(oldest.value);
    }
  }
  dynPartsCache.set(item.dynId, result);
  return result;
}

/** 单条动态卡片：独立 @Component，父组件状态变化不再整列表重建。 */
@Component
struct DynCard {
  @Prop item: DynamicItem = new DynamicItem();
  @Prop embedded: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;

  private shownImages(): Array<string> {
    return this.item.images.slice(0, 9);
  }

  build() {
    Column({ space: 8 }) {
      // 头部：头像 + 昵称 + 时间
      Row({ space: 8 }) {
        DecoratedAvatar({
          face: this.item.face,
          pendant: this.item.pendant,
          avatarSize: 36,
          containerSize: 52,
        })
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.item.decorationCard.length > 0) {
            UserDecorationBanner({
              imageUrl: this.item.decorationCard,
              numberText: this.item.decorationNumber,
              numberColor: this.item.decorationColor.length > 0 ? this.item.decorationColor : '#FFFFFF',
              bannerHeight: 46,
            })
          }
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(this.item.uname)
                .fontSize(14)
                .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
                .fontWeight(FontWeight.Medium)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(formatRelativeTime(this.item.pubtime))
                .fontSize(11)
                .fontColor('#9499A0')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (!this.embedded && this.item.decorationCard.length === 0) {
              Text('已关注')
                .fontSize(12)
                .fontColor('#9499A0')
                .backgroundColor(this.isDark ? '#34363B' : '#EEF0F2')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(12)
            }
          }
          .width('100%')
          .height(this.item.decorationCard.length > 0 ? 46 : 52)
          .padding({ left: this.item.decorationCard.length > 0 ? 8 : 0,
            right: this.item.decorationCard.length > 0 ? 74 : 0 })
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .height(52)
        .onClick(() => {
          if (this.item.mid > 0) AppNavStack.pushPathByName(NAV_USER_SPACE, { mid: this.item.mid } as UserSpaceParam);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 内容
      if (this.item.content.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(contentPartsOf(this.item), (part: DynamicContentPart) => {
            if (part.image.length > 0) {
              Image(part.image).width(25).height(25).objectFit(ImageFit.Contain).margin({ right: 2 })
            } else {
              Text(part.text).fontSize(14).fontColor(this.isDark ? '#D0D0D0' : '#222222').lineHeight(21)
            }
          }, (part: DynamicContentPart) => part.key)
        }
        .width('100%')
      }

      // 图文/专栏动态图片卡片
      if (this.item.images.length > 0) {
        Grid() {
          ForEach(this.shownImages(), (src: string, index: number) => {
            GridItem() {
              Image(src)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .onClick(() => {
                  const viewer: ImageViewerParam = { images: this.shownImages(), initialIndex: index };
                  AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer);
                })
            }
          }, (src: string, index: number) => src + String(index))
        }
        .columnsTemplate(this.item.images.length === 1 ? '1fr' : (this.item.images.length === 2 ? '1fr 1fr' : '1fr 1fr 1fr'))
        .rowsGap(4)
        .columnsGap(4)
        .height(this.item.images.length === 1 ? 210 : (this.item.images.length <= 3 ? 118 : 236))
        .width('100%')
      }

      // 视频卡片
      if (this.item.title.length > 0) {
        Row({ space: 10 }) {
          if (this.item.cover.length > 0) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Image(this.item.cover)
                .width(132)
                .height(78)
                .objectFit(ImageFit.Cover)
                .borderRadius(7)
              if (this.item.badge.length > 0) {
                Text(this.item.badge)
                  .fontSize(9).fontColor('#FFFFFF').backgroundColor('#B3FB7299')
                  .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(4).margin(5)
              }
            }
          }
          Column({ space: 6 }) {
            Text(this.item.title)
              .fontSize(14)
              .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.item.subtitle.length > 0) {
              Text(this.item.subtitle).fontSize(11).fontColor('#9499A0').maxLines(2)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(8)
        .borderRadius(9)
        .backgroundColor(this.isDark ? '#222429' : '#F5F7F9')
        .onClick(() => {
          if (this.item.bvid.length > 0) {
            const param: VideoDetailParam = { bvid: this.item.bvid, aid: this.item.aid, title: this.item.title };
            AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
          }
        })
      }

      // 底部互动
      Row({ space: 22 }) {
        Text('赞 ' + this.item.like)
          .fontSize(12)
          .fontColor('#9499A0')
        Text('评 ' + this.item.comment)
          .fontSize(12)
          .fontColor('#9499A0')
        Text('转 ' + this.item.forward)
          .fontSize(12)
          .fontColor('#9499A0')
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.isDark ? '#2A2C31' : '#FFFFFF')
  }
}

@Component
export struct DynamicView {
  /** hostMid > 0 时展示指定用户的公开动态；否则展示当前账号的关注动态。 */
  @Prop hostMid: number = 0;
  /** 嵌入用户空间时不占用主页顶部和 Dock 的安全偏移。 */
  @Prop embedded: boolean = false;
  @State loading: boolean = true;
  @State login: boolean = false;
  @State dynOffset: string = '';
  @State dynHasMore: boolean = true;
  @State feedLoading: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVer: number = 0;
  private dynSource: BasicDataSource<DynamicItem> = new BasicDataSource<DynamicItem>();
  private initializing: boolean = false;

  onLoginChanged(): void {
    // 登录/登出广播：重载动态流（Tabs 保活，aboutToAppear 不会再触发）
    this.init().catch(() => {
    });
  }

  aboutToAppear(): void {
    this.init().catch(() => {
    });
  }

  async init(): Promise<void> {
    // aboutToAppear 与登录广播可能同时触发，防重入
    if (this.initializing) {
      return;
    }
    this.initializing = true;
    try {
      this.loading = true;
      if (this.hostMid <= 0 && !UserStore.isLogin) {
        await UserStore.refresh();
      }
      this.login = this.hostMid > 0 || UserStore.isLogin;
      if (this.login) {
        await this.loadFeed(true);
      }
    } catch (e) {
      // 动态流失败保留空态，用户可点击重试。
    } finally {
      this.loading = false;
      this.initializing = false;
    }
  }

  async loadFeed(reset: boolean): Promise<void> {
    if (this.feedLoading || (!reset && !this.dynHasMore)) return;
    this.feedLoading = true;
    try {
      const off: string = reset ? '' : this.dynOffset;
      const page: DynamicPageData = this.hostMid > 0 ?
        await BiliApi.getUserDynamicFeed(this.hostMid, off) : await BiliApi.getDynamicFeed(off);
      if (reset) {
        this.dynSource.reset(page.items);
      } else {
        this.dynSource.append(page.items);
      }
      this.dynOffset = page.offset;
      this.dynHasMore = page.hasMore;
    } catch (e) {
      // 保留已加载数据，触底时可再次重试。
    } finally {
      this.feedLoading = false;
    }
  }

  @Builder
  LoginPrompt() {
    Column({ space: 14 }) {
      Text('( ゜- ゜)')
        .fontSize(40)
        .fontColor('#CCCCCC')
      Text('登录后即可查看关注动态')
        .fontSize(14)
        .fontColor('#9499A0')
      Button('去登录')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.accent)
        .borderRadius(20)
        .padding({ left: 32, right: 32 })
        .onClick(() => {
          AppNavStack.pushPathByName(NAV_LOGIN, null);
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (this.loading) {
        LoadingView({ loading: true })
          .margin({ top: 80 })
      } else if (!this.login) {
        this.LoginPrompt()
      } else if (this.dynSource.totalCount() === 0) {
        LoadingView({
          loading: false,
          empty: true,
          emptyText: this.hostMid > 0 ? '该用户暂时没有发布动态' : '暂时没有动态，去关注一些UP主吧',
          onRetry: () => {
            this.init();
          },
        })
        .margin({ top: 80 })
      } else {
        List({ space: 10 }) {
          LazyForEach(this.dynSource, (item: DynamicItem) => {
            ListItem() {
              DynCard({ item: item, embedded: this.embedded })
            }
          }, (item: DynamicItem) => item.dynId)
          ListItem() {
            LoadMoreFooter({
              loading: this.feedLoading,
              hasMore: this.dynHasMore,
              moreText: '继续加载动态',
              endText: '—— 动态到底啦 ——',
              fixedHeight: 52,
              spinnerSize: 22,
              clickable: false,
            })
          }
        }
        .width('100%')
        .height('100%')
        .cachedCount(3)
        .contentStartOffset(this.embedded ? 4 : Immersive.statusBarHeight() + 56)
        .contentEndOffset(this.embedded ? 16 : Immersive.bottomInset() + 56)
        .padding({ left: 10, right: 10 })
        .scrollBar(BarState.Off)
        .onScroll((offset: number) => {
          if (!this.embedded) AppTheme.updateHeaderFade(offset);
        })
        .onReachEnd(() => {
          this.loadFeed(false);
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
