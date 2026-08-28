/**
 * 动态域 API：单条详情 / 关注动态 feed / 点赞 / 转发 / 用户空间动态。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asBool, str, randomString } from '../common/Utils';
import { DynamicItem, DynamicPageData } from '../model/Models';
import { ActionResult, actionWithCsrf, getData, postVideoAction, webGet, webPost } from './internal/ApiCommon';

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
    const resp: HttpResponse = await webGet(Api.dynamicDetail, params, 'https://t.bilibili.com/' + id);
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
    return DynamicApi.parseDynamicPage(await webGet(Api.followDynamic, params));
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
        return webPost(Api.thumbDynamic, params, 'https://t.bilibili.com/');
      });
  }

  /** 转发动态：web_repost_src 协议，POST 到 create/dyn，场景 scene=4（引用转发）。 */
  static async repostDynamic(dynId: string): Promise<ActionResult> {
    if (dynId.length === 0) return new ActionResult(false, '动态 ID 无效');
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '转发成功', '动态转发失败',
      (csrf: string): Promise<HttpResponse> => {
        const uploadId: string = '0_' + String(Math.floor(Date.now() / 1000)) + '_' +
          String(Math.floor(Math.random() * 9000) + 1000);
        // 直接构造对象再 stringify（禁止字符串拼 JSON，dynId/uploadId 含引号会畸形）。
        // ArkTS 限制对象字面量必须对应显式声明类型，逐层构建 Record。
        const emptyContents: Array<Object> = [];
        const contentObj: Record<string, Object> = { 'contents': emptyContents };
        const appMeta: Record<string, Object> = { 'from': 'create.dynamic.web', 'mobi_app': 'web' };
        const metaObj: Record<string, Object> = { 'app_meta': appMeta };
        const dynReqObj: Record<string, Object> = {
          'content': contentObj,
          'scene': 4,
          'upload_id': uploadId,
          'meta': metaObj,
        };
        const webRepostObj: Record<string, Object> = {
          'dyn_id_str': dynId,
        };
        const params: Record<string, string> = {
          'dyn_req': JSON.stringify(dynReqObj),
          'web_repost_src': JSON.stringify(webRepostObj),
          'platform': 'web',
          'csrf': csrf,
          'csrf_token': csrf,
        };
        const query: Record<string, string> = {
          'platform': 'web',
          'x-bili-device-req-json': '{"platform":"web","device":"pc"}',
          'x-bili-web-req-json': '{"spm_id":"333.999"}',
        };
        // URL 带平台头 query + form body（两套参数），不走 webPost。
        return HttpClient.post(Api.createDynamic + '?' + HttpClient.buildQuery(query),
          HttpClient.buildQuery(params), Constants.webHeaders);
      });
  }

  static async publish(content: string): Promise<ActionResult> {
    const text: string = content.trim();
    if (text.length === 0) return new ActionResult(false, '动态内容不能为空');
    if (text.length > 2000) return new ActionResult(false, '动态内容过长（最多 2000 字）');
    return postVideoAction(Api.createDynamic, {
      'dynamic': text, 'type': '4', 'at_uids': '', 'topic_id': '',
    });
  }

  static async report(dynId: string, reason: string): Promise<ActionResult> {
    if (dynId.length === 0) return new ActionResult(false, '动态信息不完整');
    return postVideoAction(Api.dynamicReport, {
      'dyn_id': dynId, 'reason': reason, 'content': '',
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
    const resp: HttpResponse = await webGet(Api.memberDynamic, params,
      'https://space.bilibili.com/' + String(mid) + '/dynamic',
      { 'Origin': 'https://space.bilibili.com' });
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
