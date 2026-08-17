/**
 * 首页推荐与热门：Web 个性化推荐 / App 公共推荐流 / 全站热门。
 * 移植自 PiliPlus lib/http/*.dart
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants, RecommendParams } from '../common/Constants';
import { asObject, asArray, asString, asNumber } from '../common/Utils';
import { VideoItem } from '../model/Models';
import { getData, webGet } from './internal/ApiCommon';

export class FeedApi {
  /** 登录用户优先请求 Web 个性化推荐；接口失败时再回退到 App 公共推荐流。 */
  static async getRecommend(idx: number): Promise<Array<VideoItem>> {
    const loggedIn: boolean = HttpClient.getCookie('SESSDATA').length > 0 &&
      HttpClient.getCookie('DedeUserID').length > 0;
    if (loggedIn) {
      try {
        const personalized: Array<VideoItem> = await FeedApi.getRecommendWeb(idx);
        if (personalized.length > 0) return personalized;
      } catch (e) {
        // WBI key 获取或签名被风控时继续走 App 推荐，不能让首页永久停在加载态。
      }
    }
    return FeedApi.getRecommendApp(idx);
  }

  private static async getRecommendWeb(idx: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = {
      'version': '1',
      'feed_version': 'V8',
      'homepage_ver': '1',
      'ps': '20',
      'fresh_idx': String(idx),
      'brush': String(idx),
      'fresh_type': '4',
    };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.recommendListWeb, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const source: Array<Object> = asArray(data['item']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < source.length; i++) {
      const raw: Record<string, Object> = asObject(source[i]);
      if (asString(raw['goto'], '') !== 'av' || Object.keys(asObject(raw['owner'])).length === 0) continue;
      const item: VideoItem = VideoItem.fromWebRecommendItem(source[i]);
      if (item.aid > 0 || item.bvid.length > 0) result.push(item);
    }
    return result;
  }

  // ===== 首页推荐（app 端） =====
  static async getRecommendApp(idx: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = RecommendParams.build(idx);
    const query: string = HttpClient.buildQuery(params);
    const url: string = Api.recommendListApp + '?' + query;
    const headers: Record<string, string> = HttpClient.merge(Constants.appHeaders, { 'buvid': HttpClient.buvid });
    const resp: HttpResponse = await HttpClient.get(url, headers);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const items: Array<Object> = asArray(data['items']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < items.length; i++) {
      const item: Record<string, Object> = asObject(items[i]);
      const cardGoto: string = asString(item['card_goto'], '');
      const canPlay: number = asNumber(item['can_play'], 0);
      const adInfo: Object | undefined = item['ad_info'];
      // 过滤广告卡片与不可播放卡片（与 PiliPlus 一致）
      if (cardGoto === 'ad_av' || cardGoto === 'ad_web_s' || canPlay !== 1 || adInfo !== undefined) {
        continue;
      }
      result.push(VideoItem.fromAppItem(items[i]));
    }
    return result;
  }

  // ===== 热门 =====
  static async getHot(pn: number, ps: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = { 'pn': String(pn), 'ps': String(ps) };
    const resp: HttpResponse = await webGet(Api.hotList, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const list: Array<Object> = asArray(data['list']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < list.length; i++) {
      result.push(VideoItem.fromHotItem(list[i]));
    }
    return result;
  }
}
