/**
 * 评论富文本正文：表情图、@/空降/BV 跳转文本统一渲染。
 * 从 ReplyCard.ContentParts 拆出，供评论卡与其它富文本场景复用。
 */
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { ReplyItem } from '../model/Models';

@Component
export struct ReplyRichText {
  @Prop reply: ReplyItem = new ReplyItem();
  @Prop fontSize: number = 15;
  @Prop lineHeight: number = 22;
  @Prop emoteSize: number = 16;
  @StorageProp('isDarkMode') isDark: boolean = false;
  onOpenPart: (part: ReplyRenderPart) => void = (part: ReplyRenderPart) => {
  };

  build() {
    // 行内底对齐：表情图底部与文字行底对齐（Text 有 minHeight=lineHeight 兜底），
    // 避免 Center 对齐下表情上下悬空。
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.End }) {
      ForEach(parseReplyContent(this.reply), (part: ReplyRenderPart) => {
        if (part.image.length > 0) {
          Image(part.image)
            .width(part.imageSize > 1 ? this.emoteSize * 2 : this.emoteSize)
            .height(part.imageSize > 1 ? this.emoteSize * 2 : this.emoteSize)
            .objectFit(ImageFit.Contain)
            .margin({ right: 2 })
            // 长评列表中的表情图异步解码（syncLoad=false 即异步）。
            .syncLoad(false)
        } else {
          Text(part.text)
            .fontSize(this.fontSize)
            .lineHeight(this.lineHeight)
            .constraintSize({ minHeight: this.lineHeight })
            .fontColor(part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ?
              '#008AC5' : (this.isDark ? '#F0F0F0' : '#18191C'))
            .priorityGesture(TapGesture().onAction(() => this.onOpenPart(part)))
        }
      }, (part: ReplyRenderPart) => part.key)
    }
    .width('100%')
  }
}
