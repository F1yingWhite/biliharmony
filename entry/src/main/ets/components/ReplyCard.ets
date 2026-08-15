import { promptAction } from '@kit.ArkUI';
import { AppNavStack, ImageViewerParam, NAV_IMAGE_VIEWER, NAV_USER_SPACE, NAV_VIDEO_DETAIL,
  UserSpaceParam, VideoDetailParam } from '../common/AppRouter';
import { PlayerCommandBus } from '../common/PlayerCommandBus';
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { formatDuration, formatRelativeTime } from '../common/Utils';
import { ReplyItem } from '../model/Models';
import { DecoratedAvatar, UserDecorationBanner } from './UserDecorations';
import { biliImageOriginal, biliImageThumbnail } from '../common/ImageUrl';

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
  @Prop isDark: boolean = false;
  @Prop accent: string = '#FB7299';
  /** 所属稿件/动态的 UP 主 mid；评论或回复作者是本人时名字旁标注"UP主"。 */
  @Prop upMid: number = 0;
  onLike: (item: ReplyItem) => void = () => {};
  onDislike: (item: ReplyItem) => void = () => {};
  onShare: (item: ReplyItem) => void = () => {};
  onOpenThread: (item: ReplyItem) => void = () => {};
  onSelectReply: (item: ReplyItem) => void = () => {};
  onToggleThread: (item: ReplyItem) => void = () => {};
  /** Sheet 内导航由宿主先收起 Sheet，再执行实际跳转。 */
  onNavigate: (action: () => void) => void = (action: () => void) => action();
  @State measuredThreadHeight: number = 72;

  private openPart(part: ReplyRenderPart): void {
    if (part.mentionMid > 0) {
      PlayerCommandBus.stop();
      const param: UserSpaceParam = { mid: part.mentionMid };
      this.onNavigate(() => AppNavStack.pushPathByName(NAV_USER_SPACE, param));
    } else if (part.seekSeconds >= 0) {
      PlayerCommandBus.seek(part.seekSeconds);
      promptAction.showToast({ message: '已空降到 ' + formatDuration(part.seekSeconds) });
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
    this.onNavigate(() => AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer));
  }

  private visualDepth(): number {
    return Math.min(3, Math.max(0, this.threadDepth));
  }

  private threadIndent(): number {
    return this.visualDepth() * 18;
  }

  /** 回复头像容器顶部为 5vp、高 38vp；所有树枝统一对齐头像中心。 */
  private treeJoinY(): number {
    return 24;
  }

  private treeGuideX(index: number): number {
    return index * 18 + 9;
  }

  private guideIndexes(): Array<number> {
    const indexes: Array<number> = [];
    for (let i: number = 0; i < this.visualDepth(); i++) indexes.push(i);
    return indexes;
  }

  private guideContinues(index: number): boolean {
    if (this.threadGuides.length === 0) return false;
    if (index === this.visualDepth() - 1) return this.threadGuides[this.threadGuides.length - 1] ?? false;
    return this.threadGuides[index] ?? false;
  }

  private treeLineColor(): string {
    return this.isDark ? '#4A4D54' : '#D3D7DD';
  }

  private treeNodeFillColor(): string {
    return this.isDark ? '#26272B' : '#FFFFFF';
  }

  private locationLabel(): string {
    return this.item.location.replace('IP属地：', '').replace('IP属地:', '').trim();
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
    return this.threadDepth > 0 ? 60 : 78;
  }

  private replyMetaText(): string {
    const location: string = this.locationLabel();
    return formatRelativeTime(this.item.ctime) + (location.length > 0 ? '  IP属地：' + location : '');
  }

  @Builder
  ContentParts(reply: ReplyItem, fontSize: number, lineHeight: number, emoteSize: number) {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      ForEach(parseReplyContent(reply), (part: ReplyRenderPart) => {
        if (part.image.length > 0) {
          Image(part.image)
            .width(part.imageSize > 1 ? emoteSize * 2 : emoteSize)
            .height(part.imageSize > 1 ? emoteSize * 2 : emoteSize)
            .objectFit(ImageFit.Contain)
            .margin({ right: 2 })
        } else {
          Text(part.text)
            .fontSize(fontSize)
            .lineHeight(lineHeight)
            .constraintSize({ minHeight: lineHeight })
            .fontColor(part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ?
              '#008AC5' : (this.isDark ? '#F0F0F0' : '#18191C'))
            .onClick(() => this.openPart(part))
        }
      }, (part: ReplyRenderPart) => part.key)
    }
    .width('100%')
  }

  @Builder
  ReplyPreview() {
    Column({ space: 5 }) {
      ForEach(this.item.replies.slice(0, 2), (reply: ReplyItem) => {
        // 单 Text + Span 让"名字：内容"真正连排，冒号后不再被整行宽度的 Flex 挤到下一行。
        Text() {
          Span(this.upMid > 0 && reply.mid === this.upMid ? 'UP主 ' : '')
            .fontColor(this.accent)
          Span(reply.uname + '：')
            .fontColor('#008AC5')
          ForEach(parseReplyContent(reply), (part: ReplyRenderPart) => {
            if (part.image.length > 0) {
              ImageSpan(part.image)
                .width(18)
                .height(18)
                .objectFit(ImageFit.Contain)
                .verticalAlign(ImageSpanAlignment.CENTER)
            } else {
              Span(part.text)
                .fontColor(part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ?
                  '#008AC5' : (this.isDark ? '#F0F0F0' : '#18191C'))
            }
          }, (part: ReplyRenderPart) => part.key)
        }
        .fontSize(12)
        .lineHeight(18)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      }, (reply: ReplyItem) => String(reply.rpid))
      Text('共 ' + this.item.count + ' 条回复  ›')
        .fontSize(12)
        .fontColor('#008AC5')
        .padding({ top: 2, bottom: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(4)
    .backgroundColor(this.isDark ? '#26272B' : '#F5F7F9')
  }

  @Builder
  ActionBar() {
    Row({ space: this.threadDepth > 0 ? 4 : 8 }) {
      Row({ space: 4 }) {
        Image($r('app.media.ic_like'))
          .width(17)
          .height(17)
          .renderMode(ImageRenderMode.Template)
          .fillColor(this.item.liked ? this.accent : '#9499A0')
        Text(this.item.like > 0 ? String(this.item.like) : '点赞')
          .fontSize(11)
          .fontColor(this.item.liked ? this.accent : '#9499A0')
      }
      .height(30)
      .padding({ left: 4, right: 4 })
      .borderRadius(15)
      .priorityGesture(TapGesture().onAction(() => this.onLike(this.item)))
      Row({ space: 4 }) {
        Image($r('app.media.ic_dislike'))
          .width(16)
          .height(16)
          .renderMode(ImageRenderMode.Template)
          .fillColor(this.item.disliked ? this.accent : '#9499A0')
        Text('点踩')
          .fontSize(11)
          .fontColor(this.item.disliked ? this.accent : '#9499A0')
      }
      .height(30)
      .padding({ left: 4, right: 4 })
      .borderRadius(15)
      .priorityGesture(TapGesture().onAction(() => this.onDislike(this.item)))
      Row({ space: 4 }) {
        Image($r('app.media.ic_share'))
          .width(16)
          .height(16)
          .renderMode(ImageRenderMode.Template)
          .fillColor('#9499A0')
        Text('转发')
          .fontSize(11)
          .fontColor('#9499A0')
      }
      .height(30)
      .padding({ left: 4, right: 4 })
      .borderRadius(15)
      .priorityGesture(TapGesture().onAction(() => this.onShare(this.item)))
      Row({ space: 4 }) {
        Image($r('app.media.ic_comment'))
          .width(16)
          .height(16)
          .renderMode(ImageRenderMode.Template)
          .fillColor('#9499A0')
        Text('回复')
          .fontSize(11)
          .fontColor('#9499A0')
      }
      .height(30)
      .padding({ left: 4, right: 4 })
      .borderRadius(15)
      .priorityGesture(TapGesture().onAction(() => this.onSelectReply(this.item)))
      Blank()
    }
    .width('100%')
    .height(32)
    .id('reply_action_' + String(this.item.rpid) + '_' + String(this.version))
    .alignItems(VerticalAlign.Center)
  }

  /** 回复树连接线：视觉采用原生评论区的实心小圆点，圆点热区可折叠子树。 */
  @Builder
  ThreadTreeLines() {
    ForEach(this.guideIndexes(), (index: number) => {
      if (index < this.visualDepth() - 1 && this.guideContinues(index)) {
        Column()
          .width(1.5)
          .height(this.measuredThreadHeight)
          .borderRadius(0.75)
          .backgroundColor(this.treeLineColor())
          .position({ x: this.treeGuideX(index) - 0.75, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }
      if (index === this.visualDepth() - 1) {
        // 拐角终点严格落在当前层头像左缘，底边与头像中心共用 treeJoinY 基线。
        Row()
          .width(Math.max(1, this.threadIndent() - this.treeGuideX(index) + 0.75))
          .height(this.treeJoinY() + 0.75)
          .border({
            width: { left: 1.5, bottom: 1.5 },
            color: this.treeLineColor(),
            radius: { bottomLeft: 7 },
          })
          .position({ x: this.treeGuideX(index) - 0.75, y: 0 })
          .hitTestBehavior(HitTestMode.None)
        if (this.guideContinues(index)) {
          // 向下多画 16vp 探进下一个兄弟节点的拐角区，吃掉行高测量/行间距的误差，
          // 否则两段线之间会断出一截白缝。
          Column()
            .width(1.5)
            .height(Math.max(0, this.measuredThreadHeight - this.treeJoinY() + 16))
            .borderRadius(0.75)
            .backgroundColor(this.treeLineColor())
            .position({ x: this.treeGuideX(index) - 0.75, y: this.treeJoinY() })
            .hitTestBehavior(HitTestMode.None)
        }
        if (this.threadHasChildren) {
          // 参考 B 站网页版：白底灰边圆钮 + 减号，折叠态变主题色加号；叶节点拐角不画圆点。
          Stack({ alignContent: Alignment.Center }) {
            Circle()
              .width(12)
              .height(12)
              .fill(this.treeNodeFillColor())
              .stroke(this.threadCollapsed ? this.accent : this.treeLineColor())
              .strokeWidth(1.2)
            Row()
              .width(6)
              .height(1.4)
              .backgroundColor(this.threadCollapsed ? this.accent : '#9BA0A8')
            Column()
              .width(1.4)
              .height(6)
              .backgroundColor(this.accent)
              .opacity(this.threadCollapsed ? 1 : 0)
              .scale({ x: 1, y: this.threadCollapsed ? 1 : 0.1 })
              .animation({ duration: 180, curve: Curve.EaseInOut })
          }
          .width(28)
          .height(28)
          .position({ x: this.treeGuideX(index) - 14, y: this.treeJoinY() - 14 })
          .hitTestBehavior(HitTestMode.Block)
          .priorityGesture(TapGesture().onAction(() => this.onToggleThread(this.item)))
        }
      }
    }, (index: number) => 'tree-guide-' + String(this.item.rpid) + '-' + String(index))
  }

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
        this.ContentParts(this.item, this.threadDepth > 0 ? 14 : 15, this.threadDepth > 0 ? 21 : 22,
          this.threadDepth > 0 ? 22 : 24)
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
                .sharedTransition('image-viewer-reply-' + String(this.item.rpid) + '-' + String(index), {
                  duration: 300,
                  curve: Curve.EaseInOut,
                })
                .onClick(() => this.openPicture(index))
            }, (picture: string, index: number) => picture + String(index))
          }
          .width('100%')
        }
        this.ActionBar()
        if (this.showPreview && this.item.count > 0) {
          this.ReplyPreview()
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
        this.ThreadTreeLines()
      }
    }
    .width('100%')
    .padding({ top: this.threadDepth > 0 ? 0 : 12, bottom: this.threadDepth > 0 ? 0 : 12 })
    .border({ width: { bottom: this.threadDepth > 0 ? 0 : 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
    .onClick(() => {
      if (this.showPreview && this.item.count > 0) this.onOpenThread(this.item);
      else this.onSelectReply(this.item);
    })
  }
}
