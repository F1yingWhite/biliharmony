import { ApiResult, ApiErrorKind } from '../services/network/ApiResult';
/**
 * 历史与稍后再看 API。
 */
import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asNumber } from '../common/Utils';
import { HistoryPageData, HistoryVideoItem, WatchLaterItem } from '../model/Models';
import { ActionResult, getData, postVideoAction, webGet, parseDataResult } from './internal/ApiCommon';

export class HistoryApi {
  static async getHistory(max: number = 0, viewAt: number = 0): Promise<ApiResult<HistoryPageData>> {
    const params: Record<string, string> = {
      'type': 'archive', 'ps': '20', 'max': String(max), 'view_at': String(viewAt),
    };
    const resp: HttpResponse = await webGet(Api.historyList, params);
    const parsed: ApiResult<Record<string, Object>> = parseDataResult(resp);
    if (!parsed.ok || parsed.data === null) {
      return new ApiResult<HistoryPageData>(null, parsed.message, parsed.kind, parsed.code);
    }
    const data: Record<string, Object> = parsed.data;
    if (!Array.isArray(data['list'])) {
      return new ApiResult<HistoryPageData>(null, '历史记录响应格式异常，请重试', ApiErrorKind.Parse);
    }
    const result: HistoryPageData = new HistoryPageData();
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.items.push(HistoryVideoItem.from(list[i]));
    // 官方游标位于 data.cursor；不能用最后一条 aid 推导，否则第二页会重复或直接失效。
    const cursor: Record<string, Object> = asObject(data['cursor']);
    result.max = asNumber(cursor['max'], 0);
    result.viewAt = asNumber(cursor['view_at'], 0);
    if (result.items.length > 0 && result.viewAt <= 0) {
      const last: HistoryVideoItem = result.items[result.items.length - 1];
      result.max = last.video.aid;
      result.viewAt = last.viewAt;
    }
    result.hasMore = list.length >= 20;
    return new ApiResult<HistoryPageData>(result);
  }

  // ===== 稍后再看（列表一次性返回全量，最多 100 条；移植自 PiliPlus UserHttp.seeYouLater / toViewLater 等） =====
  static async getWatchLaterList(): Promise<Array<WatchLaterItem>> {
    const resp: HttpResponse = await webGet(Api.toviewList);
    const data: Record<string, Object> | null = getData(resp);
    const result: Array<WatchLaterItem> = [];
    if (data === null) throw new Error('稍后再看加载失败');
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) result.push(WatchLaterItem.from(list[i]));
    return result;
  }

  /** aid 与 bvid 至少传一个，与 PiliPlus toViewLater 对齐。 */
  static async addWatchLater(aid: number, bvid: string): Promise<ActionResult> {
    if (aid <= 0 && bvid.length === 0) return new ActionResult(false, '视频信息无效');
    const params: Record<string, string> = {};
    if (aid > 0) params['aid'] = String(aid);
    if (bvid.length > 0) params['bvid'] = bvid;
    return postVideoAction(Api.toviewAdd, params);
  }

  /** 删除单/多条：resources 为逗号分隔的 aid 列表（PiliPlus toViewDel 走 /v2/dels）。 */
  static async delWatchLater(aids: Array<number>): Promise<ActionResult> {
    if (aids.length === 0) return new ActionResult(false, '未选择要删除的视频');
    const params: Record<string, string> = {
      'resources': aids.map((id: number) => String(id)).join(','),
    };
    return postVideoAction(Api.toviewDel, params);
  }

  /** 清空全部稍后再看（PiliPlus toViewClear，clean_type 缺省即清全部）。 */
  static async clearWatchLater(): Promise<ActionResult> {
    return postVideoAction(Api.toviewClear, {});
  }

  static async deleteHistoryItem(bvid: string): Promise<ActionResult> {
    if (bvid.length === 0) return new ActionResult(false, '参数无效');
    return postVideoAction(Api.historyDelete, {
      'aid': '', 'kid': bvid, 'platform': 'web',
    });
  }

  static async clearHistory(): Promise<ActionResult> {
    return postVideoAction(Api.historyClear, { 'platform': 'web' });
  }
}
