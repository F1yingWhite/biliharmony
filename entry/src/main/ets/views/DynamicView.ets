/**
 * 动态视图：关注动态 feed（需登录）
 */
import { DynamicItem, DynamicPageData, BiliEmote } from '../model/Models';
import { AppNavStack, NAV_DYNAMIC_DETAIL, NAV_IMAGE_VIEWER, NAV_LIVE_ROOM, NAV_LOGIN, NAV_VIDEO_DETAIL,
  NAV_USER_SPACE, DynamicDetailParam, ImageViewerParam, LiveRoomParam, VideoDetailParam,
  UserSpaceParam, NAV_BANGUMI_DETAIL, BangumiDetailParam } from '../common/AppRouter';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { UserStore } from '../common/UserStore';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { formatCount, formatRelativeTime } from '../common/Utils';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { BasicDataSource } from '../common/BasicDataSource';
import { DecoratedAvatar, UserDecorationBanner } from '../components/UserDecorations';
import { LayoutTokens } from '../common/LayoutTokens';
import { vibrator } from '@kit.SensorServiceKit';

class DynamicContentPart {
  text: string = '';
  image: string = '';
  key: string = '';
}

// 表情拆分结果按动态 id 缓存（内容不可变），避免每次 build 重算 O(内容×表情数) 扫描。
const DYN_PARTS_CACHE_LIMIT: number = 100;
const dynPartsCache: Map<string, Array<DynamicContentPart>> = new Map<string, Array<DynamicContentPart>>();

function contentPartsOf(item: DynamicItem): Array<DynamicContentPart> {
  // 同一 dynId 的 feed 简版与 detail 完整版可能拥有不同表情节点，缓存键必须包含节点签名。
  let emoteSignature: string = '';
  for (let i: number = 0; i < item.emotes.length; i++) {
    emoteSignature += '|' + item.emotes[i].text + '=' + item.emotes[i].url;
  }
  const cacheKey: string = item.dynId + '|' + item.content + emoteSignature;
  const cached: Array<DynamicContentPart> | undefined = dynPartsCache.get(cacheKey);
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
  dynPartsCache.set(cacheKey, result);
  return result;
}

/** 单条动态卡片：独立 @Component，父组件状态变化不再整列表重建。 */
@Component
export struct DynCard {
  @Prop @Watch('onItemChanged') item: DynamicItem = new DynamicItem();
  @Prop embedded: boolean = false;
  @Prop detailMode: boolean = false;
  @State liked: boolean = false;
  @State likeCount: number = 0;
  @State forwardCount: number = 0;
  @State actionBusy: boolean = false;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';

  aboutToAppear(): void {
    this.syncFromItem();
  }

  onItemChanged(): void {
    this.syncFromItem();
  }

  private syncFromItem(): void {
    this.liked = this.item.liked;
    this.likeCount = this.item.like;
    this.forwardCount = this.item.forward;
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 组件销毁或窗口异常时忽略提示。
    }
  }

  private decorationNumberLabel(): string {
    const raw: string = this.item.decorationNumber.trim();
    if (raw.length === 0) return '';
    if (/^(no|co)\.?\s/i.test(raw)) return raw;
    return 'NO.' + raw;
  }

  private tapVibrate(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 15 }, { usage: 'physicalFeedback' }).catch(() => {
      });
    } catch (e) {
      // 不支持或未授权时静默忽略。
    }
  }

  private async toggleLike(): Promise<void> {
    if (this.actionBusy) return;
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再点赞');
      return;
    }
    if (this.item.dynId.length === 0) return;
    const next: boolean = this.liked ? false : true;
    const prevLiked: boolean = this.liked;
    const prevCount: number = this.likeCount;
    this.liked = next;
    this.likeCount = Math.max(0, this.likeCount + (next ? 1 : -1));
    this.item.liked = next;
    this.item.like = this.likeCount;
    this.actionBusy = true;
    try {
      const result: ActionResult = await BiliApi.likeDynamic(this.item.dynId, next);
      if (result.ok === false) {
        this.liked = prevLiked;
        this.likeCount = prevCount;
        this.item.liked = prevLiked;
        this.item.like = prevCount;
        this.toast(result.message);
      } else {
        this.toast(next ? '点赞成功' : '已取消点赞');
      }
    } catch (e) {
      this.liked = prevLiked;
      this.likeCount = prevCount;
      this.item.liked = prevLiked;
      this.item.like = prevCount;
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  private async forwardDynamic(): Promise<void> {
    if (this.actionBusy) return;
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再转发');
      return;
    }
    if (this.item.dynId.length === 0) return;
    this.actionBusy = true;
    try {
      const result: ActionResult = await BiliApi.repostDynamic(this.item.dynId);
      if (result.ok) {
        this.forwardCount++;
        this.item.forward = this.forwardCount;
        this.toast('转发成功');
      } else {
        this.toast(result.message);
      }
    } catch (e) {
      this.toast('网络异常，请稍后重试');
    } finally {
      this.actionBusy = false;
    }
  }

  private shownImages(): Array<string> {
    return this.item.images;
  }

  /** 图片网格高度随图片数量自适应，避免多图动态只显示前两行。 */
  private imageGridHeightFor(images: Array<string>): number {
    const count: number = images.length;
    if (count <= 1) return 210;
    if (count <= 3) return 118;
    const rows: number = Math.ceil(count / 3);
    return rows * 118 + (rows - 1) * 4;
  }

  private imageGridHeight(): number {
    return this.imageGridHeightFor(this.shownImages());
  }

  private openDetail(focusComments: boolean = false): void {
    if (this.detailMode || this.item.dynId.length === 0) return;
    const param: DynamicDetailParam = { item: this.item as Object, focusComments: focusComments };
    AppNavStack.pushPathByName(NAV_DYNAMIC_DETAIL, param);
  }

  private openItemDetail(item: DynamicItem): void {
    if (item.dynId.length === 0) return;
    const param: DynamicDetailParam = { item: item as Object };
    AppNavStack.pushPathByName(NAV_DYNAMIC_DETAIL, param);
  }

  private openLive(item: DynamicItem): void {
    if (item.liveRoomId <= 0) return;
    const param: LiveRoomParam = {
      roomId: item.liveRoomId,
      uid: item.liveUid > 0 ? item.liveUid : item.mid,
      title: item.title,
      uname: item.uname,
      face: item.face,
      cover: item.cover,
    };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  private openMajor(item: DynamicItem): void {
    if (item.liveRoomId > 0) {
      this.openLive(item);
    } else if (item.seasonId > 0 || item.epId > 0) {
      // PGC（番剧/影视）卡片进番剧详情页；UGC 合集卡没有 season_id/epid，仍走视频详情。
      const param: BangumiDetailParam = { seasonId: item.seasonId, epId: item.epId, title: item.title };
      AppNavStack.pushPathByName(NAV_BANGUMI_DETAIL, param);
    } else if (item.bvid.length > 0) {
      const param: VideoDetailParam = { bvid: item.bvid, aid: item.aid, title: item.title };
      AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
    } else {
      this.openItemDetail(item);
    }
  }

  private openItemImage(item: DynamicItem, index: number): void {
    const images: Array<string> = item.images;
    const transitionId: string = 'image-viewer-dynamic-' + item.dynId + '-' + String(index);
    const viewer: ImageViewerParam = { images: images, initialIndex: index, transitionId: transitionId };
    // 一镜到底：关 Navigation 默认转场（push 第三参 false）并包 animateTo，geometryTransition 才接管动画
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer, false);
    });
  }

  @Builder
  ForwardedCard(item: DynamicItem) {
    Column({ space: 7 }) {
      Text('@' + (item.uname.length > 0 ? item.uname : '原动态作者'))
        .width('100%').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#008AC5')
        .onClick(() => {
          this.openItemDetail(item);
        })
      if (item.content.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(contentPartsOf(item), (part: DynamicContentPart) => {
            if (part.image.length > 0) {
              Image(part.image).width(23).height(23).objectFit(ImageFit.Contain).margin({ right: 2 })
            } else {
              Text(part.text).fontSize(13).lineHeight(20)
                .fontColor(this.isDark ? '#D8D8DC' : '#303236')
            }
          }, (part: DynamicContentPart) => 'forward-' + part.key)
        }
        .width('100%')
        .onClick(() => {
          this.openItemDetail(item);
        })
      }
      if (item.images.length > 0) {
        Grid() {
          ForEach(item.images, (src: string, index: number) => {
            GridItem() {
              Image(src).width('100%').height('100%').objectFit(ImageFit.Cover).borderRadius(6)
                .geometryTransition('image-viewer-dynamic-' + item.dynId + '-' + String(index))
                .onClick(() => {
                  this.openItemImage(item, index);
                })
            }
          }, (src: string, index: number) => 'forward-' + src + String(index))
        }
        .columnsTemplate(item.images.length === 1 ? '1fr' : (item.images.length === 2 ? '1fr 1fr' : '1fr 1fr 1fr'))
        .columnsGap(4).height(this.imageGridHeightFor(item.images)).width('100%')
      }
      if (item.title.length > 0) {
        Row({ space: 9 }) {
          if (item.cover.length > 0) {
            Image(item.cover).width(112).height(68).objectFit(ImageFit.Cover).borderRadius(6)
          }
          Column({ space: 5 }) {
            Text(item.title).fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C').maxLines(2)
            if (item.badge.length > 0 || item.subtitle.length > 0) {
              Text(item.badge.length > 0 ? item.badge : item.subtitle).fontSize(10)
                .fontColor(item.liveRoomId > 0 ? '#FB7299' : '#9499A0')
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .onClick(() => {
          this.openMajor(item);
        })
      }
      if (item.original !== null) this.ForwardedCard(item.original)
    }
    .width('100%').padding(10).borderRadius(8)
    .backgroundColor(this.isDark ? '#222429' : '#F1F3F5')
  }

  build() {
    Column({ space: 8 }) {
      // 头部：头像 + 昵称 + 时间
      Row({ space: this.item.decorationCard.length > 0 ? 4 : 8 }) {
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
              renderNumber: false,
            })
          }
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Row({ space: 4 }) {
                Text(this.item.uname)
                  .fontSize(14)
                  .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.item.decorationNumber.length > 0) {
                  Text(this.decorationNumberLabel())
                    .fontSize(10)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.item.decorationColor.length > 0 ? this.item.decorationColor : this.accent)
                    .maxLines(1)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
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
            right: this.item.decorationCard.length > 0 ? 8 : 0 })
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .height(52)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.item.mid > 0) {
          AppNavStack.pushPathByName(NAV_USER_SPACE, { mid: this.item.mid } as UserSpaceParam);
        }
      })

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
        .onClick(() => this.openDetail())
      }

      if (this.item.original !== null) {
        this.ForwardedCard(this.item.original)
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
                .id('dyn-img-' + this.item.dynId + '-' + String(index))
                .geometryTransition('image-viewer-dynamic-' + this.item.dynId + '-' + String(index))
                .onClick(() => {
                  const viewer: ImageViewerParam = {
                    images: this.shownImages(),
                    initialIndex: index,
                    transitionId: 'image-viewer-dynamic-' + this.item.dynId + '-' + String(index),
                  };
                  // 一镜到底：关默认转场 + animateTo，geometryTransition 接管
                  this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
                    AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer, false);
                  });
                })
            }
          }, (src: string, index: number) => src + String(index))
        }
        .columnsTemplate(this.item.images.length === 1 ? '1fr' : (this.item.images.length === 2 ? '1fr 1fr' : '1fr 1fr 1fr'))
        .rowsGap(4)
        .columnsGap(4)
        .height(this.imageGridHeight())
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
          this.openMajor(this.item);
        })
      }

      // 底部互动：点赞/评论/转发均可点，点赞与转发走登录态接口。
      Row({ space: 24 }) {
        Row({ space: 4 }) {
          Image(this.liked ? $r('app.media.ic_like_fill') : $r('app.media.ic_like'))
            .width(16)
            .height(16)
            .fillColor(this.liked ? this.accent : '#9499A0')
          Text(this.likeCount > 0 ? formatCount(this.likeCount) : '赞')
            .fontSize(12)
            .fontColor(this.liked ? this.accent : '#9499A0')
        }
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.toggleLike().catch(() => {
          });
        })
        Row({ space: 4 }) {
          Image($r('app.media.ic_comment'))
            .width(16)
            .height(16)
            .fillColor('#9499A0')
          Text(this.item.comment > 0 ? formatCount(this.item.comment) : '评')
            .fontSize(12)
            .fontColor('#9499A0')
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5, bottom: 5 })
        .onClick(() => {
          this.openDetail(true);
        })
        Row({ space: 4 }) {
          Image($r('app.media.ic_share'))
            .width(16)
            .height(16)
            .fillColor('#9499A0')
          Text(this.forwardCount > 0 ? formatCount(this.forwardCount) : '转')
            .fontSize(12)
            .fontColor('#9499A0')
        }
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.forwardDynamic().catch(() => {
          });
        })
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
  @State dynType: string = 'all';
  @State dynTab: number = 0;
  @State dynHasMore: boolean = true;
  @State feedLoading: boolean = false;
  @State refreshing: boolean = false;
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  @State dynCount: number = 0;
  @State errorText: string = '';
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('headerFade') fade: number = 0;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVer: number = 0;
  private dynSource: BasicDataSource<DynamicItem> = new BasicDataSource<DynamicItem>();
  private dynTabsController: TabsController = new TabsController();
  private dynTypes: Array<string> = ['all', 'video', 'pgc', 'article'];
  private initializing: boolean = false;

  onLoginChanged(): void {
    // 登录/登出广播：重载动态流（Tabs 保活，aboutToAppear 不会再触发）
    this.init().catch(() => {
    });
  }

  aboutToAppear(): void {
    // 切到动态 Tab 时强制回到顶部状态，避免残留 fade 导致搜索栏和搜索球同时出现。
    AppTheme.resetHeaderFade();
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
      this.errorText = '';
      if (this.hostMid <= 0 && !UserStore.isLogin) {
        await UserStore.ensureLoaded();
      }
      this.login = this.hostMid > 0 || UserStore.isLogin;
      if (this.login) {
        await this.loadFeed(true);
      }
    } catch (e) {
      this.errorText = '动态加载失败，请检查登录状态或网络后重试';
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
        await BiliApi.getUserDynamicFeed(this.hostMid, off) : await BiliApi.getDynamicFeed(off, this.dynType);
      if (reset) {
        this.dynSource.reset(page.items);
      } else {
        this.dynSource.append(page.items);
      }
      this.dynCount = this.dynSource.totalCount();
      this.dynOffset = page.offset;
      this.dynHasMore = page.hasMore;
    } catch (e) {
      if (this.dynSource.isEmpty()) this.errorText = '动态加载失败，请检查登录状态或网络后重试';
    } finally {
      this.feedLoading = false;
    }
  }

  private onRefresh(): void {
    this.refreshing = true;
    this.loadFeed(true)
      .catch(() => {
      })
      .finally(() => {
        this.refreshing = false;
      });
  }

  @Builder
  DynRefreshHeader() {
    // 与首页同一套骨架：Refresh 内部只放一个空白占位，可见提示由外层悬浮绘制。
    Blank()
      .width('100%')
      .height(1)
  }

  @Builder
  DynRefreshIndicator() {
    Row({ space: 8 }) {
      if (this.refreshStatus === RefreshStatus.Refresh || this.refreshing) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.accent)
        Text('正在刷新…')
          .fontSize(12)
          .fontColor(this.isDark ? '#CACACE' : '#676B72')
      }
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    // 与首页 RefreshIndicator 完全同位置。
    .margin({ top: this.embedded ? 0 : Immersive.statusBarHeight() + 88 })
    .opacity(this.refreshStatus === RefreshStatus.Refresh || this.refreshing ? 1 : 0)
    .animation({ duration: 120, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None)
  }

  private tapVibrate(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 15 }, { usage: 'physicalFeedback' }).catch(() => {
      });
    } catch (e) {
      // 不支持或未授权时静默忽略。
    }
  }

  private changeDynType(type: string): void {
    if (this.dynType === type || this.feedLoading) return;
    this.dynType = type;
    this.dynOffset = '';
    this.dynHasMore = true;
    this.dynSource.clear();
    this.dynCount = 0;
    this.errorText = '';
    this.loadFeed(true).catch(() => {
    });
  }

  @Builder
  DynTypeChip(label: string, type: string) {
    Stack({ alignContent: Alignment.Center }) {
      Text(label)
        .fontSize(14)
        .fontWeight(this.dynType === type ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.dynType === type ? this.accent : (this.isDark ? '#A8A8AC' : '#767B82'))
    }
    .width(62)
    .height(30)
    .borderRadius(15)
    .backgroundColor(this.dynType === type ? (this.isDark ? '#33FB7299' : '#1FFB7299') : '#00000000')
    .animation({ duration: 180, curve: Curve.EaseOut })
    .onClick(() => {
      this.tapVibrate();
      const index: number = this.dynTypes.indexOf(type);
      if (index >= 0) {
        this.dynTab = index;
        this.dynTabsController.changeIndex(index);
      }
      this.changeDynType(type);
    })
  }

  @Builder
  DynTypeFilter() {
    Row({ space: 2 }) {
      this.DynTypeChip('全部', 'all')
      this.DynTypeChip('视频', 'video')
      this.DynTypeChip('番剧', 'pgc')
      this.DynTypeChip('专栏', 'article')
    }
    .width(260)
    .height(36)
    .padding(3)
    .borderRadius(18)
    .backgroundColor(this.glassOn ? '#00000000' : (this.isDark ? '#D9202125' : '#E8FFFFFF'))
    .systemMaterial(AppTheme.floatMaterial(this.glassOn))
    .margin({ top: this.embedded ? 4 : Immersive.statusBarHeight() + 50 })
    .opacity(1 - this.fade)
    .translate({ y: -12 * this.fade })
    .animation({ duration: 160, curve: Curve.EaseOut })
    .hitTestBehavior(this.fade > 0.9 ? HitTestMode.None : HitTestMode.Default)
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

  @Builder
  DynBody() {
    if (this.loading) {
      LoadingView({ loading: true })
        .margin({ top: 80 })
    } else if (!this.login) {
      this.LoginPrompt()
    } else if (this.dynCount === 0) {
      LoadingView({
        loading: this.feedLoading,
        empty: this.feedLoading ? false : this.errorText.length === 0,
        emptyText: this.hostMid > 0 ? '该用户暂时没有发布动态' :
          (this.dynType === 'all' ? '暂时没有动态，去关注一些UP主吧' : '该分类下暂无动态'),
        errorText: this.errorText,
        onRetry: () => {
          this.init();
        },
      })
      .margin({ top: 80 })
    } else {
      Refresh({ refreshing: $$this.refreshing, builder: this.DynRefreshHeader() }) {
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
        .constraintSize({ maxWidth: LayoutTokens.readingMaxWidth })
        .alignSelf(ItemAlign.Center)
        .cachedCount(3)
        // 与首页对齐：非内嵌时列表从玻璃头栏下方开始，滚动时内容可直接顶到最上方。
        .contentStartOffset(this.embedded ? 4 : Immersive.statusBarHeight() + 94)
        .contentEndOffset(this.embedded ? 16 : Immersive.bottomInset() + 56)
        .padding({ left: LayoutTokens.phonePadding, right: LayoutTokens.phonePadding })
        .scrollBar(BarState.Off)
        .nestedScroll({
          scrollForward: this.embedded ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_ONLY,
          scrollBackward: this.embedded ? NestedScrollMode.SELF_FIRST : NestedScrollMode.SELF_ONLY,
        })
        .onScroll((offset: number) => {
          if (!this.embedded) AppTheme.updateHeaderFade(offset);
        })
        .onReachEnd(() => {
          this.loadFeed(false);
        })
      }
      .refreshOffset(56)
      .pullDownRatio(undefined)
      .onStateChange((status: RefreshStatus) => {
        this.refreshStatus = status;
      })
      .onRefreshing(() => this.onRefresh())
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 动态分类 Tabs：左右滑动在 全部/视频/番剧/专栏 之间切换，与首页推荐/热门/直播一致。
      Tabs({ index: $$this.dynTab, controller: this.dynTabsController }) {
        TabContent() { this.DynBody() }.tabBar('')
        TabContent() { this.DynBody() }.tabBar('')
        TabContent() { this.DynBody() }.tabBar('')
        TabContent() { this.DynBody() }.tabBar('')
      }
      .width('100%')
      .height('100%')
      .barHeight(0)
      .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
      .animationMode(AnimationMode.CONTENT_FIRST)
      .animationDuration(320)
      .animationCurve(Curve.EaseInOut)
      .onChange((index: number) => {
        this.dynTab = index;
        const type: string | undefined = this.dynTypes[index];
        if (type !== undefined && type !== this.dynType) this.changeDynType(type);
      })

      this.DynRefreshIndicator()

      if (this.login && this.hostMid <= 0) {
        this.DynTypeFilter()
      }
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
  }
}
