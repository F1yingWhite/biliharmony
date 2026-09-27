/**
 * 评论分享卡：对齐 B 站 App 的"评论分享成图片"体验。
 * 白底卡片（头像/昵称/UP主标/时间/正文/图片/点赞数），底部 App 标识 + 二维码。
 * 由各页面用离屏 @Builder 渲染后经 componentSnapshot 截成图片。
 */
import { image } from '@kit.ImageKit';
import { UIContext, window } from '@kit.ArkUI';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { ReplyItem } from '../../model/Models';
import { CommentLog } from '../../common/CommentLog';
import { ReplySharePage, ReplyShareLine, ReplyShareRun, REPLY_SHARE_BRAND,
  REPLY_SHARE_WIDTH } from './ReplyShareLayout';

/** 生成评论分享二维码；失败时返回 null，卡片使用 ArkUI QRCode 本地生成同一地址。 */
export async function makeReplyQr(content: string): Promise<image.PixelMap | null> {
  try {
    return await generateBarcode.createBarcode(content, {
      scanType: scanCore.ScanType.QR_CODE,
      width: 240,
      height: 240,
      margin: 4,
      level: generateBarcode.ErrorCorrectionLevel.LEVEL_M,
    });
  } catch (e) {
    return null;
  }
}

export class ReplyShareBounds {
  width: number = REPLY_SHARE_WIDTH;
  height: number = 720;
}

/** Offscreen builder roots inherit the actual app window, including split-screen dimensions. */
export async function getReplyShareBounds(uiContext: UIContext): Promise<ReplyShareBounds> {
  const name: string | undefined = uiContext.getWindowName();
  const host = uiContext.getHostContext();
  if (host === undefined) throw new Error('无法获取当前窗口，请重试');
  const appWindow: window.Window = name !== undefined && name.length > 0 ? window.findWindow(name) :
    await window.getLastWindow(host);
  const rect: window.Rect = appWindow.getWindowProperties().windowRect;
  const bounds: ReplyShareBounds = new ReplyShareBounds();
  // Leave room for window insets and native root rounding; scale only changes raster resolution.
  bounds.width = Math.min(REPLY_SHARE_WIDTH, Math.floor(uiContext.px2vp(rect.width) - 24));
  bounds.height = Math.floor(uiContext.px2vp(rect.height) - 96);
  if (bounds.width < 280 || bounds.height < 500) {
    throw new Error('当前窗口过小，请放大窗口后生成分享图片');
  }
  return bounds;
}

async function validateReplyShareSnapshot(pixelMap: image.PixelMap, width: number,
  height: number): Promise<image.PixelMap> {
  try {
    const info: image.ImageInfo = await pixelMap.getImageInfo();
    if (Math.abs(info.size.width - Math.round(width)) <= 1 &&
      Math.abs(info.size.height - Math.round(height)) <= 1) return pixelMap;
  } catch (e) {
    CommentLog.warn('share.snapshot.size', CommentLog.errorText(e as Object));
  }
  try { await pixelMap.release(); } catch (e) {}
  throw new Error('评论图片尺寸不完整，请重试');
}
/**
 * 等待在线图片全部解码后截图；重试后仍不完整则明确失败，避免生成缺少附图的成功分享图。
 */
export async function makeReplyShareSnapshot(uiContext: UIContext, builder: CustomBuilder,
  height: number = 720, width: number = REPLY_SHARE_WIDTH): Promise<image.PixelMap> {
  let maxWidth: number = 4096;
  let maxHeight: number = 4096;
  try {
    const limit = uiContext.getComponentSnapshot().getSizeLimitation();
    if (limit.maxWidth > 0) maxWidth = limit.maxWidth;
    if (limit.maxHeight > 0) maxHeight = limit.maxHeight;
  } catch (e) {
    // Older devices do not expose the limit query; keep a conservative pixel-size fallback.
  }
  const scale: number = Math.min(1, maxWidth / uiContext.vp2px(width),
    maxHeight / uiContext.vp2px(Math.max(1, height)));
  let pixelMap: image.PixelMap;
  try {
    pixelMap = await uiContext.getComponentSnapshot().createFromBuilder(builder, 500, true,
      { waitUntilRenderFinished: true, scale: scale });
  } catch (e) {
    CommentLog.warn('share.snapshot.retry', 'images not ready error=' + CommentLog.errorText(e as Object));
    try {
      pixelMap = await uiContext.getComponentSnapshot().createFromBuilder(builder, 1500, true,
        { waitUntilRenderFinished: true, scale: scale });
    } catch (retryError) {
      throw new Error('评论图片未加载完整，请稍后重试');
    }
  }
  return validateReplyShareSnapshot(pixelMap, uiContext.vp2px(width) * scale, uiContext.vp2px(height) * scale);
}

@Component
export struct ReplyShareCard {
  @Prop item: ReplyItem = new ReplyItem();
  @Prop page: ReplySharePage = new ReplySharePage();
  /** 所属稿件/动态的 UP 主 mid；作者是本人时名字旁标注"UP主"。 */
  @Prop upMid: number = 0;
  @Prop qr: image.PixelMap | null = null;
  @Prop linkLabel: string = 'www.bilibili.com';
  /** 评论来源（视频/番剧/动态）卡片：封面 + 标题 + UP 主；标题为空则不显示。 */
  @Prop sourceCover: string = '';
  @Prop sourceTitle: string = '';
  @Prop sourceUpName: string = '';
  @Prop scanHint: string = '长按扫码查看内容';

  private shareDate(): string {
    const d: Date = new Date();
    const month: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return String(d.getFullYear()) + '/' + (month < 10 ? '0' : '') + String(month) +
      '/' + (day < 10 ? '0' : '') + String(day);
  }

  build() {
    Column() {
      // 头部：头像 + 昵称 + "发表了评论"（对齐官方分享图）
      Row({ space: 12 }) {
        Image(this.item.avatar.length > 0 ? this.item.avatar : $r('app.media.bilix_empty_2233'))
          .width(50)
          .height(50)
          .borderRadius(25)
          .objectFit(ImageFit.Cover)
          .border({ width: 1, color: '#E5F4FA' })
        Column({ space: 4 }) {
          Row({ space: 5 }) {
            Text(this.item.uname)
              .fontSize('18vp')
              .fontWeight(FontWeight.Medium)
              .fontColor('#18191C')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.upMid > 0 && this.item.mid === this.upMid) {
              Text('UP主')
                .fontSize('9vp')
                .fontColor('#FB7299')
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .borderRadius(3)
                .backgroundColor('#1AFB7299')
            }
          }
          .width('100%')
          Text('发表了评论')
            .fontSize('14vp')
            .fontColor('#9499A0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .height(50)
      .alignItems(VerticalAlign.Center)

      // 按原生字体测量结果逐行排版；每页尺寸限制在当前窗口可截图范围内。
      Column() {
        ForEach(this.page.lines, (line: ReplyShareLine, lineIndex: number) => {
          Text() {
            ForEach(line.runs, (run: ReplyShareRun, runIndex: number) => {
              if (run.image.length > 0) {
                ImageSpan(run.image).width(run.imageSize).height(run.imageSize)
                  .verticalAlign(ImageSpanAlignment.CENTER)
              } else {
                Span(run.text).fontSize('19vp').fontColor(run.linked ? '#008AC5' : '#18191C')
              }
            }, (_run: ReplyShareRun, runIndex: number) => String(runIndex))
          }
          .fontSize('19vp').lineHeight(32).height(line.height).width('100%')
          .maxLines(1).minFontScale(1).maxFontScale(1)
        }, (_line: ReplyShareLine, lineIndex: number) => String(lineIndex))
      }
      .width('100%')
      .height(this.page.lines.length * 32)
      .margin({ top: 20 })

      // 每张附图完整包含在网格中；超过一页由布局规划继续输出，不裁切或遗漏。
      if (this.page.pictures.length > 0) {
        Column({ space: 6 }) {
          ForEach(this.page.pictures.filter((_pic: string, index: number) => index % 3 === 0),
            (_pic: string, row: number) => {
              Row({ space: 10 }) {
                ForEach(this.page.pictures.slice(row * 3, row * 3 + 3), (pic: string, column: number) => {
                  Image(pic).width(this.page.pictureSize).height(this.page.pictureSize).objectFit(ImageFit.Contain)
                    .backgroundColor('#F5F7F9').borderRadius(7)
                }, (_pic: string, column: number) => String(column))
              }.width('100%').height(this.page.pictureSize)
            }, (_pic: string, row: number) => String(row))
        }
        .width('100%')
        .margin({ top: 16 })
      }

      // UP 主赞过标记（官方样式：一行灰字）
      if (this.item.upLiked) {
        Text('UP主觉得很赞')
          .fontSize('14vp')
          .fontColor('#9499A0')
          .width('100%')
          .height(20)
          .margin({ top: 12 })
      }

      // 来源内容卡：封面 + 标题 + UP 主（对齐官方分享图的视频卡）
      Column() {
      if (this.sourceTitle.length > 0) {
        Row({ space: 12 }) {
          if (this.sourceCover.length > 0) {
            Image(this.sourceCover)
              .width(104)
              .height(66)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
          }
          Column({ space: 6 }) {
            Text(this.sourceTitle)
              .fontSize('15vp')
              .fontColor('#18191C')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.sourceUpName.length > 0) {
              Row({ space: 4 }) {
                Text('UP')
                  .fontSize('9vp')
                  .fontColor('#9499A0')
                  .padding({ left: 3, right: 3 })
                  .border({ width: 0.5, color: '#9499A0', radius: 3 })
                Text(this.sourceUpName)
                  .fontSize('12vp')
                  .fontColor('#9499A0')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(VerticalAlign.Center)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .height(86)
        .padding(10)
        .backgroundColor('#F5F7F9')
        .borderRadius(8)
        .margin({ top: 18 })
      }
      }.width('100%').height(104)

      // 底部：App 标识 + 提示文案 + 二维码
      Row() {
        Image($r('app.media.bilix_logo'))
          .width(Math.min(96, (this.page.width - 48) * 0.27))
          .height(42)
          .objectFit(ImageFit.Contain)
          .renderMode(ImageRenderMode.Template)
          .fillColor(REPLY_SHARE_BRAND)
        Column({ space: 2 }) {
          Text('扫码查看原评论')
            .fontSize('12vp')
            .fontColor('#61666D')
          Text('分享于' + this.shareDate())
            .fontSize('11vp')
            .fontColor('#9499A0')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.End)
        .margin({ right: 8 })
        Stack() {
          if (this.qr !== null) {
            Image(this.qr).width(78).height(78).objectFit(ImageFit.Contain)
          } else {
            // ScanKit 不可用时仍由 ArkUI 本地生成二维码，不能退化为缺失链接的空白。
            QRCode(this.linkLabel).width(78).height(78).color('#18191C').backgroundColor('#FFFFFF')
          }
        }.width(88).height(88).backgroundColor('#FFFFFF')
      }
      .width('100%')
      .height(88)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 26 })
      Text(this.page.total > 1 ? '第 ' + String(this.page.number) + ' / ' + String(this.page.total) + ' 页' : '来自哔哩哔哩')
        .fontSize('10vp').fontColor('#9499A0').width('100%').height(20).textAlign(TextAlign.End)
    }
    .width(this.page.width)
    .height(this.page.height)
    .padding({ left: 24, right: 24, top: 26, bottom: 22 })
    .borderRadius(26)
    .backgroundColor('#FFFFFF')
  }
}
