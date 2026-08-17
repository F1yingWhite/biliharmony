import { AppTheme } from '../common/AppTheme';
import { ReplyActionBar } from './ReplyActionBar';
import { ReplyRichText } from './ReplyRichText';
import { ReplyPreview } from './ReplyPreview';
import { ReplyThreadGuides } from './ReplyThreadGuides';
import { AppNavStack, ImageViewerParam, NAV_IMAGE_VIEWER, NAV_USER_SPACE, NAV_VIDEO_DETAIL,
  UserSpaceParam, VideoDetailParam } from '../common/AppRouter';
import { PlayerCommandBus } from '../common/PlayerCommandBus';
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { formatDuration } from '../common/Utils';
import { formatReplyMeta } from '../common/ReplyMeta';
import { ReplyItem } from '../model/Models';
import { DecoratedAvatar, UserDecorationBanner } from './UserDecorations';
import { biliImageOriginal, biliImageThumbnail } from '../common/ImageUrl';
import { Haptic } from '../common/Haptic';
import { curves } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { BiliApi, ActionResult } from '../api/BiliApi';
import { UserStore } from '../common/UserStore';
import { CommentApi } from '../api/CommentApi';

/** showDialog 按钮声明（promptAction 的 Button 类型不便直接引用）。 */
interface ReportButtonItem {
  text: string;
  color: string;
}

/**
 * 视频评论、动态详情与回复列表共用的完整评论卡片。
 * 头像装扮、富文本、图片、@/空降/BV 跳转和点赞态都只能在这里实现，
 * 避免不同页面的评论能力与视觉继续分叉。
 */
@Component
export struct ReplyCard {
  @Prop item: ReplyItem = new ReplyItem();
  @Prop showPreview: boolean = false;
  @Prop parentLabel: string = '';
  @Prop threadDepth: number = 0;
  @Prop threadGuides: Array<boolean> = [];
  @Prop threadHasChildren: boolean = false;
  @Prop threadCollapsed: boolean = false;
  @Prop version: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  /** 所属稿件/动态的 UP 主 mid；评论或回复作者是本人时名字旁标注"UP主"。 */
  @Prop upMid: number = 0;
  onLike: (item: ReplyItem) => void = () => {};
  onDislike: (item: ReplyItem) => void = () => {};
  onShare: (item: ReplyItem) => void = () => {};
  onOpenThread: (item: ReplyItem) => void = () => {};
  onSelectReply: (item: ReplyItem) => void = () => {};
  onToggleThread: (item: ReplyItem) => void = () => {};
  /** 删除自己的评论成功后由宿主移除该行/子树。 */
  onDeleted: (item: ReplyItem) => void = () => {};
  /** Sheet 内导航由宿主先收起 Sheet，再执行实际跳转。 */
  onNavigate: (action: () => void) => void = (action: () => void) => action();
  @State measuredThreadHeight: number = 72;
  @State likeScale: number = 1;
  @State dislikeScale: number = 1;
  /** 本地镜像：点赞/点踩状态的单一事实源（UI 渲染用这组值，不再依赖 @Prop item 的深拷贝同步，
   * 修复"列表稳定 key 下数据源更新不驱动 UI 刷新"的问题）。 */
  @State mirrorLiked: boolean = false;
  @State mirrorDisliked: boolean = false;
  @State mirrorLike: number = 0;
  private destroyed: boolean = false;
  private likeTimers: Set<number> = new Set<number>();

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 组件销毁或窗口异常时忽略提示。
    }
  }

  aboutToAppear(): void {
    this.destroyed = false;
    this.syncMirrorFromItem();
  }

  private syncMirrorFromItem(): void {
    this.mirrorLiked = this.item.liked;
    this.mirrorDisliked = this.item.disliked;
    this.mirrorLike = this.item.like;
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.likeTimers.forEach((id: number) => clearTimeout(id));
    this.likeTimers.clear();
  }

  private scheduleLikeTimeout(callback: () => void, delayMs: number): void {
    const id: number = setTimeout(() => {
      this.likeTimers.delete(id);
      if (!this.destroyed) callback();
    }, delayMs);
    this.likeTimers.add(id);
  }

  /** 点赞动效：先放大再 spring 回弹；父页面负责真实状态翻转。 */
  private playLikeAnimation(): void {
    Haptic.tap();
    this.getUIContext().animateTo({ duration: 110, curve: Curve.EaseOut }, () => {
      this.likeScale = 1.28;
    });
    this.scheduleLikeTimeout(() => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.7) }, () => {
        this.likeScale = 1;
      });
    }, 110);
  }

  /** 点踩动效：轻微下沉，回弹。 */
  private playDislikeAnimation(): void {
    Haptic.tap();
    this.getUIContext().animateTo({ duration: 110, curve: Curve.EaseOut }, () => {
      this.dislikeScale = 0.8;
    });
    this.scheduleLikeTimeout(() => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.7) }, () => {
        this.dislikeScale = 1;
      });
    }, 110);
  }

  private openPart(part: ReplyRenderPart): void {
    if (part.mentionMid > 0) {
      PlayerCommandBus.stop();
      const param: UserSpaceParam = { mid: part.mentionMid };
      this.onNavigate(() => AppNavStack.pushPathByName(NAV_USER_SPACE, param));
    } else if (part.seekSeconds >= 0) {
      PlayerCommandBus.seek(part.seekSeconds);
      this.getUIContext().getPromptAction().showToast({ message: '已空降到 ' + formatDuration(part.seekSeconds) });
    } else if (part.bvid.length > 0 || part.aid > 0) {
      PlayerCommandBus.stop();
      const param: VideoDetailParam = { bvid: part.bvid, aid: part.aid, title: part.text };
      this.onNavigate(() => AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param));
    }
  }

  private openUser(): void {
    if (this.item.mid <= 0) return;
    PlayerCommandBus.stop();
    const param: UserSpaceParam = { mid: this.item.mid };
    this.onNavigate(() => AppNavStack.pushPathByName(NAV_USER_SPACE, param));
  }

  private openPicture(index: number): void {
    const originals: Array<string> = this.item.pictures.map((url: string) => biliImageOriginal(url));
    const transitionId: string = 'image-viewer-reply-' + String(this.item.rpid) + '-' + String(index);
    const viewer: ImageViewerParam = { images: originals, initialIndex: index, transitionId: transitionId };
    // 一镜到底：关默认转场 + animateTo，geometryTransition 接管
    this.onNavigate(() => this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
      AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer, false);
    }));
  }

  private visualDepth(): number {
    return Math.min(3, Math.max(0, this.threadDepth));
  }

  private threadIndent(): number {
    return this.visualDepth() * 18;
  }

  /** 回复头像容器顶部为 5vp、高 38vp；所有树枝统一对齐头像中心。 */
  private replyMetaText(): string {
    return formatReplyMeta(this.item);
  }

  private shouldShowParentLabel(): boolean {
    if (this.parentLabel.length === 0) return false;
    // 部分回复正文已经由接口返回“回复 @用户名”，移动端再单独占一行会重复且挤压内容。
    return this.item.content.indexOf('@' + this.parentLabel) < 0;
  }

  private decorationHeight(): number {
    return this.threadDepth > 0 ? 34 : 40;
  }

  private decorationReserve(): number {
    if (this.item.cardBackground.length === 0) return 0;
    return this.threadDepth > 0 ? 40 : 48;
  }

  @Builder
  ActionBar() {
    ReplyActionBar({
      mirrorLiked: this.mirrorLiked,
      mirrorDisliked: this.mirrorDisliked,
      mirrorLike: this.mirrorLike,
      likeScale: this.likeScale,
      dislikeScale: this.dislikeScale,
      threadDepth: this.threadDepth,
      onLike: (): void => {
        this.playLikeAnimation();
        if (this.mirrorLiked) {
          this.mirrorLiked = false;
          this.mirrorLike = Math.max(0, this.mirrorLike - 1);
        } else {
          this.mirrorLiked = true;
          this.mirrorLike++;
          this.mirrorDisliked = false;
        }
        this.onLike(this.item);
      },
      onDislike: (): void => {
        this.playDislikeAnimation();
        if (this.mirrorDisliked) {
          this.mirrorDisliked = false;
        } else {
          this.mirrorDisliked = true;
          if (this.mirrorLiked) {
            this.mirrorLiked = false;
            this.mirrorLike = Math.max(0, this.mirrorLike - 1);
          }
        }
        this.onDislike(this.item);
      },
      onShare: (): void => {
        this.onShare(this.item);
      },
      onSelectReply: (): void => {
        this.onSelectReply(this.item);
      },
      onMore: (): void => {
        this.showMoreMenu();
      },
    })
  }


  /** 三点菜单：先给一级菜单（复制/屏蔽/举报或删除），点"举报"才进原因选择，避免一点就直接弹举报。 */
  private showMoreMenu(): void {
    if (this.item.rpid <= 0 || this.item.oid <= 0) {
      this.toast('评论信息不完整，暂不支持操作');
      return;
    }
    const isMine: boolean = UserStore.isLogin && UserStore.current !== null && UserStore.current.mid === this.item.mid;
    const darkText: string = this.isDark ? '#E6E6E6' : '#18191C';
    try {
      if (isMine) {
        this.getUIContext().getPromptAction().showActionMenu({
          title: this.item.content.substring(0, Math.min(18, this.item.content.length)),
          buttons: [
            { text: '复制评论', color: darkText },
            { text: '删除这条评论', color: AppTheme.DANGER },
          ],
        }).then((menuResult) => {
          const pick: number = Number(menuResult.index);
          if (pick === 0) this.copyComment();
          else if (pick === 1) this.deleteOwnComment();
        });
      } else {
        this.getUIContext().getPromptAction().showActionMenu({
          title: this.item.content.substring(0, Math.min(18, this.item.content.length)),
          buttons: [
            { text: '复制评论', color: darkText },
            { text: '屏蔽该用户', color: darkText },
            { text: '举报', color: darkText },
          ],
        }).then((menuResult) => {
          const pick: number = Number(menuResult.index);
          if (pick === 0) this.copyComment();
          else if (pick === 1) this.blockAuthor();
          else if (pick === 2) this.promptReport();
        });
      }
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  /** 复制评论全文到剪贴板。 */
  private copyComment(): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        this.item.content.trim().length > 0 ? this.item.content : '');
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('评论已复制');
      }).catch(() => {
        this.toast('复制失败');
      });
    } catch (e) {
      this.toast('复制失败');
    }
  }

  /** 屏蔽作者：确认后调服务端拉黑，失败给提示。 */
  private blockAuthor(): void {
    if (UserStore.isLogin === false) {
      this.toast('请先登录后再屏蔽');
      return;
    }
    if (this.item.mid <= 0) {
      this.toast('该用户信息不完整，暂不支持屏蔽');
      return;
    }
    BiliApi.blockUser(this.item.mid, true).then((r: ActionResult) => {
      this.toast(r.ok ? '已屏蔽该用户' : r.message);
    }).catch(() => {
      this.toast('屏蔽失败，请稍后重试');
    });
  }

  /** 评论操作：自己的评论可删除；他人评论走举报原因选择。 */
  private promptReport(): void {
    if (this.item.rpid <= 0 || this.item.oid <= 0) {
      this.toast('评论信息不完整，暂不支持操作');
      return;
    }
    const isMine: boolean = UserStore.isLogin && UserStore.current !== null && UserStore.current.mid === this.item.mid;
    const reasons: Array<string> = ['违法违规', '色情低俗', '垃圾广告', '人身攻击', '引战引流量', '剧透', '其他'];
    const values: Array<string> = ['21', '22', '23', '24', '25', '26', '99'];
    const buttons: Array<ReportButtonItem> = [];
    if (isMine) {
      buttons.push({ text: '删除这条评论', color: AppTheme.DANGER });
    } else {
      for (let i: number = 0; i < reasons.length; i++) {
        buttons.push({ text: reasons[i], color: this.isDark ? '#CCFFFFFF' : '#18191C' });
      }
    }
    buttons.push({ text: '取消', color: '#9499A0' });
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: isMine ? '评论管理' : '举报评论',
        message: this.item.content.substring(0, Math.min(24, this.item.content.length)),
        buttons: buttons,
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        if (isMine) {
          if (pick !== 0) return;
          this.deleteOwnComment();
          return;
        }
        if (pick < 0 || pick >= reasons.length) return;
        if (UserStore.isLogin === false) {
          this.toast('请先登录后再举报评论');
          return;
        }
        CommentApi.reportReply(this.item.oid, this.item.type, this.item.rpid, values[pick])
          .then((r: ActionResult) => {
            this.toast(r.ok ? '已提交举报，感谢反馈' : r.message);
          })
          .catch(() => {
            this.toast('举报失败，请稍后重试');
          });
      });
    } catch (e) {
      // 组件销毁或窗口异常时忽略。
    }
  }

  /** 删除自己的评论：二次确认后调服务端删除，成功交给宿主移除该行。 */
  private deleteOwnComment(): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除评论',
        message: '删除后无法恢复，确定删除这条评论吗？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '删除', color: AppTheme.DANGER },
        ],
      }).then((dialogResult) => {
        if (Number(dialogResult.index) !== 1) return;
        CommentApi.deleteReply(this.item.oid, this.item.type, this.item.rpid)
          .then((r: ActionResult) => {
            if (r.ok) {
              this.toast('评论已删除');
              this.onDeleted(this.item);
            } else {
              this.toast(r.message);
            }
          })
          .catch(() => {
            this.toast('删除失败，请稍后重试');
          });
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  /** 回复树连接线：视觉采用原生评论区的实心小圆点，圆点热区可折叠子树。 */
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: this.threadDepth > 0 ? 8 : 10 }) {
        DecoratedAvatar({
          face: this.item.avatar,
          pendant: this.item.pendant,
          avatarSize: this.threadDepth > 0 ? 30 : 38,
          containerSize: this.threadDepth > 0 ? 38 : 50,
        })
          .priorityGesture(TapGesture().onAction(() => this.openUser()))
        Column({ space: this.threadDepth > 0 ? 4 : 5 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          if (this.item.cardBackground.length > 0) {
            UserDecorationBanner({
              imageUrl: this.item.cardBackground,
              numberPrefix: this.item.cardNumberPrefix,
              numberText: this.item.cardNumber,
              numberColor: this.item.cardNumberColor.length > 0 ? this.item.cardNumberColor : '#FFFFFF',
              bannerHeight: this.decorationHeight(),
            })
          }
          Column({ space: 2 }) {
            Row({ space: 6 }) {
              Text(this.item.uname)
                .fontSize(this.threadDepth > 0 ? 13 : 14)
                .fontColor(this.item.nameColor.length > 0 ? this.item.nameColor : (this.isDark ? '#D0D0D0' : '#61666D'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.item.level > 0) {
                Text('LV' + this.item.level)
                  .fontSize(9)
                  .fontColor(this.accent)
                  .border({ width: 0.5, color: this.accent, radius: 2 })
                  .padding({ left: 2, right: 2 })
              }
              if (this.upMid > 0 && this.item.mid === this.upMid) {
                Text('UP主')
                  .fontSize(9)
                  .fontColor('#FFFFFF')
                  .backgroundColor(this.accent)
                  .borderRadius(2)
                  .padding({ left: 3, right: 3 })
              }
              if (this.item.nameplate.length > 0) {
                Image(this.item.nameplate).width(30).height(15).objectFit(ImageFit.Contain)
              }
            }
            .height(18)
            .alignItems(VerticalAlign.Center)
            Text(this.replyMetaText())
              .fontSize(10)
              .fontColor('#9499A0')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .height(this.decorationHeight())
          .padding({ right: this.decorationReserve() })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height(this.decorationHeight())
        if (this.shouldShowParentLabel()) {
          Text('回复 @' + this.parentLabel)
            .fontSize(11)
            .fontColor('#008AC5')
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor(this.isDark ? '#26343C' : '#EAF5FA')
        }
        ReplyRichText({
          reply: this.item,
          fontSize: this.threadDepth > 0 ? 14 : 15,
          lineHeight: this.threadDepth > 0 ? 21 : 22,
          emoteSize: this.threadDepth > 0 ? 22 : 24,
          onOpenPart: (part: ReplyRenderPart): void => {
            this.openPart(part);
          },
        })
        if (this.item.pictures.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.item.pictures, (picture: string, index: number) => {
              Image(biliImageThumbnail(picture, this.item.pictures.length === 1 ? 640 : 320))
                .width(this.item.pictures.length === 1 ? 190 : 92)
                .height(this.item.pictures.length === 1 ? 150 : 92)
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .margin({ right: 5, bottom: 5 })
                .id('reply-img-' + String(this.item.rpid) + '-' + String(index))
                .geometryTransition('image-viewer-reply-' + String(this.item.rpid) + '-' + String(index))
                // 评论附图异步解码，长列表滚动不卡。
                .syncLoad(false)
                .priorityGesture(TapGesture().onAction(() => this.openPicture(index)))
            }, (picture: string, index: number) => picture + String(index))
          }
          .width('100%')
        }
        this.ActionBar()
        if (this.showPreview && this.item.count > 0) {
          ReplyPreview({
          reply: this.item,
          upMid: this.upMid,
          onOpenThread: (): void => {
            this.onOpenThread(this.item);
          },
        })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: this.threadIndent(), top: this.threadDepth > 0 ? 5 : 0,
        bottom: this.threadDepth > 0 ? 5 : 0 })
      .onAreaChange((oldValue: Area, newValue: Area) => {
        if (this.threadDepth <= 0) return;
        const height: number = Number.parseFloat(String(newValue.height));
        if (Number.isFinite(height) && height > 0 && Math.abs(height - this.measuredThreadHeight) > 0.5) {
          this.measuredThreadHeight = height;
        }
      })
      // 连接线和折叠节点最后绘制，避免被整行评论覆盖而无法点击。
      if (this.threadDepth > 0) {
        ReplyThreadGuides({
          threadDepth: this.threadDepth,
          threadGuides: this.threadGuides,
          threadHasChildren: this.threadHasChildren,
          threadCollapsed: this.threadCollapsed,
          measuredHeight: this.measuredThreadHeight,
          onToggle: (): void => {
            this.onToggleThread(this.item);
          },
        })
      }
    }
    .width('100%')
    .padding({ top: this.threadDepth > 0 ? 0 : 12, bottom: this.threadDepth > 0 ? 0 : 12 })
    .border({ width: { bottom: this.threadDepth > 0 ? 0 : 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
    .onClick((event: ClickEvent) => {
      if (this.showPreview && this.item.count > 0) this.onOpenThread(this.item);
      else this.onSelectReply(this.item);
    })
  }
}
