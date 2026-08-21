/**
 * 远程装扮资源磁盘缓存。
 *
 * 图片与短视频按业务目录落到 cacheDir，命中时直接返回本地路径；同一资源的并发请求
 * 共用一个 Promise。下载结果必须通过文件头校验，CDN 错误页不会被当成永久缓存。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';

const DIR_EMOTES: string = 'emotes';
const DIR_AVATARS: string = 'avatars';
const DIR_DECORATIONS: string = 'decorations';
const DIR_COLLECTIONS: string = 'collections';
const DIR_COLLECTION_MEDIA: string = 'collection_media';
const MAX_IMAGE_BYTES: number = 32 * 1024 * 1024;
const MAX_MEDIA_BYTES: number = 80 * 1024 * 1024;

let assetCacheDir: string = '';

export class RemoteAssetCache {
  private static inFlight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  static attach(context: common.Context): void {
    try {
      assetCacheDir = context.cacheDir;
    } catch (e) {
      assetCacheDir = '';
    }
  }

  static cachedEmote(url: string): string {
    return RemoteAssetCache.cached(url, DIR_EMOTES, false);
  }

  static ensureEmote(url: string): Promise<string> {
    return RemoteAssetCache.ensure(url, DIR_EMOTES, false);
  }

  static cachedAvatar(url: string): string {
    return RemoteAssetCache.cached(url, DIR_AVATARS, false);
  }

  static ensureAvatar(url: string): Promise<string> {
    return RemoteAssetCache.ensure(url, DIR_AVATARS, false);
  }

  static cachedDecoration(url: string): string {
    return RemoteAssetCache.cached(url, DIR_DECORATIONS, false);
  }

  static ensureDecoration(url: string): Promise<string> {
    return RemoteAssetCache.ensure(url, DIR_DECORATIONS, false);
  }

  static cachedCollectionImage(url: string): string {
    return RemoteAssetCache.cached(url, DIR_COLLECTIONS, false);
  }

  static ensureCollectionImage(url: string): Promise<string> {
    return RemoteAssetCache.ensure(url, DIR_COLLECTIONS, false);
  }

  static cachedCollectionMedia(url: string): string {
    return RemoteAssetCache.cached(url, DIR_COLLECTION_MEDIA, true);
  }

  static ensureCollectionMedia(url: string): Promise<string> {
    return RemoteAssetCache.ensure(url, DIR_COLLECTION_MEDIA, true);
  }

  private static cached(url: string, subdir: string, media: boolean): string {
    if (!url.startsWith('http')) return url;
    const path: string = RemoteAssetCache.localPath(url, subdir, media);
    if (path === url) return url;
    try {
      fs.statSync(path);
      if (RemoteAssetCache.isValidFile(path, media)) return RemoteAssetCache.uriOf(path, url);
      try {
        fs.unlinkSync(path);
      } catch (e) {
      }
    } catch (e) {
      // 未命中。
    }
    return url;
  }

  private static async ensure(url: string, subdir: string, media: boolean): Promise<string> {
    const cached: string = RemoteAssetCache.cached(url, subdir, media);
    if (cached !== url || !url.startsWith('http')) return cached;
    const path: string = RemoteAssetCache.localPath(url, subdir, media);
    if (path === url) return url;
    const key: string = subdir + '\n' + url;
    const running: Promise<string> | undefined = RemoteAssetCache.inFlight.get(key);
    if (running !== undefined) return running;
    const task: Promise<string> = RemoteAssetCache.download(url, path, subdir, media);
    RemoteAssetCache.inFlight.set(key, task);
    try {
      return await task;
    } finally {
      RemoteAssetCache.inFlight.delete(key);
    }
  }

  private static async download(url: string, path: string, subdir: string, media: boolean): Promise<string> {
    let request: http.HttpRequest | null = null;
    try {
      request = http.createHttp();
      const resp: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: media ? 30000 : 10000,
      });
      if (resp.responseCode < 200 || resp.responseCode >= 300 || typeof resp.result === 'string') return url;
      let buffer: ArrayBuffer;
      if (resp.result instanceof ArrayBuffer) {
        buffer = resp.result;
      } else if (ArrayBuffer.isView(resp.result)) {
        buffer = (resp.result as ArrayBufferView).buffer as ArrayBuffer;
      } else {
        return url;
      }
      const limit: number = media ? MAX_MEDIA_BYTES : MAX_IMAGE_BYTES;
      if (buffer.byteLength === 0 || buffer.byteLength > limit ||
        !RemoteAssetCache.matchesMagic(new Uint8Array(buffer), media)) return url;
      const dir: string = RemoteAssetCache.dirPath(subdir);
      if (dir.length === 0) return url;
      try {
        fs.mkdirSync(dir);
      } catch (e) {
      }
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
      return RemoteAssetCache.uriOf(path, url);
    } catch (e) {
      return url;
    } finally {
      if (request !== null) request.destroy();
    }
  }

  private static isValidFile(path: string, media: boolean): boolean {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(16);
      const length: number = fs.readSync(file.fd, buffer, { offset: 0 });
      return length >= 12 && RemoteAssetCache.matchesMagic(new Uint8Array(buffer, 0, length), media);
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

  private static matchesMagic(bytes: Uint8Array, media: boolean): boolean {
    if (media) {
      // ISO BMFF（MP4/MOV）与 WebM。
      if (bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70) return true;
      return bytes[0] === 0x1A && bytes[1] === 0x45 && bytes[2] === 0xDF && bytes[3] === 0xA3;
    }
    if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) return true;
    if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return true;
    if (bytes[0] === 0xFF && bytes[1] === 0xD8) return true;
    if (bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46 &&
      bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return true;
    return bytes[0] === 0x42 && bytes[1] === 0x4D;
  }

  private static localPath(url: string, subdir: string, media: boolean): string {
    const dir: string = RemoteAssetCache.dirPath(subdir);
    if (dir.length === 0) return url;
    return dir + '/' + RemoteAssetCache.hash(url) + '.' + RemoteAssetCache.extension(url, media);
  }

  /** ArkUI Image/ImageSpan/Video 必须使用沙箱 file URI，不能直接传 cacheDir 绝对路径。 */
  private static uriOf(path: string, fallback: string): string {
    try {
      return fileUri.getUriFromPath(path);
    } catch (e) {
      return fallback;
    }
  }

  private static dirPath(subdir: string): string {
    return assetCacheDir.length > 0 ? assetCacheDir + '/' + subdir : '';
  }

  private static hash(url: string): string {
    let value: number = 5381;
    for (let i: number = 0; i < url.length; i++) value = ((value << 5) + value) ^ url.charCodeAt(i);
    return 'a' + (value >>> 0).toString(16);
  }

  private static extension(url: string, media: boolean): string {
    const pattern: RegExp = media ? /\.(mp4|m4v|mov|webm)/i : /\.(png|webp|gif|jpe?g|bmp)/i;
    const match: RegExpExecArray | null = pattern.exec(url);
    return match === null ? (media ? 'mp4' : 'png') : match[1].toLowerCase();
  }
}
