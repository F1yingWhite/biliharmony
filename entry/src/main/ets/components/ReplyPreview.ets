/**
 * 楼中楼预览：前两条回复 + “共 N 条回复 ›”，点击进入完整楼中楼。
 * 从 ReplyCard.ReplyPreview 拆出，让评论卡只保留主结构。
 */
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { ReplyItem } from '../model/Models';

@Component
export struct ReplyPreview {
  @Prop reply: ReplyItem = new ReplyItem();
  @Prop upMid: number = 0;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onOpenThread: () => void = () => {};

  build() {
    Column({ space: 5 }) {
      ForEach(this.reply.replies.slice(0, 2), (reply: ReplyItem) => {
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
                .verticalAlign(ImageSpanAlignment.BOTTOM)
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
      Text('共 ' + this.reply.count + ' 条回复  ›')
        .fontSize(12)
        .fontColor('#008AC5')
        .padding({ top: 2, bottom: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(4)
    .backgroundColor(this.isDark ? '#26272B' : '#F5F7F9')
    .onClick(() => this.onOpenThread())
  }
}
