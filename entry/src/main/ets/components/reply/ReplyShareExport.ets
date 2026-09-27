import { image } from '@kit.ImageKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';

export class ReplyShareImageFile {
  path: string = '';
  uri: string = '';
}

/** Pack and release each page before rendering the next, keeping long comments' memory use bounded. */
export async function saveReplyShareImage(context: common.UIAbilityContext, pixelMap: image.PixelMap,
  fileName: string): Promise<ReplyShareImageFile> {
  const result: ReplyShareImageFile = new ReplyShareImageFile();
  result.path = context.cacheDir + '/' + fileName + '.png';
  try {
    const packer: image.ImagePacker = image.createImagePacker();
    let buffer: ArrayBuffer;
    try {
      buffer = await packer.packToData(pixelMap, { format: 'image/png', quality: 100 });
    } finally {
      await packer.release();
    }
    const file: fs.File = fs.openSync(result.path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      let written: number = 0;
      while (written < buffer.byteLength) {
        const count: number = fs.writeSync(file.fd, written === 0 ? buffer : buffer.slice(written));
        if (count <= 0) throw new Error('评论图片写入失败');
        written += count;
      }
    } finally {
      fs.closeSync(file);
    }
    result.uri = fileUri.getUriFromPath(result.path);
    return result;
  } catch (e) {
    try { fs.unlinkSync(result.path); } catch (ignored) {}
    throw e as Error;
  } finally {
    try { await pixelMap.release(); } catch (ignored) {}
  }
}

export function removeReplyShareImages(files: Array<ReplyShareImageFile>): void {
  for (let i: number = 0; i < files.length; i++) {
    try { fs.unlinkSync(files[i].path); } catch (ignored) {}
  }
}

/** Open a preview for every page. Sending to another app remains an explicit user action. */
export async function showReplyShareImages(context: common.UIAbilityContext,
  files: Array<ReplyShareImageFile>): Promise<void> {
  if (files.length === 0) return;
  const imageType: string = utd.getUniformDataTypeByFilenameExtension('.png', utd.UniformDataType.IMAGE);
  const data: systemShare.SharedData = new systemShare.SharedData({
    utd: imageType, title: '分享评论', uri: files[0].uri, thumbnailUri: files[0].uri,
    description: '来自哔哩哔哩的完整评论',
  });
  for (let i: number = 1; i < files.length; i++) {
    data.addRecord({ utd: imageType, title: '评论 ' + String(i + 1) + '/' + String(files.length),
      uri: files[i].uri, thumbnailUri: files[i].uri });
  }
  const controller: systemShare.ShareController = new systemShare.ShareController(data);
  let cleanupScheduled: boolean = false;
  const scheduleCleanup = (): void => {
    if (cleanupScheduled) return;
    cleanupScheduled = true;
    setTimeout(() => removeReplyShareImages(files), 10000);
  };
  controller.on('shareCompleted', scheduleCleanup);
  controller.on('dismiss', scheduleCleanup);
  try {
    await controller.show(context, {
      selectionMode: files.length > 1 ? systemShare.SelectionMode.BATCH : systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DETAIL,
    });
  } catch (e) {
    removeReplyShareImages(files);
    throw e as Error;
  }
}
