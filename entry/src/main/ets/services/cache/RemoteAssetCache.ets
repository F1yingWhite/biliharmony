/**
 * 远程装扮资源磁盘缓存。
 *
 * 图片与短视频按业务目录落到 cacheDir，命中时直接返回本地路径；同一资源的并发请求
 * 共用一个 Promise。下载结果必须通过文件头校验，CDN 错误页不会被当成永久缓存。
 *
 * 查询入口 cached() 只读内存、不做任何同步文件 IO，可安全用于 UI build 路径
 * （列表每帧都会重查）；磁盘存在性与文件头校验全部走异步重验与 ensure()。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { AssetDownload } from './AssetDownload';

const DIR_EMOTES: string = 'emotes';
/** 旧版曾把每个用户头像永久保存到此目录；现仅用于升级后的分批清理。 */
const DIR_LEGACY_AVATARS: string = 'avatars';
const DIR_DECORATIONS: string = 'decorations';
const DIR_COLLECTIONS: string = 'collections';
const DIR_COLLECTION_MEDIA: string = 'collection_media';
/** 视频缩略图（目前用于 YouTube 卡片）：与其它远程图片同一条可配代理的下载管线。 */
const DIR_THUMBNAILS: string = 'thumbnails';
const MAX_IMAGE_BYTES: number = 32 * 1024 * 1024;
const MAX_MEDIA_BYTES: number = 80 * 1024 * 1024;
/** 已验证记录的有效期；过期后乐观复用并触发一次后台重验，重验完成前不重复触发。 */
const VERIFIED_TTL_MS: number = 5000;

let assetCacheDir: string = '';

class VerifiedAsset {
  uri: string;
  at: number = Date.now();
  constructor(uri: string) { this.uri = uri; }
}

export class RemoteAssetCache {
  private static inFlight: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** path → 已验证记录：TTL 内零 IO 命中；过期后乐观复用并单飞重验。 */
  private static verifiedPaths: Map<string, VerifiedAsset> = new Map<string, VerifiedAsset>();
  /** 正在后台重验的本地路径：同一文件同时最多一次在途重验，避免每次渲染都建 Promise。 */
  private static revalidatingPaths: Set<string> = new Set<string>();
  private static legacyAvatarPurgeScheduled: boolean = false;
  private static legacyReplySharePurgeScheduled: boolean = false;

  static attach(context: common.Context): void {
    try {
      assetCacheDir = context.cacheDir;
      RemoteAssetCache.scheduleLegacyAvatarPurge();
      RemoteAssetCache.scheduleLegacyReplySharePurge();
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

  /**
   * 列表缩略图：ArkUI `Image()` 走系统网络栈，既不读 HttpClient 的 usingProxy，
   * 也不读 ArkWeb 的代理下发，因此在只能靠代理出网的环境里会整片空白。
   * 走这条管线后缩略图与应用其余流量同源，并且命中后不再重复请求。
   */
  static cachedThumbnail(url: string): string {
    return RemoteAssetCache.cached(url, DIR_THUMBNAILS, false);
  }

  static ensureThumbnail(url: string): Promise<string> {
    return RemoteAssetCache.ensure(url, DIR_THUMBNAILS, false);
  }

  /**
   * build 路径专用查询：只读内存，绝不发起同步文件 IO。
   * - 有效期内命中：直接返回本地 uri（现状，零 IO）；
   * - 过期命中：乐观返回本地 uri，同时触发一次后台单飞重验（stat + 读文件头均为
   *   异步）；重验失败会删除文件并移除记录，下次调用走未命中路径重新下载；
   * - 未命中：返回远程 url，不阻塞；磁盘恢复与下载由调用方配对的 ensure() 异步完成。
   */
  private static cached(url: string, subdir: string, media: boolean): string {
    if (!url.startsWith('http')) return url;
    const path: string = RemoteAssetCache.localPath(url, subdir, media);
    if (path === url) return url;
    const verified: VerifiedAsset | undefined = RemoteAssetCache.verifiedPaths.get(path);
    if (verified === undefined) return url;
    if (Date.now() - verified.at < VERIFIED_TTL_MS) return verified.uri;
    RemoteAssetCache.scheduleRevalidate(path, url, subdir, media);
    return verified.uri;
  }

  private static async ensure(url: string, subdir: string, media: boolean): Promise<string> {
    if (!url.startsWith('http')) return url;
    const path: string = RemoteAssetCache.localPath(url, subdir, media);
    if (path === url) return url;
    const verified: VerifiedAsset | undefined = RemoteAssetCache.verifiedPaths.get(path);
    if (verified !== undefined) {
      // 含过期乐观项：记录由后台重验兜底，这里不再重复校验。
      if (Date.now() - verified.at >= VERIFIED_TTL_MS) {
        RemoteAssetCache.scheduleRevalidate(path, url, subdir, media);
      }
      return verified.uri;
    }
    // 冷启动磁盘恢复：记录是内存态，进程重启后为空，但上次下载的文件可能仍在。
    // 先异步校验文件头，命中直接复用，避免把整份缓存重新下载一遍。
    if (await RemoteAssetCache.validateFile(path, media)) return RemoteAssetCache.remember(path, url);
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

  /** 过期记录的单飞重验入口：同一文件同时最多一次在途；下载在途时交给下载结果刷新。 */
  private static scheduleRevalidate(path: string, url: string, subdir: string, media: boolean): void {
    if (RemoteAssetCache.revalidatingPaths.has(path)) return;
    if (RemoteAssetCache.inFlight.has(subdir + '\n' + url)) return;
    RemoteAssetCache.revalidatingPaths.add(path);
    RemoteAssetCache.revalidate(path, url, media).catch((): void => {
      // 重验内部已兜底所有文件错误；这里只为保证 finally 一定执行。
    }).finally(() => {
      RemoteAssetCache.revalidatingPaths.delete(path);
    });
  }

  private static async revalidate(path: string, url: string, media: boolean): Promise<void> {
    // 重验期间记录可能已被下载刷新或容量清理（512 上限）移除，以最新状态为准。
    if (RemoteAssetCache.verifiedPaths.get(path) === undefined) return;
    if (await RemoteAssetCache.validateFile(path, media)) {
      // 校验通过：刷新时间戳，本窗口内不再重复重验。
      RemoteAssetCache.remember(path, url);
      return;
    }
    RemoteAssetCache.verifiedPaths.delete(path);
    try {
      await fs.unlink(path);
    } catch (e) {
      // 文件可能已被系统先行回收，忽略。
    }
  }

  private static remember(path: string, fallback: string): string {
    const uri: string = RemoteAssetCache.uriOf(path, fallback);
    // 短期记住已验证的命中；过期后由后台异步重验刷新，允许系统回收缓存文件。
    if (RemoteAssetCache.verifiedPaths.size >= 512) RemoteAssetCache.verifiedPaths.clear();
    RemoteAssetCache.verifiedPaths.set(path, new VerifiedAsset(uri));
    return uri;
  }

  private static async download(url: string, path: string, subdir: string, media: boolean): Promise<string> {
    try {
      const dir: string = RemoteAssetCache.dirPath(subdir);
      if (dir.length === 0) return url;
      try { await fs.mkdir(dir); } catch (e) {}
      const saved: boolean = await AssetDownload.save(url, path, media ? MAX_MEDIA_BYTES : MAX_IMAGE_BYTES,
        media ? 30000 : 10000, (header: Uint8Array): boolean => RemoteAssetCache.matchesMagic(header, media));
      return saved ? RemoteAssetCache.remember(path, url) : url;
    } catch (e) {
      return url;
    }
  }

  /** 异步校验缓存文件确实存在且文件头是受支持的图片/媒体格式。 */
  private static async validateFile(path: string, media: boolean): Promise<boolean> {
    let file: fs.File | null = null;
    try {
      file = await fs.open(path, fs.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(16);
      const length: number = await fs.read(file.fd, buffer, { offset: 0 });
      return length >= 12 && RemoteAssetCache.matchesMagic(new Uint8Array(buffer, 0, length), media);
    } catch (e) {
      return false;
    } finally {
      if (file !== null) {
        try {
          await fs.close(file);
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

  /**
   * 升级后回收旧版无上限头像缓存。每删除 128 个文件就让出事件循环，避免
   * 同步删除上万个文件卡住 Ability 启动；中途退出时下次启动会继续清理。
   */
  private static scheduleLegacyAvatarPurge(): void {
    if (RemoteAssetCache.legacyAvatarPurgeScheduled) return;
    const dir: string = RemoteAssetCache.dirPath(DIR_LEGACY_AVATARS);
    if (dir.length === 0) return;
    let entries: Array<string> = [];
    try {
      entries = fs.listFileSync(dir);
    } catch (e) {
      return;
    }
    RemoteAssetCache.legacyAvatarPurgeScheduled = true;
    let index: number = 0;
    const removeBatch = (): void => {
      const end: number = Math.min(entries.length, index + 128);
      for (; index < end; index++) {
        try {
          fs.unlinkSync(dir + '/' + entries[index]);
        } catch (e) {
          // 单个旧缓存文件失败不阻塞其余清理；下次启动会再次尝试。
        }
      }
      if (index < entries.length) {
        setTimeout(removeBatch, 0);
        return;
      }
      try {
        fs.rmdirSync(dir);
      } catch (e) {
        // 目录仍有失败项时保留，下次启动继续清理。
      }
    };
    setTimeout(removeBatch, 0);
  }

  /** 升级后回收旧版曾长期留在 cacheDir 根目录的评论分享图与缩略图。 */
  private static scheduleLegacyReplySharePurge(): void {
    if (RemoteAssetCache.legacyReplySharePurgeScheduled || assetCacheDir.length === 0) return;
    let entries: Array<string> = [];
    try {
      entries = fs.listFileSync(assetCacheDir);
    } catch (e) {
      return;
    }
    const legacyFiles: Array<string> = [];
    for (let i: number = 0; i < entries.length; i++) {
      if (/^reply_share_[0-9]+(?:_thumb)?\.(?:png|jpg)$/i.test(entries[i])) legacyFiles.push(entries[i]);
    }
    if (legacyFiles.length === 0) return;
    RemoteAssetCache.legacyReplySharePurgeScheduled = true;
    let index: number = 0;
    const removeBatch = (): void => {
      const end: number = Math.min(legacyFiles.length, index + 64);
      for (; index < end; index++) {
        try {
          fs.unlinkSync(assetCacheDir + '/' + legacyFiles[index]);
        } catch (e) {
          // 单个旧文件失败不阻塞其余清理；下次启动会再次尝试。
        }
      }
      if (index < legacyFiles.length) setTimeout(removeBatch, 0);
    };
    setTimeout(removeBatch, 0);
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
