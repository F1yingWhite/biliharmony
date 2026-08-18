/**
 * 动态视图：关注动态 feed（需登录）
 */
import { DynamicItem, DynamicPageData, BiliEmote, RelationUserItem, RelationUserPageData } from '../model/Models';
import { AppNavStack, NAV_DYNAMIC_DETAIL, NAV_IMAGE_VIEWER, NAV_LIVE_ROOM, NAV_LOGIN, NAV_VIDEO_DETAIL,
  NAV_USER_SPACE, DynamicDetailParam, ImageViewerParam, LiveRoomParam, VideoDetailParam,
  UserSpaceParam, NAV_BANGUMI_DETAIL, BangumiDetailParam } from '../common/AppRouter';
import { ActionResult, BiliApi } from '../api/BiliApi';
import { UserStore } from '../common/UserStore';
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
import { LiveApi } from '../api/LiveApi';
import { UserApi } from '../api/UserApi';

/** showDialog 按钮声明（promptAction 的 Button 类型不便直接引用）。 */
interface ReportButtonItem {
  text: string;
  color: string;
}

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

/** 单条动态卡片：独立 @Component，父组件状态变化不再整列表重建；@Reusable 复用滚动项。 */
@Reusable
@Component
export struct DynCard {
  @Prop @Watch('onItemChanged') item: DynamicItem = new DynamicItem();
  @Prop embedded: boolean = false;
  @Prop detailMode: boolean = false;
  @State liked: boolean = false;
  @State likeCount: number = 0;
  @State forwardCount: number = 0;
  @State actionBusy: boolean = false;
  /** 图片宫格可用宽（onAreaChange 实测），用于按官方三列正方形单元计算高度。 */
  @State gridWidth: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';

  aboutToAppear(): void {
    this.syncFromItem();
  }

  aboutToReuse(params: Record<string, Object>): void {
    // 复用实例直接换数据，避免整卡重建（LazyForEach 滚动性能）。
    const next: DynamicItem | undefined = params.item as DynamicItem | undefined;
    if (next !== undefined) {
      this.item = next;
    }
    this.actionBusy = false;
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

  /** 图文动态宫格：单图 2/3 宽正方形，多图三列正方形单元（对齐官方客户端）。
   *  超过 9 张时只展示前 9 张，第 9 张压暗并叠加 +N（官方同款处理）。 */
  @Builder
  ImageGrid(item: DynamicItem, inset: number) {
    if (item.images.length === 1) {
      Image(biliImageThumbnail(item.images[0], 900))
        .width(this.gridCell(inset) * 2 + 4)
        .height(this.gridCell(inset) * 2 + 4)
        .objectFit(ImageFit.Cover)
        .borderRadius(8)
        .id('dynamic-img-' + item.dynId + '-0')
        .geometryTransition('image-viewer-dynamic-' + item.dynId + '-0')
        .onClick(() => {
          this.openItemImage(item, 0);
        })
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
                .id('dynamic-img-' + item.dynId + '-' + String(index))
                .geometryTransition('image-viewer-dynamic-' + item.dynId + '-' + String(index))
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
        this.ImageGrid(item, 20)
      }
      if (item.title.length > 0) {
        Row({ space: 9 }) {
          if (item.cover.length > 0) {
            Image(biliImageThumbnail(item.cover, 240)).width(112).height(68).objectFit(ImageFit.Cover).borderRadius(6)
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

      // 图文/专栏动态图片宫格（详情态也走缩略图，内存友好；点击进 ImageViewer 时再拉原图）。
      if (this.item.images.length > 0) {
        this.ImageGrid(this.item, 0)
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
        BiliApi.reportDynamic(this.item.dynId, reasonValues[pick])
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
    }
  }

  async loadFeed(reset: boolean): Promise<void> {
    if (this.feedLoading || (!reset && !this.dynHasMore)) return;
    this.feedLoading = true;
    try {
      const off: string = reset ? '' : this.dynOffset;
      const page: DynamicPageData = this.hostMid > 0 ?
        await DynamicApi.getUserDynamicFeed(this.hostMid, off) : await DynamicApi.getDynamicFeed(off, this.dynType);
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

  /** 并行拉取关注 UP 主第一页，仅作横滑栏展示，失败静默（不影响动态主流程）。 */
  private async loadFollowStrip(): Promise<void> {
    if (this.followingLoaded || this.followLoading) return;
    this.followLoading = true;
    try {
      await UserStore.ensureLoaded();
      const mid: number = UserStore.current !== null ? UserStore.current.mid : 0;
      if (mid <= 0) return;
      const page: RelationUserPageData = await UserApi.getRelationUsers(mid, 'following', 1);
      if (page.users.length > 0) {
        this.followed = page.users;
      }
    } catch (e) {
      // 关注列表失败时静默隐藏横滑条。
    } finally {
      this.followingLoaded = true;
      this.followLoading = false;
      // 列表到位后异步补开播状态（直播角标）；失败静默。
      this.refreshLiveBadges();
    }
  }

  /** 批量查询关注 UP 的开播状态，驱动横滑栏「直播中」角标。 */
  private async refreshLiveBadges(): Promise<void> {
    if (this.followed.length === 0 || this.liveFetching) return;
    this.liveFetching = true;
    try {
      const uids: Array<number> = [];
      for (let i: number = 0; i < this.followed.length; i++) {
        uids.push(this.followed[i].mid);
      }
      const items = await LiveApi.getLiveStatusByUids(uids);
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
      this.liveFetching = false;
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
        // 悬浮 Dock 高 52 + 底部边距 16，末端留白必须大于 68 才能完整露出末行。
        .contentEndOffset(this.embedded ? 16 : Immersive.bottomInset() + 76)
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
      const result: ActionResult = await BiliApi.publishDynamic(this.composerText);
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
