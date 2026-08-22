/**
 * 番剧与影视（PGC）API：详情、追番、索引和时间表。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { Api, Constants } from '../common/Constants';
import { asArray, asBool, asNumber, asObject, str } from '../common/Utils';
import { BangumiIndexItem, BangumiIndexPageData, BangumiSeason, TimeLineDay, TimeLineEpisode,
  WatchLaterSeasonItem } from '../model/Models';
import { ActionResult, getData, postVideoAction, webGet } from './internal/ApiCommon';

export class BangumiApi {
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
    if (data === null) return result;
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
    if (asNumber(json['code'], -1) !== 0) return result;
    const days: Array<Object> = asArray(json['result']);
    for (let i: number = 0; i < days.length; i++) {
      const raw: Record<string, Object> = asObject(days[i]);
      const day: TimeLineDay = new TimeLineDay();
      day.date = str(raw, 'date', '');
      day.dayOfWeek = asNumber(raw['day_of_week'], 0);
      const episodes: Array<Object> = asArray(raw['episodes']);
      for (let j: number = 0; j < episodes.length; j++) day.episodes.push(TimeLineEpisode.from(episodes[j]));
      result.push(day);
    }
    return result;
  }
}
