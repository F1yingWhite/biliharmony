/**
 * 评论富文本正文：表情图、@/空降/BV 跳转文本统一渲染。
 * 从 ReplyCard.ContentParts 拆出，供评论卡与其它富文本场景复用。
 */
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { EmoteImageCache } from '../common/EmoteImageCache';
import { ReplyItem } from '../model/Models';

@Component
export struct ReplyRichText {
  @Prop @Watch('onReplyChanged') reply: ReplyItem = new ReplyItem();
  /** 表情图本地缓存映射：网络 URL → cacheDir 本地路径。 */
  @State emoteLocal: Map<string, string> = new Map<string, string>();
  @Prop fontSize: number = 15;
  @Prop lineHeight: number = 22;
  @Prop emoteSize: number = 16;
  @StorageProp('isDarkMode') isDark: boolean = false;
  onOpenPart: (part: ReplyRenderPart) => void = (part: ReplyRenderPart) => {
  };

  aboutToAppear(): void {
    this.primeEmotes();
  }

  onReplyChanged(): void {
    this.primeEmotes();
  }

  /** 把正文里出现的表情图下载到本地缓存，完成后回填渲染。 */
  private primeEmotes(): void {
    const parts: Array<ReplyRenderPart> = parseReplyContent(this.reply);
    for (let i: number = 0; i < parts.length; i++) {
      const image: string = parts[i].image;
      if (image.length === 0 || this.emoteLocal.has(image)) {
        continue;
      }
      EmoteImageCache.ensure(image).then((local: string) => {
        if (local !== image) {
          this.emoteLocal.set(image, local);
        }
      }).catch(() => {
      });
    }
  }

  private imageSrc(image: string): string {
    if (image.length === 0) return '';
    const local: string | undefined = this.emoteLocal.get(image);
    return local !== undefined && local.length > 0 ? local : image;
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      ForEach(parseReplyContent(this.reply), (part: ReplyRenderPart) => {
        if (part.image.length > 0) {
          Image(this.imageSrc(part.image))
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
