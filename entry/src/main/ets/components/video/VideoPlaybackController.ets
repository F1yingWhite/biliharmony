import { BiliApi } from '../../api/BiliApi';
import { PlayerQualityPreference } from '../../common/PlayerQualityPreference';
import { PlaybackSelection, PlaybackSourceCoordinator } from '../../services/media/PlaybackSourceCoordinator';
import { PlayUrlInfo, VideoDetail, VideoPage } from '../../model/Models';

/** 播放选择提交口；页面只负责发布 ArkUI 属性与恢复布局。 */
export interface VideoPlaybackAccess {
  isDestroyed: () => boolean;
  getDetail: () => VideoDetail;
  getCurrentCid: () => number;
  hasPlaybackUrls: () => boolean;
  getSwitchingCid: () => number;
  getResumeCid: () => number;
  getResumePosition: () => number;
  beginInitial: (cid: number) => void;
  publish: (info: PlayUrlInfo, cid: number, index: number, seekSeconds: number) => void;
  initialFailed: (message: string) => void;
  initialSelected: (selection: PlaybackSelection) => void;
  setSwitchingCid: (cid: number) => void;
  pageSwitched: () => void;
  toast: (message: string) => void;
}

/** 初始续播、手动分 P 与播放心跳的生命周期；不持有 UI、动画或导航。 */
export class VideoPlaybackController {
  private readonly access: VideoPlaybackAccess;
  private sources: PlaybackSourceCoordinator = new PlaybackSourceCoordinator();
  private lastHeartbeatSeconds: number = -1;

  constructor(access: VideoPlaybackAccess) {
    this.access = access;
  }

  invalidate(): void {
    this.sources.invalidate();
  }

  resetHeartbeat(): void {
    this.lastHeartbeatSeconds = -1;
  }

  /** 播放中每 5 秒报一次；暂停与离场强制补报。 */
  reportHeartbeat(seconds: number, playing: boolean, force: boolean = false): void {
    if (!Number.isFinite(seconds) || seconds <= 0) return;
    // 回退进度后从新位置重新计时，不能等到追上上一次的播放位置才恢复上报。
    if (!force && (!playing || (seconds >= this.lastHeartbeatSeconds &&
      seconds - this.lastHeartbeatSeconds < 5))) return;
    this.lastHeartbeatSeconds = seconds;
    const detail: VideoDetail = this.access.getDetail();
    BiliApi.reportHeartbeat(detail.aid, detail.bvid, this.access.getCurrentCid(), seconds).catch(() => {
    });
  }

  async loadInitial(detail: VideoDetail): Promise<void> {
    const request: number = this.sources.next();
    this.access.beginInitial(detail.cid > 0 ? detail.cid : (detail.pages.length > 0 ? detail.pages[0].cid : 0));
    try {
      const selection: PlaybackSelection | null = await this.sources.initial(detail,
        PlayerQualityPreference.requested(), request, this.access.getResumeCid(), this.access.getResumePosition());
      if (!this.isCurrent(request)) return;
      if (selection === null) {
        this.access.initialFailed('获取播放地址失败');
        return;
      }
      this.access.publish(selection.info, selection.cid, selection.pageIndex, selection.resumeSeconds);
      this.access.initialSelected(selection);
    } catch (e) {
      if (this.isCurrent(request)) {
        this.access.initialFailed(detail.epId > 0 ? (e as Error).message : '获取播放地址失败');
      }
    }
  }

  async switchPage(page: VideoPage, index: number): Promise<void> {
    if (page.cid <= 0) return;
    if (page.cid === this.access.getCurrentCid() && this.access.getSwitchingCid() === 0 &&
      this.access.hasPlaybackUrls()) return;
    const request: number = this.sources.next();
    this.access.setSwitchingCid(page.cid);
    const detail: VideoDetail = this.access.getDetail();
    try {
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(detail.aid, detail.bvid, page.cid,
        PlayerQualityPreference.requested(), detail.epId);
      if (!this.isCurrent(request)) return;
      this.access.setSwitchingCid(0);
      if (info === null || info.urls.length === 0) {
        this.access.toast('该分 P 暂时无法播放');
        return;
      }
      this.access.publish(info, page.cid, index, 0);
      this.access.pageSwitched();
    } catch (e) {
      if (this.isCurrent(request)) {
        this.access.setSwitchingCid(0);
        this.access.toast('网络异常，切换分 P 失败');
      }
    }
  }

  private isCurrent(request: number): boolean {
    return !this.access.isDestroyed() && this.sources.isCurrent(request);
  }
}
