import { MotionTokens } from '../../common/MotionTokens';
import { DynamicItem } from '../../model/Models';
import { AppNavStack, NAV_USER_SPACE, UserSpaceParam, NAV_SEARCH } from '../../common/AppRouter';
import { ActionResult } from '../../api/BiliApi';
import { UserStore } from '../../services/auth/UserStore';
import { formatCount, formatRelativeTime } from '../../common/Utils';
import { biliImageThumbnail } from '../../common/ImageUrl';
import { DecoratedAvatar, UserDecorationBanner } from '../UserDecorations';
import { Haptic } from '../../common/Haptic';
import { DynamicApi } from '../../api/DynamicApi';
import { EmoteResolver } from '../../common/EmoteResolver';
import { EmoteImageCache } from '../../common/EmoteImageCache';
import { DynamicContentPart, contentPartsOf, ensureDynamicRichDetail, cachedDynamicRichDetail } from './DynamicContent';
import { DynamicCardNavigation } from './DynamicCardNavigation';
import { DynamicCardActions, DynamicActionState } from './DynamicCardActions';

interface ReportButtonItem { text: string; color: string; }

interface DynamicImageGridParams {
  item: DynamicItem;
  inset: number;
}

interface DynamicForwardedCardParams {
  item: DynamicItem;
}

/** 单条动态卡片：独立 @Component，父组件状态变化不再整列表重建；@Reusable 复用滚动项。 */
@Reusable
@Component
export struct DynCard {
  @Prop @Watch('onItemChanged') item: DynamicItem = new DynamicItem();
  @Prop embedded: boolean = false;
  @Prop detailMode: boolean = false;
  /** 是否启用图片共享元素转场（geometryTransition）。仅内嵌场景（用户空间等已入栈页面）可用；
   *  主页底部 Tabs 内是 Navigation 根页面，geometryTransition 不生效，该场景走 srcRect 矩形放大 push。 */
  @Prop sharedImageTransition: boolean = true;
  /**
   * 图片 id / 共享元素转场 id 前缀：同一动态可能同时存在于不同分类页签中，
   * 同一动态会渲染出多张同 id 缩略图；getRectangleById 命中离屏页签的图时，
   * 看图入场便从错误的矩形（常是相邻页签方向）放大。各容器传唯一前缀区分。
   */
  @Prop idPrefix: string = '';
  /**
   * 点赞成功回调：@Prop item 是深拷贝快照，卡片上的乐观更新不会进入数据源；
   * 必须把结果回传给持有数据源的父级（按 dynId 定位，不捕获索引，复用场景不串卡）。
   */
  onLikeResult: (dynId: string, liked: boolean, count: number) => void = () => {};
  @State action: DynamicActionState = new DynamicActionState();
  private actions: DynamicCardActions = new DynamicCardActions(() => this.item, () => this.onLikeResult,
    (state: DynamicActionState) => { this.action = state; }, (message: string) => this.toast(message));
  /** 表情图本地缓存映射：原网络 URL → cacheDir 内本地路径（落盘缓存，离线可显示）。 */
  @State emoteLocal: Map<string, string> = new Map<string, string>();
  /** 确认加载失败的表情 URL：回退渲染 [表情名] 文字，避免行内空白块。 */
  @State emoteFailed: Set<string> = new Set<string>();
  /** Feed 缺失表情节点时按动态 ID 补拉的详情正文；只替换正文渲染，不改卡片其他字段。 */
  @State hydratedContent: DynamicItem = new DynamicItem();
  /** 图片宫格可用宽（onAreaChange 实测），用于按官方三列正方形单元计算高度。 */
  @State gridWidth: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  // 表情表加载完成后版本号 +1：引用它的 build 会重跑，拆分缓存键也随之失效。
  @StorageProp('emoteResolverVersion') emoteVer: number = 0;
  private hydrateGeneration: number = 0;
  private navigator: DynamicCardNavigation = new DynamicCardNavigation(new DynamicItem(), false, true, '',
    () => this.getUIContext());

  aboutToAppear(): void {
    EmoteResolver.ensureLoaded();
    this.syncFromItem();
  }

  aboutToReuse(params: Record<string, Object>): void {
    this.actions.invalidate();
    // 复用实例直接换数据，避免整卡重建（LazyForEach 滚动性能）。
    const next: DynamicItem | undefined = params.item as DynamicItem | undefined;
    if (next !== undefined) {
      this.item = next;
    }
    this.idPrefix = params.idPrefix === undefined ? '' : params.idPrefix as string;
    // 普通成员变量复用时不会自动同步：数据源不变则各次创建传入的是同一父级回调，兜底重取一次。
    const likeCb: ((dynId: string, liked: boolean, count: number) => void) | undefined =
      params.onLikeResult as ((dynId: string, liked: boolean, count: number) => void) | undefined;
    if (likeCb !== undefined) this.onLikeResult = likeCb;
    this.syncFromItem();
  }

  aboutToDisappear(): void {
    this.hydrateGeneration++;
    this.actions.invalidate();
  }

  onItemChanged(): void {
    this.syncFromItem();
  }

  private syncFromItem(): void {
    this.actions.sync();
    const cached: DynamicItem | undefined = cachedDynamicRichDetail(this.item.dynId);
    this.hydratedContent = cached !== undefined ? cached : new DynamicItem();
    this.hydrateMissingRichContent();
    this.primeEmoteLocalCache();
  }

  private renderContentItem(): DynamicItem {
    return this.hydratedContent.dynId === this.item.dynId ? this.hydratedContent : this.item;
  }

  private hasUnresolvedRichEmote(item: DynamicItem): boolean {
    const tokenPattern: RegExp = /\[[^\[\]\r\n]{1,64}\]/;
    if (item.richNodes.length === 0) return tokenPattern.test(item.content);
    for (let i: number = 0; i < item.richNodes.length; i++) {
      if (item.richNodes[i].emote === null && tokenPattern.test(item.richNodes[i].text)) return true;
    }
    return false;
  }

  /** Web Feed 会省略部分主题表情的 emoji 对象；只为含未解析占位符的可见卡片补拉详情。 */
  private hydrateMissingRichContent(): void {
    const item: DynamicItem = this.item;
    const generation: number = ++this.hydrateGeneration;
    if (this.detailMode || item.dynId.length === 0 || !this.hasUnresolvedRichEmote(item) ||
      this.hydratedContent.dynId === item.dynId) return;
    ensureDynamicRichDetail(item.dynId).then((detail: DynamicItem | null): void => {
      if (generation !== this.hydrateGeneration || detail === null || this.item.dynId !== item.dynId) return;
      this.hydratedContent = detail;
      this.primeEmoteLocalCache();
    }).catch((): void => {
    });
  }

  /** 把内容里出现的表情 URL 逐一下载到本地缓存；完成后触发重渲染走本地路径。 */
  private primeEmoteLocalCache(): void {
    const parts: Array<DynamicContentPart> = contentPartsOf(this.renderContentItem(), this.emoteVer);
    for (let i: number = 0; i < parts.length; i++) {
      const image: string = parts[i].image;
      if (image.length === 0 || this.emoteLocal.has(image) || this.emoteFailed.has(image)) continue;
      const cached: string = EmoteImageCache.localPathOf(image);
      if (cached !== image) {
        const nextCached: Map<string, string> = new Map<string, string>(this.emoteLocal);
        nextCached.set(image, cached);
        this.emoteLocal = nextCached;
        continue;
      }
      EmoteImageCache.ensure(image).then((local: string) => {
        // 与 image 相同表示下载失败；只有拿到了本地路径才更新，否则记失败走 [表情名] 回退。
        if (local !== image) {
          const nextLocal: Map<string, string> = new Map<string, string>(this.emoteLocal);
          nextLocal.set(image, local);
          this.emoteLocal = nextLocal;
        } else {
          const nextFailed: Set<string> = new Set<string>(this.emoteFailed);
          nextFailed.add(image);
          this.emoteFailed = nextFailed;
        }
      }).catch(() => {
        const nextFailed: Set<string> = new Set<string>(this.emoteFailed);
        nextFailed.add(image);
        this.emoteFailed = nextFailed;
      });
    }
  }

  /** 表情图渲染源：只使用本地路径，等待统一下载器完成。 */
  private emoteSrc(image: string): string {
    if (image.length === 0) return '';
    const local: string | undefined = this.emoteLocal.get(image);
    if (local !== undefined && local.length > 0) return local;
    const cached: string = EmoteImageCache.localPathOf(image);
    return cached !== image ? cached : '';
  }

  /** 话题点击：注入关键词并直达搜索页（与视频 TAG 同一机制）。 */
  private searchTopic(text: string): void {
    const name: string = text.replace(/^#+/, '').replace(/#+$/, '').trim();
    if (name.length === 0) return;
    AppStorage.setOrCreate<string>('searchPrefillKeyword', name);
    AppNavStack.pushPathByName(NAV_SEARCH, null);
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
    Haptic.tap();
  }

  /** 宫格单元边长：官方图文动态为三列正方形单元，间距 4vp；inset 为卡片内层额外左右留白之和。 */
  private gridCell(inset: number = 0): number {
    if (this.gridWidth <= 0) return 104;
    return (this.gridWidth - inset - 8) / 3;
  }

  /** 图片网格高度：>=2 图按三列正方形单元；单图约占 2/3 宽的正方形。 */
  private imageGridHeightFor(images: Array<string>, inset: number = 0): number {
    const count: number = images.length;
    const cell: number = this.gridCell(inset);
    if (count <= 1) return cell * 2 + 4;
    const rows: number = Math.ceil(count / 3);
    return rows * cell + (rows - 1) * 4;
  }

  private navigation(): DynamicCardNavigation {
    this.navigator.bind(this.item, this.detailMode, this.sharedImageTransition, this.idPrefix);
    return this.navigator;
  }

  /** 图文动态宫格：单图 2/3 宽正方形，多图三列正方形单元（对齐官方客户端）。
   *  超过 9 张时只展示前 9 张，第 9 张压暗并叠加 +N（官方同款处理）。 */
  // 单个对象字面量按引用传入；卡片复用换 item 时，图片源、key 和点击目标一起更新。
  @Builder
  ImageGrid(params: DynamicImageGridParams) {
    if (params.item.images.length === 1) {
      // 单图也必须有内容级 key。DynCard 被 LazyForEach 复用时，旧 Image 节点会在新图加载前
      // 保留上一条动态的位图，视觉上就像“下面的图片串到上面”。
      ForEach(params.item.images.slice(0, 1), (src: string) => {
        Image(biliImageThumbnail(src, 900))
          .width(this.gridCell(params.inset) * 2 + 4)
          .height(this.gridCell(params.inset) * 2 + 4)
          .objectFit(ImageFit.Cover)
          .borderRadius(8)
          .id(this.navigation().imgId(params.item.dynId, 0))
          .geometryTransition(this.sharedImageTransition && !this.reduceMotion ?
            this.navigation().imgTransitionId(params.item.dynId, 0) : '')
          .onClick(() => {
            this.navigation().openItemImage(params.item, 0);
          })
      }, (src: string) => params.item.dynId + '-single-' + src)
    } else {
      Grid() {
        ForEach(params.item.images.slice(0, 9), (src: string, index: number) => {
          GridItem() {
            Stack({ alignContent: Alignment.Center }) {
              // 宫格缩略图（320w webp）：动态流大批图片时避免原图占满内存。
              Image(src.length > 0 ? biliImageThumbnail(src, 320) : src)
                .width('100%')
                .aspectRatio(1)
                .objectFit(ImageFit.Cover)
                .id(this.navigation().imgId(params.item.dynId, index))
                .geometryTransition(this.sharedImageTransition && !this.reduceMotion ?
                  this.navigation().imgTransitionId(params.item.dynId, index) : '')
              if (index === 8 && params.item.images.length > 9) {
                Column() {
                  Text('+' + String(params.item.images.length - 9))
                    .fontSize(20)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                }
                .width('100%')
                .aspectRatio(1)
                .justifyContent(FlexAlign.Center)
                .backgroundColor('#59000000')
                .hitTestBehavior(HitTestMode.None)
              }
            }
            .width('100%')
            .clip(true)
            .borderRadius(6)
            .onClick(() => {
              this.navigation().openItemImage(params.item, index);
            })
          }
        }, (src: string, index: number) => params.item.dynId + '-' + src + String(index))
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsTemplate(this.gridRowsTemplate(Math.min(9, params.item.images.length)))
      .rowsGap(4)
      .columnsGap(4)
      .height(this.imageGridHeightFor(params.item.images.slice(0, 9), params.inset))
      .width('100%')
      .scrollBar(BarState.Off)
    }
  }

  private gridRowsTemplate(count: number): string {
    const rows: number = Math.max(1, Math.ceil(count / 3));
    let tpl: string = '1fr';
    for (let i: number = 1; i < rows; i++) {
      tpl += ' 1fr';
    }
    return tpl;
  }

  @Builder
  ForwardedCard(params: DynamicForwardedCardParams) {
    Column({ space: 7 }) {
      Text('@' + (params.item.uname.length > 0 ? params.item.uname : '原动态作者'))
        .width('100%').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#008AC5')
        .onClick(() => {
          this.navigation().openItemDetail(params.item);
        })
      if (params.item.content.length > 0) {
        // 行内流：与评论区一致，表情随文字同流换行（Flex 独立 item 会把表情挤到新行），底部对齐。
        Text() {
          ForEach(contentPartsOf(params.item, this.emoteVer), (part: DynamicContentPart) => {
            if (part.image.length > 0 && this.emoteFailed.has(part.image)) {
              Span(part.imageLabel.length > 0 ? part.imageLabel : '[表情]')
            } else if (part.image.length > 0) {
              ImageSpan(this.emoteSrc(part.image)).width(part.imageSize > 1 ? 46 : 23).height(part.imageSize > 1 ? 46 : 23).objectFit(ImageFit.Contain).verticalAlign(ImageSpanAlignment.BOTTOM)
            } else if (part.isTopic) {
              Span(part.text)
                .fontColor(this.accent)
                .onClick(() => this.searchTopic(part.text))
            } else {
              Span(part.text)
            }
          }, (part: DynamicContentPart) => 'forward-' + part.key)
        }
        .fontSize(13)
        .lineHeight(20)
        .width('100%')
        .fontColor(this.isDark ? '#D8D8DC' : '#303236')
        .onClick(() => {
          this.navigation().openItemDetail(params.item);
        })
      }
      if (params.item.images.length > 0) {
        this.ImageGrid({ item: params.item, inset: 20 })
      }
      if (params.item.title.length > 0) {
        Row({ space: 9 }) {
          if (params.item.cover.length > 0) {
            ForEach([params.item.cover], (cover: string) => {
              Image(biliImageThumbnail(cover, 240))
                .width(112)
                .height(68)
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .id(this.navigation().videoCoverId(params.item))
            }, (cover: string) => params.item.dynId + '-forward-cover-' + cover)
          }
          Column({ space: 5 }) {
            Text(params.item.title).fontSize(13).fontColor(this.isDark ? '#E6E6E6' : '#18191C').maxLines(2)
            if (params.item.badge.length > 0 || params.item.subtitle.length > 0) {
              Text(params.item.badge.length > 0 ? params.item.badge : params.item.subtitle).fontSize(10)
                .fontColor(params.item.liveRoomId > 0 ? '#FB7299' : '#9499A0')
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .id(this.navigation().videoCardId(params.item))
        .onClick(() => {
          this.navigation().openMajor(params.item);
        })
      }
      if (params.item.original !== null) this.ForwardedCard({ item: params.item.original })
    }
    .width('100%').padding(10).borderRadius(8)
    .backgroundColor(this.isDark ? '#222429' : '#F1F3F5')
  }

  build() {
    Column({ space: 8 }) {
      // 头部：头像 + 昵称 + 时间；有装扮时装扮小卡按原始比例显示在行右端（官方动态卡片样式）。
      Row({ space: 8 }) {
        DecoratedAvatar({
          face: this.item.face,
          pendant: this.item.pendant,
          avatarSize: 36,
          containerSize: 52,
        })
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Text(this.item.uname)
              .fontSize(14)
              .fontColor(this.isDark ? '#E6E6E6' : '#18191C')
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.item.decorationNumber.length > 0 && this.item.decorationCard.length === 0) {
              Text(this.decorationNumberLabel())
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.item.decorationColor.length > 0 ? this.item.decorationColor : this.accent)
                .maxLines(1)
            }
          }
          .alignItems(VerticalAlign.Center)
          Text(formatRelativeTime(this.item.pubtime))
            .fontSize(11)
            .fontColor('#9499A0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.item.decorationCard.length > 0) {
          UserDecorationBanner({
            imageUrl: this.item.decorationCard,
            numberText: this.item.decorationNumber,
            numberColor: this.item.decorationColor.length > 0 ? this.item.decorationColor : '#FFFFFF',
            bannerHeight: 44,
            fitWidth: true,
          })
        } else if (!this.embedded) {
          Text('已关注')
            .fontSize(12)
            .fontColor('#9499A0')
            .backgroundColor(this.isDark ? '#34363B' : '#EEF0F2')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.item.mid > 0) {
          AppNavStack.pushPathByName(NAV_USER_SPACE, { mid: this.item.mid } as UserSpaceParam);
        }
      })

      // 内容
      if (this.renderContentItem().content.length > 0) {
        // 行内流：与评论区一致，表情随文字同流换行（Flex 独立 item 会把表情挤到新行），底部对齐。
        Text() {
          ForEach(contentPartsOf(this.renderContentItem(), this.emoteVer), (part: DynamicContentPart) => {
            if (part.image.length > 0 && this.emoteFailed.has(part.image)) {
              Span(part.imageLabel.length > 0 ? part.imageLabel : '[表情]')
            } else if (part.image.length > 0) {
              ImageSpan(this.emoteSrc(part.image)).width(part.imageSize > 1 ? 50 : 25).height(part.imageSize > 1 ? 50 : 25).objectFit(ImageFit.Contain).verticalAlign(ImageSpanAlignment.BOTTOM)
            } else if (part.isTopic) {
              Span(part.text)
                .fontColor(this.accent)
                .onClick(() => this.searchTopic(part.text))
            } else {
              Span(part.text)
            }
          }, (part: DynamicContentPart) => part.key)
        }
        .fontSize(14)
        .lineHeight(21)
        .width('100%')
        .fontColor(this.isDark ? '#D0D0D0' : '#222222')
        .onClick(() => this.navigation().openDetail())
      }

      if (this.item.original !== null) {
        this.ForwardedCard({ item: this.item.original })
      }

      // 图文/专栏动态图片宫格（详情态也走缩略图，内存友好；点击进 ImageViewer 时再拉原图）。
      if (this.item.images.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          // 图片本身仍打开看图器；单图左右的留白属于动态卡片，点击应进入动态详情。
          Row()
            .width('100%')
            .height(this.imageGridHeightFor(this.item.images.slice(0, 9), 0))
            .onClick(() => this.navigation().openDetail())
          this.ImageGrid({ item: this.item, inset: 0 })
        }
        .width('100%')
        .height(this.imageGridHeightFor(this.item.images.slice(0, 9), 0))
      }

      // 视频卡片
      if (this.item.title.length > 0) {
        Row({ space: 10 }) {
          if (this.item.cover.length > 0) {
            ForEach([this.item.cover], (cover: string) => {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(biliImageThumbnail(cover, 480))
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
              .id(this.navigation().videoCoverId(this.item))
            }, (cover: string) => this.item.dynId + '-video-cover-' + cover)
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
        .id(this.navigation().videoCardId(this.item))
        .onClick(() => {
          this.navigation().openMajor(this.item);
        })
      }

      // 底部互动：点赞/评论/转发均可点，点赞与转发走登录态接口。
      Row({ space: 12 }) {
        Row({ space: 4 }) {
          Image(this.action.liked ? $r('app.media.ic_like_fill') : $r('app.media.ic_like'))
            .width(16)
            .height(16)
            .fillColor(this.action.liked ? this.accent : '#9499A0')
          Text(this.action.likeCount > 0 ? formatCount(this.action.likeCount) : '赞')
            .fontSize(12)
            .fontColor(this.action.liked ? this.accent : '#9499A0')
        }
        .height(44)
        .constraintSize({ minWidth: 44 })
        .alignItems(VerticalAlign.Center)
        .accessibilityGroup(true)
        .accessibilityText((this.action.liked ? '取消点赞，' : '点赞，') + String(this.action.likeCount) + '个赞')
        .accessibilitySelected(this.action.liked)
        .onClick(() => {
          this.actions.toggleLike().catch(() => {
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
        .height(44)
        .constraintSize({ minWidth: 44 })
        .alignItems(VerticalAlign.Center)
        .accessibilityGroup(true)
        .accessibilityText('查看评论，' + String(this.item.comment) + '条评论')
        .onClick(() => {
          this.navigation().openDetail(true);
        })
        Row({ space: 4 }) {
          Image($r('app.media.ic_share'))
            .width(16)
            .height(16)
            .fillColor('#9499A0')
          Text(this.action.forwardCount > 0 ? formatCount(this.action.forwardCount) : '转')
            .fontSize(12)
            .fontColor('#9499A0')
        }
        .height(44)
        .constraintSize({ minWidth: 44 })
        .alignItems(VerticalAlign.Center)
        .accessibilityGroup(true)
        .accessibilityText('转发动态，' + String(this.action.forwardCount) + '次转发')
        .onClick(() => {
          this.actions.forwardDynamic().catch(() => {
          });
        })
        // 更多菜单固定贴齐卡片右边，不再紧跟在转发按钮后面。
        Blank()
          .layoutWeight(1)
        Row({ space: 4 }) {
          Image($r('app.media.ic_more'))
            .width(16)
            .height(16)
            .fillColor('#9499A0')
        }
        .width(44)
        .height(44)
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.End)
        .accessibilityGroup(true)
        .accessibilityText('举报动态')
        .onClick(() => {
          this.promptReportDynamic();
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(10)
    .backgroundColor(this.isDark ? '#2A2C31' : '#FFFFFF')
    .id(this.navigation().cardId())
    .onAreaChange((oldV: Area, newV: Area) => {
      // 实测卡片内容宽（减去自身 padding 24），供图片宫格计算正方形单元边长。
      const w: number = Number.parseFloat(String(newV.width));
      if (Number.isFinite(w) && w > 24 && Math.abs(w - 24 - this.gridWidth) > 1) {
        this.gridWidth = w - 24;
      }
    })
  }

  /** 动态举报：原因选择弹窗（showDialog 不支持回调，用 index 回读）。 */
  private promptReportDynamic(): void {
    if (this.item.dynId.length === 0) {
      this.toast('动态信息不完整，暂不支持举报');
      return;
    }
    const reasons: Array<string> = ['违法违规', '色情低俗', '垃圾广告', '人身攻击', '抄袭洗稿', '其他'];
    const buttons: Array<ReportButtonItem> = [];
    for (let i: number = 0; i < reasons.length; i++) {
      buttons.push({ text: reasons[i], color: this.isDark ? '#CCFFFFFF' : '#18191C' });
    }
    buttons.push({ text: '取消', color: '#9499A0' });
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '举报动态',
        message: this.item.content.substring(0, Math.min(24, this.item.content.length)),
        buttons: buttons,
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        if (pick < 0 || pick >= reasons.length) return;
        if (UserStore.isLogin === false) {
          this.toast('请先登录后再举报动态');
          return;
        }
        const reasonValues: Array<string> = ['1', '2', '6', '5', '14', '99'];
        DynamicApi.report(this.item.dynId, reasonValues[pick])
          .then((r: ActionResult) => {
            this.toast(r.ok ? '已提交举报，感谢反馈' : r.message);
          })
          .catch(() => {
            this.toast('举报失败，请稍后重试');
          });
      });
    } catch (e) {
      // 窗口异常忽略。
    }
  }
}
