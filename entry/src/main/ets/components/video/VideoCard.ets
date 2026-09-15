import { MotionTokens } from '../../common/MotionTokens';
/**
 * 视频卡片（B 站风格）：封面数据叠层 + 标题 + UP 主信息行
 * 首页信息流可开卡片右下 ⋮（举报/不想看浮层）
 * @Reusable：LazyForEach 回收复用，数据通过 @Prop + aboutToReuse 刷新
 */
import { VideoRowCard } from './VideoRowCard';
import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { VideoItem } from '../../model/Models';
import { formatCount, formatDuration } from '../../common/Utils';
import { AppNavStack, HERO_BG_SNAPSHOT_KEY, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  NAV_VIDEO_DETAIL, VideoDetailParam, ImageViewerSrcRect } from '../../common/AppRouter';
import { Haptic } from '../../common/Haptic';
import { UserStore } from '../../services/auth/UserStore';
import { FeedCardTitle, FeedCoverImage, FeedGradientMask } from '../FeedCardParts';
import { biliImageThumbnail } from '../../common/ImageUrl';

/** showDialog 按钮声明（promptAction 的 Button 类型不便直接引用）。 */
interface CardMenuButtonItem {
  text: string;
  color: string;
}
@Reusable
@Component
export struct VideoCard {
  @Prop video: VideoItem = new VideoItem();
  /** 用户空间等紧凑网格隐藏 UP/分区行，复用同一封面和跳转逻辑。 */
  @Prop compact: boolean = false;
  /** 首页采用更舒展的圆角和文字留白。 */
  @Prop homeStyle: boolean = false;
  @Prop horizontal: boolean = false;
  @Prop highlightKeyword: string = '';
  /**
   * 卡片 id 前缀：同一窗口内可能有多个常驻容器渲染同一视频（首页推荐/热门 Tabs、
   * 搜索页与用户空间叠在首页之上），裸 bvid 会让 getRectangleById 命中离屏卡片，
   * 入场动画便从错误的矩形（常是右侧相邻 Tab）放大。各调用方传唯一前缀区分。
   */
  @Prop idPrefix: string = '';
  /** 首页开启整卡到详情页的一镜到底；其他复用场景保留现有封面转场。 */
  @Prop wholeCardTransition: boolean = false;
  /** UP 主信息行显示 ⋮（举报/不想看）：首页信息流开启（@Prop 保证跨容器复用不串台）。 */
  @Prop showMore: boolean = false;
  onReport: ((item: VideoItem) => void) | null = null;
  onHide: ((item: VideoItem) => void) | null = null;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State moreOpen: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    this.video = params.video as VideoItem;
    this.compact = params.compact === true;
    this.homeStyle = params.homeStyle === true;
    this.horizontal = params.horizontal === true;
    this.highlightKeyword = params.highlightKeyword === undefined ? '' : params.highlightKeyword as string;
    this.idPrefix = params.idPrefix === undefined ? '' : params.idPrefix as string;
    this.wholeCardTransition = params.wholeCardTransition === true;
    // showMore 现为 @Prop（框架自动同步）；两个回调是普通属性，复用必须按新调用方重置。
    this.showMore = params.showMore === true;
    const report: Object | undefined = params['onReport'];
    this.onReport = typeof report === 'function' ? report as (item: VideoItem) => void : null;
    const hide: Object | undefined = params['onHide'];
    this.onHide = typeof hide === 'function' ? hide as (item: VideoItem) => void : null;
    this.moreOpen = false;
  }

  private cardId(): string {
    return this.idPrefix + 'video-card-' + (this.video.bvid.length > 0 ? this.video.bvid : 'a' + String(this.video.aid));
  }

  private coverId(): string {
    return this.cardId() + '-cover';
  }

  build() {
    if (this.horizontal) {
      VideoRowCard({
        cover: biliImageThumbnail(this.video.cover, 900),
        coverId: this.coverId(),
        title: this.video.title,
        highlightKeyword: this.highlightKeyword,
        upName: this.video.upName,
        overlayText: this.video.duration > 0 ? formatDuration(this.video.duration) : '',
        extraText: (this.video.playText || formatCount(this.video.play)) + ' 播放 · ' +
          (this.video.danmakuText || formatCount(this.video.danmaku)) + ' 弹幕',
        compact: true,
        onTap: () => this.openDetail(),
      })
      .id(this.cardId())
    } else {
      this.GridCard()
    }
  }

  @Builder
  GridCard() {
    Column() {
      // 封面：点击区是封面本身（标题/信息区各自挂点击，互不误触）。
      Stack() {
        Stack() {
          FeedCoverImage({ cover: this.video.cover, isDark: this.isDark })
          // 覆盖层：上 = 多P标识，下 = 播放/弹幕/时长，复刻首页卡片的信息层级。
          Column() {
            Row() {
              Text('多P · ' + this.video.videos)
                .fontSize(10)
                .fontColor('#FFFFFF')
                .backgroundColor('#99000000')
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .borderRadius(4)
                .visibility(this.video.videos > 1 ? Visibility.Visible : Visibility.None)
            }
            .width('100%')
            .padding({ left: 6, top: 6 })

            Blank()

            Stack({ alignContent: Alignment.Bottom }) {
              FeedGradientMask({ height: 40, bottomColor: '#A6000000' })
              Row({ space: 10 }) {
                if (this.video.playText.length > 0 || this.video.play > 0) {
                  Row({ space: 4 }) {
                    Stack() {
                      Image($r('app.media.ic_play'))
                        .width(6)
                        .height(6)
                        .renderMode(ImageRenderMode.Template)
                        .fillColor('#FFFFFF')
                    }
                    .width(17)
                    .height(12)
                    .alignContent(Alignment.Center)
                    .border({ width: 1, color: '#FFFFFF', radius: 3 })
                    Text(this.video.playText.length > 0 ? this.video.playText : formatCount(this.video.play))
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                      .maxLines(1)
                  }
                  .alignItems(VerticalAlign.Center)
                }
                if (this.video.danmakuText.length > 0 || this.video.danmaku > 0) {
                  Row({ space: 4 }) {
                    Image($r('app.media.ic_danmaku_on'))
                      .width(14)
                      .height(14)
                      .renderMode(ImageRenderMode.Template)
                      .fillColor('#FFFFFF')
                    Text(this.video.danmakuText.length > 0 ? this.video.danmakuText : formatCount(this.video.danmaku))
                      .fontSize(11)
                      .fontColor('#FFFFFF')
                      .maxLines(1)
                  }
                  .alignItems(VerticalAlign.Center)
                }
                Blank()
                if (this.video.duration > 0) {
                  Text(formatDuration(this.video.duration))
                    .fontSize(11)
                    .fontColor('#FFFFFF')
                    .maxLines(1)
                }
              }
              .width('100%')
              .height(32)
              .padding({ left: 8, right: 8 })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
          }
          .width('100%')
          // 与封面同高：百分比高度会顶满 List 卡片槽位，改用相同宽高比
          // 对齐原生 B 站首页双列卡片的竖感封面比例
          .aspectRatio(4 / 3)
        }
        .width('100%')
        .clip(true)
        // 卡片整体由外层白色卡片承载边界，封面自身不再描边/投影。
        .aspectRatio(4 / 3)
        .onClick(() => this.openDetail())
      }
      .width('100%')
      .id(this.coverId())

      // 标题（@Builder 不能链式修饰，用 Row 承载左右内缩）
      // 固定两行高度：卡片高度不随标题长短变化，双列网格每张卡片严格等大、间距一致。
      Row() {
        FeedCardTitle({ title: this.video.title, isDark: this.isDark })
      }
      .width('100%')
      // 首页标题预留两行 38vp + 顶部 8vp，避免作者行贴住第二行标题。
      .height(this.homeStyle ? 50 : (this.showMore ? 46 : 38))
      .alignItems(VerticalAlign.Top)
      .padding({ left: this.homeStyle ? 12 : 10, right: this.homeStyle ? 12 : 10, top: this.homeStyle ? 10 : 8 })
      .onClick(() => this.openDetail())

      // 底栏只保留 UP 标识、作者与竖向菜单；播放数据已回到封面叠层。
      if (!this.compact) {
        Row({ space: 6 }) {
          Row({ space: 5 }) {
            Text('UP')
              .fontSize(8)
              .fontColor(this.isDark ? '#8A8A8F' : '#9499A0')
              .padding({ left: 2, right: 2 })
              .border({ width: 0.8, color: this.isDark ? '#666970' : '#AEB2B8', radius: 2 })
            Text(this.video.upName)
              .fontSize(11)
              .fontColor(this.isDark ? '#A5AAB5' : '#7D8490')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          .onClick(() => this.openDetail())
          if (this.showMore) {
            this.MoreDot()
          }
        }
        .width('100%')
        .height(this.homeStyle ? 32 : (this.showMore ? 26 : 30))
        .padding({ left: this.homeStyle ? 12 : 10, right: this.homeStyle ? 8 : 5 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    // 首页底栏整体下移 6vp；收回多余底部留白，保持卡片总高度不变。
    .padding({ bottom: this.homeStyle ? 6 : (this.showMore ? 2 : 6) })
    .alignItems(HorizontalAlign.Start)
    // 白色卡片承载边界：封面通顶、文字区内缩，浅色白底/深色深灰底。
    .backgroundColor(this.isDark ? (this.homeStyle ? '#24272E' : '#2B2D34') : '#FFFFFF')
    .borderRadius(this.homeStyle ? 16 : 6)
    .clip(true)
    .shadow({ radius: this.homeStyle ? 8 : 4, color: this.homeStyle ? '#08000000' : (this.isDark ? '#52000000' : '#18000000'), offsetX: 0, offsetY: 1 })
    .animation({ duration: MotionTokens.feedback, curve: Curve.EaseOut })
    .stateStyles({
      pressed: {
        opacity: 0.9,
      },
      normal: {
        opacity: 1,
      },
    })
    .id(this.cardId())
  }

  /** 卡片右下角 ⋮（竖三点）：点击弹「举报/不想看」浮层，向上展开、箭头指回 ⋮。 */
  @Builder
  MoreDot() {
    Stack() {
      Image($r('app.media.ic_more'))
        .width(14)
        .height(14)
        .renderMode(ImageRenderMode.Template)
        .fillColor('#9499A0')
    }
    .width(24)
    .height(24)
    .alignContent(Alignment.Center)
    .onClick(() => {
      Haptic.light();
      this.moreOpen = !this.moreOpen;
    })
    .bindPopup(this.moreOpen, {
      builder: this.MoreMenuBuilder(),
      placement: Placement.TopRight,
      popupColor: this.isDark ? '#2A2C31' : '#FFFFFF',
      backgroundBlurStyle: BlurStyle.NONE,
      radius: 12,
      shadow: { radius: 18, color: this.isDark ? '#8C000000' : '#33000000', offsetX: 0, offsetY: -4 },
      enableArrow: true,
      arrowPointPosition: ArrowPointPosition.END,
      offset: { x: 0, y: -4 },
      autoCancel: true,
    })
  }

  /** ⋮ 菜单内容：举报 + 不想看（实心图标，官方浮层样式）。 */
  @Builder
  MoreMenuBuilder() {
    Column() {
      this.MoreMenuItem($r('app.media.ic_report_flag'), '举报', () => this.onMoreReport())
      this.MoreMenuItem($r('app.media.bilix_icon_dislike'), '不想看', () => this.onMoreHide())
    }
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  MoreMenuItem(icon: Resource, label: string, onTap: () => void) {
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
    .onClick(() => onTap())
  }

  /** ⋮-举报：选原因后交宿主反馈（Web 端无视频举报接口）。 */
  private onMoreReport(): void {
    this.moreOpen = false;
    if (!UserStore.isLogin) {
      this.toast('请先登录后再举报');
      return;
    }
    const item: VideoItem = this.video;
    const reasons: Array<string> = ['违法违规', '色情低俗', '垃圾广告', '人身攻击', '引战', '其他'];
    const buttons: Array<CardMenuButtonItem> = [];
    for (let i: number = 0; i < reasons.length; i++) {
      buttons.push({ text: reasons[i], color: this.isDark ? '#CCFFFFFF' : '#18191C' });
    }
    buttons.push({ text: '取消', color: '#9499A0' });
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '举报视频',
        message: item.title.substring(0, Math.min(24, item.title.length)),
        buttons: buttons,
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        if (pick < 0 || pick >= reasons.length) return;
        if (this.onReport !== null) this.onReport(item);
      });
    } catch (e) {
      // 组件销毁或窗口异常时忽略。
    }
  }

  /** ⋮-不想看：确认后交宿主移除该卡（信息流本地屏蔽，本轮会话生效）。 */
  private onMoreHide(): void {
    this.moreOpen = false;
    const onHide = this.onHide;
    if (onHide === null) return;
    const item: VideoItem = this.video;
    const buttons: Array<CardMenuButtonItem> = [
      { text: '取消', color: '#9499A0' },
      { text: '确定', color: this.isDark ? '#CCFFFFFF' : '#18191C' },
    ];
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '不想看',
        message: '确定不想看这条内容吗？将减少此类推荐。',
        buttons: buttons,
      }).then((dialogResult) => {
        if (Number(dialogResult.index) === 1) onHide(item);
      });
    } catch (e) {
      // 组件销毁或窗口异常时忽略。
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 弹 toast 失败忽略。
    }
  }

  /** 封面/标题/信息区点击开稿（与 ⋮ 菜单分开绑定，避免整卡 onClick 把 ⋮ 也带飞）。 */
  private openDetail(): void {
    Haptic.light();
    if (this.video.bvid.length > 0 || this.video.aid > 0) {
      const param: VideoDetailParam = {
        bvid: this.video.bvid,
        aid: this.video.aid,
        title: this.video.title,
        // FeedCoverImage 使用 900w 缩略图；hero 传同一 URL 才能命中已解码纹理缓存。
        cover: biliImageThumbnail(this.video.cover, 900),
      };
      if (this.wholeCardTransition) {
        try {
          const rect = this.getUIContext().getComponentUtils().getRectangleById(this.cardId());
          const x: number = this.getUIContext().px2vp(rect.windowOffset.x);
          const vpW: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
          if (rect.size.width > 0 && rect.size.height > 0 && x >= 0 && x < vpW) {
            const snapshot: image.PixelMap = this.getUIContext().getComponentSnapshot().getSync(this.cardId(), {
              waitUntilRenderFinished: true,
            });
            param.cardRect = {
              x: x,
              y: this.getUIContext().px2vp(rect.windowOffset.y),
              w: this.getUIContext().px2vp(rect.size.width),
              h: this.getUIContext().px2vp(rect.size.height),
            };
            // PixelMap 不能放进 NavPathStack 参数；官方示例同样通过页外存储把快照交给目标页。
            AppStorage.setOrCreate<image.PixelMap>(HERO_BG_SNAPSHOT_KEY, snapshot);
            this.pushDetail(param, undefined);
            return;
          }
        } catch (e) {
          // 截图或测量失败时回退到原有封面转场，点击不能因此失效。
        }
      }
      // 只记录封面窗口矩形：详情页仅让封面飞向播放区，标题、数据和整页都不参与缩放。
      // 根页面 push 无共享元素转场，且要关默认右滑动画（push 第三参 false）。
      let srcRect: ImageViewerSrcRect | undefined = undefined;
      try {
        const rect = this.getUIContext().getComponentUtils().getRectangleById(this.coverId());
        const x: number = this.getUIContext().px2vp(rect.windowOffset.x);
        const vpW: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
        // 横向离屏（残留同 id 离屏卡片等异常）时回退默认转场，避免从屏幕外放大。
        if (rect.size.width > 0 && rect.size.height > 0 && x >= 0 && x < vpW) {
          srcRect = {
            x: x,
            y: this.getUIContext().px2vp(rect.windowOffset.y),
            // size 同样是 px（SDK d.ts 标注 Unit: px），漏转会把放大起点位移约一个密度倍率
            w: this.getUIContext().px2vp(rect.size.width),
            h: this.getUIContext().px2vp(rect.size.height),
          };
        }
      } catch (e) {
        // 取不到矩形则走默认转场。
      }
      this.pushDetail(param, srcRect);
    }
  }

  /** 详情页 push：官方 Navigation 自定义内容转场在 hero 期间保活来源页。 */
  private pushDetail(param: VideoDetailParam, srcRect: ImageViewerSrcRect | undefined): void {
    if (param.cardRect !== undefined || srcRect !== undefined) {
      if (srcRect !== undefined) param.srcRect = srcRect;
      AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
      AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
    }
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }
}
