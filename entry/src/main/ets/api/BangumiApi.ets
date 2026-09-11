/**
 * 番剧与影视（PGC）API：详情、追番、索引和时间表。
 */
import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { Api, Constants } from '../common/Constants';
import { asArray, asBool, asNumber, asObject, str } from '../common/Utils';
import { BangumiIndexItem, BangumiIndexPageData, BangumiSeason, TimeLineDay, TimeLineEpisode,
  WatchLaterSeasonItem, VideoDetail, VideoPage, PlayUrlInfo } from '../model/Models';
import { ActionResult, getData, postVideoAction, webGet } from './internal/ApiCommon';

export class BangumiApi {
  /** 以服务端集信息恢复播放身份，不依赖普通投稿详情是否对 PGC 开放。 */
  static async getEpisodeVideoDetail(epId: number): Promise<VideoDetail | null> {
    const season: BangumiSeason | null = await BangumiApi.getSeason(0, epId);
    if (season === null) throw new Error('番剧详情加载失败，请稍后重试');
    const episode = season.episodes.find((item) => item.epId === epId);
    if (episode === undefined || episode.cid <= 0 || episode.aid <= 0) return null;
    const detail: VideoDetail = new VideoDetail();
    detail.epId = epId;
    detail.aid = episode.aid;
    detail.bvid = episode.bvid;
    detail.cid = episode.cid;
    detail.title = season.title + ' ' + episode.title +
      (episode.longTitle.length > 0 ? ' ' + episode.longTitle : '');
    detail.desc = season.evaluate;
    detail.cover = episode.cover.length > 0 ? episode.cover : season.cover;
    detail.duration = episode.duration;
    const page: VideoPage = new VideoPage();
    page.cid = episode.cid;
    page.part = episode.longTitle.length > 0 ? episode.longTitle : episode.title;
    page.duration = episode.duration;
    detail.pages = [page];
    return detail;
  }

  /** 使用当前账号的官方 PGC 权限；只处理服务端返回的可播放源。 */
  static async getPlayUrl(epId: number, cid: number, qn: number): Promise<PlayUrlInfo | null> {
    if (epId <= 0 || cid <= 0) return null;
    const resp: HttpResponse = await webGet('https://api.bilibili.com/pgc/player/web/playurl', {
      'ep_id': String(epId), 'cid': String(cid), 'qn': String(qn),
      'fnval': '4048', 'fnver': '0', 'fourk': '1', 'https_url_req': '1',
    }, 'https://www.bilibili.com/bangumi/play/ep' + String(epId));
    if (!resp.ok) throw new Error(resp.status < 0 ? resp.transportMessage : '番剧播放请求失败，请稍后重试');
    const json: Record<string, Object> = resp.json();
    const code: number = asNumber(json['code'], -1);
    if (code !== 0) {
      const message: string = str(json, 'message', '');
      throw new Error(message.length > 0 ? message : '当前账号暂时无法播放本集，请检查观看权限');
    }
    const data: Record<string, Object> = asObject(json['result']);
    if (asNumber(data['is_drm'], 0) !== 0 || data['is_drm'] === true) {
      throw new Error('此内容需要受保护的播放环境，请前往官方客户端观看');
    }
    if (asArray(data['durl']).length > 1) {
      throw new Error('当前分段格式暂不支持播放，请前往官方客户端观看');
    }
    const info: PlayUrlInfo = PlayUrlInfo.fromPlayUrl(data, qn);
    if (info.urls.length === 0) throw new Error('本集没有可用播放地址，请检查观看权限后重试');
    return info;
  }

  static async getSeason(seasonId: number, epId: number): Promise<BangumiSeason | null> {
    if (seasonId <= 0 && epId <= 0) return null;
    const params: Record<string, string> = {};
    if (seasonId > 0) params['season_id'] = String(seasonId);
    else params['ep_id'] = String(epId);
    const resp: HttpResponse = await webGet(Api.bangumiSeason + '?' + HttpClient.buildQuery(params));
    if (!resp.ok) return null;
    const json: Record<string, Object> = resp.json();
    if (asNumber(json['code'], -1) !== 0) return null;
    const result: Record<string, Object> = asObject(json['result']);
    return Object.keys(result).length === 0 ? null : BangumiSeason.from(result);
  }

  static async setFollowed(seasonId: number, followed: boolean): Promise<ActionResult> {
    if (seasonId <= 0) return new ActionResult(false, '番剧信息无效');
    return postVideoAction(followed ? Api.bangumiFollowAdd : Api.bangumiFollowDel, {
      'season_id': String(seasonId),
    });
  }

  static async getFollowList(type: number, page: number, mid: number): Promise<Array<WatchLaterSeasonItem>> {
    if (mid <= 0) return [];
    const params: Record<string, string> = {
      'vmid': String(mid), 'type': String(type), 'follow_status': '0', 'pn': String(Math.max(1, page)),
    };
    const data: Record<string, Object> | null = getData(await webGet(Api.bangumiFollowList, params));
    if (data === null) return [];
    const items: Array<Object> = asArray(data['list']);
    const result: Array<WatchLaterSeasonItem> = [];
    for (let i: number = 0; i < items.length; i++) result.push(WatchLaterSeasonItem.from(items[i]));
    return result;
  }

  static async getIndex(seasonType: number, isFinish: number, page: number,
    order: number = 0): Promise<BangumiIndexPageData> {
    const result: BangumiIndexPageData = new BangumiIndexPageData();
    const params: Record<string, string> = {
      'season_id': '-1', 'area': '-1', 'is_finish': String(isFinish), 'copyright': '-1',
      'season_status': '-1', 'year': '-1', 'style_id': '-1', 'order': String(order), 'st': '1',
      'sort': '0', 'page': String(Math.max(1, page)), 'season_type': String(seasonType),
      'pagesize': '20', 'type': '1',
    };
    const headers: Record<string, string> = HttpClient.merge(Constants.webHeaders, {
      'Referer': 'https://www.bilibili.com/anime/',
    });
    const data: Record<string, Object> | null = getData(
      await webGet(Api.bangumiIndex, params, undefined, headers));
    if (data === null) throw new Error('番剧索引加载失败');
    result.hasNext = asBool(data['has_next'], false);
    result.total = asNumber(data['total'], 0);
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) {
      const item: BangumiIndexItem = BangumiIndexItem.from(asObject(list[i]));
      if (item.seasonId > 0) result.items.push(item);
    }
    return result;
  }

  static async getTimeline(types: number, before: number, after: number): Promise<Array<TimeLineDay>> {
    const result: Array<TimeLineDay> = [];
    const params: Record<string, string> = {
      'types': String(types), 'before': String(before), 'after': String(after),
    };
    const resp: HttpResponse = await webGet(Api.pgcTimeline, params, 'https://www.bilibili.com/anime/timeline/');
    const json: Record<string, Object> = resp.json();
    if (asNumber(json['code'], -1) !== 0) throw new Error('时间表加载失败');
    const days: Array<Object> = asArray(json['result']);
    for (let i: number = 0; i < days.length; i++) {
      const raw: Record<string, Object> = asObject(days[i]);
      const day: TimeLineDay = new TimeLineDay();
      day.date = str(raw, 'date', '');
      day.dateTimestamp = asNumber(raw['date_ts'], 0);
      day.isToday = asNumber(raw['is_today'], 0) === 1;
      day.dayOfWeek = asNumber(raw['day_of_week'], 0);
      const episodes: Array<Object> = asArray(raw['episodes']);
      for (let j: number = 0; j < episodes.length; j++) {
        const episode: TimeLineEpisode = TimeLineEpisode.from(episodes[j]);
        episode.seasonType = types;
        day.episodes.push(episode);
      }
      result.push(day);
    }
    return result;
  }
}
