import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { BiliApi } from '../../api/BiliApi';
import { DanmakuItem } from '../../model/video/VideoAuxiliaryModels';
import { PlayUrlInfo, SubtitleCue, SubtitleTrack, VideoQualityOption } from '../../model/Models';
import { RequestEpoch } from '../../common/RequestEpoch';
import { HttpClient } from '../../services/network/HttpClient';
import { DownloadCenter, DOWNLOAD_KIND_AUDIO, DOWNLOAD_KIND_VIDEO } from '../../services/media/DownloadCenter';
import { VideoDownloadService } from '../../services/media/VideoDownloadService';
import { PhotoLibrarySaver } from '../../services/media/PhotoLibrarySaver';
import { DocumentExportService } from '../../services/media/DocumentExportService';
import { MediaExportFormat } from '../../services/media/MediaExportFormat';

/** 操作开始时捕获；在任意 await 之后都不再向播放器读取这些字段。 */
export interface PlayerMediaExportSnapshot {
  aid: number;
  bvid: string;
  cid: number;
  epId: number;
  title: string;
  partTitle: string;
  cover: string;
  duration: number;
  playhead: number;
  quality: number;
  qualityOptions: Array<VideoQualityOption>;
  subtitle: SubtitleTrack | null;
}

export interface PlayerDownloadUi {
  busy: boolean;
  progress: number;
  /** 0 表示保持已有画质选项；解析播放地址后发布实际档位。 */
  quality: number;
}

export interface PlayerMediaExportHost {
  getContext: () => common.UIAbilityContext | undefined;
  snapshot: () => PlayerMediaExportSnapshot;
  isDestroyed: () => boolean;
  closePanels: () => void;
  toast: (message: string) => void;
  publishDownload: (state: PlayerDownloadUi) => void;
}

interface ExportOperation {
  request: number;
  snapshot: PlayerMediaExportSnapshot;
  context: common.UIAbilityContext;
}

/** 下载/导出的任务生命周期。持久化队列接收任务后独立运行，旧页回调仍被代际隔离。 */
export class PlayerMediaExportController {
  private host: PlayerMediaExportHost;
  private captureFrame: (seconds: number) => Promise<image.PixelMap | null>;
  private requests: RequestEpoch = new RequestEpoch();
  private active: number = 0;

  constructor(host: PlayerMediaExportHost, captureFrame: (seconds: number) => Promise<image.PixelMap | null>) {
    this.host = host;
    this.captureFrame = captureFrame;
  }

  /** 换源与离场都调用；不能取消已入列/已启动的后台文件任务。 */
  invalidate(): void {
    this.requests.invalidate();
    this.active = 0;
  }

  syncDownload(): void {
    if (!this.host.isDestroyed()) {
      this.host.publishDownload({ busy: VideoDownloadService.isActive(),
        progress: VideoDownloadService.currentProgress(), quality: 0 });
    }
  }

  async enqueueCenterDownload(audioOnly: boolean): Promise<void> {
    const operation: ExportOperation | null = this.begin();
    if (operation === null) return;
    try {
      const snapshot: PlayerMediaExportSnapshot = operation.snapshot;
      this.validateVideo(snapshot);
      await DownloadCenter.init(operation.context);
      if (!this.current(operation)) return;
      const label: string = audioOnly ? '音频' : MediaExportFormat.qualityText(snapshot.qualityOptions, snapshot.quality);
      const title: string = MediaExportFormat.safeName(MediaExportFormat.title(snapshot.title, snapshot.partTitle) + ' [' + label + ']');
      await DownloadCenter.enqueue(audioOnly ? DOWNLOAD_KIND_AUDIO : DOWNLOAD_KIND_VIDEO,
        snapshot.aid, snapshot.bvid, snapshot.cid, 0, audioOnly ? 0 : snapshot.quality, title, label);
      this.notify(operation, '已加入下载中心' + (DownloadCenter.hasActive() ? '，正在下载' : '，排队中'));
    } catch (error) {
      this.failed(operation, error as Object, '加入下载中心失败，请重试');
    } finally {
      this.finish(operation);
    }
  }

  async startMediaDownload(audioOnly: boolean): Promise<void> {
    if (VideoDownloadService.isActive()) {
      if (!this.host.isDestroyed()) this.host.toast('已有下载任务正在进行');
      return;
    }
    const operation: ExportOperation | null = this.begin();
    if (operation === null) return;
    const snapshot: PlayerMediaExportSnapshot = operation.snapshot;
    this.host.publishDownload({ busy: true, progress: -1, quality: 0 });
    try {
      this.validateVideo(snapshot);
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(snapshot.aid, snapshot.bvid, snapshot.cid, snapshot.quality);
      if (!this.current(operation)) return;
      if (info === null) throw new Error('暂时无法获取下载地址');
      const urls: Array<string> = (audioOnly ? info.downloadAudioUrls : info.urls).slice();
      if (audioOnly && urls.length === 0) throw new Error('当前视频没有可下载的独立音轨');
      if (!audioOnly && (urls.length === 0 || info.isDash)) {
        throw new Error('该画质只有 DASH 分离流，暂时无法直接保存为单个 MP4');
      }
      if (!audioOnly && !info.format.startsWith('mp4') &&
        !urls.some((url: string) => url.split('?')[0].toLowerCase().endsWith('.mp4'))) {
        throw new Error('该视频仅提供旧版分段格式，暂时无法保存为单个 MP4');
      }
      const label: string = audioOnly ? '音频' : MediaExportFormat.qualityText(snapshot.qualityOptions, info.quality);
      const identity: string = MediaExportFormat.identity(snapshot.aid, snapshot.bvid);
      const fileName: string = MediaExportFormat.safeName(MediaExportFormat.title(snapshot.title, snapshot.partTitle) +
        ' [' + identity + '] [' + label + ']') + (audioOnly ? '.m4a' : '.mp4');
      this.host.publishDownload({ busy: true, progress: -1, quality: info.quality });
      this.host.closePanels();
      const target: string = await DocumentExportService.chooseTarget(operation.context, fileName,
        audioOnly ? '音频文件|.m4a' : '视频文件|.mp4', (): boolean => this.current(operation));
      if (target.length === 0 || !this.current(operation)) return;
      this.notify(operation, audioOnly ? '音频已开始下载，可在通知栏查看进度' : '视频已开始下载，可在通知栏查看进度');
      await VideoDownloadService.downloadToUri(operation.context, urls, target, fileName,
        HttpClient.getDownloadHeaders('https://www.bilibili.com/video/' + identity),
        (received: number, total: number): void => {
          if (this.current(operation)) {
            this.host.publishDownload({ busy: true,
              progress: total > 0 ? Math.max(0, Math.min(100, Math.floor(received * 100 / total))) : -1, quality: 0 });
          }
        });
      this.notify(operation, audioOnly ? '音频已保存到所选位置' : '视频已保存到所选位置');
    } catch (error) {
      this.failed(operation, error as Object, '下载失败，请稍后重试');
    } finally {
      if (this.current(operation)) this.syncDownload();
      this.finish(operation);
    }
  }

  async exportDanmaku(): Promise<void> {
    const operation: ExportOperation | null = this.begin();
    if (operation === null) return;
    try {
      const snapshot: PlayerMediaExportSnapshot = operation.snapshot;
      if (snapshot.cid <= 0) throw new Error('当前视频没有弹幕');
      this.notify(operation, '正在整理弹幕…');
      const count: number = MediaExportFormat.danmakuSegments(snapshot.duration);
      const all: Array<DanmakuItem> = [];
      for (let segment: number = 1; segment <= count; segment++) {
        const items: Array<DanmakuItem> | null = await BiliApi.getDanmakuSeg(snapshot.cid, snapshot.aid, segment);
        if (!this.current(operation)) return;
        if (items === null) throw new Error('弹幕第 ' + segment + ' 段加载失败，未导出不完整文件');
        // 空段也是成功响应；后续时间段仍然可能有弹幕。
        items.forEach((item: DanmakuItem): void => { all.push(item); });
      }
      if (all.length === 0) throw new Error('当前视频没有弹幕');
      const fileName: string = MediaExportFormat.safeName(MediaExportFormat.title(snapshot.title, snapshot.partTitle) +
        ' [' + MediaExportFormat.identity(snapshot.aid, snapshot.bvid) + ']') + '.xml';
      const saved: boolean = await DocumentExportService.saveText(operation.context, fileName, '弹幕文件|.xml',
        MediaExportFormat.danmaku(snapshot.cid, all), (): boolean => this.current(operation));
      const range: string = Number.isFinite(snapshot.duration) && snapshot.duration > 0 ? '' : '前 72 分钟，';
      if (saved) this.notify(operation, '弹幕已保存（' + range + all.length + ' 条）');
    } catch (error) {
      this.failed(operation, error as Object, '弹幕导出失败，请重试');
    } finally {
      this.finish(operation);
    }
  }

  async exportSubtitle(): Promise<void> {
    const operation: ExportOperation | null = this.begin();
    if (operation === null) return;
    try {
      const snapshot: PlayerMediaExportSnapshot = operation.snapshot;
      const track: SubtitleTrack | null = snapshot.subtitle;
      if (track === null || track.url.length === 0) throw new Error('请先选择要导出的 CC 字幕轨道');
      const cues: Array<SubtitleCue> = await BiliApi.getSubtitleCues(track.url);
      if (!this.current(operation)) return;
      if (cues.length === 0) throw new Error('字幕内容获取失败');
      const label: string = track.lanDoc.length > 0 ? track.lanDoc : (track.lan.length > 0 ? track.lan : '字幕');
      const fileName: string = MediaExportFormat.safeName(MediaExportFormat.title(snapshot.title, snapshot.partTitle) + ' [' + label + ']') + '.srt';
      const saved: boolean = await DocumentExportService.saveText(operation.context, fileName, '字幕文件|.srt',
        MediaExportFormat.subtitle(cues), (): boolean => this.current(operation));
      if (saved) this.notify(operation, '字幕已保存（' + cues.length + ' 条）');
    } catch (error) {
      this.failed(operation, error as Object, '字幕导出失败，请重试');
    } finally {
      this.finish(operation);
    }
  }

  async exportCover(): Promise<void> {
    const operation: ExportOperation | null = this.begin();
    if (operation === null) return;
    try {
      const snapshot: PlayerMediaExportSnapshot = operation.snapshot;
      if (snapshot.cover.length === 0) throw new Error('当前视频没有封面');
      const bytes: ArrayBuffer = await HttpClient.getBytes(snapshot.cover);
      if (!this.current(operation)) return;
      const extension: string = MediaExportFormat.coverExtension(snapshot.cover);
      const fileName: string = MediaExportFormat.safeName(snapshot.title + ' [封面] [' +
        MediaExportFormat.identity(snapshot.aid, snapshot.bvid) + ']') + extension;
      const saved: boolean = await DocumentExportService.saveBinary(operation.context, fileName, '图片文件|' + extension,
        bytes, (): boolean => this.current(operation));
      if (saved) this.notify(operation, '封面已保存');
    } catch (error) {
      this.failed(operation, error as Object, '封面下载失败，请重试');
    } finally {
      this.finish(operation);
    }
  }

  async captureScreenshot(): Promise<void> {
    const operation: ExportOperation | null = this.begin();
    if (operation === null) return;
    let frame: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      frame = await this.captureFrame(operation.snapshot.playhead);
      if (!this.current(operation)) return;
      if (frame === null) throw new Error('该视频暂不支持截图');
      packer = image.createImagePacker();
      const bytes: ArrayBuffer = await packer.packToData(frame, { format: 'image/jpeg', quality: 92 });
      if (!this.current(operation)) return;
      const saved: boolean = await PhotoLibrarySaver.saveImage(operation.context, bytes, 'jpeg',
        'BiliHarmony_' + Math.floor(operation.snapshot.playhead) + 's', (): boolean => this.current(operation));
      if (saved) this.notify(operation, '截图已保存到相册');
    } catch (error) {
      this.failed(operation, error as Object, '截图保存失败，请重试');
    } finally {
      if (packer !== null) { try { await packer.release(); } catch (error) {} }
      if (frame !== null) { try { await frame.release(); } catch (error) {} }
      this.finish(operation);
    }
  }

  private begin(): ExportOperation | null {
    if (this.host.isDestroyed()) return null;
    if (this.active !== 0) {
      this.host.toast('正在处理上一项导出或下载，请稍候');
      return null;
    }
    const context: common.UIAbilityContext | undefined = this.host.getContext();
    if (context === undefined) return null;
    const source: PlayerMediaExportSnapshot = this.host.snapshot();
    const subtitle: SubtitleTrack | null = source.subtitle;
    const track: SubtitleTrack | null = subtitle === null ? null : new SubtitleTrack();
    if (track !== null && subtitle !== null) {
      track.url = subtitle.url;
      track.lan = subtitle.lan;
      track.lanDoc = subtitle.lanDoc;
    }
    const snapshot: PlayerMediaExportSnapshot = {
      aid: source.aid, bvid: source.bvid, cid: source.cid, epId: source.epId, title: source.title,
      partTitle: source.partTitle, cover: source.cover, duration: source.duration, playhead: source.playhead,
      quality: source.quality,
      qualityOptions: source.qualityOptions.map((option: VideoQualityOption) => new VideoQualityOption(option.qn, option.label, option.available)),
      subtitle: track,
    };
    const request: number = this.requests.next();
    this.active = request;
    return { request: request, snapshot: snapshot, context: context };
  }

  private validateVideo(snapshot: PlayerMediaExportSnapshot): void {
    if (snapshot.epId > 0) throw new Error('番剧下载暂未开放');
    if (snapshot.cid <= 0 || (snapshot.aid <= 0 && snapshot.bvid.length === 0)) {
      throw new Error('当前视频信息不完整，无法下载');
    }
  }

  private current(operation: ExportOperation): boolean {
    return !this.host.isDestroyed() && this.requests.isCurrent(operation.request);
  }

  private notify(operation: ExportOperation, message: string): void {
    if (this.current(operation)) this.host.toast(message);
  }

  private failed(operation: ExportOperation, error: Object, fallback: string): void {
    if (DocumentExportService.isCancelled(error)) return;
    this.notify(operation, error instanceof Error && error.message.length > 0 ? error.message : fallback);
  }

  private finish(operation: ExportOperation): void {
    if (this.active === operation.request) this.active = 0;
  }
}
