import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 为 libmpv 的 TLS 后端提供明确的 CA 文件；媒体访问始终验证服务端证书。 */
export class PlayerMpvResources {
  private static context: common.Context | null = null;
  private static caFilePromise: Promise<string> | null = null;

  static configure(context: common.Context): void { PlayerMpvResources.context = context; }

  static caFile(): Promise<string> {
    if (PlayerMpvResources.caFilePromise !== null) return PlayerMpvResources.caFilePromise;
    const context: common.Context | null = PlayerMpvResources.context;
    if (context === null) return Promise.reject(new Error('播放资源尚未初始化'));
    const caFilePromise: Promise<string> = PlayerMpvResources.copyCA(context);
    PlayerMpvResources.caFilePromise = caFilePromise;
    caFilePromise.catch((): void => {
      if (PlayerMpvResources.caFilePromise === caFilePromise) PlayerMpvResources.caFilePromise = null;
    });
    return caFilePromise;
  }

  private static async copyCA(context: common.Context): Promise<string> {
    const path: string = context.filesDir + '/bilimpv-ca-v1.pem';
    const bytes: Uint8Array = await context.resourceManager.getRawFileContent('mpv/cacert.pem');
    const file: fs.File = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE);
    try {
      let offset: number = 0;
      while (offset < bytes.byteLength) {
        const written: number = await fs.write(file.fd,
          bytes.buffer.slice(bytes.byteOffset + offset, bytes.byteOffset + bytes.byteLength));
        if (written <= 0) throw new Error('播放证书写入失败');
        offset += written;
      }
    } finally { await fs.close(file); }
    return path;
  }
}
