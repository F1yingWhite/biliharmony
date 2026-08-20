/**
 * 视频卡片（B 站风格）：封面（时长）+ 标题 + UP + 底部数据行（评论/播放）
 * 首页推荐流可开卡片右下 ⋮（举报/不想看浮层）
 * @Reusable：LazyForEach 回收复用，数据通过 @Prop + aboutToReuse 刷新
 */
import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { VideoItem } from '../model/Models';
import { formatCount, formatDuration } from '../common/Utils';
import { AppNavStack, APP_ROOT_SNAPSHOT_ID, HERO_BG_SNAPSHOT_KEY, NAV_VIDEO_DETAIL, VideoDetailParam,
  ImageViewerSrcRect } from '../common/AppRouter';
import { Haptic } from '../common/Haptic';
import { UserStore } from '../common/UserStore';
import { FeedCardTitle, FeedCoverImage, FeedGradientMask } from './FeedCardParts';

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
  /**
   * 卡片 id 前缀：同一窗口内可能有多个常驻容器渲染同一视频（首页推荐/热门 Tabs、
   * 搜索页与用户空间叠在首页之上），裸 bvid 会让 getRectangleById 命中离屏卡片，
   * 入场动画便从错误的矩形（常是右侧相邻 Tab）放大。各调用方传唯一前缀区分。
   */
  @Prop idPrefix: string = '';
  /** 右下数据行显示 ⋮（举报/不想看）：仅首页推荐信息流开启（@Prop 保证跨容器复用不串台）。 */
  @Prop showMore: boolean = false;
  onReport: ((item: VideoItem) => void) | null = null;
  onHide: ((item: VideoItem) => void) | null = null;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  @State moreOpen: boolean = false;

  aboutToReuse(params: Record<string, Object>): void {
    this.video = params.video as VideoItem;
    this.compact = params.compact === true;
    this.idPrefix = params.idPrefix === undefined ? '' : params.idPrefix as string;
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

  build() {
    Column({ space: 6 }) {
      // 封面：点击区是封面本身（标题/信息区各自挂点击，互不误触）。
      Stack() {
        Stack() {
          FeedCoverImage({ cover: this.video.cover, isDark: this.isDark })
          // 覆盖层：上 = 多P标识，下 = 时长（播放/评论数移到卡底部数据行，官方排布）
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

            Stack({ alignContent: Alignment.BottomEnd }) {
              FeedGradientMask({ height: 36, bottomColor: '#73000000' })
              Text(formatDuration(this.video.duration))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .backgroundColor('#99000000')
                .padding({ left: 5, right: 5, top: 2, bottom: 2 })
                .borderRadius(4)
                .visibility(this.video.duration > 0 ? Visibility.Visible : Visibility.None)
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

      // 标题（@Builder 不能链式修饰，用 Row 承载左右内缩）
      // 固定两行高度：卡片高度不随标题长短变化，双列网格每张卡片严格等大、间距一致。
      Row() {
        FeedCardTitle({ title: this.video.title, isDark: this.isDark })
      }
      .width('100%')
      .height(38)
      .alignItems(VerticalAlign.Top)
      .padding({ left: 10, right: 10 })
      .onClick(() => this.openDetail())

      // UP 主 + 推荐理由 / 分区；数据行（评论/播放）沉底，⋮ 落卡片右下角（官方排布）。
      // 文本行各自挂点击开稿，⋮ 独立子树，避开父子 onClick 同触。
      if (!this.compact) {
        Column({ space: 5 }) {
          Row({ space: 6 }) {
            Text(this.video.upName)
              .fontSize(11)
              .fontColor(this.isDark ? '#8a8a8a' : '#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.video.rcmdReason.length > 0 ? this.video.rcmdReason : this.video.tname)
              .fontSize(10)
              .fontColor(this.accent)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .border({ width: 0.5, color: this.accent, radius: 3 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '48%' })
              .visibility(this.video.rcmdReason.length > 0 || this.video.tname.length > 0 ? Visibility.Visible : Visibility.None)
          }
          .width('100%')
          .height(18)
          .alignItems(VerticalAlign.Center)
          .onClick(() => this.openDetail())

          Row() {
            Row({ space: 8 }) {
              if (this.video.reply > 0) {
                Row({ space: 3 }) {
                  Image($r('app.media.ic_comment'))
                    .width(11)
                    .height(11)
                    .renderMode(ImageRenderMode.Template)
                    .fillColor('#9499A0')
                  Text(formatCount(this.video.reply))
                    .fontSize(10)
                    .fontColor('#9499A0')
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
              }
              if (this.video.playText.length > 0) {
                Row({ space: 3 }) {
                  Image($r('app.media.ic_play'))
                    .width(11)
                    .height(11)
                    .renderMode(ImageRenderMode.Template)
                    .fillColor('#9499A0')
                  Text(this.video.playText)
                    .fontSize(10)
                    .fontColor('#9499A0')
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
              }
            }
            .alignItems(VerticalAlign.Center)
            .layoutWeight(1)
            .onClick(() => this.openDetail())
            if (this.showMore) {
              this.MoreDot()
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 10, right: 10 })
      }
    }
    .width('100%')
    .padding({ bottom: 10 })
    .alignItems(HorizontalAlign.Start)
    // 白色卡片承载边界：封面通顶、文字区内缩，浅色白底/深色深灰底。
    .backgroundColor(this.isDark ? '#2B2D34' : '#FFFFFF')
    .borderRadius(12)
    .clip(true)
    .shadow({ radius: 10, color: this.isDark ? '#59000000' : '#14000000', offsetX: 0, offsetY: 3 })
    .stateStyles({
      pressed: {
        opacity: 0.85,
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
      const param: VideoDetailParam = { bvid: this.video.bvid, aid: this.video.aid, title: this.video.title, cover: this.video.cover };
      // 从卡片位置放大到全屏：记录卡片窗口矩形，详情页首帧压到矩形上再展开。
      // 根页面 push 无共享元素转场，且要关默认右滑动画（push 第三参 false）。
      let srcRect: ImageViewerSrcRect | undefined = undefined;
      try {
        const rect = this.getUIContext().getComponentUtils().getRectangleById(this.cardId());
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

  /** 详情页 push：有 srcRect 关默认转场走手动矩形放大。根页面场景先截根页图附给目标页
   *  垫底——push 后根页 feed 不再渲染，没有截图会透出纯白窗口底，hero 动画显得"背景全白"。 */
  private pushDetail(param: VideoDetailParam, srcRect: ImageViewerSrcRect | undefined): void {
    const pushNow = (): void => {
      if (srcRect !== undefined) {
        param.srcRect = srcRect;
        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param, false);
      } else {
        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
      }
    };
    if (AppNavStack.getAllPathName().length === 0) {
      try {
        this.getUIContext().getComponentSnapshot().get(APP_ROOT_SNAPSHOT_ID)
          .then((pix: image.PixelMap) => {
        AppStorage.setOrCreate(HERO_BG_SNAPSHOT_KEY, pix);
        pushNow();
      }).catch(() => {
        pushNow();
      });
        return;
      } catch (e) {
        // 截图失败退化为直接 push。
      }
    }
    pushNow();
  }
}
