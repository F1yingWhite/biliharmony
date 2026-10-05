/**
 * 评论富文本正文：表情图、@/空降/BV 跳转文本统一渲染。
 * 从 ReplyCard.ContentParts 拆出，供评论卡与其它富文本场景复用。
 *
 * 视觉必须走 Text + Span/ImageSpan 行内流（与 ReplyPreview/ReplyComposer 一致）：
 * 旧实现是 Flex(Wrap) 里塞独立 Text/Image item。Flex 会把整段多行 Text 当成
 * 一个高 item，表情作为下一个 flex item 必然落到新行——行尾哪怕还有空位，
 * 表情也会"莫名其妙单独成一行"。行内流下表情与文字同流排版，换行与官方一致。
 *
 * 点击交给 Span 原生命中，跟随真实字形、换行和表情排版。Text 只记录触摸移动，
 * 防止滚动或长按复制后的同一触点顺带打开链接，不再估算文字点击区域。
 */
import { parseReplyContent, ReplyRenderPart } from '../../common/ReplyContentParser';
import { EmoteImageCache } from '../../common/EmoteImageCache';
import { ReplyItem } from '../../model/Models';

@Component
export struct ReplyRichText {
  @Prop @Watch('onReplyChanged') reply: ReplyItem = new ReplyItem();
  /** 表情图本地缓存映射：网络 URL → cacheDir 本地路径。 */
  @State emoteLocal: Map<string, string> = new Map<string, string>();
  @Prop fontSize: number = 15;
  @Prop lineHeight: number = 22;
  /** 确认加载失败的表情 URL：回退渲染 [表情名] 文字，避免行内留下空白。
   *  ImageSpan 没有 onError，失败判定来自 EmoteImageCache.ensure() 的结果。 */
  @State emoteFailed: Set<string> = new Set<string>();
  /** 纯文本按实际约束宽度测出的高度（vp），用于规避部分真机多预留两行的 Text 固有高度。 */
  @State plainHeight: number = 0;
  @Prop emoteSize: number = 16;
  @StorageProp('isDarkMode') isDark: boolean = false;
  onOpenPart: (part: ReplyRenderPart) => void = (part: ReplyRenderPart) => {
  };
  onLongPress: () => void = () => {
  };
  /** 触点按下坐标：判断"点按"还是"划过/滚动"，避免划动松手误触发跳转。 */
  private tapDownX: number = 0;
  private tapDownY: number = 0;
  private tapDownValid: boolean = false;
  private tapMoved: boolean = false;
  private actionGeneration: number = 0;
  /** 长按已处理后吞掉同一触点的 Up，避免顺带打开 @/时间点/BV 链接。 */
  private longPressHandled: boolean = false;

  aboutToAppear(): void {
    this.primeEmotes();
  }

  onReplyChanged(): void {
    this.actionGeneration++;
    this.tapDownValid = false;
    this.tapMoved = false;
    this.longPressHandled = false;
    this.plainHeight = 0;
    this.primeEmotes();
  }

  aboutToDisappear(): void {
    this.actionGeneration++;
    this.tapDownValid = false;
  }

  /** 把正文里出现的表情图下载到本地缓存；成功回填 ImageSpan 本地路径，
   *  失败记入 emoteFailed 由 [表情名] 文字接管渲染。 */
  private primeEmotes(): void {
    const parts: Array<ReplyRenderPart> = parseReplyContent(this.reply);
    for (let i: number = 0; i < parts.length; i++) {
      const image: string = parts[i].image;
      if (image.length === 0 || this.emoteLocal.has(image) || this.emoteFailed.has(image)) {
        continue;
      }
      const cached: string = EmoteImageCache.localPathOf(image);
      if (cached !== image) {
        const nextCached: Map<string, string> = new Map<string, string>(this.emoteLocal);
        nextCached.set(image, cached);
        this.emoteLocal = nextCached;
        continue;
      }
      EmoteImageCache.ensure(image).then((local: string) => {
        if (local !== image) {
          const nextLocal: Map<string, string> = new Map<string, string>(this.emoteLocal);
          nextLocal.set(image, local);
          this.emoteLocal = nextLocal;
        } else {
          const nextFailed: Set<string> = new Set<string>(this.emoteFailed);
          nextFailed.add(image);
          this.emoteFailed = nextFailed;
        }
      }).catch((): void => {
        const nextFailed: Set<string> = new Set<string>(this.emoteFailed);
        nextFailed.add(image);
        this.emoteFailed = nextFailed;
      });
    }
  }

  /** ImageSpan 源：只读本地缓存，未就绪保持原有尺寸占位。 */
  private emoteSrc(image: string): string {
    const local: string | undefined = this.emoteLocal.get(image);
    if (local !== undefined && local.length > 0) return local;
    const cached: string = EmoteImageCache.localPathOf(image);
    return cached !== image ? cached : '';
  }

  private plainColor(): string {
    return this.isDark ? '#F0F0F0' : '#18191C';
  }

  private linkColor(): string {
    return '#008AC5';
  }

  private isClickable(part: ReplyRenderPart): boolean {
    return part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ||
      part.url.length > 0;
  }

  private spanClick(part: ReplyRenderPart): () => void {
    const generation: number = this.actionGeneration;
    const oid: number = this.reply.oid;
    const type: number = this.reply.type;
    const rpid: number = this.reply.rpid;
    const key: string = part.key;
    return (): void => {
      if (generation !== this.actionGeneration || oid !== this.reply.oid || type !== this.reply.type ||
        rpid !== this.reply.rpid || this.tapMoved || this.longPressHandled) return;
      const current: ReplyRenderPart | undefined = parseReplyContent(this.reply)
        .find((value: ReplyRenderPart): boolean => value.key === key);
      if (current !== undefined && this.isClickable(current)) this.onOpenPart(current);
    };
  }

  private isPlainContent(): boolean {
    const parts: Array<ReplyRenderPart> = parseReplyContent(this.reply);
    return parts.length === 1 && parts[0].image.length === 0 && !this.isClickable(parts[0]);
  }

  private plainContent(): string {
    const parts: Array<ReplyRenderPart> = parseReplyContent(this.reply);
    return parts.length === 1 ? parts[0].text : '';
  }

  private handleLongPress(): void {
    this.longPressHandled = true;
    this.tapDownValid = false;
    this.onLongPress();
  }

  /** 纯表情 Text 没有文字基线时，部分真机会把整行测成零高度。 */
  private isImageOnlyContent(): boolean {
    const parts: Array<ReplyRenderPart> = parseReplyContent(this.reply);
    if (parts.length === 0) return false;
    for (let i: number = 0; i < parts.length; i++) {
      if (parts[i].image.length === 0) return false;
    }
    return true;
  }

  private richContentMinHeight(): number {
    const parts: Array<ReplyRenderPart> = parseReplyContent(this.reply);
    let height: number = this.lineHeight;
    for (let i: number = 0; i < parts.length; i++) {
      if (parts[i].image.length > 0) {
        height = Math.max(height, parts[i].imageSize > 1 ? this.emoteSize * 2 : this.emoteSize);
      }
    }
    return height;
  }

  private measurePlainHeight(width: number): void {
    if (width <= 0) return;
    try {
      const measured = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: this.plainContent(),
        constraintWidth: width,
        fontSize: this.fontSize,
        lineHeight: this.lineHeight,
      });
      const height: number = Math.max(this.lineHeight, this.getUIContext().px2vp(Number(measured.height)));
      if (Number.isFinite(height) && Math.abs(height - this.plainHeight) > 0.5) {
        this.plainHeight = height;
      }
    } catch (e) {
      // 测量 API 异常时保留 Text 自适应高度，不影响正文显示。
    }
  }

  build() {
    if (this.isPlainContent()) {
      // 纯文本不进入 Span/ForEach 测量路径；部分真机上后者会为一行文字错误预留数行高度。
      Text(this.plainContent())
        .fontSize(this.fontSize)
        .fontColor(this.plainColor())
        .lineHeight(this.lineHeight)
        .width('100%')
        .height(this.plainHeight > 0 ? this.plainHeight : undefined)
        .onAreaChange((_o: Area, n: Area): void => {
          this.measurePlainHeight(Number(n.width));
        })
        .gesture(
          LongPressGesture({ fingers: 1, repeat: false, duration: 450 })
            .onAction((): void => this.handleLongPress())
        )
    } else {
      Text() {
        if (this.isImageOnlyContent()) {
          // ImageSpanAlignment.BOTTOM 依赖文本基线；零宽字符只提供基线，不产生可见内容或额外宽度。
          Span('\u200B')
            .fontSize(this.fontSize)
        }
        ForEach(parseReplyContent(this.reply), (part: ReplyRenderPart) => {
          if (part.image.length > 0 && this.emoteFailed.has(part.image)) {
            // 加载失败：[表情名] 文字兜底（与旧版回退一致），避免行内空白块。
            Span(part.imageLabel.length > 0 ? part.imageLabel : '[表情]')
              .fontColor(this.plainColor())
          } else if (part.image.length > 0) {
            // 已缓存走本地路径（弱网/离线也可显示）；下载中先用网络 URL 直出，
            // 完成后切本地路径（同一张图，无跳变）。
            // 底部对齐：表情图底边与文字行底对齐（官方观感），而非垂直居中。
            ImageSpan(this.emoteSrc(part.image))
              .width(part.imageSize > 1 ? this.emoteSize * 2 : this.emoteSize)
              .height(part.imageSize > 1 ? this.emoteSize * 2 : this.emoteSize)
              .objectFit(ImageFit.Contain)
              .verticalAlign(ImageSpanAlignment.BOTTOM)
          } else {
            Span(part.text)
              .fontColor(this.isClickable(part) ? this.linkColor() : this.plainColor())
              .onClick(this.spanClick(part))
          }
        }, (part: ReplyRenderPart) => part.key + ':' + String(this.actionGeneration))
      }
      .fontSize(this.fontSize)
      .lineHeight(this.lineHeight)
      .width('100%')
      .constraintSize({ minHeight: this.richContentMinHeight() })
      .onTouch((ev: TouchEvent): void => {
        if (ev.type === TouchType.Down) {
          const d: TouchObject = ev.touches[0];
          this.tapDownX = d.x;
          this.tapDownY = d.y;
          this.tapDownValid = true;
          this.tapMoved = false;
          this.longPressHandled = false;
          return;
        }
        if (ev.type === TouchType.Cancel) {
          this.tapDownValid = false;
          this.tapMoved = true;
          return;
        }
        if ((ev.type !== TouchType.Move && ev.type !== TouchType.Up) || !this.tapDownValid) {
          return;
        }
        const t: TouchObject = ev.touches[0];
        // Keep these flags through Up: native Span.onClick may follow Text.onTouch.
        if (Math.abs(t.x - this.tapDownX) > 10 || Math.abs(t.y - this.tapDownY) > 10) {
          this.tapMoved = true;
        }
        if (ev.type === TouchType.Up) this.tapDownValid = false;
      })
      .gesture(
        LongPressGesture({ fingers: 1, repeat: false, duration: 450 })
          .onAction((): void => this.handleLongPress())
      )
    }
  }
}
