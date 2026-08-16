/**
 * 动态域 API：单条详情 / 关注动态 feed / 点赞 / 转发 / 用户空间动态。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asBool, str, randomString } from '../common/Utils';
import { DynamicItem, DynamicPageData } from '../model/Models';
import { ActionResult, actionWithCsrf, getData } from './internal/ApiCommon';

export class DynamicApi {
  static async getDynamicDetail(id: string): Promise<DynamicItem | null> {
    if (id.length === 0) return null;
    const params: Record<string, string> = {
      'timezone_offset': '-480',
      'id': id,
      'features': Constants.dynFeatures,
      'gaia_source': 'Athena',
      'web_location': '333.1330',
      'x-bili-device-req-json': '{"platform":"web","device":"pc","spmid":"333.1330"}',
    };
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length > 0) params['csrf'] = csrf;
    const resp: HttpResponse = await HttpClient.get(Api.dynamicDetail + '?' + HttpClient.buildQuery(params),
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://t.bilibili.com/' + id }));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return null;
    const item: Record<string, Object> = asObject(data['item']);
    return Object.keys(item).length > 0 ? DynamicItem.from(item) : null;
  }

  // ===== 动态 feed（关注动态，未登录为空） =====
  static async getDynamicFeed(offset: string, dynType: string = 'all'): Promise<DynamicPageData> {
    const params: Record<string, string> = {
      'timezone_offset': '-480',
      // all 返回全部；video/pgc/article 与 PiliPlus DynamicsTabType 对齐，用于动态分类筛选。
      'type': dynType,
      'page': '1',
      'features': Constants.dynFeatures,
      'offset': offset,
    };
    const url: string = Api.followDynamic + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    return DynamicApi.parseDynamicPage(resp);
  }

  /** 动态点赞：up=1 点赞、0 取消，协议对齐 PiliPlus lib/http/dynamics.dart thumbDynamic。 */
  static async likeDynamic(dynId: string, like: boolean): Promise<ActionResult> {
    if (dynId.length === 0) return new ActionResult(false, '动态 ID 无效');
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', like ? '点赞成功' : '已取消点赞', '动态点赞失败',
      (csrf: string): Promise<HttpResponse> => {
        const params: Record<string, string> = {
          'dyn_id': dynId,
          'dyn_id_str': dynId,
          'up': like ? '1' : '0',
          'platform': 'web',
          'spmid': '333.1365.0.0',
          'csrf': csrf,
        };
        return HttpClient.post(Api.thumbDynamic, HttpClient.buildQuery(params),
          HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://t.bilibili.com/' }));
      });
  }

  /** 转发动态：web_repost_src 协议，POST 到 create/dyn，场景 scene=4（引用转发）。 */
  static async repostDynamic(dynId: string): Promise<ActionResult> {
    if (dynId.length === 0) return new ActionResult(false, '动态 ID 无效');
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '转发成功', '动态转发失败',
      (csrf: string): Promise<HttpResponse> => {
        const uploadId: string = '0_' + String(Math.floor(Date.now() / 1000)) + '_' +
          String(Math.floor(Math.random() * 9000) + 1000);
        const dynReq: Record<string, Object> = asObject(JSON.parse(
          '{"content":{"contents":[]},"scene":4,"upload_id":"' + uploadId +
          '","meta":{"app_meta":{"from":"create.dynamic.web","mobi_app":"web"}}}') as Object);
        const webRepostSrc: Record<string, Object> = asObject(JSON.parse(
          '{"dyn_id_str":"' + dynId + '"}') as Object);
        const params: Record<string, string> = {
          'dyn_req': JSON.stringify(dynReq),
          'web_repost_src': JSON.stringify(webRepostSrc),
          'platform': 'web',
          'csrf': csrf,
          'csrf_token': csrf,
        };
        const query: Record<string, string> = {
          'platform': 'web',
          'x-bili-device-req-json': '{"platform":"web","device":"pc"}',
          'x-bili-web-req-json': '{"spm_id":"333.999"}',
        };
        return HttpClient.post(Api.createDynamic + '?' + HttpClient.buildQuery(query),
          HttpClient.buildQuery(params), Constants.webHeaders);
      });
  }

  // ===== 用户空间动态（公开数据，WBI 签名） =====
  static async getUserDynamicFeed(mid: number, offset: string): Promise<DynamicPageData> {
    const params: Record<string, string> = {
      'offset': offset,
      'host_mid': String(mid),
      'timezone_offset': '-480',
      'features': Constants.dynFeatures,
      'platform': 'web',
      'web_location': '333.1387',
      'dm_img_list': '[]',
      'dm_img_str': randomString(32),
      'dm_cover_img_str': randomString(64),
      'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
      'x-bili-device-req-json': '{"platform":"web","device":"pc","spmid":"333.1387"}',
    };
    await WbiSign.encWbi(params);
    const url: string = Api.memberDynamic + '?' + HttpClient.buildQuery(params);
    const headers: Record<string, string> = HttpClient.merge(Constants.webHeaders, {
      'Origin': 'https://space.bilibili.com',
      'Referer': 'https://space.bilibili.com/' + String(mid) + '/dynamic',
    });
    const resp: HttpResponse = await HttpClient.get(url, headers);
    return DynamicApi.parseDynamicPage(resp);
  }

  private static parseDynamicPage(resp: HttpResponse): DynamicPageData {
    const data: Record<string, Object> | null = getData(resp);
    const result: DynamicPageData = new DynamicPageData();
    if (data === null) {
      return result;
    }
    const items: Array<Object> = asArray(data['items']);
    for (let i: number = 0; i < items.length; i++) {
      result.items.push(DynamicItem.from(items[i]));
    }
    result.offset = str(data, 'offset', '');
    result.hasMore = asBool(data['has_more'], result.offset.length > 0 && items.length > 0);
    return result;
  }
}
