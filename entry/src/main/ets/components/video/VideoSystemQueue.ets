import { VideoDetail, VideoPage, UgcSeasonEpisode } from '../../model/Models';

export interface VideoQueueTarget {
  assetId: string;
  aid: number;
  bvid: string;
  cid: number;
  title: string;
  /** >= 0 is a part of this video; -1 is a different video in the collection. */
  pageIndex: number;
}

/** System next/previous traverse parts first, then the explicit collection, never recommendations. */
export class VideoSystemQueue {
  static assetId(aid: number, bvid: string, cid: number): string {
    return (bvid.length > 0 ? bvid : 'av' + String(aid)) + ':' + String(cid);
  }

  static neighbor(detail: VideoDetail, cid: number, direction: number): VideoQueueTarget | undefined {
    if (cid <= 0 || (direction !== -1 && direction !== 1)) return undefined;
    const currentPart: number = detail.pages.findIndex((page: VideoPage): boolean => page.cid === cid);
    const targetPart: number = currentPart + direction;
    if (currentPart >= 0 && targetPart >= 0 && targetPart < detail.pages.length) {
      const page: VideoPage = detail.pages[targetPart];
      if (page.cid > 0) return {
        assetId: VideoSystemQueue.assetId(detail.aid, detail.bvid, page.cid), aid: detail.aid,
        bvid: detail.bvid, cid: page.cid, title: page.part, pageIndex: targetPart,
      };
    }
    if (detail.ugcSeason === null) return undefined;
    const episodes: Array<UgcSeasonEpisode> = [];
    for (const section of detail.ugcSeason.sections) episodes.push(...section.episodes);
    let current: number = episodes.findIndex((episode: UgcSeasonEpisode): boolean =>
      episode.cid === cid && ((detail.bvid.length > 0 && episode.bvid === detail.bvid) ||
        (episode.aid > 0 && episode.aid === detail.aid)));
    if (current < 0 && currentPart >= 0) current = episodes.findIndex((episode: UgcSeasonEpisode): boolean =>
      (detail.bvid.length > 0 && episode.bvid === detail.bvid) ||
      (episode.aid > 0 && episode.aid === detail.aid));
    let target: number = current + direction;
    while (currentPart >= 0 && target >= 0 && target < episodes.length &&
      ((detail.bvid.length > 0 && episodes[target].bvid === detail.bvid) ||
        (episodes[target].aid > 0 && episodes[target].aid === detail.aid))) target += direction;
    if (current < 0 || target < 0 || target >= episodes.length) return undefined;
    const episode: UgcSeasonEpisode = episodes[target];
    if (episode.cid <= 0 || (episode.aid <= 0 && episode.bvid.length === 0)) return undefined;
    return { assetId: VideoSystemQueue.assetId(episode.aid, episode.bvid, episode.cid), aid: episode.aid,
      bvid: episode.bvid, cid: episode.cid, title: episode.title, pageIndex: -1 };
  }
}
