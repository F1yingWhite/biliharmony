/**
 * 动态发布图片预处理：picker 选中的媒体 URI → 应用沙箱缓存里的草稿文件。
 * - GIF 按原字节拷贝，保留帧动画（重编码会变静图）；
 * - 静态图解码后长边超过 2048 时等比缩放，重编码为 JPEG，并把 EXIF 方向转进像素
 *   （重编码不带 EXIF，不转会导致相机竖拍照片上传后横躺）。
 * 预处理在选择图片时完成，发布阶段只上传缓存文件：单张失败只跳过该张，不阻塞整条动态。
 */
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/** 静态图重编码的长边上限。B 站动态展示宽度远小于此，2048 已远超清晰度需求。 */
const MAX_EDGE: number = 2048;

/** 发布面板中的一张待上传图片草稿（缓存文件随发随清）。 */
export class DynDraftImage {
  /** ForEach 复用键：缓存文件名（含时间戳 + 随机段，稳定且唯一）。 */
  key: string = '';
  /** 沙箱内缓存文件绝对路径（Image 显示与上传读字节都用它）。 */
  cachePath: string = '';
  fileName: string = '';
  mimeType: string = 'image/jpeg';
  width: number = 0;
  height: number = 0;
  byteSize: number = 0;
  isGif: boolean = false;
}

export class DynImagePreparer {
  /** 把一张 picker 媒体 URI 处理成草稿；任何一步失败返回 null（调用方跳过该张）。 */
  static async prepare(context: common.Context, sourceUri: string): Promise<DynDraftImage | null> {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(sourceUri, fs.OpenMode.READ_ONLY);
      const isGif: boolean = DynImagePreparer.isGifFile(file.fd);
      const dir: string = context.cacheDir + '/dyn_publish';
      // 目录已存在时 mkdir 会抛错，按项目惯例吞掉即可。
      try {
        await fs.mkdir(dir);
      } catch (e) {
      }
      const name: string = 'dyn_' + String(Date.now()) + '_' +
        String(Math.floor(Math.random() * 9000) + 1000) + (isGif ? '.gif' : '.jpg');
      const path: string = dir + '/' + name;
      const draft: DynDraftImage | null = isGif
        ? await DynImagePreparer.copyGif(file.fd, path, name)
        : await DynImagePreparer.reencode(file.fd, path, name);
      if (draft === null) {
        // 半成品文件必须清掉，避免缓存目录积累垃圾。
        try {
          fs.unlinkSync(path);
        } catch (e) {
        }
        return null;
      }
      return draft;
    } catch (e) {
      return null;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  /** 发布时读回草稿字节用于上传。 */
  static async readBytes(path: string): Promise<ArrayBuffer> {
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      let total: number = 0;
      const view: Uint8Array = new Uint8Array(buffer);
      while (total < size) {
        const chunkLen: number = Math.min(1024 * 1024, size - total);
        const chunk: ArrayBuffer = new ArrayBuffer(chunkLen);
        const read: number = fs.readSync(file.fd, chunk, { offset: total });
        if (read <= 0) {
          break;
        }
        view.set(new Uint8Array(chunk, 0, read), total);
        total += read;
      }
      return total === size ? buffer : buffer.slice(0, total);
    } finally {
      try {
        fs.closeSync(file);
      } catch (e) {
      }
    }
  }

  /** 清理草稿缓存文件（发布成功后调用；单个失败不影响其余）。 */
  static cleanup(drafts: Array<DynDraftImage>): void {
    for (let i: number = 0; i < drafts.length; i++) {
      try {
        fs.unlinkSync(drafts[i].cachePath);
      } catch (e) {
      }
    }
  }

  /** 文件头三个字节是否为 GIF 魔数（'GIF'）。 */
  private static isGifFile(fd: number): boolean {
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(3);
      const read: number = fs.readSync(fd, buffer, { offset: 0 });
      const bytes: Uint8Array = new Uint8Array(buffer, 0, read);
      return bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46;
    } catch (e) {
      return false;
    }
  }

  /** GIF 原字节拷贝：尺寸从首帧解码信息取，内容不动。 */
  private static async copyGif(fd: number, path: string, name: string): Promise<DynDraftImage | null> {
    let source: image.ImageSource | null = null;
    try {
      const size: number = fs.statSync(fd).size;
      // 20MB 兜底上限：更大的文件大概率是异常选择，直接判失败。
      if (size <= 0 || size > 20 * 1024 * 1024) {
        return null;
      }
      const buffer: ArrayBuffer | null = await DynImagePreparer.readAllByFd(fd, size);
      if (buffer === null) {
        return null;
      }
      DynImagePreparer.writeAll(path, buffer);
      source = image.createImageSource(fd);
      const info: image.ImageInfo = await source.getImageInfo();
      const draft: DynDraftImage = new DynDraftImage();
      draft.key = name;
      draft.cachePath = path;
      draft.fileName = name;
      draft.mimeType = 'image/gif';
      draft.width = info.size.width;
      draft.height = info.size.height;
      draft.byteSize = buffer.byteLength;
      draft.isGif = true;
      return draft;
    } catch (e) {
      return null;
    } finally {
      if (source !== null) {
        try {
          await source.release();
        } catch (e) {
        }
      }
    }
  }

  /** 静态图：解码（超限等比缩放）→ EXIF 方向转进像素 → 重编码 JPEG 85 → 写缓存。 */
  private static async reencode(fd: number, path: string, name: string): Promise<DynDraftImage | null> {
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      source = image.createImageSource(fd);
      const info: image.ImageInfo = await source.getImageInfo();
      const rawW: number = info.size.width;
      const rawH: number = info.size.height;
      if (rawW <= 0 || rawH <= 0) {
        return null;
      }
      let options: image.DecodingOptions = {};
      const longest: number = Math.max(rawW, rawH);
      if (longest > MAX_EDGE) {
        const scale: number = MAX_EDGE / longest;
        options = {
          desiredSize: {
            width: Math.max(1, Math.round(rawW * scale)),
            height: Math.max(1, Math.round(rawH * scale)),
          },
        };
      }
      pixelMap = await source.createPixelMap(options);
      await DynImagePreparer.applyExifOrientation(source, pixelMap);
      const finalInfo: image.ImageInfo = await pixelMap.getImageInfo();
      packer = image.createImagePacker();
      const buffer: ArrayBuffer = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 85 });
      if (buffer.byteLength === 0) {
        return null;
      }
      DynImagePreparer.writeAll(path, buffer);
      const draft: DynDraftImage = new DynDraftImage();
      draft.key = name;
      draft.cachePath = path;
      draft.fileName = name;
      draft.mimeType = 'image/jpeg';
      draft.width = finalInfo.size.width;
      draft.height = finalInfo.size.height;
      draft.byteSize = buffer.byteLength;
      draft.isGif = false;
      return draft;
    } catch (e) {
      return null;
    } finally {
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (e) {
        }
      }
      if (packer !== null) {
        try {
          await packer.release();
        } catch (e) {
        }
      }
      if (source !== null) {
        try {
          await source.release();
        } catch (e) {
        }
      }
    }
  }

  /**
   * EXIF 方向修正：重编码的 JPEG 不带 EXIF，方向必须在此转进像素。
   * 值域（精简）：1=正常、3=转180°、6=顺时针90°、8=逆时针90°；缺失或异常按原样。
   */
  private static async applyExifOrientation(source: image.ImageSource, pixelMap: image.PixelMap): Promise<void> {
    try {
      const orientation: string = await source.getImageProperty('Orientation');
      if (orientation === '3') {
        await pixelMap.rotate(180);
      } else if (orientation === '6') {
        await pixelMap.rotate(90);
      } else if (orientation === '8') {
        await pixelMap.rotate(270);
      }
    } catch (e) {
      // 无 EXIF 或属性读取失败：按原方向处理。
    }
  }

  /** 按文件描述符整读指定长度（1MB 分块，规避单次读取上限）。 */
  private static async readAllByFd(fd: number, size: number): Promise<ArrayBuffer | null> {
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const view: Uint8Array = new Uint8Array(buffer);
      let total: number = 0;
      while (total < size) {
        const chunkLen: number = Math.min(1024 * 1024, size - total);
        const chunk: ArrayBuffer = new ArrayBuffer(chunkLen);
        const read: number = fs.readSync(fd, chunk, { offset: total });
        if (read <= 0) {
          break;
        }
        view.set(new Uint8Array(chunk, 0, read), total);
        total += read;
      }
      return total === size ? buffer : null;
    } catch (e) {
      return null;
    }
  }

  private static writeAll(path: string, buffer: ArrayBuffer): void {
    const file: fs.File =
      fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, buffer);
    } finally {
      try {
        fs.closeSync(file);
      } catch (e) {
      }
    }
  }
}
