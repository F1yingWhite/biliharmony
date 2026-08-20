/**
 * 表情图片本地磁盘缓存：把表情图的网络 URL 下载到应用缓存目录（cacheDir/emotes/），
 * 之后渲染直接用本地文件路径，弱网/离线也能显示，且缓存体量计入「清空缓存」。
 * 下载失败自动回退网络直连，不影响展示。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';

const SUBDIR: string = 'emotes';
let baseCacheDir: string = '';

export class EmoteImageCache {
  /** 进行中的下载去重：同一 URL 只发一次请求，其余调用等待同一个 Promise。 */
  private static inFlight: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** 由 EntryAbility 注入 Context（得到 cacheDir）。 */
  static attach(context: common.Context): void {
    try {
      baseCacheDir = context.cacheDir;
    } catch (e) {
      baseCacheDir = '';
    }
  }

  /** 资源对应本地缓存文件路径（无缓存也返回该路径，展开时创建目录）。 */
  static localPathOf(url: string): string {
    if (!url.startsWith('http')) {
      return url;
    }
    const dir: string = EmoteImageCache.dirPath();
    if (dir.length === 0) {
      return url;
    }
    const ext: string = EmoteImageCache.extensionOf(url);
    return dir + '/' + EmoteImageCache.hashOf(url) + '.' + ext;
  }

  /** 并发受限地执行下载任务：全局闸门在慢网下会堵死其他包的请求（表情整体瘫痪），
    已废弃全局限流，改为“懒加载当前包 + 单 URL 去重 + 超时兜底”，并行交给系统栈。 */
  private static async throttle<T>(fn: () => Promise<T>): Promise<T> {
    return fn();
  }

  /** 确保本地已缓存并返回本地路径；失败返回原 URL（回退网络）。 */
  static async ensure(url: string): Promise<string> {
    if (!url.startsWith('http')) {
      return url;
    }
    const path: string = EmoteImageCache.localPathOf(url);
    if (path === url) {
      return url;
    }
    try {
      // 命中校验用魔数而不是文件大小：极小的合法 GIF/PNG 会被 size>64 误杀，
      // 命中路径反复删+重下，弱网下表情永远停留在"加载不出来"。
      fs.statSync(path);
      if (EmoteImageCache.isImageFile(path)) {
        return path;
      }
      // 历史版本落盘未校验，可能把 CDN 的 JSON 错误体存成假图片（表情永久空白的根因之一）：
      // 魔数不符的文件直接删掉重新下载。
      try {
        fs.unlinkSync(path);
      } catch (e) {
      }
    } catch (e) {
      // 不存在则继续下载
    }
    const running: Promise<string> | undefined = EmoteImageCache.inFlight.get(url);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string> = EmoteImageCache.throttle<string>(async (): Promise<string> => {
      try {
        return await EmoteImageCache.downloadOnce(url, path);
      } catch (e) {
        return url;
      }
    });
    EmoteImageCache.inFlight.set(url, task);
    try {
      return await task;
    } finally {
      EmoteImageCache.inFlight.delete(url);
    }
  }

  /** 单次下载并落盘；失败返回原 URL（回退网络）。 */
  private static async downloadOnce(url: string, path: string): Promise<string> {
    try {
      const request: http.HttpRequest = http.createHttp();
      const resp: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 8000,
      });
      request.destroy();
      // 404/502 的 JSON 错误体此前也会被写盘、之后永久命中"已缓存"，把表情钉死成空白。
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return url;
      }
      // 真机可能返回裸 ArrayBuffer，模拟器偶返回 Uint8Array（视图），两者都是二进制；
      // 只有“真字符串”响应才放弃落盘。此前用 ArrayBuffer.isView() 判断误伤了裸 ArrayBuffer，
      // 导致真机永远不落盘。
      if (typeof resp.result === 'string') {
        return url;
      }
      let buf: ArrayBuffer;
      if (resp.result instanceof ArrayBuffer) {
        buf = resp.result;
      } else if (ArrayBuffer.isView(resp.result)) {
        buf = (resp.result as ArrayBufferView).buffer as ArrayBuffer;
      } else {
        return url;
      }
      if (buf.byteLength === 0) {
        return url;
      }
      if (!EmoteImageCache.isImageBytes(buf)) {
        return url;
      }
      const dir: string = EmoteImageCache.dirPath();
        if (dir.length === 0) {
          return url;
        }
        // 目录已存在时 mkdirSync 会抛异常（真机必现），存在即跳过，不能把下载判失败。
        try {
          fs.mkdirSync(dir);
        } catch (e) {
        }
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, buf);
      fs.closeSync(file);
      return path;
    } catch (e) {
      return url;
    }
  }

  /** 图片魔数校验：只有真正的图片二进制才允许落盘。 */
  private static isImageBytes(buf: ArrayBuffer): boolean {
    if (buf.byteLength < 12) {
      return false;
    }
    return EmoteImageCache.matchesImageMagic(new Uint8Array(buf));
  }

  /** 已缓存文件是否真图片：只读文件头 16 字节，不整文件进内存。 */
  static isImageFile(path: string): boolean {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(16);
      const len: number = fs.readSync(file.fd, buf, { offset: 0 });
      if (len < 12) {
        return false;
      }
      return EmoteImageCache.matchesImageMagic(new Uint8Array(buf, 0, len));
    } catch (e) {
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
        }
      }
    }
  }

  private static matchesImageMagic(b: Uint8Array): boolean {
    if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) return true; // PNG
    if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return true; // GIF
    if (b[0] === 0xFF && b[1] === 0xD8) return true; // JPEG
    if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
      b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return true; // WebP
    if (b[0] === 0x42 && b[1] === 0x4D) return true; // BMP
    return false;
  }

  private static dirPath(): string {
    if (baseCacheDir.length === 0) {
      return '';
    }
    return baseCacheDir + '/' + SUBDIR;
  }

  /** 稳定的短哈希做文件名（避免 URL 专用字符当路径）。 */
  private static hashOf(url: string): string {
    let h: number = 5381;
    for (let i: number = 0; i < url.length; i++) {
      h = ((h << 5) + h) ^ url.charCodeAt(i);
    }
    return 'e' + (h >>> 0).toString(16);
  }

  private static extensionOf(url: string): string {
    const m: RegExpExecArray | null = /\.(png|webp|gif|jpe?g|bmp)/i.exec(url);
    if (m === null) return 'png';
    return m[1].toLowerCase();
  }
}