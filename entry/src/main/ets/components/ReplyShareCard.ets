/**
 * 评论分享卡：对齐 B 站 App 的"评论分享成图片"体验。
 * 白底卡片（头像/昵称/UP主标/时间/正文/图片/点赞数），底部 App 标识 + 二维码。
 * 由各页面用离屏 @Builder 渲染后经 componentSnapshot 截成图片。
 */
import { image } from '@kit.ImageKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { parseReplyContent, ReplyRenderPart } from '../common/ReplyContentParser';
import { ReplyItem } from '../model/Models';

/** 生成评论分享二维码；失败时返回 null，卡片退化为一行链接文字。 */
export async function makeReplyQr(content: string): Promise<image.PixelMap | null> {
  try {
    return await generateBarcode.createBarcode(content, {
      scanType: scanCore.ScanType.QR_CODE,
      width: 240,
      height: 240,
      margin: 1,
      level: generateBarcode.ErrorCorrectionLevel.LEVEL_M,
    });
  } catch (e) {
    return null;
  }
}

/** 把分享卡截图打成 PNG 存入缓存目录，并调起系统分享面板。 */
export async function sharePixelMapAsImage(context: common.UIAbilityContext, pixelMap: image.PixelMap,
  fileName: string): Promise<void> {
  const packer: image.ImagePacker = image.createImagePacker();
  const buffer: ArrayBuffer = await packer.packing(pixelMap, { format: 'image/png', quality: 100 });
  const path: string = context.cacheDir + '/' + fileName + '.png';
  const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, buffer);
  } finally {
    fs.closeSync(file);
  }
  // 生成 JPEG 缩略图作为分享面板的预览图（thumbnailUri 缺省时系统会用
  // 通用图标占位，观感就是"分享的是一个 logo"）。缩略图 < 32KB 才可传给
  // thumbnail 字段，这里用 thumbnailUri 指向缓存文件，避免尺寸限制。
  let thumbnailUri: string = '';
  try {
    const thumbPacker: image.ImagePacker = image.createImagePacker();
    const thumbBuffer: ArrayBuffer = await thumbPacker.packing(pixelMap, { format: 'image/jpeg', quality: 82 });
    const thumbPath: string = context.cacheDir + '/' + fileName + '_thumb.jpg';
    const thumbFile: fs.File = fs.openSync(thumbPath,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(thumbFile.fd, thumbBuffer);
    } finally {
      fs.closeSync(thumbFile);
    }
    thumbnailUri = fileUri.getUriFromPath(thumbPath);
  } catch (e) {
    thumbnailUri = '';
  }
  const data: systemShare.SharedData = new systemShare.SharedData({
    utd: 'general.png',
    title: '分享评论',
    content: fileUri.getUriFromPath(path),
    thumbnailUri,
    description: '来自哔哩哔哩的评论',
  });
  const controller: systemShare.ShareController = new systemShare.ShareController(data);
  await controller.show(context, { previewMode: systemShare.SharePreviewMode.DETAIL });
}

@Component
export struct ReplyShareCard {
  @Prop item: ReplyItem = new ReplyItem();
  /** 所属稿件/动态的 UP 主 mid；作者是本人时名字旁标注"UP主"。 */
  @Prop upMid: number = 0;
  @Prop qr: image.PixelMap | null = null;
  @Prop linkLabel: string = 'www.bilibili.com';
  /** 评论来源（视频/番剧/动态）卡片：封面 + 标题 + UP 主；标题为空则不显示。 */
  @Prop sourceCover: string = '';
  @Prop sourceTitle: string = '';
  @Prop sourceUpName: string = '';

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
      Row({ space: 10 }) {
        Image(this.item.avatar.length > 0 ? this.item.avatar : $r('app.media.bilix_empty_2233'))
          .width(44)
          .height(44)
          .borderRadius(22)
          .objectFit(ImageFit.Cover)
        Column({ space: 4 }) {
          Row({ space: 5 }) {
            Text(this.item.uname)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18191C')
            if (this.upMid > 0 && this.item.mid === this.upMid) {
              Text('UP主')
                .fontSize(9)
                .fontColor('#FB7299')
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .borderRadius(3)
                .backgroundColor('#1AFB7299')
            }
          }
          Text('发表了评论')
            .fontSize(12)
            .fontColor('#9499A0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 正文（固定白底卡片，文字恒为深色）。用 Text + Span 渲染富文本，
      // maxLines=5 截断长评论，防止分享图被拉成超长条。
      Text() {
        ForEach(parseReplyContent(this.item), (part: ReplyRenderPart) => {
          if (part.image.length > 0) {
            ImageSpan(part.image)
              .width(part.imageSize > 1 ? 30 : 18)
              .height(part.imageSize > 1 ? 30 : 18)
              .verticalAlign(ImageSpanAlignment.CENTER)
          } else {
            Span(part.text)
              .fontSize(16)
              .fontColor(part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ?
                '#008AC5' : '#18191C')
          }
        }, (part: ReplyRenderPart) => part.key)
      }
      .fontSize(16)
      .lineHeight(24)
      .width('100%')
      .maxLines(5)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .margin({ top: 12 })

      // 评论附图：最多 3 张。
      if (this.item.pictures.length > 0) {
        Row({ space: 6 }) {
          ForEach(this.item.pictures.slice(0, 3), (pic: string) => {
            Image(pic)
              .width(96)
              .height(96)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
          }, (pic: string) => pic)
        }
        .width('100%')
        .margin({ top: 10 })
      }

      // UP 主赞过标记（官方样式：一行灰字）
      if (this.item.upLiked) {
        Text('UP主觉得很赞')
          .fontSize(12)
          .fontColor('#9499A0')
          .width('100%')
          .margin({ top: 10 })
      }

      // 来源内容卡：封面 + 标题 + UP 主（对齐官方分享图的视频卡）
      if (this.sourceTitle.length > 0) {
        Row({ space: 10 }) {
          if (this.sourceCover.length > 0) {
            Image(this.sourceCover)
              .width(96)
              .height(60)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
          }
          Column({ space: 6 }) {
            Text(this.sourceTitle)
              .fontSize(13)
              .fontColor('#18191C')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.sourceUpName.length > 0) {
              Row({ space: 4 }) {
                Text('UP')
                  .fontSize(9)
                  .fontColor('#FB7299')
                  .padding({ left: 3, right: 3 })
                  .border({ width: 0.5, color: '#FB7299', radius: 3 })
                Text(this.sourceUpName)
                  .fontSize(11)
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
        .padding(8)
        .backgroundColor('#F7F8FA')
        .borderRadius(10)
        .margin({ top: 12 })
      }

      // 底部：App 标识 + 提示文案 + 二维码
      Row() {
        Image($r('app.media.bilix_logo'))
          .height(26)
          .objectFit(ImageFit.Contain)
        Blank()
        Column({ space: 2 }) {
          Text('保存图片至相册')
            .fontSize(12)
            .fontColor('#61666D')
          Text(this.qr !== null ? '长按扫码查看内容' : this.linkLabel)
            .fontSize(12)
            .fontColor('#61666D')
          Text('分享于' + this.shareDate())
            .fontSize(10)
            .fontColor('#9499A0')
        }
        .alignItems(HorizontalAlign.End)
        .margin({ right: 8 })
        if (this.qr !== null) {
          Image(this.qr)
            .width(64)
            .height(64)
            .objectFit(ImageFit.Contain)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 16 })
    }
    .width(340)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .borderRadius(14)
    .backgroundColor('#FFFFFF')
  }
}
