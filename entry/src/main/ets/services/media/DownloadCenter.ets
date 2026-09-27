/**
 * 下载中心：带持久化任务记录的媒体下载队列。
 *
 * 与 VideoDownloadService（导出到用户自选位置的一次性任务）互补：
 * - 任务先落盘到应用沙箱 filesDir/downloads，完成后可导出/直接删除；
 * - 队列单并发，FIFO；任务记录持久化到 Preferences，重启后运行中的任务标记为
 *   「已中断」，可重试（重试会重新解析播放地址，旧 CDN URL 会过期）；
 * - 进度经 request.downloadFile 的 background 通知同步展示。
 */
import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { HttpClient } from '../network/HttpClient';
import { BiliApi } from '../../api/BiliApi';
import { PlayUrlInfo } from '../../model/Models';

/** SDK file.fs 只提供 accessSync；包一层存在性判断。 */
function fileExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

export const DOWNLOAD_KIND_VIDEO: number = 0;
export const DOWNLOAD_KIND_AUDIO: number = 1;

export const DOWNLOAD_STATUS_QUEUED: number = 0;
export const DOWNLOAD_STATUS_RUNNING: number = 1;
export const DOWNLOAD_STATUS_DONE: number = 2;
export const DOWNLOAD_STATUS_FAILED: number = 3;
export const DOWNLOAD_STATUS_INTERRUPTED: number = 4;

export class DownloadTaskItem {
  id: string = '';
  kind: number = DOWNLOAD_KIND_VIDEO;
  aid: number = 0;
  bvid: string = '';
  cid: number = 0;
  epId: number = 0;
  /** 重试重解析时请求的清晰度（qn）。 */
  qn: number = 0;
  /** 展示名（含分 P 与画质标签），不含扩展名。 */
  title: string = '';
  qualityLabel: string = '';
  status: number = DOWNLOAD_STATUS_QUEUED;
  progress: number = -1;
  message: string = '';
  /** 沙箱内最终文件路径；完成前为空串。 */
  filePath: string = '';
  createdAt: number = 0;

  extension(): string {
    return this.kind === DOWNLOAD_KIND_AUDIO ? '.m4a' : '.mp4';
  }

  statusLabel(): string {
    switch (this.status) {
      case DOWNLOAD_STATUS_QUEUED:
        return '排队中';
      case DOWNLOAD_STATUS_RUNNING:
        return this.progress >= 0 ? '下载中 ' + String(this.progress) + '%' : '下载中';
      case DOWNLOAD_STATUS_DONE:
        return '已完成';
      case DOWNLOAD_STATUS_FAILED:
        return '失败';
      case DOWNLOAD_STATUS_INTERRUPTED:
        return '已中断';
      default:
        return '';
    }
  }

  static from(o: Object): DownloadTaskItem {
    const j: Record<string, Object> = o as Record<string, Object>;
    const t: DownloadTaskItem = new DownloadTaskItem();
    t.id = typeof j['id'] === 'string' ? j['id'] as string : '';
    t.kind = typeof j['kind'] === 'number' ? j['kind'] as number : DOWNLOAD_KIND_VIDEO;
    t.aid = typeof j['aid'] === 'number' ? j['aid'] as number : 0;
    t.bvid = typeof j['bvid'] === 'string' ? j['bvid'] as string : '';
    t.cid = typeof j['cid'] === 'number' ? j['cid'] as number : 0;
    t.epId = typeof j['epId'] === 'number' ? j['epId'] as number : 0;
    t.qn = typeof j['qn'] === 'number' ? j['qn'] as number : 0;
    t.title = typeof j['title'] === 'string' ? j['title'] as string : '';
    t.qualityLabel = typeof j['qualityLabel'] === 'string' ? j['qualityLabel'] as string : '';
    t.status = typeof j['status'] === 'number' ? j['status'] as number : DOWNLOAD_STATUS_FAILED;
    t.progress = typeof j['progress'] === 'number' ? j['progress'] as number : -1;
    t.message = typeof j['message'] === 'string' ? j['message'] as string : '';
    t.filePath = typeof j['filePath'] === 'string' ? j['filePath'] as string : '';
    t.createdAt = typeof j['createdAt'] === 'number' ? j['createdAt'] as number : 0;
    return t;
  }
}

export class DownloadCenter {
  private static readonly PREFS_NAME: string = 'download_center';
  private static readonly TASKS_KEY: string = 'tasks_v1';
  private static tasks: Array<DownloadTaskItem> = [];
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;
  private static context: common.UIAbilityContext | null = null;
  private static running: boolean = false;
  private static currentRequestId: string = '';
  private static version: number = 0;
  private static progressPersistTimer: number = -1;
  /** 当前系统下载句柄：删除任务时用于取消。 */
  static activeSystemTask: request.DownloadTask | null = null;
  private static activeCancel: (() => void) | null = null;

  /** 由 EntryAbility/页面首次访问前调用：恢复记录并把中断任务标记出来。 */
  static init(context: common.UIAbilityContext): Promise<void> {
    if (DownloadCenter.ready !== null) return DownloadCenter.ready;
    DownloadCenter.context = context;
    DownloadCenter.ready = DownloadCenter.restore(context);
    return DownloadCenter.ready;
  }

  private static async restore(context: common.UIAbilityContext): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, {
        name: DownloadCenter.PREFS_NAME,
      });
      DownloadCenter.store = store;
      const raw: string = store.getSync(DownloadCenter.TASKS_KEY, '[]') as string;
      const parsed: Object = JSON.parse(raw.length > 0 ? raw : '[]') as Object;
      if (Array.isArray(parsed)) {
        const list: Array<Object> = parsed as Array<Object>;
        DownloadCenter.tasks = list.map((item: Object): DownloadTaskItem => DownloadTaskItem.from(item))
          .filter((t: DownloadTaskItem): boolean => t.id.length > 0);
      }
      // 上次退出时还在排队/下载的任务：CDN URL 已失效，标记为中断等待重试。
      let changed: boolean = false;
      for (let i: number = 0; i < DownloadCenter.tasks.length; i++) {
        const t: DownloadTaskItem = DownloadCenter.tasks[i];
        if (t.status === DOWNLOAD_STATUS_QUEUED || t.status === DOWNLOAD_STATUS_RUNNING) {
          t.status = DOWNLOAD_STATUS_INTERRUPTED;
          t.progress = -1;
          t.message = '应用退出导致下载中断，可重试';
          changed = true;
        }
      }
      if (changed) await DownloadCenter.persist();
    } catch (e) {
      // 记录恢复失败不阻断功能：空队列重新开始。
      DownloadCenter.tasks = [];
    }
  }

  static async ensureLoaded(): Promise<void> {
    if (DownloadCenter.ready !== null) await DownloadCenter.ready;
  }

  static list(): Array<DownloadTaskItem> {
    return DownloadCenter.tasks;
  }

  static hasActive(): boolean {
    return DownloadCenter.running ||
      DownloadCenter.tasks.some((t: DownloadTaskItem): boolean =>
        t.status === DOWNLOAD_STATUS_QUEUED || t.status === DOWNLOAD_STATUS_RUNNING);
  }

  private static async persist(): Promise<void> {
    DownloadCenter.version++;
    if (DownloadCenter.store === null) return;
    const raw: string = JSON.stringify(DownloadCenter.tasks);
    try {
      DownloadCenter.store.putSync(DownloadCenter.TASKS_KEY, raw);
      await DownloadCenter.store.flush();
    } catch (e) {
      // 落盘失败保内存态，下次操作再写。
    }
  }

  /** 进度最多每秒写盘一次；完成、失败和删除仍立即持久化。 */
  private static scheduleProgressPersist(): void {
    if (DownloadCenter.progressPersistTimer >= 0) return;
    DownloadCenter.progressPersistTimer = setTimeout(() => {
      DownloadCenter.progressPersistTimer = -1;
      void DownloadCenter.persist();
    }, 1000);
  }

  private static clearProgressPersistTimer(): void {
    if (DownloadCenter.progressPersistTimer < 0) return;
    clearTimeout(DownloadCenter.progressPersistTimer);
    DownloadCenter.progressPersistTimer = -1;
  }

  /** 入队：调用方已带好标识信息；地址在任务真正开始时解析（避免入队时 URL 过期）。 */
  static async enqueue(kind: number, aid: number, bvid: string, cid: number, epId: number,
    qn: number, title: string, qualityLabel: string): Promise<string> {
    await DownloadCenter.ensureLoaded();
    if (DownloadCenter.context === null) throw new Error('下载中心尚未初始化');
    const item: DownloadTaskItem = new DownloadTaskItem();
    item.id = 'dl' + String(Date.now()) + String(Math.floor(Math.random() * 9000 + 1000));
    item.kind = kind;
    item.aid = aid;
    item.bvid = bvid;
    item.cid = cid;
    item.epId = epId;
    item.qn = qn;
    item.title = title;
    item.qualityLabel = qualityLabel;
    item.status = DOWNLOAD_STATUS_QUEUED;
    item.createdAt = Date.now();
    DownloadCenter.tasks.unshift(item);
    await DownloadCenter.persist();
    DownloadCenter.pump();
    return item.id;
  }

  private static pump(): void {
    if (DownloadCenter.running) return;
    let next: DownloadTaskItem | null = null;
    for (let i: number = DownloadCenter.tasks.length - 1; i >= 0; i--) {
      // tasks 是新任务在前的数组：从尾部找最早的排队任务，保持 FIFO。
      const t: DownloadTaskItem = DownloadCenter.tasks[i];
      if (t.status === DOWNLOAD_STATUS_QUEUED) {
        next = t;
        break;
      }
    }
    if (next === null) return;
    const task: DownloadTaskItem = next;
    DownloadCenter.running = true;
    DownloadCenter.currentRequestId = task.id;
    DownloadCenter.runOne(task).catch(() => {
    }).finally(() => {
      const isCurrent: boolean = DownloadCenter.currentRequestId === task.id;
      DownloadCenter.running = false;
      DownloadCenter.currentRequestId = '';
      if (isCurrent) DownloadCenter.pump();
    });
  }

  private static async runOne(task: DownloadTaskItem): Promise<void> {
    if (DownloadCenter.context === null) return;
    task.status = DOWNLOAD_STATUS_RUNNING;
    task.progress = -1;
    task.message = '';
    await DownloadCenter.persist();
    try {
      if (task.status === DOWNLOAD_STATUS_INTERRUPTED) return;
      // 解析下载地址（重试场景下旧地址已过期，必须每次重取）。
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(task.aid, task.bvid, task.cid,
        task.qn > 0 ? task.qn : 127, task.epId, false);
      if (task.status === DOWNLOAD_STATUS_INTERRUPTED) return;
      if (info === null) throw new Error('暂时无法获取下载地址');
      const urls: Array<string> = task.kind === DOWNLOAD_KIND_AUDIO ? info.downloadAudioUrls : info.urls;
      if (urls.length === 0) {
        throw new Error(task.kind === DOWNLOAD_KIND_AUDIO ? '该视频没有独立音轨' : '该画质没有可下载的视频流');
      }
      if (task.kind === DOWNLOAD_KIND_VIDEO && info.isDash) {
        // DASH 分离流无法在沙箱内合成 MP4：仅缓存 MP4 单流画质。
        throw new Error('该画质只有分离流，请选择更低画质（MP4）或使用导出');
      }
      const dir: string = DownloadCenter.context.filesDir + '/downloads';
      try {
        if (!fileExists(dir)) fs.mkdirSync(dir, true);
      } catch (e) {
        // 目录已存在。
      }
      const partPath: string = dir + '/' + task.id + '.part';
      const finalPath: string = dir + '/' + task.id + task.extension();
      const refererId: string = task.bvid.length > 0 ? task.bvid : 'av' + String(task.aid);
      await VideoDownloadServiceLike.downloadToFile(DownloadCenter.context, urls, partPath, finalPath,
        HttpClient.getDownloadHeaders('https://www.bilibili.com/video/' + refererId),
        (received: number, total: number): void => {
          if (task.status !== DOWNLOAD_STATUS_RUNNING) return;
          const nextProgress: number = total > 0 ? Math.max(0, Math.min(100, Math.floor(received * 100 / total))) : -1;
          if (nextProgress === task.progress) return;
          task.progress = nextProgress;
          DownloadCenter.scheduleProgressPersist();
        }, (): boolean => task.status === DOWNLOAD_STATUS_INTERRUPTED,
        (cancel: (() => void) | null): void => { DownloadCenter.activeCancel = cancel; });
      if (task.status === DOWNLOAD_STATUS_INTERRUPTED) return;
      task.filePath = finalPath;
      task.progress = 100;
      task.status = DOWNLOAD_STATUS_DONE;
    } catch (e) {
      if (task.status === DOWNLOAD_STATUS_INTERRUPTED) return; // 用户已删除任务
      task.status = DOWNLOAD_STATUS_FAILED;
      task.progress = -1;
      task.message = e instanceof Error ? e.message : String(e);
      if (task.message.length === 0) task.message = '下载失败';
    }
    DownloadCenter.clearProgressPersistTimer();
    await DownloadCenter.persist();
  }

  /** 重试：重新解析地址并排队。 */
  static async retry(id: string): Promise<void> {
    await DownloadCenter.ensureLoaded();
    const task: DownloadTaskItem | null = DownloadCenter.find(id);
    if (task === null) return;
    if (task.status === DOWNLOAD_STATUS_RUNNING) return;
    try {
      if (fileExists(task.filePath)) fs.unlinkSync(task.filePath);
    } catch (e) {
      // 文件可能尚未生成。
    }
    task.filePath = '';
    task.status = DOWNLOAD_STATUS_QUEUED;
    task.progress = -1;
    task.message = '';
    await DownloadCenter.persist();
    DownloadCenter.pump();
  }

  /** 删除任务与已落盘文件。运行中的任务先由下载器感知 remove 停止。 */
  static async remove(id: string): Promise<void> {
    await DownloadCenter.ensureLoaded();
    const task: DownloadTaskItem | null = DownloadCenter.find(id);
    if (task === null) return;
    const wasRunning: boolean = task.status === DOWNLOAD_STATUS_RUNNING;
    task.status = DOWNLOAD_STATUS_INTERRUPTED;
    task.message = '';
    DownloadCenter.clearProgressPersistTimer();
    // 运行中先取消系统任务（runOne 的 catch 感知中断后不再回写状态）。
    if (wasRunning && DownloadCenter.activeSystemTask !== null) {
      try {
        await DownloadCenter.activeSystemTask.delete();
      } catch (e) {
        // 任务可能已结束。
      }
    }
    if (wasRunning && DownloadCenter.activeCancel !== null) DownloadCenter.activeCancel();
    try {
      if (task.filePath.length > 0 && fileExists(task.filePath)) fs.unlinkSync(task.filePath);
    } catch (e) {
      // 文件可能已被清理。
    }
    DownloadCenter.tasks = DownloadCenter.tasks.filter((t: DownloadTaskItem): boolean => t.id !== id);
    try {
      const part: string = DownloadCenter.context !== null
        ? DownloadCenter.context.filesDir + '/downloads/' + id + '.part' : '';
      if (part.length > 0 && fileExists(part)) fs.unlinkSync(part);
    } catch (e) {
      // 忽略。
    }
    await DownloadCenter.persist();
  }

  /** 清理已完成/已失败/已中断的记录及其本地文件；调用方需明确告知未导出文件也会删除。 */
  static async clearFinished(): Promise<void> {
    await DownloadCenter.ensureLoaded();
    const finished: Array<DownloadTaskItem> = DownloadCenter.tasks.filter((t: DownloadTaskItem): boolean =>
      t.status === DOWNLOAD_STATUS_DONE || t.status === DOWNLOAD_STATUS_FAILED ||
      t.status === DOWNLOAD_STATUS_INTERRUPTED);
    for (let i: number = 0; i < finished.length; i++) {
      try {
        const t: DownloadTaskItem = finished[i];
        if (t.filePath.length > 0 && fileExists(t.filePath)) fs.unlinkSync(t.filePath);
      } catch (e) {
        // 忽略单个文件失败。
      }
    }
    DownloadCenter.tasks = DownloadCenter.tasks.filter((t: DownloadTaskItem): boolean =>
      t.status === DOWNLOAD_STATUS_QUEUED || t.status === DOWNLOAD_STATUS_RUNNING);
    await DownloadCenter.persist();
  }

  private static find(id: string): DownloadTaskItem | null {
    for (let i: number = 0; i < DownloadCenter.tasks.length; i++) {
      if (DownloadCenter.tasks[i].id === id) return DownloadCenter.tasks[i];
    }
    return null;
  }
}

/**
 * 复用 VideoDownloadService 的 CDN 容错下载，但落到指定路径而不是用户 URI。
 * 独立成内部包装，避免把导出语义（DocumentSaveOptions）带进下载中心。
 */
class VideoDownloadServiceLike {
  static async downloadToFile(context: common.UIAbilityContext, urls: Array<string>, partPath: string,
    finalPath: string, headers: Record<string, string>, onProgress: (received: number, total: number) => void,
    isCancelled: () => boolean, setCancel: (cancel: (() => void) | null) => void)
    : Promise<void> {
    let lastError: Error = new Error('所有下载线路均不可用');
    for (let i: number = 0; i < urls.length; i++) {
      if (isCancelled()) throw new Error('下载已取消');
      try {
        const task: request.DownloadTask = await request.downloadFile(context, {
          url: urls[i],
          header: headers,
          filePath: partPath,
          title: 'BiliHaromny 下载中心',
          description: 'BiliHaromny 媒体下载',
          background: true,
          enableMetered: true,
        });
        if (isCancelled()) {
          try { await task.delete(); } catch (e) {}
          throw new Error('下载已取消');
        }
        DownloadCenter.activeSystemTask = task;
        await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
          let settled: boolean = false;
          const progress = (received: number, total: number): void => {
            if (!isCancelled()) onProgress(received, total);
          };
          const complete = (): void => {
            if (settled) return;
            settled = true;
            detach();
            resolve();
          };
          const fail = (reason: number): void => {
            if (settled) return;
            settled = true;
            detach();
            reject(new Error('下载任务失败：' + String(reason)));
          };
          const removed = (): void => {
            if (settled) return;
            settled = true;
            detach();
            reject(new Error('下载已取消'));
          };
          setCancel(removed);
          const detach = (): void => {
            setCancel(null);
            try {
              task.off('progress', progress);
              task.off('complete', complete);
              task.off('fail', fail);
              task.off('remove', removed);
            } catch (e) {
              // 监听器可能已被系统释放。
            }
          };
          task.on('progress', progress);
          task.on('complete', complete);
          task.on('fail', fail);
          task.on('remove', removed);
        });
        DownloadCenter.activeSystemTask = null;
        if (isCancelled()) throw new Error('下载已取消');
        if (fileExists(partPath)) fs.moveFileSync(partPath, finalPath);
        return;
      } catch (e) {
        DownloadCenter.activeSystemTask = null;
        setCancel(null);
        try {
          if (fileExists(partPath)) fs.unlinkSync(partPath);
        } catch (err) {
          // 忽略。
        }
        lastError = e instanceof Error ? e : new Error(String(e));
        if (isCancelled()) throw lastError;
      }
    }
    throw lastError;
  }
}
