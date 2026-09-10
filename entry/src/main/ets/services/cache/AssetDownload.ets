import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 有界流式落盘：不拼接整个响应；短写续写，失败只删除临时文件。 */
export class AssetDownload {
  private static active: number = 0;
  private static waiting: Array<() => void> = [];
  private static serial: number = 0;
  private static readonly MAX_CONCURRENT: number = 3;
  private static readonly MAX_PENDING_BYTES: number = 4 * 1024 * 1024;

  private static async acquire(): Promise<void> {
    if (AssetDownload.active < AssetDownload.MAX_CONCURRENT) {
      AssetDownload.active++;
      return;
    }
    await new Promise<void>((resolve) => AssetDownload.waiting.push(resolve));
  }

  private static release(): void {
    const next: (() => void) | undefined = AssetDownload.waiting.shift();
    if (next !== undefined) next();
    else AssetDownload.active--;
  }

  static async save(url: string, path: string, limit: number, readTimeout: number,
    validate: (header: Uint8Array) => boolean): Promise<boolean> {
    await AssetDownload.acquire();
    try {
      return await AssetDownload.transfer(url, path, limit, readTimeout, validate);
    } finally {
      AssetDownload.release();
    }
  }

  private static async transfer(url: string, path: string, limit: number, readTimeout: number,
    validate: (header: Uint8Array) => boolean): Promise<boolean> {
    const tempPath: string = path + '.' + String(++AssetDownload.serial) + '.part';
    let file: fs.File | null = null;
    let request: http.HttpRequest | null = null;
    let writes: Promise<void> = Promise.resolve();
    let received: number = 0;
    let pending: number = 0;
    let failed: boolean = false;
    let finish: () => void = () => {};
    const ended: Promise<void> = new Promise<void>((resolve) => { finish = resolve; });
    try {
      file = await fs.open(tempPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const fd: number = file.fd;
      const stream: http.HttpRequest = http.createHttp();
      request = stream;
      const stop = (): void => {
        if (failed) return;
        failed = true;
        finish();
        stream.destroy();
      };
      stream.on('dataEnd', () => finish());
      stream.on('dataReceive', (chunk: ArrayBuffer) => {
        if (failed) return;
        received += chunk.byteLength;
        if (received > limit || pending + chunk.byteLength > AssetDownload.MAX_PENDING_BYTES) {
          stop();
          return;
        }
        pending += chunk.byteLength;
        writes = writes.then(async (): Promise<void> => {
          if (failed) return;
          let offset: number = 0;
          while (offset < chunk.byteLength) {
            const remaining: ArrayBuffer = offset === 0 ? chunk : chunk.slice(offset);
            const written: number = await fs.write(fd, remaining);
            if (written <= 0) throw new Error('缓存文件写入未推进');
            offset += written;
          }
        }).catch(() => stop()).finally(() => { pending -= chunk.byteLength; });
      });
      const status: number = await stream.requestInStream(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: readTimeout,
        maxLimit: limit,
      });
      await ended;
      await writes;
      if (failed || status < 200 || status >= 300 || received < 12) return false;
      const header: ArrayBuffer = new ArrayBuffer(16);
      const length: number = await fs.read(fd, header, { offset: 0 });
      if (length < 12 || !validate(new Uint8Array(header, 0, length))) return false;
      await fs.close(file);
      file = null;
      await fs.rename(tempPath, path);
      return true;
    } catch (e) {
      failed = true;
      return false;
    } finally {
      if (request !== null) request.destroy();
      await writes;
      if (file !== null) {
        try { await fs.close(file); } catch (e) {}
      }
      try { await fs.unlink(tempPath); } catch (e) {}
    }
  }
}
