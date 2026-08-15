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
import { formatCount, formatRelativeTime } from '../common/Utils';
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
  const data: systemShare.SharedData = new systemShare.SharedData({
    utd: 'general.png',
    title: '分享评论',
    content: fileUri.getUriFromPath(path),
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

  private metaText(): string {
    const location: string = this.item.location.replace('IP属地：', '').replace('IP属地:', '').trim();
    return formatRelativeTime(this.item.ctime) + (location.length > 0 ? '  IP属地：' + location : '');
  }

  build() {
    Column() {
      // 头部：头像 + 昵称 + 时间
      Row({ space: 10 }) {
        Image(this.item.avatar.length > 0 ? this.item.avatar : $r('app.media.bilix_empty_2233'))
          .width(40)
          .height(40)
          .borderRadius(20)
          .objectFit(ImageFit.Cover)
        Column({ space: 3 }) {
          Row({ space: 5 }) {
            Text(this.item.uname)
              .fontSize(14)
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
          Text(this.metaText())
            .fontSize(10)
            .fontColor('#9499A0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 正文（固定白底卡片，文字恒为深色）
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        ForEach(parseReplyContent(this.item), (part: ReplyRenderPart) => {
          if (part.image.length > 0) {
            Image(part.image)
              .width(part.imageSize > 1 ? 40 : 20)
              .height(part.imageSize > 1 ? 40 : 20)
              .objectFit(ImageFit.Contain)
              .margin({ right: 2 })
          } else {
            Text(part.text)
              .fontSize(14)
              .lineHeight(21)
              .constraintSize({ minHeight: 21 })
              .fontColor(part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 || part.aid > 0 ?
                '#008AC5' : '#18191C')
          }
        }, (part: ReplyRenderPart) => part.key)
      }
      .width('100%')
      .margin({ top: 10 })

      // 评论附图
      if (this.item.pictures.length > 0) {
        Row({ space: 6 }) {
          ForEach(this.item.pictures.slice(0, 3), (url: string) => {
            Image(url)
              .width(96)
              .height(96)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
          }, (url: string) => url)
        }
        .width('100%')
        .margin({ top: 8 })
      }

      // 点赞 / 回复数
      Row({ space: 14 }) {
        Row({ space: 4 }) {
          Image($r('app.media.ic_like'))
            .width(14)
            .height(14)
            .renderMode(ImageRenderMode.Template)
            .fillColor('#9499A0')
          Text(formatCount(this.item.like))
            .fontSize(11)
            .fontColor('#9499A0')
        }
        if (this.item.count > 0) {
          Text('共 ' + formatCount(this.item.count) + ' 条回复')
            .fontSize(11)
            .fontColor('#9499A0')
        }
      }
      .width('100%')
      .margin({ top: 12 })

      Divider().color('#E3E5E7').strokeWidth(0.5).margin({ top: 14, bottom: 12 })

      // 底部：App 标识 + 二维码
      Row({ space: 8 }) {
        Image($r('app.media.bilix_logo'))
          .width(30)
          .height(30)
          .objectFit(ImageFit.Contain)
        Column({ space: 2 }) {
          Text('哔哩哔哩 ( ゜- ゜)つロ 干杯')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#18191C')
          Text(this.qr !== null ? '扫码查看这条评论' : this.linkLabel)
            .fontSize(10)
            .fontColor('#9499A0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.qr !== null) {
          Image(this.qr)
            .width(56)
            .height(56)
            .objectFit(ImageFit.Contain)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width(340)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .borderRadius(14)
    .backgroundColor('#FFFFFF')
  }
}
