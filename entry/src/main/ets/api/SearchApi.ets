/**
 * 搜索域 API：热搜 / 综合搜索 / 分类搜索 / 全站排行 / 每周必看 / 入站必刷 / 搜索建议。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asString, asNumber, str } from '../common/Utils';
import { ArticleSearchItem, ArticleSearchResult, HotSearchItem, PgcSearchItem, PgcSearchResult,
  PopularSeriesData, PopularSeriesItem, SearchAllResult, SearchAllSection, SearchTypes, UserSearchItem,
  UserSearchResult, VideoItem, VideoSearchResult } from '../model/Models';
import { LiveRoomItem, LiveSearchResult } from '../model/LiveModels';
import { getData, webGet } from './internal/ApiCommon';

/** web 搜索每页条数：B 站搜索接口翻页时必须显式传 page_size，否则 page>1 返回空 result。 */
const SEARCH_PAGE_SIZE: number = 20;

export class SearchApi {
  // ===== 热搜 =====
  static async getHotSearch(): Promise<Array<HotSearchItem>> {
    const resp: HttpResponse = await webGet(Api.hotSearchList);
    if (!resp.ok) {
      return [];
    }
    const json: Record<string, Object> = resp.json();
    const list: Array<Object> = asArray(json['list']);
    const result: Array<HotSearchItem> = [];
    for (let i: number = 0; i < list.length; i++) {
      result.push(HotSearchItem.from(list[i]));
    }
    return result;
  }

  // ===== 搜索趋势榜（x/v2/search/trending/ranking；keyword 可直接搜索） =====
  static async getSearchTrending(): Promise<Array<HotSearchItem>> {
    const resp: HttpResponse = await webGet(Api.searchTrending);
    if (!resp.ok) {
      return [];
    }
    const json: Record<string, Object> = resp.json();
    const data: Record<string, Object> = asObject(json['data']);
    const list: Array<Object> = asArray(data['list']);
    const result: Array<HotSearchItem> = [];
    for (let i: number = 0; i < list.length; i++) {
      result.push(HotSearchItem.from(list[i]));
    }
    return result;
  }

  // ===== 搜索（综合，取视频结果） =====
  static async search(keyword: string, page: number): Promise<Array<VideoItem>> {
    const params: Record<string, string> = {
      'keyword': keyword,
      'page': String(page),
    };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.searchAll, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return [];
    }
    const results: Array<Object> = asArray(data['result']);
    const result: Array<VideoItem> = [];
    for (let i: number = 0; i < results.length; i++) {
      const r: Record<string, Object> = asObject(results[i]);
      const rtype: string = asString(r['result_type'], '');
      if (rtype !== 'video') {
        continue;
      }
      const vids: Array<Object> = asArray(r['data']);
      for (let j: number = 0; j < vids.length; j++) {
        result.push(VideoItem.fromSearchItem(vids[j]));
      }
    }
    return result;
  }

  // ===== 综合搜索（all/v2）：按 result_type 分区混排；番剧/用户分区只在第一页返回（与 PiliPlus 一致） =====
  static async searchAll(keyword: string, page: number): Promise<SearchAllResult> {
    const result: SearchAllResult = new SearchAllResult();
    const params: Record<string, string> = {
      'keyword': keyword,
      'page': String(page),
      'page_size': String(SEARCH_PAGE_SIZE),
    };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.searchAll, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return result;
    }
    // pageinfo：各分类结果总数，用于结果页 Tab 徽标
    const pageinfo: Record<string, Object> = asObject(data['pageinfo']);
    const infoKeys: Array<string> = Object.keys(pageinfo);
    for (let i: number = 0; i < infoKeys.length; i++) {
      const info: Record<string, Object> = asObject(pageinfo[infoKeys[i]]);
      result.totals.set(infoKeys[i], asNumber(info['numResults'], 0));
    }
    const groups: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < groups.length; i++) {
      const group: Record<string, Object> = asObject(groups[i]);
      const rtype: string = asString(group['result_type'], '');
      const items: Array<Object> = asArray(group['data']);
      if (items.length === 0) {
        continue;
      }
      const section: SearchAllSection = new SearchAllSection();
      section.type = rtype;
      if (rtype === SearchTypes.video) {
        for (let j: number = 0; j < items.length; j++) {
          const entry: Record<string, Object> = asObject(items[j]);
          // 视频分区会混入 live_room/广告卡（无 bvid，aid=0），
          // 渲染键会撞 '0' 导致 ForEach 键冲突、列表停更，直接跳过。
          if (asString(entry['type'], 'video') !== 'video') {
            continue;
          }
          section.videos.push(VideoItem.fromSearchItem(items[j]));
        }
        result.sections.push(section);
      } else if (rtype === SearchTypes.biliUser && page === 1) {
        for (let j = 0; j < items.length; j++) {
          section.users.push(UserSearchItem.from(items[j]));
        }
        result.sections.push(section);
      } else if ((rtype === SearchTypes.mediaBangumi || rtype === SearchTypes.mediaFt) && page === 1) {
        for (let j = 0; j < items.length; j++) {
          const item: PgcSearchItem = PgcSearchItem.from(items[j]);
          if (item.seasonId > 0) {
            section.pgc.push(item);
          }
        }
        if (section.pgc.length > 0) {
          result.sections.push(section);
        }
      }
    }
    return result;
  }

  // ===== 分类搜索（search/type，WBI 签名；extra 为类型专属筛选参数，参与签名） =====
  static async searchByType(keyword: string, searchType: string, page: number, order: string = '',
    extra?: Record<string, string>): Promise<Record<string, Object> | null> {
    const params: Record<string, string> = {
      'keyword': keyword,
      'search_type': searchType,
      'page': String(page),
      'page_size': String(SEARCH_PAGE_SIZE),
    };
    if (order.length > 0) {
      params['order'] = order;
    }
    if (extra !== undefined) {
      const keys: Array<string> = Object.keys(extra);
      for (let i: number = 0; i < keys.length; i++) {
        params[keys[i]] = extra[keys[i]];
      }
    }
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.searchByType, params);
    return getData(resp);
  }

  // ===== 视频搜索（order 排序 + 时长/发布时间/分区筛选） =====
  static async searchVideosByType(keyword: string, page: number, order: string, duration: number,
    pubtimeBegin: number, tids: number): Promise<VideoSearchResult> {
    const extra: Record<string, string> = {};
    if (duration > 0) {
      extra['duration'] = String(duration);
    }
    if (pubtimeBegin > 0) {
      extra['pubtime_begin_s'] = String(pubtimeBegin);
      extra['pubtime_end_s'] = String(Math.floor(Date.now() / 1000));
    }
    if (tids > 0) {
      extra['tids'] = String(tids);
    }
    const result: VideoSearchResult = new VideoSearchResult();
    const data: Record<string, Object> | null = await SearchApi.searchByType(keyword, SearchTypes.video, page, order, extra);
    if (data === null) {
      return result;
    }
    result.numResults = asNumber(data['numResults'], 0);
    const list: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < list.length; i++) {
      result.videos.push(VideoItem.fromSearchItem(list[i]));
    }
    return result;
  }

  // ===== 用户搜索（order: ''/fans/level；userType: 0 不限 1 认证UP主 2 普通用户 3 认证用户） =====
  static async searchUsers(keyword: string, page: number, order: string,
    userType: number = 0): Promise<UserSearchResult> {
    const extra: Record<string, string> = {};
    if (order.length > 0) {
      extra['order_sort'] = '0';
    }
    if (userType > 0) {
      extra['user_type'] = String(userType);
    }
    const result: UserSearchResult = new UserSearchResult();
    const data: Record<string, Object> | null = await SearchApi.searchByType(keyword, SearchTypes.biliUser, page, order, extra);
    if (data === null) {
      return result;
    }
    result.numResults = asNumber(data['numResults'], 0);
    const list: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < list.length; i++) {
      result.users.push(UserSearchItem.from(list[i]));
    }
    return result;
  }

  // ===== 番剧/影视搜索（media_bangumi / media_ft） =====
  static async searchMedia(keyword: string, searchType: string, page: number): Promise<PgcSearchResult> {
    const result: PgcSearchResult = new PgcSearchResult();
    const data: Record<string, Object> | null = await SearchApi.searchByType(keyword, searchType, page);
    if (data === null) {
      return result;
    }
    result.numResults = asNumber(data['numResults'], 0);
    const list: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < list.length; i++) {
      const item: PgcSearchItem = PgcSearchItem.from(list[i]);
      if (item.seasonId > 0) {
        result.items.push(item);
      }
    }
    return result;
  }

  // ===== 直播搜索（live_room，order: online 人气 / live_time 最新开播） =====
  static async searchLiveRooms(keyword: string, page: number, order: string): Promise<LiveSearchResult> {
    const result: LiveSearchResult = new LiveSearchResult();
    const data: Record<string, Object> | null = await SearchApi.searchByType(keyword, SearchTypes.liveRoom, page, order);
    if (data === null) {
      return result;
    }
    result.numResults = asNumber(data['numResults'], 0);
    const list: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < list.length; i++) {
      const room: LiveRoomItem = LiveRoomItem.fromSearch(list[i]);
      if (room.roomId > 0) {
        result.rooms.push(room);
      }
    }
    return result;
  }

  // ===== 专栏搜索（article） =====
  static async searchArticles(keyword: string, page: number): Promise<ArticleSearchResult> {
    const result: ArticleSearchResult = new ArticleSearchResult();
    const data: Record<string, Object> | null = await SearchApi.searchByType(keyword, SearchTypes.article, page);
    if (data === null) {
      return result;
    }
    result.numResults = asNumber(data['numResults'], 0);
    const list: Array<Object> = asArray(data['result']);
    for (let i: number = 0; i < list.length; i++) {
      const item: ArticleSearchItem = ArticleSearchItem.from(list[i]);
      if (item.id > 0) {
        result.articles.push(item);
      }
    }
    return result;
  }

  // ===== 全站排行（rid=0 综合榜，WBI 签名；参考 PiliPlus getRankVideoList） =====
  static async getRankVideos(rid: number = 0): Promise<Array<VideoItem>> {
    const params: Record<string, string> = { 'rid': String(rid), 'type': 'all' };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.rankAll, params);
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

  // ===== 每周必看：series/list 取最新一期 number，再由 series/one 拉该期视频 =====
  static async getPopularSeriesList(): Promise<Array<PopularSeriesItem>> {
    const params: Record<string, string> = { 'web_location': '333.934' };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.popularSeriesList, params);
    const data: Record<string, Object> | null = getData(resp);
    const result: Array<PopularSeriesItem> = [];
    if (data === null) {
      return result;
    }
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) {
      const item: PopularSeriesItem = PopularSeriesItem.from(list[i]);
      if (item.number > 0) {
        result.push(item);
      }
    }
    return result;
  }

  static async getPopularSeriesOne(number: number): Promise<PopularSeriesData> {
    const result: PopularSeriesData = new PopularSeriesData();
    if (number <= 0) {
      return result;
    }
    const params: Record<string, string> = { 'number': String(number), 'web_location': '333.934' };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.popularSeriesOne, params);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      return result;
    }
    const config: Record<string, Object> = asObject(data['config']);
    result.name = str(config, 'name', '');
    result.label = str(config, 'label', '');
    result.reminder = str(data, 'reminder', '');
    const list: Array<Object> = asArray(data['list']);
    for (let i: number = 0; i < list.length; i++) {
      result.videos.push(VideoItem.fromHotItem(list[i]));
    }
    return result;
  }

  // ===== 入站必刷（PiliPlus 实际走 popular/precious 分页接口，page_size=100） =====
  static async getPopularPrecious(page: number = 1): Promise<Array<VideoItem>> {
    const params: Record<string, string> = {
      'page_size': '100', 'page': String(page), 'web_location': '333.934',
    };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webGet(Api.popularPrecious, params);
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

  // ===== 搜索默认词（B 站首页搜索框的兜底占位词） =====
  static async getSearchDefault(): Promise<string> {
    try {
      const params: Record<string, string> = {};
      await WbiSign.encWbi(params);
      const resp: HttpResponse = await webGet(Api.searchDefault, params);
      const data: Record<string, Object> | null = getData(resp);
      if (data === null) return '';
      // 实测返回结构：data.show_name 是字符串（如 "脱缰凯KK"），name 冗余同值。
      const direct: string = asString(data['show_name'], '');
      if (direct.length > 0) return direct;
      const show: Record<string, Object> = asObject(data['show_name']);
      const val: string = asString(show['value'], '');
      return val.length > 0 ? val : '';
    } catch (e) {
      return '';
    }
  }

  // ===== 搜索建议 =====
  static async searchSuggest(term: string): Promise<Array<string>> {
    const params: Record<string, string> = { 'term': term, 'main_ver': 'v1' };
    const resp: HttpResponse = await webGet(Api.searchSuggest, params);
    if (!resp.ok) {
      return [];
    }
    const json: Record<string, Object> = resp.json();
    const resultObj: Record<string, Object> = asObject(json['result']);
    const tag: Array<Object> = asArray(resultObj['tag']);
    const out: Array<string> = [];
    for (let i: number = 0; i < tag.length; i++) {
      const t: Record<string, Object> = asObject(tag[i]);
      const v: string = asString(t['value'], '');
      if (v.length > 0) {
        out.push(v);
      }
    }
    return out;
  }
}

