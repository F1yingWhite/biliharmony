/**
 * 下载中心：带持久化任务记录的媒体下载队列。
 *
 * 与 VideoDownloadService（导出到用户自选位置的一次性任务）互补：
 * - 任务先落盘到应用沙箱 filesDir/downloads，完成后可导出/直接删除；
 * - 队列单并发，FIFO；保存系统任务 ID，重启后接管后台任务；
 * - 重试重新解析地址，并用独立临时文件隔离无法接管的旧下载；
 * - 进度经 request.agent 的后台通知同步展示，前台主动补查状态。
 */
import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
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
export const DOWNLOAD_STATUS_WAITING: number = 5;
export const DOWNLOAD_STATUS_PAUSED: number = 6;

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
  systemTaskId: string = '';
  partPath: string = '';
  attempt: number = 0;
  receivedBytes: number = 0;
  totalBytes: number = -1;
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
      case DOWNLOAD_STATUS_WAITING:
        return '等待网络或系统资源';
      case DOWNLOAD_STATUS_PAUSED:
        return '已暂停';
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
    t.systemTaskId = typeof j['systemTaskId'] === 'string' ? j['systemTaskId'] as string : '';
    t.partPath = typeof j['partPath'] === 'string' ? j['partPath'] as string : '';
    t.attempt = typeof j['attempt'] === 'number' ? Math.max(0, Math.floor(j['attempt'] as number)) : 0;
    t.receivedBytes = typeof j['receivedBytes'] === 'number' ? j['receivedBytes'] as number : 0;
    t.totalBytes = typeof j['totalBytes'] === 'number' ? j['totalBytes'] as number : -1;
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
  private static currentRun: Promise<void> | null = null;
  private static version: number = 0;
  private static progressPersistTimer: number = -1;
  /** 当前系统下载句柄：删除任务时用于取消。 */
  static activeSystemTask: request.agent.Task | null = null;
  private static activeCancel: (() => void) | null = null;
  private static activeSync: (() => Promise<void>) | null = null;
  private static foregroundSync: Promise<void> | null = null;
  private static mutations: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  /** 由 EntryAbility/页面首次访问前调用：恢复记录并把中断任务标记出来。 */
  static init(context: common.UIAbilityContext): Promise<void> {
    if (DownloadCenter.ready !== null) return DownloadCenter.ready;
    DownloadCenter.context = context;
    DownloadCenter.ready = DownloadCenter.restore(context).catch(() => {
      // 只缓存成功的恢复；失败时禁用写入，下一次访问可以重新读盘。
      DownloadCenter.store = null;
      DownloadCenter.ready = null;
      throw new Error('下载记录恢复失败，请重试');
    });
    return DownloadCenter.ready;
  }

  private static async restore(context: common.UIAbilityContext): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, {
      name: DownloadCenter.PREFS_NAME,
    });
    const raw: string = store.getSync(DownloadCenter.TASKS_KEY, '[]') as string;
    const parsed: Object = JSON.parse(raw.length > 0 ? raw : '[]') as Object;
    if (!Array.isArray(parsed)) throw new Error('下载记录格式错误');
    const list: Array<Object> = parsed as Array<Object>;
    const restored: Array<DownloadTaskItem> = list
      .map((item: Object): DownloadTaskItem => DownloadTaskItem.from(item))
      .filter((t: DownloadTaskItem): boolean => t.id.length > 0);
    // 读取和解析全部成功后才发布 store，避免失败后把原记录覆盖成空列表。
    DownloadCenter.tasks = restored;
    DownloadCenter.store = store;
    // 可接管的系统任务保留 ID；旧版本无 ID 的下载不能确认是否仍写入，保留旧文件。
    let changed: boolean = false;
    for (let i: number = 0; i < DownloadCenter.tasks.length; i++) {
      const t: DownloadTaskItem = DownloadCenter.tasks[i];
      if (t.status !== DOWNLOAD_STATUS_DONE && t.systemTaskId.length > 0) {
        t.status = DOWNLOAD_STATUS_WAITING;
        t.message = '正在恢复系统下载';
        changed = true;
      } else if (t.status === DOWNLOAD_STATUS_QUEUED || t.status === DOWNLOAD_STATUS_RUNNING ||
        t.status === DOWNLOAD_STATUS_WAITING || t.status === DOWNLOAD_STATUS_PAUSED) {
        t.status = DOWNLOAD_STATUS_INTERRUPTED;
        t.progress = -1;
        t.message = '旧下载无法接管，可重试；重试使用独立临时文件';
        changed = true;
      }
    }
    if (changed) await DownloadCenter.persist();
    DownloadCenter.pump();
  }

  static async ensureLoaded(): Promise<void> {
    if (DownloadCenter.ready !== null) {
      await DownloadCenter.ready;
    } else if (DownloadCenter.context !== null) {
      await DownloadCenter.init(DownloadCenter.context);
    } else {
      throw new Error('下载中心尚未初始化');
    }
  }

  static list(): Array<DownloadTaskItem> {
    return DownloadCenter.tasks;
  }

  /** EntryAbility.onForeground 与页面进入时调用；单飞补查后台丢失的状态/进度。 */
  static onForeground(context: common.UIAbilityContext): Promise<void> {
    if (DownloadCenter.foregroundSync !== null) return DownloadCenter.foregroundSync;
    const pending: Promise<void> = DownloadCenter.init(context).then(async (): Promise<void> => {
      if (DownloadCenter.activeSync !== null) {
        await DownloadCenter.activeSync();
      } else {
        for (const item of DownloadCenter.tasks) {
          if (!DownloadCenter.mutations.has(item.id) && item.systemTaskId.length > 0 &&
            item.status === DOWNLOAD_STATUS_INTERRUPTED) {
            item.status = DOWNLOAD_STATUS_WAITING;
          }
        }
        DownloadCenter.pump();
      }
    }).finally(() => { DownloadCenter.foregroundSync = null; });
    DownloadCenter.foregroundSync = pending;
    return pending;
  }

  static hasActive(): boolean {
    return DownloadCenter.running ||
      DownloadCenter.tasks.some((t: DownloadTaskItem): boolean =>
        t.status === DOWNLOAD_STATUS_QUEUED || t.status === DOWNLOAD_STATUS_RUNNING ||
        t.status === DOWNLOAD_STATUS_WAITING || t.status === DOWNLOAD_STATUS_PAUSED ||
        (t.systemTaskId.length > 0 && t.status !== DOWNLOAD_STATUS_DONE));
  }

  private static async persist(required: boolean = false): Promise<void> {
    DownloadCenter.version++;
    if (DownloadCenter.store === null) {
      if (required) throw new Error('下载记录尚未恢复，无法启动系统任务');
      return;
    }
    const raw: string = JSON.stringify(DownloadCenter.tasks);
    try {
      DownloadCenter.store.putSync(DownloadCenter.TASKS_KEY, raw);
      await DownloadCenter.store.flush();
    } catch (e) {
      // 落盘失败保内存态，下次操作再写。
      if (required) throw new Error('下载记录保存失败，请重试');
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
    // 未确认旧系统任务停止时，不启动第二个后台任务破坏单并发。
    if (DownloadCenter.tasks.some((t: DownloadTaskItem): boolean => t.systemTaskId.length > 0 &&
      (t.status === DOWNLOAD_STATUS_INTERRUPTED || t.status === DOWNLOAD_STATUS_FAILED))) return;
    let next: DownloadTaskItem | null = null;
    for (let i: number = DownloadCenter.tasks.length - 1; i >= 0; i--) {
      // tasks 是新任务在前的数组：从尾部找最早的排队任务，保持 FIFO。
      const t: DownloadTaskItem = DownloadCenter.tasks[i];
      if (t.status === DOWNLOAD_STATUS_QUEUED || (t.systemTaskId.length > 0 &&
        (t.status === DOWNLOAD_STATUS_WAITING || t.status === DOWNLOAD_STATUS_PAUSED ||
        t.status === DOWNLOAD_STATUS_RUNNING))) {
        next = t;
        break;
      }
    }
    if (next === null) return;
    const task: DownloadTaskItem = next;
    DownloadCenter.running = true;
    DownloadCenter.currentRequestId = task.id;
    const pending: Promise<void> = DownloadCenter.runOne(task).catch(() => {
    }).finally(() => {
      const isCurrent: boolean = DownloadCenter.currentRequestId === task.id;
      if (isCurrent) {
        DownloadCenter.running = false;
        DownloadCenter.currentRequestId = '';
        DownloadCenter.currentRun = null;
        DownloadCenter.pump();
      }
    });
    DownloadCenter.currentRun = pending;
  }

  private static async runOne(task: DownloadTaskItem): Promise<void> {
    if (DownloadCenter.context === null) return;
    if (task.systemTaskId.length > 0) {
      try {
        const system: request.agent.Task = await request.agent.getTask(DownloadCenter.context, task.systemTaskId);
        if (DownloadCenter.isCancelled(task)) return;
        await DownloadCenter.waitForSystem(task, system, false);
        await DownloadCenter.finishFile(task);
      } catch (e) {
        if (!DownloadCenter.isCancelled(task)) {
          task.status = DOWNLOAD_STATUS_INTERRUPTED;
          task.message = '系统下载恢复失败，可返回前台再试或重试';
          await DownloadCenter.persist();
        }
      }
      return;
    }
    task.status = DOWNLOAD_STATUS_RUNNING;
    task.progress = -1;
    task.message = '';
    await DownloadCenter.persist();
    try {
      if (DownloadCenter.isCancelled(task)) return;
      // 解析下载地址（重试场景下旧地址已过期，必须每次重取）。
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(task.aid, task.bvid, task.cid,
        task.qn > 0 ? task.qn : 127, task.epId, false);
      if (DownloadCenter.isCancelled(task)) return;
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
      const refererId: string = task.bvid.length > 0 ? task.bvid : 'av' + String(task.aid);
      let lastError: Error = new Error('所有下载线路均不可用');
      for (const url of urls) {
        if (DownloadCenter.isCancelled(task)) return;
        task.attempt++;
        task.partPath = dir + '/' + task.id + '.a' + String(task.attempt) + '.part';
        await DownloadCenter.persist(true);
        if (DownloadCenter.isCancelled(task)) return;
        try {
          const system: request.agent.Task = await request.agent.create(DownloadCenter.context, {
            action: request.agent.Action.DOWNLOAD, mode: request.agent.Mode.BACKGROUND,
            url: url, headers: HttpClient.getDownloadHeaders('https://www.bilibili.com/video/' + refererId),
            saveas: task.partPath, overwrite: false, metered: true, roaming: false,
            retry: true, gauge: true, title: 'BiliHaromny 下载中心', description: '媒体下载',
          });
          if (DownloadCenter.isCancelled(task)) {
            await request.agent.remove(system.tid);
            DownloadCenter.cleanPart(task);
            return;
          }
          task.systemTaskId = system.tid;
          // 先落盘 ID，再启动；创建与保存之间退出只留下未启动的系统任务。
          await DownloadCenter.persist(true);
          if (DownloadCenter.isCancelled(task)) return;
          await DownloadCenter.waitForSystem(task, system, true);
          await DownloadCenter.finishFile(task);
          return;
        } catch (e) {
          if (DownloadCenter.isCancelled(task)) return;
          lastError = e instanceof Error ? e : new Error(String(e));
          // remove 确认系统停止后才回收临时文件或尝试另一线路。
          await DownloadCenter.stopSystem(task);
          DownloadCenter.cleanPart(task);
        }
      }
      throw lastError;
    } catch (e) {
      if (DownloadCenter.isCancelled(task)) return; // 用户已删除任务
      task.status = DOWNLOAD_STATUS_FAILED;
      task.progress = -1;
      task.message = e instanceof Error ? e.message : String(e);
      if (task.message.length === 0) task.message = '下载失败';
    }
    DownloadCenter.clearProgressPersistTimer();
    await DownloadCenter.persist();
  }

  /** 重试：重新解析地址并排队。 */
  static retry(id: string): Promise<void> {
    return DownloadCenter.mutate(id, (): Promise<void> => DownloadCenter.retryOne(id));
  }

  private static async retryOne(id: string): Promise<void> {
    await DownloadCenter.ensureLoaded();
    const task: DownloadTaskItem | null = DownloadCenter.find(id);
    if (task === null) return;
    if (task.status === DOWNLOAD_STATUS_RUNNING || task.status === DOWNLOAD_STATUS_QUEUED) return;
    const previousStatus: number = task.status;
    const oldRun: Promise<void> | null = DownloadCenter.currentRequestId === id ? DownloadCenter.currentRun : null;
    task.status = DOWNLOAD_STATUS_INTERRUPTED;
    try { await DownloadCenter.stopSystem(task); } catch (e) { task.status = previousStatus; throw (e as Error); }
    if (DownloadCenter.currentRequestId === id && DownloadCenter.activeCancel !== null) DownloadCenter.activeCancel();
    if (oldRun !== null) await oldRun;
    if (DownloadCenter.find(id) !== task) return;
    DownloadCenter.cleanPart(task);
    try {
      if (fileExists(task.filePath)) fs.unlinkSync(task.filePath);
    } catch (e) {
      // 文件可能尚未生成。
    }
    task.filePath = '';
    task.status = DOWNLOAD_STATUS_QUEUED;
    task.progress = -1;
    task.message = '';
    task.receivedBytes = 0;
    task.totalBytes = -1;
    await DownloadCenter.persist();
    DownloadCenter.pump();
  }

  static resume(id: string): Promise<void> {
    return DownloadCenter.mutate(id, (): Promise<void> => DownloadCenter.resumeOne(id));
  }

  private static async resumeOne(id: string): Promise<void> {
    await DownloadCenter.ensureLoaded();
    const item: DownloadTaskItem | null = DownloadCenter.find(id);
    if (item === null || DownloadCenter.context === null || item.systemTaskId.length === 0 ||
      item.status !== DOWNLOAD_STATUS_PAUSED) return;
    const system: request.agent.Task = DownloadCenter.activeSystemTask !== null &&
      DownloadCenter.currentRequestId === id ? DownloadCenter.activeSystemTask :
      await request.agent.getTask(DownloadCenter.context, item.systemTaskId);
    const info: request.agent.TaskInfo = await request.agent.show(system.tid);
    if (DownloadCenter.find(id) !== item || item.systemTaskId !== system.tid) return;
    if (info.progress.state === request.agent.State.STOPPED || info.progress.state === request.agent.State.INITIALIZED) {
      await system.start();
    } else if (info.progress.state === request.agent.State.PAUSED) {
      await system.resume();
    }
    if (DownloadCenter.find(id) !== item) return;
    item.status = DOWNLOAD_STATUS_RUNNING;
    item.message = '';
    await DownloadCenter.persist();
    DownloadCenter.pump();
    if (DownloadCenter.activeSync !== null) await DownloadCenter.activeSync();
  }

  /** 删除任务与已落盘文件。运行中的任务先由下载器感知 remove 停止。 */
  static remove(id: string): Promise<void> {
    return DownloadCenter.mutate(id, (): Promise<void> => DownloadCenter.removeOne(id));
  }

  private static async removeOne(id: string): Promise<void> {
    await DownloadCenter.ensureLoaded();
    const task: DownloadTaskItem | null = DownloadCenter.find(id);
    if (task === null) return;
    const oldStatus: number = task.status;
    const oldRun: Promise<void> | null = DownloadCenter.currentRequestId === id ? DownloadCenter.currentRun : null;
    task.status = DOWNLOAD_STATUS_INTERRUPTED;
    task.message = '';
    DownloadCenter.clearProgressPersistTimer();
    try {
      await DownloadCenter.stopSystem(task);
    } catch (e) {
      task.status = oldStatus;
      task.message = '系统下载尚未停止，请稍后重试删除';
      await DownloadCenter.persist();
      throw (e as Error);
    }
    if (DownloadCenter.currentRequestId === id && DownloadCenter.activeCancel !== null) DownloadCenter.activeCancel();
    if (oldRun !== null) await oldRun;
    try {
      if (task.filePath.length > 0 && fileExists(task.filePath)) fs.unlinkSync(task.filePath);
    } catch (e) {
      // 文件可能已被清理。
    }
    DownloadCenter.tasks = DownloadCenter.tasks.filter((t: DownloadTaskItem): boolean => t.id !== id);
    DownloadCenter.cleanPart(task);
    await DownloadCenter.persist();
    DownloadCenter.pump();
  }

  /** 清理已完成/已失败/已中断的记录及其本地文件；调用方需明确告知未导出文件也会删除。 */
  static async clearFinished(): Promise<void> {
    await DownloadCenter.ensureLoaded();
    const finished: Array<DownloadTaskItem> = DownloadCenter.tasks.filter((t: DownloadTaskItem): boolean =>
      t.status === DOWNLOAD_STATUS_DONE || t.status === DOWNLOAD_STATUS_FAILED ||
      t.status === DOWNLOAD_STATUS_INTERRUPTED);
    for (let i: number = 0; i < finished.length; i++) {
      const t: DownloadTaskItem = finished[i];
      await DownloadCenter.mutate(t.id, async (): Promise<void> => {
        const current: DownloadTaskItem | null = DownloadCenter.find(t.id);
        if (current !== null && (current.status === DOWNLOAD_STATUS_DONE || current.status === DOWNLOAD_STATUS_FAILED ||
          current.status === DOWNLOAD_STATUS_INTERRUPTED)) await DownloadCenter.removeOne(t.id);
      });
    }
  }

  private static mutate(id: string, action: () => Promise<void>): Promise<void> {
    const previous: Promise<void> = DownloadCenter.mutations.get(id) || Promise.resolve();
    const pending: Promise<void> = previous.catch(() => {}).then(action).finally(() => {
      if (DownloadCenter.mutations.get(id) === pending) DownloadCenter.mutations.delete(id);
    });
    DownloadCenter.mutations.set(id, pending);
    return pending;
  }

  private static find(id: string): DownloadTaskItem | null {
    for (let i: number = 0; i < DownloadCenter.tasks.length; i++) {
      if (DownloadCenter.tasks[i].id === id) return DownloadCenter.tasks[i];
    }
    return null;
  }

  private static isCancelled(item: DownloadTaskItem): boolean {
    return DownloadCenter.find(item.id) !== item || item.status === DOWNLOAD_STATUS_INTERRUPTED;
  }

  private static cleanPart(item: DownloadTaskItem): void {
    if (item.systemTaskId.length > 0 || DownloadCenter.context === null) return;
    const expected: string = DownloadCenter.context.filesDir + '/downloads/' + item.id + '.a' +
      String(item.attempt) + '.part';
    // 无 ID 的旧版 .part 可能仍由系统写入，不能猜测其已停止。
    if (item.partPath !== expected) return;
    try { if (fileExists(expected)) fs.unlinkSync(expected); } catch (e) {}
    item.partPath = '';
  }

  private static async stopSystem(item: DownloadTaskItem): Promise<void> {
    if (item.systemTaskId.length === 0) return;
    try {
      await request.agent.remove(item.systemTaskId);
    } catch (e) {
      if ((e as BusinessError).code !== 21900006) throw (e as Error); // 仅“已删除/不存在”可确认没有写入者。
    }
    item.systemTaskId = '';
    await DownloadCenter.persist();
  }

  private static async finishFile(item: DownloadTaskItem): Promise<void> {
    if (DownloadCenter.isCancelled(item) || DownloadCenter.context === null) return;
    const finalPath: string = DownloadCenter.context.filesDir + '/downloads/' + item.id + item.extension();
    if (fileExists(item.partPath)) fs.moveFileSync(item.partPath, finalPath);
    else if (!fileExists(finalPath)) throw new Error('下载文件不存在，请重试');
    item.filePath = finalPath;
    item.status = DOWNLOAD_STATUS_DONE;
    item.progress = 100;
    item.message = '';
    DownloadCenter.clearProgressPersistTimer();
    await DownloadCenter.persist();
    // 文件已完成，保留删除失败的 ID 供下一次清理；不把完成下载改为失败。
    try { await DownloadCenter.stopSystem(item); } catch (e) {}
  }

  private static updateProgress(item: DownloadTaskItem, progress: request.agent.Progress): void {
    if (DownloadCenter.isCancelled(item)) return;
    item.receivedBytes = progress.processed;
    item.totalBytes = progress.sizes.length > 0 ? progress.sizes[0] : -1;
    item.progress = item.totalBytes > 0 ? Math.max(0, Math.min(100,
      Math.floor(item.receivedBytes * 100 / item.totalBytes))) : -1;
    if (progress.state === request.agent.State.WAITING) {
      item.status = DOWNLOAD_STATUS_WAITING;
      item.message = '等待网络或系统资源，恢复后继续下载';
    } else if (progress.state === request.agent.State.PAUSED) {
      item.status = DOWNLOAD_STATUS_PAUSED;
      item.message = '系统下载已暂停，可恢复或重试';
    } else if (progress.state === request.agent.State.RUNNING || progress.state === request.agent.State.RETRYING) {
      item.status = DOWNLOAD_STATUS_RUNNING;
      item.message = '';
    }
    DownloadCenter.scheduleProgressPersist();
  }

  private static waitForSystem(item: DownloadTaskItem, system: request.agent.Task, start: boolean): Promise<void> {
    DownloadCenter.activeSystemTask = system;
    return new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
      let settled: boolean = false;
      let revision: number = 0;
      let querying: Promise<void> | null = null;
      const detach = (): void => {
        try {
          system.off('progress', progress); system.off('completed', complete);
          system.off('failed', fail); system.off('pause', progress);
          system.off('resume', progress); system.off('remove', removed);
          system.off('wait', waiting);
        } catch (e) {}
        if (DownloadCenter.activeSystemTask === system) {
          DownloadCenter.activeSystemTask = null;
          DownloadCenter.activeCancel = null;
          DownloadCenter.activeSync = null;
        }
      };
      const finish = (error: Error | null): void => {
        if (settled) return;
        settled = true;
        detach();
        if (error !== null) reject(error); else resolve();
      };
      const progress = (value: request.agent.Progress): void => {
        revision++;
        if (!settled) DownloadCenter.updateProgress(item, value);
      };
      const complete = (): void => { revision++; finish(null); };
      const fail = (): void => { revision++; finish(new Error('系统下载失败，请重试')); };
      const removed = (): void => { revision++; finish(new Error('下载已取消')); };
      const waiting = (reason: request.agent.WaitingReason): void => {
        revision++;
        if (settled || DownloadCenter.isCancelled(item)) return;
        item.status = DOWNLOAD_STATUS_WAITING;
        item.message = reason === request.agent.WaitingReason.NETWORK_NOT_MATCH ?
          '等待网络连接，恢复后继续下载' : '等待系统资源，恢复后继续下载';
        DownloadCenter.scheduleProgressPersist();
      };
      const sync = (): Promise<void> => {
        if (querying !== null) return querying;
        const before: number = revision;
        querying = request.agent.show(system.tid).then(async (info: request.agent.TaskInfo): Promise<void> => {
          if (settled || DownloadCenter.isCancelled(item) || item.systemTaskId !== system.tid || before !== revision) return;
          DownloadCenter.updateProgress(item, info.progress);
          switch (info.progress.state) {
            case request.agent.State.COMPLETED: complete(); break;
            case request.agent.State.FAILED: fail(); break;
            case request.agent.State.REMOVED: removed(); break;
            case request.agent.State.STOPPED:
              item.status = DOWNLOAD_STATUS_PAUSED;
              item.message = '系统下载已停止，可重试';
              break;
            case request.agent.State.INITIALIZED:
              if (!start) await system.start(); // 保存 ID 后、首次启动前退出的任务。
              break;
          }
        }).finally(() => { querying = null; });
        return querying;
      };
      DownloadCenter.activeCancel = removed;
      DownloadCenter.activeSync = sync;
      try {
        system.on('progress', progress); system.on('completed', complete);
        system.on('failed', fail); system.on('pause', progress);
        system.on('resume', progress); system.on('remove', removed);
        system.on('wait', waiting);
      } catch (e) {
        finish(new Error('无法监听系统下载'));
        return;
      }
      const begin = async (): Promise<void> => {
        if (DownloadCenter.isCancelled(item)) { removed(); return; }
        if (start) await system.start();
        // 查询失败时保留句柄与监听器，前台入口可以补查，不重建仍运行的下载。
        await sync().catch(() => {});
      };
      begin().catch(() => finish(new Error('无法启动系统下载')));
    });
  }
}
