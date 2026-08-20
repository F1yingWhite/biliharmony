/**
 * 评论富文本正文：表情图、@/空降/BV 跳转文本统一渲染。
 * 从 ReplyCard.ContentParts 拆出，供评论卡与其它富文本场景复用。
 *
 * 视觉必须走 Text + Span/ImageSpan 行内流（与 ReplyPreview/ReplyComposer 一致）：
 * 旧实现是 Flex(Wrap) 里塞独立 Text/Image item。Flex 会把整段多行 Text 当成
 * 一个高 item，表情作为下一个 flex item 必然落到新行——行尾哪怕还有空位，
 * 表情也会"莫名其妙单独成一行"。行内流下表情与文字同流排版，换行与官方一致。
 *
 * 点击：本 SDK 无 onSpanClick / 文本测量 API，无法按 span 命中。改为 Text 整体
 *  onTouch + 轻量布局模拟：CJK 全角=fontSize、半角≈0.52*fontSize、表情=emoteSize，
 * 按 contentWidth 模拟折行并记录每个片段占用的 (行号, x 区间)。lineHeight 固定，
 * y/lineHeight 精确落到行号，x 在行内区间判定，足够命中 @/空降/BV 这类短片段。
 */
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { EmoteImageCache } from '../common/EmoteImageCache';
import { ReplyItem } from '../model/Models';

/** 点击命中所需的片段布局盒：segs 为 [行号, startX, endX, 行号, startX, endX, ...]。 */
class PartHit {
  part: ReplyRenderPart = new ReplyRenderPart();
  segs: number[] = [];
}

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
  @Prop emoteSize: number = 16;
  @StorageProp('isDarkMode') isDark: boolean = false;
  onOpenPart: (part: ReplyRenderPart) => void = (part: ReplyRenderPart) => {
  };
  /** 正文宽度（vp）：onAreaChange 提供，布局模拟与点击命中都需要。 */
  private contentWidth: number = 0;
  private hits: PartHit[] = [];
  /** 各行实际高度（vp）：含 2x 大表情的行会比 lineHeight 高，命中测试按累计行顶落行。 */
  private lineHeights: number[] = [];
  /** 触点按下坐标：判断"点按"还是"划过/滚动"，避免划动松手误触发跳转。 */
  private tapDownX: number = 0;
  private tapDownY: number = 0;
  private tapDownValid: boolean = false;

  aboutToAppear(): void {
    this.primeEmotes();
  }

  onReplyChanged(): void {
    this.primeEmotes();
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
      EmoteImageCache.ensure(image).then((local: string) => {
        if (local !== image) {
          this.emoteLocal.set(image, local);
        } else {
          this.emoteFailed.add(image);
        }
      }).catch((): void => {
        this.emoteFailed.add(image);
      });
    }
  }

  private isFullWidth(code: number): boolean {
    return code > 0x2E7F;
  }

  private charWidth(code: number): number {
    return this.isFullWidth(code) ? this.fontSize : this.fontSize * 0.52;
  }

  /** 模拟行内折行，记录每个片段占用的 (行号, x 区间)，供 onTouch 命中。
   *  大表情会让所在行变高，lineHeights 按行累计用于 y→行号 的精确落行。 */
  private rebuildHits(): void {
    if (this.contentWidth <= 0) {
      this.hits = [];
      this.lineHeights = [];
      return;
    }
    const parts: Array<ReplyRenderPart> = parseReplyContent(this.reply);
    this.hits = [];
    this.lineHeights = [this.lineHeight];
    let line: number = 0;
    let x: number = 0;
    for (let pi: number = 0; pi < parts.length; pi++) {
      const part: ReplyRenderPart = parts[pi];
      const hit: PartHit = new PartHit();
      hit.part = part;
      if (part.image.length > 0) {
        const w: number = part.imageSize > 1 ? this.emoteSize * 2 : this.emoteSize;
        if (x > 0 && x + w > this.contentWidth) {
          line++;
          x = 0;
          this.lineHeights.push(this.lineHeight);
        }
        if (w > this.lineHeights[line]) {
          this.lineHeights[line] = w;
        }
        hit.segs.push(line, x, x + w);
        x += w;
      } else {
        let segLine: number = line;
        let segStart: number = x;
        for (let ci: number = 0; ci < part.text.length; ci++) {
          const code: number = part.text.charCodeAt(ci);
          if (code === 10) {
            if (x > segStart) {
              hit.segs.push(segLine, segStart, x);
            }
            line++;
            x = 0;
            this.lineHeights.push(this.lineHeight);
            segLine = line;
            segStart = 0;
            continue;
          }
          const w: number = this.charWidth(code);
          if (x > 0 && x + w > this.contentWidth) {
            hit.segs.push(segLine, segStart, x);
            line++;
            x = 0;
            this.lineHeights.push(this.lineHeight);
            segLine = line;
            segStart = 0;
          }
          x += w;
        }
        if (x > segStart) {
          hit.segs.push(segLine, segStart, x);
        }
      }
      this.hits.push(hit);
    }
  }

  /** ty（相对 Text 顶）→ 行号：按 lineHeights 累计行高向下落，兼容大表情增高行。 */
  private lineAt(ty: number): number {
    let y: number = ty;
    for (let i: number = 0; i < this.lineHeights.length; i++) {
      if (y < this.lineHeights[i]) {
        return i;
      }
      y -= this.lineHeights[i];
    }
    return -1;
  }

  private hitAt(tx: number, ty: number): ReplyRenderPart | null {
    if (this.hits.length === 0 || this.lineHeights.length === 0) {
      return null;
    }
    const line: number = this.lineAt(ty);
    if (line < 0) {
      return null;
    }
    for (let hi: number = 0; hi < this.hits.length; hi++) {
      const segs: number[] = this.hits[hi].segs;
      for (let s: number = 0; s + 2 < segs.length; s += 3) {
        if (segs[s] === line && tx >= segs[s + 1] && tx < segs[s + 2]) {
          return this.hits[hi].part;
        }
      }
    }
    return null;
  }

  /** ImageSpan 源：本地缓存路径优先，未就绪回退网络 URL。 */
  private emoteSrc(image: string): string {
    const local: string | undefined = this.emoteLocal.get(image);
    return local !== undefined && local.length > 0 ? local : image;
  }

  private plainColor(): string {
    return this.isDark ? '#F0F0F0' : '#18191C';
  }

  private linkColor(): string {
    return '#008AC5';
  }

  private isClickable(part: ReplyRenderPart): boolean {
    return part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0;
  }

  build() {
    Text() {
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
        }
      }, (part: ReplyRenderPart) => part.key)
    }
    .fontSize(this.fontSize)
    .lineHeight(this.lineHeight)
    .width('100%')
    .onAreaChange((_o: Area, n: Area): void => {
      this.contentWidth = Number(n.width);
      this.rebuildHits();
    })
    .onTouch((ev: TouchEvent): void => {
      if (ev.type === TouchType.Down) {
        const d: TouchObject = ev.touches[0];
        this.tapDownX = d.x;
        this.tapDownY = d.y;
        this.tapDownValid = true;
        return;
      }
      if (ev.type !== TouchType.Up || !this.tapDownValid) {
        return;
      }
      this.tapDownValid = false;
      const t: TouchObject = ev.touches[0];
      // 位移超过 10vp 视为划动/滚动，不触发跳转
      if (Math.abs(t.x - this.tapDownX) > 10 || Math.abs(t.y - this.tapDownY) > 10) {
        return;
      }
      const part: ReplyRenderPart | null = this.hitAt(t.x, t.y);
      if (part !== null && this.isClickable(part)) {
        this.onOpenPart(part);
      }
    })
  }
}
