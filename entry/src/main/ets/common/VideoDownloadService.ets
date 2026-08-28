/**
 * 媒体文件下载：使用系统 DownloadTask 流式落盘，失败时按播放地址的备用 CDN 顺序重试，
 * 完成后再复制到用户通过文件选择器授权的目标 URI。避免把整段媒体读进 ArkTS 内存。
 */
import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export class VideoDownloadService {
  private static active: boolean = false;
  private static percent: number = -1;

  static isActive(): boolean {
    return VideoDownloadService.active;
  }

  static currentProgress(): number {
    return VideoDownloadService.percent;
  }

  static async downloadToUri(context: common.UIAbilityContext, urls: Array<string>, targetUri: string,
    title: string, headers: Record<string, string>, onProgress: (received: number, total: number) => void): Promise<void> {
    if (urls.length === 0 || targetUri.length === 0) throw new Error('下载地址无效');
    if (VideoDownloadService.active) throw new Error('已有下载任务正在进行');
    VideoDownloadService.active = true;
    VideoDownloadService.percent = -1;
    const tempPath: string = context.cacheDir + '/video_download_' + String(Date.now()) + '.part';
    let lastError: Error = new Error('所有下载线路均不可用');
    try {
      for (let i: number = 0; i < urls.length; i++) {
        VideoDownloadService.removeTemp(tempPath);
        try {
          await VideoDownloadService.downloadCandidate(context, urls[i], tempPath, title, headers,
            (received: number, total: number): void => {
              VideoDownloadService.percent = total > 0 ? Math.max(0, Math.min(100,
                Math.floor(received * 100 / total))) : -1;
              onProgress(received, total);
            });
          const target: fs.File = fs.openSync(targetUri,
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            await fs.copyFile(tempPath, target.fd);
          } finally {
            fs.closeSync(target);
          }
          return;
        } catch (e) {
          lastError = e instanceof Error ? e : new Error(String(e));
        }
      }
      throw lastError;
    } finally {
      VideoDownloadService.removeTemp(tempPath);
      VideoDownloadService.active = false;
      VideoDownloadService.percent = -1;
    }
  }

  private static async downloadCandidate(context: common.UIAbilityContext, url: string, filePath: string,
    title: string, headers: Record<string, string>, onProgress: (received: number, total: number) => void): Promise<void> {
    const task: request.DownloadTask = await request.downloadFile(context, {
      url: url,
      header: headers,
      filePath: filePath,
      title: title,
      description: 'BiliHarmony 媒体下载',
      background: true,
      enableMetered: true,
    });
    return new Promise<void>((resolve, reject) => {
      let settled: boolean = false;
      const progress = (received: number, total: number): void => {
        onProgress(received, total);
      };
      const complete = (): void => {
        if (settled) return;
        settled = true;
        VideoDownloadService.detach(task, progress, complete, fail);
        resolve();
      };
      const fail = (reason: number): void => {
        if (settled) return;
        settled = true;
        VideoDownloadService.detach(task, progress, complete, fail);
        reject(new Error('下载任务失败：' + String(reason)));
      };
      task.on('progress', progress);
      task.on('complete', complete);
      task.on('fail', fail);
    });
  }

  private static detach(task: request.DownloadTask, progress: (received: number, total: number) => void,
    complete: () => void, fail: (reason: number) => void): void {
    try {
      task.off('progress', progress);
      task.off('complete', complete);
      task.off('fail', fail);
    } catch (e) {
      // 任务结束后系统可能已先释放监听器，不影响最终文件。
    }
  }

  private static removeTemp(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // 文件尚未创建或已被系统清理。
    }
  }
}
