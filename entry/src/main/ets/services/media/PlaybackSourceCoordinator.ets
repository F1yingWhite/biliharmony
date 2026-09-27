import { BiliApi } from '../../api/BiliApi';
import { RequestEpoch } from '../../common/RequestEpoch';
import { PlayUrlInfo, VideoDetail } from '../../model/Models';

export class PlaybackSelection {
  info: PlayUrlInfo;
  cid: number;
  pageIndex: number;
  resumeSeconds: number;

  constructor(info: PlayUrlInfo, cid: number, pageIndex: number) {
    this.info = info;
    this.cid = cid;
    this.pageIndex = pageIndex;
    this.resumeSeconds = Number.isFinite(info.lastPlayTime) ?
      Math.max(0, Math.floor(info.lastPlayTime / 1000)) : 0;
  }
}

/** 初次续播与手动分 P 共用一个请求代际，页面只提交完整且仍有效的播放源。 */
export class PlaybackSourceCoordinator extends RequestEpoch {
  async initial(detail: VideoDetail, quality: number, request: number,
    preferredCid: number = 0, position: number = 0): Promise<PlaybackSelection | null> {
    const localResume: boolean = preferredCid > 0 &&
      (detail.cid === preferredCid || detail.pages.some((page) => page.cid === preferredCid));
    const cid: number = localResume ? preferredCid :
      (detail.cid > 0 ? detail.cid : (detail.pages.length > 0 ? detail.pages[0].cid : 0));
    let index: number = detail.pages.findIndex((page) => page.cid === cid);
    if (index < 0) index = 0;
    const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(detail.aid, detail.bvid, cid, quality, detail.epId);
    if (!this.isCurrent(request) || info === null || info.urls.length === 0) return null;
    if (localResume) {
      const selection: PlaybackSelection = new PlaybackSelection(info, cid, index);
      selection.resumeSeconds = Number.isFinite(position) ? Math.max(0, Math.floor(position)) : 0;
      return selection;
    }
    const lastIndex: number = detail.pages.findIndex((page) => page.cid === info.lastPlayCid);
    if (info.lastPlayCid > 0 && info.lastPlayCid !== cid && detail.pages.length > 1 && lastIndex >= 0) {
      const lastCid: number = info.lastPlayCid;
      const lastInfo: PlayUrlInfo | null = await BiliApi.getPlayUrl(detail.aid, detail.bvid, lastCid, quality, detail.epId);
      if (!this.isCurrent(request)) return null;
      if (lastInfo !== null && lastInfo.urls.length > 0) return new PlaybackSelection(lastInfo, lastCid, lastIndex);
    }
    return new PlaybackSelection(info, cid, index);
  }
}
