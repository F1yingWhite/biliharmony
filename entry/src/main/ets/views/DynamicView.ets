import { MotionTokens } from '../common/MotionTokens';
import { RequestEpoch } from '../common/RequestEpoch';
/**
 * 动态视图：关注动态 feed（需登录）
 */
import { DynamicItem, DynamicPageData, DynamicRichNode, BiliEmote, RelationUserItem,
  RelationUserPageData } from '../model/Models';
import { AppNavStack, HERO_BG_SNAPSHOT_KEY, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  NAV_DYNAMIC_DETAIL,
  NAV_IMAGE_VIEWER,
  NAV_LIVE_ROOM, NAV_LOGIN,
  NAV_VIDEO_DETAIL,
  NAV_USER_SPACE, DynamicDetailParam, ImageViewerParam, ImageViewerSrcRect, LiveRoomParam, VideoDetailParam,
    UserSpaceParam, NAV_BANGUMI_DETAIL, BangumiDetailParam } from '../common/AppRouter';
import { ActionResult } from '../api/BiliApi';
import { UserStore } from '../services/auth/UserStore';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { formatCount, formatRelativeTime } from '../common/Utils';
import { biliImageThumbnail } from '../common/ImageUrl';
import { Immersive } from '../common/Immersive';
import { AppTheme } from '../common/AppTheme';
import { BasicDataSource } from '../common/BasicDataSource';
import { DecoratedAvatar, UserDecorationBanner } from '../components/UserDecorations';
import { LayoutTokens } from '../common/LayoutTokens';
import { Haptic } from '../common/Haptic';
import { DynamicApi } from '../api/DynamicApi';
import { EmoteResolver } from '../common/EmoteResolver';
import { EmoteImageCache } from '../common/EmoteImageCache';
import { LiveApi } from '../api/LiveApi';
import { UserApi } from '../api/UserApi';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';

/** showDialog 按钮声明（promptAction 的 Button 类型不便直接引用）。 */
interface ReportButtonItem {
  text: string;
  color: string;
}

class DynamicContentPart {
  text: string = '';
  image: string = '';
  key: string = '';
  /** 1 = 单行高，2 = 双行高（动态卡片行内表情放大 2 倍）。 */
  imageSize: number = 1;
  /** 表情标签（如 [doge]）：图加载失败时回退文字，避免行内空白。 */
  imageLabel: string = '';
}

// 表情拆分结果按动态 id 缓存（内容不可变），避免每次 build 重算 O(内容×表情数) 扫描。
const DYN_PARTS_CACHE_LIMIT: number = 100;
const dynPartsCache: Map<string, Array<DynamicContentPart>> = new Map<string, Array<DynamicContentPart>>();
const DYN_RICH_DETAIL_CACHE_LIMIT: number = 80;
const dynRichDetailCache: Map<string, DynamicItem> = new Map<string, DynamicItem>();
const dynRichDetailInFlight: Map<string, Promise<DynamicItem | null>> =
  new Map<string, Promise<DynamicItem | null>>();

function ensureDynamicRichDetail(dynId: string): Promise<DynamicItem | null> {
  const cached: DynamicItem | undefined = dynRichDetailCache.get(dynId);
  if (cached !== undefined) return Promise.resolve(cached);
  const running: Promise<DynamicItem | null> | undefined = dynRichDetailInFlight.get(dynId);
  if (running !== undefined) return running;
  const request: Promise<DynamicItem | null> = DynamicApi.getDynamicDetail(dynId).then((detail: DynamicItem | null) => {
    if (detail !== null) {
      if (dynRichDetailCache.size >= DYN_RICH_DETAIL_CACHE_LIMIT) {
        const oldest: IteratorResult<string> = dynRichDetailCache.keys().next();
        if (!oldest.done) dynRichDetailCache.delete(oldest.value);
      }
      dynRichDetailCache.set(dynId, detail);
    }
    return detail;
  }).catch((): DynamicItem | null => null).finally(() => {
    dynRichDetailInFlight.delete(dynId);
  });
  dynRichDetailInFlight.set(dynId, request);
  return request;
}

function splitDynamicText(text: string, emotes: Array<BiliEmote>, keyPrefix: string): Array<DynamicContentPart> {
  const result: Array<DynamicContentPart> = [];
  let rest: string = text;
  let keyIndex: number = 0;
  while (rest.length > 0) {
    let foundAt: number = rest.length;
    let found: BiliEmote | null = null;
    for (let i: number = 0; i < emotes.length; i++) {
      const at: number = rest.indexOf(emotes[i].text);
      if (at >= 0 && (at < foundAt || (at === foundAt && found !== null &&
        emotes[i].text.length > found.text.length))) {
        foundAt = at;
        found = emotes[i];
      }
    }
    // 兜底：接口没下发 emoji 节点时（直播预告等），用通用表情表解析 [xxx] 占位符。
    let fallbackUrl: string = '';
    let fallbackToken: string = '';
    if (found === null) {
      // 官方主题表情的名称可能很长（例如活动周年同人表情），16 字限制会把它留成原文。
      const tokenMatch: RegExpExecArray | null = /\[[^\[\]]{1,64}\]/.exec(rest);
      if (tokenMatch !== null) {
        const url: string = EmoteResolver.lookup(tokenMatch[0]);
        if (url.length > 0) {
          foundAt = tokenMatch.index;
          fallbackUrl = url;
          fallbackToken = tokenMatch[0];
        }
      }
    }
    if (found === null && fallbackUrl.length === 0) {
      const part: DynamicContentPart = new DynamicContentPart();
      part.text = rest; part.key = keyPrefix + '-t' + String(keyIndex++); result.push(part); break;
    }
    if (foundAt > 0) {
      const part: DynamicContentPart = new DynamicContentPart();
      part.text = rest.substring(0, foundAt); part.key = keyPrefix + '-t' + String(keyIndex++); result.push(part);
    }
    const emotePart: DynamicContentPart = new DynamicContentPart();
    emotePart.image = found !== null ? found.displayUrl() : fallbackUrl;
    emotePart.imageSize = found !== null ? found.size : 1;
    emotePart.imageLabel = found !== null ? found.text : fallbackToken;
    emotePart.key = keyPrefix + '-e' + String(keyIndex++);
    result.push(emotePart);
    rest = rest.substring(foundAt + (found !== null ? found.text.length : fallbackToken.length));
  }
  return result;
}

function contentPartsOf(item: DynamicItem, emoteVersion: number): Array<DynamicContentPart> {
  // 同一 dynId 的 feed 简版与 detail 完整版可能拥有不同表情节点，缓存键必须包含节点签名。
  let nodeSignature: string = '';
  for (let i: number = 0; i < item.richNodes.length; i++) {
    const node: DynamicRichNode = item.richNodes[i];
    nodeSignature += '|n' + node.text + '=' + (node.emote !== null ? node.emote.displayUrl() : '');
  }
  // 版本号纳入缓存键：表情表加载完成后用旧缓存会永远拿不到表情图。
  const cacheKey: string = item.dynId + '|v' + String(emoteVersion) + '|' + item.content + nodeSignature;
  const cached: Array<DynamicContentPart> | undefined = dynPartsCache.get(cacheKey);
  if (cached !== undefined) return cached;
  let result: Array<DynamicContentPart> = [];
  if (item.richNodes.length > 0) {
    for (let i: number = 0; i < item.richNodes.length; i++) {
      const node: DynamicRichNode = item.richNodes[i];
      if (node.emote !== null && node.emote.displayUrl().length > 0) {
        const emotePart: DynamicContentPart = new DynamicContentPart();
        emotePart.image = node.emote.displayUrl();
        emotePart.imageSize = node.emote.size;
        emotePart.imageLabel = node.text;
        emotePart.key = item.dynId + '-node-emote-' + String(i);
        result.push(emotePart);
      } else if (node.text.length > 0) {
        result = result.concat(splitDynamicText(node.text, [], item.dynId + '-node-' + String(i)));
      }
    }
  } else {
    result = splitDynamicText(item.content, item.emotes, item.dynId);
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
   * 图片 id / 共享元素转场 id 前缀：动态分类 Tabs 四个页签常驻且共用同一 dynSource，
   * 同一动态会渲染出多张同 id 缩略图；getRectangleById 命中离屏页签的图时，
   * 看图入场便从错误的矩形（常是相邻页签方向）放大。各容器传唯一前缀区分。
   */
  @Prop idPrefix: string = '';
  @State liked: boolean = false;
  @State likeCount: number = 0;
  @State forwardCount: number = 0;
  @State actionBusy: boolean = false;
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
  // 表情表加载完成后版本号 +1：引用它的 build 会重跑，拆分缓存键也随之失效。
  @StorageProp('emoteResolverVersion') emoteVer: number = 0;
  private hydrateGeneration: number = 0;

  aboutToAppear(): void {
    EmoteResolver.ensureLoaded();
    this.syncFromItem();
  }

  aboutToReuse(params: Record<string, Object>): void {
    // 复用实例直接换数据，避免整卡重建（LazyForEach 滚动性能）。
    const next: DynamicItem | undefined = params.item as DynamicItem | undefined;
    if (next !== undefined) {
      this.item = next;
    }
    this.idPrefix = params.idPrefix === undefined ? '' : params.idPrefix as string;
    this.actionBusy = false;
    this.syncFromItem();
  }

  aboutToDisappear(): void {
    this.hydrateGeneration++;
  }

  onItemChanged(): void {
    this.syncFromItem();
  }

  private syncFromItem(): void {
    this.liked = this.item.liked;
    this.likeCount = this.item.like;
    this.forwardCount = this.item.forward;
    const cached: DynamicItem | undefined = dynRichDetailCache.get(this.item.dynId);
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

  /** 表情图渲染源：已缓存用本地路径，否则用网络 URL。 */
  private emoteSrc(image: string): string {
    if (image.length === 0) return '';
    const local: string | undefined = this.emoteLocal.get(image);
    return local !== undefined && local.length > 0 ? local : image;
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
      const result: ActionResult = await DynamicApi.likeDynamic(this.item.dynId, next);
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
      const result: ActionResult = await DynamicApi.repostDynamic(this.item.dynId);
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

  private imgId(dynId: string, index: number): string {
    return this.idPrefix + 'dynamic-host-' + this.item.dynId + '-img-' + dynId + '-' + String(index);
  }

  private imgTransitionId(dynId: string, index: number): string {
    return this.idPrefix + 'image-viewer-host-' + this.item.dynId + '-img-' + dynId + '-' + String(index);
  }

  private cardId(): string {
    return this.idPrefix + 'dynamic-card-' + this.item.dynId;
  }

  private videoCoverId(item: DynamicItem): string {
    const videoId: string = item.bvid.length > 0 ? item.bvid : 'a' + String(item.aid);
    return this.idPrefix + 'dynamic-video-host-' + this.item.dynId + '-cover-' + item.dynId + '-' + videoId;
  }

  private videoCardId(item: DynamicItem): string {
    const videoId: string = item.bvid.length > 0 ? item.bvid : 'a' + String(item.aid);
    return this.idPrefix + 'dynamic-video-host-' + this.item.dynId + '-card-' + item.dynId + '-' + videoId;
  }

  /** 图文动态宫格：单图 2/3 宽正方形，多图三列正方形单元（对齐官方客户端）。
   *  超过 9 张时只展示前 9 张，第 9 张压暗并叠加 +N（官方同款处理）。 */
  @Builder
  ImageGrid(item: DynamicItem, inset: number) {
    if (item.images.length === 1) {
      // 单图也必须有内容级 key。DynCard 被 LazyForEach 复用时，旧 Image 节点会在新图加载前
      // 保留上一条动态的位图，视觉上就像“下面的图片串到上面”。
      ForEach(item.images.slice(0, 1), (src: string) => {
        Image(biliImageThumbnail(src, 900))
          .width(this.gridCell(inset) * 2 + 4)
          .height(this.gridCell(inset) * 2 + 4)
          .objectFit(ImageFit.Cover)
          .borderRadius(8)
          .id(this.imgId(item.dynId, 0))
          .geometryTransition(this.imgTransitionId(item.dynId, 0))
          .onClick(() => {
            this.openItemImage(item, 0);
          })
      }, (src: string) => item.dynId + '-single-' + src)
    } else {
      Grid() {
        ForEach(item.images.slice(0, 9), (src: string, index: number) => {
          GridItem() {
            Stack({ alignContent: Alignment.Center }) {
              // 宫格缩略图（320w webp）：动态流大批图片时避免原图占满内存。
              Image(src.length > 0 ? biliImageThumbnail(src, 320) : src)
                .width('100%')
                .aspectRatio(1)
                .objectFit(ImageFit.Cover)
                .id(this.imgId(item.dynId, index))
                .geometryTransition(this.imgTransitionId(item.dynId, index))
              if (index === 8 && item.images.length > 9) {
                Column() {
                  Text('+' + String(item.images.length - 9))
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
              this.openItemImage(item, index);
            })
          }
        }, (src: string, index: number) => item.dynId + '-' + src + String(index))
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsTemplate(this.gridRowsTemplate(Math.min(9, item.images.length)))
      .rowsGap(4)
      .columnsGap(4)
      .height(this.imageGridHeightFor(item.images.slice(0, 9), inset))
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

  private openDetail(focusComments: boolean = false): void {
    if (this.detailMode || this.item.dynId.length === 0) return;
    let srcRect: ImageViewerSrcRect | undefined = undefined;
    try {
      const area = this.getUIContext().getComponentUtils().getRectangleById(this.cardId());
      if (area.size.width > 0 && area.size.height > 0 && area.windowOffset.x >= 0) {
        srcRect = {
          x: this.getUIContext().px2vp(area.windowOffset.x),
          y: this.getUIContext().px2vp(area.windowOffset.y),
          w: this.getUIContext().px2vp(area.size.width),
          h: this.getUIContext().px2vp(area.size.height),
        };
      }
    } catch (e) {
      // 取不到卡片矩形时保持普通导航。
    }
    const param: DynamicDetailParam = { item: this.item as Object, focusComments: focusComments, srcRect: srcRect };
    if (srcRect !== undefined) {
      AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
      AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 380);
    }
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
    } else if (item.bvid.length > 0 || item.aid > 0) {
      this.openVideo(item);
    } else {
      this.openItemDetail(item);
    }
  }

  /** 动态里的投稿视频与首页视频共用整卡扩展；快照失败时回退原有封面转场。 */
  private openVideo(item: DynamicItem): void {
    const entryCoverWidth: number = item.dynId === this.item.dynId ? 480 : 240;
    const param: VideoDetailParam = {
      bvid: item.bvid,
      aid: item.aid,
      title: item.title,
      // 与卡片实际显示的缩略图保持同一 URL，hero 可直接复用已解码纹理。
      cover: biliImageThumbnail(item.cover, entryCoverWidth),
      // 动态流位于根 Tabs 的懒加载列表中，视频页覆盖期间来源卡可能被回收。
      // 保留入场放大，返回使用普通出栈，避免详情页缩回后因目标节点缺失而悬停。
      mirrorHeroReturn: false,
    };
    try {
      const cardArea = this.getUIContext().getComponentUtils().getRectangleById(this.videoCardId(item));
      if (cardArea.size.width > 0 && cardArea.size.height > 0 &&
        cardArea.windowOffset.x >= 0 && cardArea.windowOffset.y >= 0) {
        const snapshot: image.PixelMap = this.getUIContext().getComponentSnapshot().getSync(this.videoCardId(item), {
          waitUntilRenderFinished: true,
        });
        param.cardRect = {
          x: this.getUIContext().px2vp(cardArea.windowOffset.x),
          y: this.getUIContext().px2vp(cardArea.windowOffset.y),
          w: this.getUIContext().px2vp(cardArea.size.width),
          h: this.getUIContext().px2vp(cardArea.size.height),
        };
        AppStorage.setOrCreate<image.PixelMap>(HERO_BG_SNAPSHOT_KEY, snapshot);
        AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
        AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
        return;
      }
    } catch (e) {
      // 组件快照不可用时继续走下方已验证的封面矩形动画。
    }
    let srcRect: ImageViewerSrcRect | undefined = undefined;
    try {
      const area = this.getUIContext().getComponentUtils().getRectangleById(this.videoCoverId(item));
      if (area.size.width > 0 && area.size.height > 0 && area.windowOffset.x >= 0 && area.windowOffset.y >= 0) {
        srcRect = {
          x: this.getUIContext().px2vp(area.windowOffset.x),
          y: this.getUIContext().px2vp(area.windowOffset.y),
          w: this.getUIContext().px2vp(area.size.width),
          h: this.getUIContext().px2vp(area.size.height),
        };
      }
    } catch (e) {
      // 无封面或尚未完成布局时退回普通导航。
    }
    if (srcRect !== undefined) {
      param.srcRect = srcRect;
      AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
      AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
    }
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  private openItemImage(item: DynamicItem, index: number): void {
    const images: Array<string> = item.images;
    const rects: Array<ImageViewerSrcRect> = this.collectImageRects(item);
    const rect: ImageViewerSrcRect | undefined = index < rects.length && rects[index].w > 0 ? rects[index] : undefined;
    const ids: Array<string> = [];
    const transitionIds: Array<string> = [];
    const previews: Array<string> = [];
    for (let i: number = 0; i < images.length; i++) {
      // 第 10 张以后都由第 9 格的“+N”入口承载，返回时也以该格为实时目标。
      ids.push(this.imgId(item.dynId, Math.min(i, 8)));
      transitionIds.push(this.imgTransitionId(item.dynId, Math.min(i, 8)));
      previews.push(biliImageThumbnail(images[i], images.length === 1 ? 900 : 320));
    }
    const viewer: ImageViewerParam = {
      images: images,
      initialIndex: index,
      srcRect: rect,
      srcRects: rects,
      srcIds: ids,
      srcPreviews: previews,
    };
    if (this.sharedImageTransition) {
      viewer.transitionId = this.imgTransitionId(item.dynId, Math.min(index, 8));
      viewer.transitionIds = transitionIds;
    }
    this.pushViewer(viewer);
  }

  /** 记录宫格每一格的窗口矩形；超过 9 张的图片统一收回“+N”所在的第 9 格。 */
  private collectImageRects(item: DynamicItem): Array<ImageViewerSrcRect> {
    const rects: Array<ImageViewerSrcRect> = [];
    let overflowRect: ImageViewerSrcRect = { x: 0, y: 0, w: 0, h: 0 };
    for (let i: number = 0; i < item.images.length; i++) {
      if (i >= 9) {
        rects.push(overflowRect);
        continue;
      }
      let rect: ImageViewerSrcRect = { x: 0, y: 0, w: 0, h: 0 };
      try {
        const area = this.getUIContext().getComponentUtils().getRectangleById(this.imgId(item.dynId, i));
        if (area.size.width > 0 && area.size.height > 0 && area.windowOffset.x >= 0) {
          rect = {
            x: this.getUIContext().px2vp(area.windowOffset.x),
            y: this.getUIContext().px2vp(area.windowOffset.y),
            w: this.getUIContext().px2vp(area.size.width),
            h: this.getUIContext().px2vp(area.size.height),
          };
        }
      } catch (e) {
        // 未布局的格子保留零矩形，退出时退化为淡出。
      }
      rects.push(rect);
      if (i === 8) overflowRect = rect;
    }
    return rects;
  }

  /** 普通 Navigation 层级使用 geometryTransition；根 Tabs 则使用窗口矩形 hero 规避坐标系偏移。 */
  private pushViewer(viewer: ImageViewerParam): void {
    if ((viewer.transitionId ?? '').length > 0) {
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
        AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer, false);
      });
      return;
    }
    AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
    AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
    AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer);
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
        // 行内流：与评论区一致，表情随文字同流换行（Flex 独立 item 会把表情挤到新行），底部对齐。
        Text() {
          ForEach(contentPartsOf(item, this.emoteVer), (part: DynamicContentPart) => {
            if (part.image.length > 0 && this.emoteFailed.has(part.image)) {
              Span(part.imageLabel.length > 0 ? part.imageLabel : '[表情]')
            } else if (part.image.length > 0) {
              ImageSpan(this.emoteSrc(part.image)).width(part.imageSize > 1 ? 46 : 23).height(part.imageSize > 1 ? 46 : 23).objectFit(ImageFit.Contain).verticalAlign(ImageSpanAlignment.BOTTOM)
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
          this.openItemDetail(item);
        })
      }
      if (item.images.length > 0) {
        this.ImageGrid(item, 20)
      }
      if (item.title.length > 0) {
        Row({ space: 9 }) {
          if (item.cover.length > 0) {
            ForEach([item.cover], (cover: string) => {
              Image(biliImageThumbnail(cover, 240))
                .width(112)
                .height(68)
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .id(this.videoCoverId(item))
            }, (cover: string) => item.dynId + '-forward-cover-' + cover)
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
        .id(this.videoCardId(item))
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
            } else {
              Span(part.text)
            }
          }, (part: DynamicContentPart) => part.key)
        }
        .fontSize(14)
        .lineHeight(21)
        .width('100%')
        .fontColor(this.isDark ? '#D0D0D0' : '#222222')
        .onClick(() => this.openDetail())
      }

      if (this.item.original !== null) {
        this.ForwardedCard(this.item.original)
      }

      // 图文/专栏动态图片宫格（详情态也走缩略图，内存友好；点击进 ImageViewer 时再拉原图）。
      if (this.item.images.length > 0) {
        Stack({ alignContent: Alignment.TopStart }) {
          // 图片本身仍打开看图器；单图左右的留白属于动态卡片，点击应进入动态详情。
          Row()
            .width('100%')
            .height(this.imageGridHeightFor(this.item.images.slice(0, 9), 0))
            .onClick(() => this.openDetail())
          this.ImageGrid(this.item, 0)
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
              .id(this.videoCoverId(this.item))
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
        .id(this.videoCardId(this.item))
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
        // 更多菜单固定贴齐卡片右边，不再紧跟在转发按钮后面。
        Blank()
          .layoutWeight(1)
        Row({ space: 4 }) {
          Image($r('app.media.ic_more'))
            .width(16)
            .height(16)
            .fillColor('#9499A0')
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5, bottom: 5 })
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
    .id(this.cardId())
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
  // 发布动态（纯文字）面板状态
  @State showComposer: boolean = false;
  @State composerText: string = '';
  @State composing: boolean = false;
  // 顶部「关注 UP 主」横滑栏：登录后拉取关注列表第一页，不阻塞动态流加载。
  @State followed: Array<RelationUserItem> = [];
  /** uid -> 直播间 roomId（仅直播中的 UP；由批量开播状态接口异步补充，失败不影响横滑条）。 */
  @State liveRooms: Map<number, number> = new Map<number, number>();
  @State followingLoaded: boolean = false;
  private followLoading: boolean = false;
  private liveFetching: boolean = false;
  private accountGeneration: number = 0;
  @State feedMoreFailed: boolean = false;
  @State feedNeedsLogin: boolean = false;
  private feedRetryReset: boolean = false;
  private feedEpoch: RequestEpoch = new RequestEpoch();
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('glassEnabled') glassOn: boolean = true;
  @StorageProp('headerFade') fade: number = 0;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVer: number = 0;
  private dynSource: BasicDataSource<DynamicItem> = new BasicDataSource<DynamicItem>();
  private dynTabsController: TabsController = new TabsController();
  private dynTypes: Array<string> = ['all', 'video', 'pgc', 'article'];
  private initializing: boolean = false;
  /** 初始化期间收到登录广播时补跑一次，避免 Tabs 保活页面永久停在旧登录态。 */
  private initPending: boolean = false;

  onLoginChanged(): void {
    // 登录/登出广播：重载动态流（Tabs 保活，aboutToAppear 不会再触发）
    // 关注列表与直播角标属于账号数据，切换账号时必须清空并重新拉取。
    this.accountGeneration++;
    this.feedEpoch.invalidate();
    this.feedLoading = false;
    this.dynSource.clear();
    this.dynCount = 0;
    this.dynOffset = '';
    this.dynHasMore = true;
    this.followed = [];
    this.liveRooms = new Map<number, number>();
    this.followingLoaded = false;
    this.followLoading = false;
    this.liveFetching = false;
    this.init().catch(() => {
    });
  }

  aboutToAppear(): void {
    EmoteResolver.ensureLoaded();
    // 切到动态 Tab 时强制回到顶部状态，避免残留 fade 导致搜索栏和搜索球同时出现。
    AppTheme.resetHeaderFade();
    this.init().catch(() => {
    });
  }

  async init(): Promise<void> {
    // aboutToAppear 与登录广播可能同时触发，防重入
    if (this.initializing) {
      this.initPending = true;
      return;
    }
    this.initializing = true;
    this.initPending = false;
    try {
      this.loading = true;
      this.errorText = '';
      if (this.hostMid <= 0 && !UserStore.isLogin) {
        await UserStore.ensureLoaded();
      }
      this.login = this.hostMid > 0 || UserStore.isLogin;
      if (this.login) {
        // 只有主页关注流展示 UP 横滑栏；用户空间内嵌版与指定用户动态都不需要。
        if (this.hostMid <= 0 && !this.embedded) {
          this.loadFollowStrip();
        }
        await this.loadFeed(true);
      }
    } catch (e) {
      this.errorText = '动态加载失败，请检查登录状态或网络后重试';
    } finally {
      this.loading = false;
      this.initializing = false;
      if (this.initPending) {
        this.initPending = false;
        this.init().catch(() => {
        });
      }
    }
  }

  async loadFeed(reset: boolean): Promise<void> {
    if (!reset && (this.feedLoading || !this.dynHasMore)) return;
    const epoch: number = this.feedEpoch.next();
    this.feedMoreFailed = false;
    this.feedNeedsLogin = false;
    this.feedRetryReset = reset;
    this.errorText = '';
    this.feedLoading = true;
    try {
      const off: string = reset ? '' : this.dynOffset;
      const page: DynamicPageData = this.hostMid > 0 ?
        await DynamicApi.getUserDynamicFeed(this.hostMid, off) : await DynamicApi.getDynamicFeed(off, this.dynType);
      if (!this.feedEpoch.isCurrent(epoch)) return;
      if (reset) {
        this.dynSource.reset(page.items);
      } else {
        this.dynSource.append(page.items);
      }
      this.dynCount = this.dynSource.totalCount();
      this.dynOffset = page.offset;
      this.dynHasMore = page.hasMore;
    } catch (e) {
      if (!this.feedEpoch.isCurrent(epoch)) return;
      this.feedNeedsLogin = (e as Error).message === '登录已失效，请重新登录后查看动态';
      if (this.dynSource.isEmpty()) this.errorText = this.feedNeedsLogin ?
        '登录已失效，请重新登录后查看动态' : '动态加载失败，请稍后重试';
      else this.feedMoreFailed = true;
    } finally {
      if (this.feedEpoch.isCurrent(epoch)) this.feedLoading = false;
    }
  }

  private recoverFeed(): void {
    if (this.feedNeedsLogin) {
      AppNavStack.pushPathByName(NAV_LOGIN, null);
    } else if (this.dynCount === 0) {
      this.init();
    } else {
      this.loadFeed(this.feedMoreFailed && this.feedRetryReset);
    }
  }

  /** 并行拉取关注 UP 主第一页，仅作横滑栏展示，失败静默（不影响动态主流程）。 */
  private async loadFollowStrip(): Promise<void> {
    if (this.followingLoaded || this.followLoading) return;
    const generation: number = this.accountGeneration;
    this.followLoading = true;
    try {
      await UserStore.ensureLoaded();
      const mid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      if (mid <= 0) return;
      const page: RelationUserPageData = await UserApi.getRelationUsers(mid, 'following', 1);
      if (generation !== this.accountGeneration || UserStore.current === null || UserStore.current.mid !== mid) return;
      if (page.users.length > 0) {
        this.followed = page.users;
      }
    } catch (e) {
      // 关注列表失败时静默隐藏横滑条。
    } finally {
      if (generation === this.accountGeneration) {
        this.followingLoaded = true;
        this.followLoading = false;
        // 列表到位后异步补开播状态（直播角标）；失败静默。
        this.refreshLiveBadges();
      }
    }
  }

  /** 批量查询关注 UP 的开播状态，驱动横滑栏「直播中」角标。 */
  private async refreshLiveBadges(): Promise<void> {
    if (this.followed.length === 0 || this.liveFetching) return;
    const generation: number = this.accountGeneration;
    this.liveFetching = true;
    try {
      const uids: Array<number> = [];
      for (let i: number = 0; i < this.followed.length; i++) {
        uids.push(this.followed[i].mid);
      }
      const items = await LiveApi.getLiveStatusByUids(uids);
      if (generation !== this.accountGeneration) return;
      const next: Map<number, number> = new Map<number, number>();
      for (let i: number = 0; i < items.length; i++) {
        if (items[i].liveStatus === 1 && items[i].roomId > 0) {
          next.set(items[i].uid, items[i].roomId);
        }
      }
      this.liveRooms = next;
    } catch (e) {
      // 开播状态失败时只少一个角标，不打扰。
    } finally {
      if (generation === this.accountGeneration) this.liveFetching = false;
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
    Haptic.tap();
  }

  /** 关注栏 UP「直播中」角标点击：直达直播间。 */
  private openLiveRoom(mid: number): void {
    const roomId: number | undefined = this.liveRooms.get(mid);
    if (roomId === undefined || roomId <= 0) return;
    this.tapVibrate();
    const followee: RelationUserItem | undefined =
      this.followed.find((u: RelationUserItem) => u.mid === mid);
    const param: LiveRoomParam = {
      roomId: roomId,
      uid: mid,
      title: '',
      uname: followee !== undefined ? followee.uname : '',
      face: followee !== undefined ? followee.face : '',
      cover: '',
    };
    AppNavStack.pushPathByName(NAV_LIVE_ROOM, param);
  }

  private changeDynType(type: string): void {
    if (this.dynType === type) return;
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

  /** 顶部「关注 UP 主」横滑栏：第一条动态下展示关注对象，点击进用户空间；开播中的 UP 带红点。 */
  @Builder
  FollowStrip() {
    List({ space: 14 }) {
      ForEach(this.followed, (u: RelationUserItem) => {
        ListItem() {
          Column({ space: 6 }) {
            Stack({ alignContent: Alignment.TopEnd }) {
              Stack({ alignContent: Alignment.Center }) {
                Image(u.face.length > 0 ? u.face : $r('app.media.placeholder_avatar_noface'))
                  .width(46)
                  .height(46)
                  .borderRadius(23)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor(this.isDark ? '#33353A' : '#EEF0F2')
                  .syncLoad(false)
              }
              .width(47)
              .height(47)
              if (this.liveRooms.get(u.mid) !== undefined) {
                // 直播中角标：与 B 站 App 关注栏一致，点角标直达直播间。
                Text('直播中')
                  .fontSize(8)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#F53F3F')
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .borderRadius(6)
                  .margin({ right: -2, top: -2 })
                  .priorityGesture(TapGesture().onAction(() => {
                    this.openLiveRoom(u.mid);
                  }))
              }
            }
            .width(47)
            .height(47)
            Text(u.uname)
              .fontSize(11)
              .fontColor(this.isDark ? '#C9C9CE' : '#61666D')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(62)
              .textAlign(TextAlign.Center)
          }
          .width(64)
          .onClick(() => {
            this.tapVibrate();
            if (u.mid > 0) {
              const param: UserSpaceParam = { mid: u.mid };
              AppNavStack.pushPathByName(NAV_USER_SPACE, param);
            }
          })
          .stateStyles({
            pressed: { opacity: 0.6 },
            normal: { opacity: 1 },
          })
        }
      }, (u: RelationUserItem) => String(u.mid))
    }
    .listDirection(Axis.Horizontal)
    .width('100%')
    .height(84)
    .padding({ left: 4, right: 4 })
    .scrollBar(BarState.Off)
    .cachedCount(4)
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

  /** 动态图片 id 前缀基座：主页动态 tab 与用户空间内嵌实例可能同屏共存，按场景+hostMid 区分。 */
  private cardIdPrefix(tabIdx: number): string {
    return (this.embedded ? 'dyn-e' + String(this.hostMid) : 'dyn-h') + '-' + String(tabIdx) + '-';
  }

  @Builder
  DynBody(tabIdx: number) {
    if (this.loading) {
      LoadingView({ skeleton: 'social', loading: true })
        .margin({ top: this.embedded ? 4 : Immersive.statusBarHeight() + 86 })
    } else if (!this.login) {
      this.LoginPrompt()
    } else if (this.dynCount === 0) {
      LoadingView({ skeleton: 'social',
        loading: this.feedLoading,
        empty: this.feedLoading ? false : this.errorText.length === 0,
        emptyText: this.hostMid > 0 ? '该用户暂时没有发布动态' :
          (this.dynType === 'all' ? '暂时没有动态，去关注一些UP主吧' : '该分类下暂无动态'),
        errorText: this.errorText,
        retryText: this.feedNeedsLogin ? '去登录' : '重新加载',
        onRetry: () => this.recoverFeed(),
      })
      .margin({ top: this.embedded ? 4 : Immersive.statusBarHeight() + 86 })
    } else {
      Refresh({ refreshing: $$this.refreshing, builder: this.DynRefreshHeader() }) {
        List({ space: 10 }) {
          if (this.followed.length > 0 && !this.embedded && this.hostMid <= 0) {
            ListItem() {
              Column({ space: 8 }) {
                Row({ space: 6 }) {
                  Text('关注')
                    .fontSize(12)
                    .fontColor('#9499A0')
                  Text(this.followed.length + ' 位')
                    .fontSize(11)
                    .fontColor('#B0B3B8')
                  Blank()
                }
                .width('100%')
                .padding({ left: 2, right: 2 })
                this.FollowStrip()
              }
              .width('100%')
              .padding({ top: 10, bottom: 2 })
            }
          }
          LazyForEach(this.dynSource, (item: DynamicItem) => {
            ListItem() {
              // 主页底部 Tabs 里的动态流（Navigation 根页面）走 push + srcRect 矩形放大看图。
              DynCard({ item: item, embedded: this.embedded, sharedImageTransition: this.embedded,
                idPrefix: this.cardIdPrefix(tabIdx) })
            }
          }, (item: DynamicItem) => item.dynId)
          ListItem() {
            LoadMoreFooter({
              loading: this.feedLoading,
              hasMore: this.dynHasMore || this.feedMoreFailed,
              moreText: this.feedNeedsLogin ? '登录已失效，去登录' : (this.feedMoreFailed ? '加载失败，点击重试' : '继续加载动态'),
              endText: '—— 动态到底啦 ——',
              fixedHeight: 52,
              spinnerSize: 22,
              clickable: true,
              onLoadMore: () => this.recoverFeed(),
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
        // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
        .contentEndOffset(this.embedded ? 16 : Immersive.bottomInset() + 76)
        .padding({ left: LayoutTokens.phonePadding, right: LayoutTokens.phonePadding })
        .scrollBar(BarState.Off)
        .nestedScroll({
          scrollForward: this.embedded ? NestedScrollMode.PARENT_FIRST : NestedScrollMode.SELF_ONLY,
          scrollBackward: this.embedded ? NestedScrollMode.SELF_FIRST : NestedScrollMode.SELF_ONLY,
        })
        .onDidScroll((offset: number) => {
          if (!this.embedded) AppTheme.updateHeaderFade(offset);
        })
        .onReachEnd(() => {
          if (!this.feedMoreFailed) this.loadFeed(false);
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

  /** 发布动态（纯文本）底部面板：输入 + 发布；发布成功后重载 feed。用系统 bindSheet 从底部滑出。 */
  @Builder
  DynComposerSheet() {
    Column({ space: 12 }) {
      Row() {
        Text('发布动态').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        Blank()
        Text('取消').fontSize(13).fontColor('#9499A0')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .stateStyles({
            pressed: { opacity: 0.6 },
            normal: { opacity: 1 },
          })
          .onClick(() => this.showComposer = false)
      }
      .width('100%')
      TextArea({ placeholder: '分享新鲜事…', text: this.composerText })
        .width('100%')
        .height(150)
        .fontSize(15)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .placeholderColor('#9499A0')
        .backgroundColor(this.isDark ? '#26272B' : '#F3F4F6')
        .borderRadius(10)
        .onChange((value: string) => this.composerText = value)
      Text(this.composerText.length + ' / 2000')
        .width('100%').fontSize(11).fontColor('#B0B3B8').textAlign(TextAlign.End)
      Button(this.composing ? '发布中…' : '发布')
        .width('100%').height(42).borderRadius(21)
        .fontSize(15).fontColor('#FFFFFF')
        .backgroundColor(this.accent)
        .enabled(!this.composing && this.composerText.trim().length > 0)
        .onClick(() => this.submitDynamic())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
  }

  private async submitDynamic(): Promise<void> {
    if (this.composing) return;
    this.composing = true;
    try {
      const result: ActionResult = await DynamicApi.publish(this.composerText);
      if (result.ok) {
        this.showComposer = false;
        this.composerText = '';
        this.showToast('发布成功');
        this.loadFeed(true).catch(() => {
        });
      } else {
        this.showToast(result.message);
      }
    } catch (e) {
      this.showToast('发布失败，请检查网络');
    } finally {
      this.composing = false;
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 组件销毁或窗口异常时忽略提示。
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 动态分类 Tabs：左右滑动在 全部/视频/番剧/专栏 之间切换，与首页推荐/热门/直播一致。
      // 内嵌模式（用户空间"动态"页）禁用内层横向滑动：让外层"主页/动态/投稿"Tabs 收到手势，
      // 避免两层横向 Tabs 抢手势导致从中间页滑不出去；分类切换在独立动态页内仍可用。
      Tabs({ index: $$this.dynTab, controller: this.dynTabsController }) {
        TabContent() { this.DynBody(0) }.tabBar('')
        TabContent() { this.DynBody(1) }.tabBar('')
        TabContent() { this.DynBody(2) }.tabBar('')
        TabContent() { this.DynBody(3) }.tabBar('')
      }
      .width('100%')
      .height('100%')
      .scrollable(!this.embedded)
      .barHeight(0)
      .cachedMaxCount(1, TabsCacheMode.CACHE_BOTH_SIDE)
      .animationMode(AnimationMode.CONTENT_FIRST)
      .animationDuration(MotionTokens.navigation)
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

      // 发布动态 FAB：主页动态流右下角悬浮（非内嵌、已登录时显示）。
      // align(Middle/BottomEnd) 锚定在悬浮 Dock 上方，不再用百分比 position 避免随屏高漂移。
      // 发布动态 FAB：不依赖子组件 .align()（在该布局下会错位到顶部），
      // 用独立全屏容器 + alignContent(BottomEnd) 直接锚定右下角，避开悬浮 Dock。
      if (this.login && this.hostMid <= 0 && this.embedded === false) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_comment'))
              .width(22)
              .height(22)
              .fillColor('#FFFFFF')
          }
          .width(48)
          .height(48)
          .borderRadius(24)
          .backgroundColor(this.accent)
          .shadow({ radius: 12, color: '#66FB7299', offsetY: 3 })
          .onClick(() => {
            this.showComposer = true;
          })
          .stateStyles({
            pressed: { opacity: 0.85 },
            normal: { opacity: 1 },
          })
        }
        .width('100%')
        .height('100%')
        .padding({ right: 16, bottom: Immersive.bottomInset() + 88 })
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(50)
      }
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .bindSheet($$this.showComposer, this.DynComposerSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      radius: { topLeft: 18, topRight: 18 },
      backgroundColor: this.isDark ? '#1E2024' : '#FFFFFF',
    })
  }
}
