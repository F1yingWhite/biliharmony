/**
 * 首页推荐与热门：Web 个性化推荐 / App 推流 / 全站热门。
 * 移植自 PiliPlus lib/http/*.dart。
 *
 * 推荐会话链（防重复的关键，缺失会导致服务端把每次请求当独立请求、重复内容反复下发）：
 * - Web（官方网页端同款协议）：fresh_idx 每页 +1，并把上一页响应的 feed_id/bucket_id
 *   回传给下一页；下拉刷新重置序号、丢弃旧 feed_id，开启新会话。
 * - App（x/v2/feed/index）：第一帧 idx=0（pull=true），之后取上一页最后一条的 idx 作游标，
 *   服务端按游标续推、天然去重。
 * 推荐源由设置项控制（AppStorage 'recommendMode'：'web' | 'app'），可在「我的 → 外观与交互」切换。
 */
import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { Api, Constants, RecommendParams } from '../common/Constants';
import { appSign } from '../common/AppSign';
import { asObject, asArray, asString, asNumber } from '../common/Utils';
import { VideoItem } from '../model/Models';
import { getData, webGet, webGetSigned } from './internal/ApiCommon';

/** 一页推荐：items 为展示数据；feedId/bucketId/cursor 为解析出的会话游标。 */
export class FeedPage {
  items: Array<VideoItem> = [];
  feedId: string = '';
  bucketId: string = '';
  cursor: number = 0;
}

export class FeedApi {
  // ===== 推荐会话状态（进程内；下拉刷新时 resetRecommendSession 归零开新会话）=====
  private static webFreshIdx: number = 0;
  private static webFeedId: string = '';
  private static webBucketId: string = '';
  private static appCursor: number = 0;

  static resetRecommendSession(): void {
    FeedApi.webFreshIdx = 0;
    FeedApi.webFeedId = '';
    FeedApi.webBucketId = '';
    FeedApi.appCursor = 0;
  }

  /** 当前推荐源（'web' | 'app'），默认 Web。 */
  static recommendMode(): string {
    const mode: string | undefined = AppStorage.get<string>('recommendMode');
    return mode === 'app' ? 'app' : 'web';
  }

  /** Web 推荐请求参数构建（纯函数，QA 直接测）：fresh_idx 为 1 起的页序号。 */
  static buildWebRcmdParams(freshIdx: number, feedId: string, bucketId: string): Record<string, string> {
    const params: Record<string, string> = {
      'version': '1',
      'feed_version': 'V8',
      'homepage_ver': '1',
      'ps': '20',
      'fresh_idx': String(freshIdx),
      'brush': String(freshIdx),
      'fresh_type': '4',
    };
    if (feedId.length > 0) params['feed_id'] = feedId;
    if (bucketId.length > 0) params['bucket_id'] = bucketId;
    return params;
  }

  /** Web 推荐响应解析（纯函数）：过滤非视频卡，同时取会话标识。 */
  static parseWebRcmd(data: Record<string, Object>): FeedPage {
    const page: FeedPage = new FeedPage();
    page.feedId = asString(data['feed_id'], '');
    page.bucketId = asString(data['bucket_id'], '');
    const source: Array<Object> = asArray(data['item']);
    for (let i: number = 0; i < source.length; i++) {
      const raw: Record<string, Object> = asObject(source[i]);
      if (asString(raw['goto'], '') !== 'av' || Object.keys(asObject(raw['owner'])).length === 0) continue;
      const item: VideoItem = VideoItem.fromWebRecommendItem(source[i]);
      if (item.aid > 0 || item.bvid.length > 0) page.items.push(item);
    }
    return page;
  }

  /** App 推流请求参数构建（纯函数；签名在调用处追加 appkey/ts/sign）。 */
  static buildAppFeedParams(idx: number, accessKey: string): Record<string, string> {
    const params: Record<string, string> = RecommendParams.build(idx);
    if (accessKey.length > 0) params['access_key'] = accessKey;
    return params;
  }

  /** App 推流响应解析（纯函数）：过滤广告/不可播卡，游标取最后一条有效卡的 idx。 */
  static parseAppFeed(data: Record<string, Object>): FeedPage {
    const page: FeedPage = new FeedPage();
    const items: Array<Object> = asArray(data['items']);
    for (let i: number = 0; i < items.length; i++) {
      const item: Record<string, Object> = asObject(items[i]);
      const cardGoto: string = asString(item['card_goto'], '');
      const canPlay: number = asNumber(item['can_play'], 0);
      const adInfo: Object | undefined = item['ad_info'];
      // 过滤广告卡片与不可播放卡片（与 PiliPlus 一致）
      if (cardGoto === 'ad_av' || cardGoto === 'ad_web_s' || canPlay !== 1 || adInfo !== undefined) {
        continue;
      }
      page.items.push(VideoItem.fromAppItem(items[i]));
      const idx: number = asNumber(item['idx'], 0);
      if (idx > 0) page.cursor = idx;
    }
    return page;
  }

  /**
   * 取一页推荐。reset=true（下拉刷新/首次）开新会话；false 续当前会话翻页。
   * 失败时按推荐源回退到另一路（Web ↔ App），不让首页停在加载态。
   */
  static async getRecommend(reset: boolean): Promise<Array<VideoItem>> {
    if (reset) FeedApi.resetRecommendSession();
    const loggedIn: boolean = HttpClient.getCookie('SESSDATA').length > 0 &&
      HttpClient.getCookie('DedeUserID').length > 0;
    const preferApp: boolean = FeedApi.recommendMode() === 'app';
    if (preferApp) {
      try {
        const appPage: Array<VideoItem> = await FeedApi.getRecommendApp();
        if (appPage.length > 0) return appPage;
      } catch (e) {
        // App 推流被风控或网络失败：回退 Web。
      }
      try {
        const webPage: Array<VideoItem> = await FeedApi.getRecommendWeb();
        if (webPage.length > 0) return webPage;
      } catch (e) {
        // 同上，回退也失败则返回空。
      }
      return [];
    }
    if (loggedIn) {
      try {
        const personalized: Array<VideoItem> = await FeedApi.getRecommendWeb();
        if (personalized.length > 0) return personalized;
      } catch (e) {
        // WBI key 获取或签名被风控时继续走 App 推荐，不能让首页永久停在加载态。
      }
    }
    return FeedApi.getRecommendApp();
  }

  static async getRecommendWeb(): Promise<Array<VideoItem>> {
    // 官方协议：页序号从 1 起，每页 +1；把上一页的会话标识回传。
    const idx: number = FeedApi.webFreshIdx + 1;
    const params: Record<string, string> =
      FeedApi.buildWebRcmdParams(idx, FeedApi.webFeedId, FeedApi.webBucketId);
    const resp: HttpResponse = await webGetSigned(Api.recommendListWeb, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const page: FeedPage = FeedApi.parseWebRcmd(data);
    // 只有拿到有效响应才推进会话；feed_id 服务端可能不回，保留旧值比清空好。
    FeedApi.webFreshIdx = idx;
    if (page.feedId.length > 0) FeedApi.webFeedId = page.feedId;
    if (page.bucketId.length > 0) FeedApi.webBucketId = page.bucketId;
    return page.items;
  }

  static async getRecommendApp(): Promise<Array<VideoItem>> {
    const params: Record<string, string> =
      FeedApi.buildAppFeedParams(FeedApi.appCursor, HttpClient.getAppAccessToken());
    await appSign(params);
    const query: string = HttpClient.buildQuery(params);
    const url: string = Api.recommendListApp + '?' + query;
    const headers: Record<string, string> = HttpClient.merge(Constants.appHeaders, { 'buvid': HttpClient.buvid });
    const resp: HttpResponse = await HttpClient.get(url, headers);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const page: FeedPage = FeedApi.parseAppFeed(data);
    if (page.items.length > 0 && page.cursor > 0) FeedApi.appCursor = page.cursor;
    return page.items;
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
