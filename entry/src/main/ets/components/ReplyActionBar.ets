/**
 * 评论卡片底部操作条：点赞/点踩/转发/回复/更多。
 * 只负责展示与手指回调，状态仍由宿主 ReplyCard 管理，避免复用卡片时本地状态失同步。
 */
import { Haptic } from '../common/Haptic';

@Component
export struct ReplyActionBar {
  @Prop mirrorLiked: boolean = false;
  @Prop mirrorDisliked: boolean = false;
  @Prop mirrorLike: number = 0;
  @Prop likeScale: number = 1;
  @Prop dislikeScale: number = 1;
  @Prop threadDepth: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onLike: () => void = () => {};
  onDislike: () => void = () => {};
  onShare: () => void = () => {};
  onSelectReply: () => void = () => {};
  onMore: () => void = () => {};

  @Builder
  LikeButton() {
    Row({ space: 4 }) {
      Image($r('app.media.ic_like'))
        .width(17)
        .height(17)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.mirrorLiked ? this.accent : '#9499A0')
        .scale({ x: this.likeScale, y: this.likeScale })
      Text(this.mirrorLike > 0 ? String(this.mirrorLike) : '点赞')
        .fontSize(11)
        .fontColor(this.mirrorLiked ? this.accent : '#9499A0')
    }
    .height(30)
    .padding({ left: 6, right: 6 })
    .borderRadius(15)
    .backgroundColor('#00000000')
    .stateStyles({
      pressed: {
        .backgroundColor(this.isDark ? '#33FFFFFF' : '#12000000')
        .scale({ x: 0.94, y: 0.94 })
      },
    })
    .priorityGesture(TapGesture().onAction(() => {
      Haptic.tap();
      this.onLike();
    }))
  }

  @Builder
  DislikeButton() {
    Row({ space: 4 }) {
      Image($r('app.media.ic_dislike'))
        .width(16)
        .height(16)
        .renderMode(ImageRenderMode.Template)
        .fillColor(this.mirrorDisliked ? this.accent : '#9499A0')
        .scale({ x: this.dislikeScale, y: this.dislikeScale })
      Text('点踩')
        .fontSize(11)
        .fontColor(this.mirrorDisliked ? this.accent : '#9499A0')
    }
    .height(30)
    .padding({ left: 6, right: 6 })
    .borderRadius(15)
    .backgroundColor('#00000000')
    .stateStyles({
      pressed: {
        .backgroundColor(this.isDark ? '#33FFFFFF' : '#12000000')
        .scale({ x: 0.94, y: 0.94 })
      },
    })
    .priorityGesture(TapGesture().onAction(() => {
      Haptic.tap();
      this.onDislike();
    }))
  }

  @Builder
  ShareButton() {
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
    .padding({ left: 6, right: 6 })
    .borderRadius(15)
    .backgroundColor('#00000000')
    .stateStyles({
      pressed: {
        .backgroundColor(this.isDark ? '#33FFFFFF' : '#12000000')
        .scale({ x: 0.94, y: 0.94 })
      },
    })
    .priorityGesture(TapGesture().onAction(() => {
      Haptic.tap();
      this.onShare();
    }))
  }

  @Builder
  ReplyButton() {
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
    .padding({ left: 6, right: 6 })
    .borderRadius(15)
    .backgroundColor('#00000000')
    .stateStyles({
      pressed: {
        .backgroundColor(this.isDark ? '#33FFFFFF' : '#12000000')
        .scale({ x: 0.94, y: 0.94 })
      },
    })
    .priorityGesture(TapGesture().onAction(() => {
      Haptic.tap();
      this.onSelectReply();
    }))
  }

  @Builder
  MoreButton() {
    Row({ space: 4 }) {
      Image($r('app.media.ic_more'))
        .width(16)
        .height(16)
        .renderMode(ImageRenderMode.Template)
        .fillColor('#9499A0')
    }
    .height(30)
    .padding({ left: 6, right: 6 })
    .borderRadius(15)
    .backgroundColor('#00000000')
    .stateStyles({
      pressed: {
        .backgroundColor(this.isDark ? '#33FFFFFF' : '#12000000')
        .scale({ x: 0.94, y: 0.94 })
      },
    })
    .priorityGesture(TapGesture().onAction(() => {
      Haptic.tap();
      this.onMore();
    }))
  }

  build() {
    Row({ space: this.threadDepth > 0 ? 4 : 8 }) {
      this.LikeButton()
      this.DislikeButton()
      this.ShareButton()
      this.ReplyButton()
      this.MoreButton()
      Blank()
    }
    .width('100%')
    .height(32)
    .alignItems(VerticalAlign.Center)
  }
}