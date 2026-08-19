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
      const st: fs.Stat | null = fs.statSync(path);
      if (st !== null && st.size > 0) {
        return path;
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