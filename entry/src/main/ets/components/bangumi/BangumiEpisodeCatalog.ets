import { VideoDetailParam } from '../../common/AppRouter';
import { BangumiEpisode, BangumiSeason } from '../../model/Models';

/** PGC 集选择与展示规则。保留 epId/cid，播放与画质切换均使用番剧鉴权。 */
export class BangumiEpisodeCatalog {
  static pick(season: BangumiSeason, preferredEpId: number): number {
    if (preferredEpId > 0 && season.episodes.some((episode: BangumiEpisode) => episode.epId === preferredEpId)) {
      return preferredEpId;
    }
    return season.episodes.length > 0 ? season.episodes[0].epId : 0;
  }

  static current(season: BangumiSeason, epId: number): BangumiEpisode | null {
    const found: BangumiEpisode | undefined = season.episodes.find((episode: BangumiEpisode) => episode.epId === epId);
    return found ?? (season.episodes.length > 0 ? season.episodes[0] : null);
  }

  static episodeUnit(season: BangumiSeason): string {
    return season.seasonType === 1 || season.seasonType === 4 ? '话' : '集';
  }

  static followLabel(season: BangumiSeason): string {
    return season.seasonType === 1 || season.seasonType === 4 ? '追番' : '追剧';
  }

  static currentLabel(season: BangumiSeason, epId: number): string {
    const episode: BangumiEpisode | null = BangumiEpisodeCatalog.current(season, epId);
    if (episode === null || episode.title.length === 0) return '';
    return /^[0-9]+$/.test(episode.title) ?
      '第 ' + episode.title + ' ' + BangumiEpisodeCatalog.episodeUnit(season) : episode.title;
  }

  static fullTitle(season: BangumiSeason, episode: BangumiEpisode): string {
    let title: string = season.title + ' ' + episode.title;
    if (episode.longTitle.length > 0) title += ' ' + episode.longTitle;
    return title;
  }

  static playbackParam(season: BangumiSeason, episode: BangumiEpisode): VideoDetailParam {
    return { bvid: episode.bvid, aid: episode.aid, title: BangumiEpisodeCatalog.fullTitle(season, episode),
      epId: episode.epId, cid: episode.cid, cover: episode.cover };
  }
}
