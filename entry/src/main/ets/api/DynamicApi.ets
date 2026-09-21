/**
 * 动态域 API：单条详情 / 关注动态 feed / 点赞 / 转发 / 图文发布 / 用户空间动态。
 */
import { HttpClient, HttpResponse, RequestPriority } from '../services/network/HttpClient';
import { buildMultipart, MultipartField, MultipartFile, MultipartRequest } from '../services/network/MultipartBody';
import { Api, Constants } from '../common/Constants';
import { asObject, asArray, asBool, asNumber, str, randomString } from '../common/Utils';
import { DynamicItem, DynamicPageData } from '../model/Models';
import { ActionResult, actionWithCsrf, getData, postVideoAction, webGet, webGetSigned,
  webPost } from './internal/ApiCommon';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';

/** 一张已上传到 B 站 bfs 的动态图片（publishWithImages 的入参单元）。 */
export class DynUploadedImage {
  imgSrc: string = '';
  imgWidth: number = 0;
  imgHeight: number = 0;
  imgSize: number = 0;
}

/** 图片上传结果：ok=false 时 message 为用户可读原因。 */
export class DynUploadResult {
  ok: boolean = false;
  message: string = '';
  image: DynUploadedImage | null = null;

  constructor(ok: boolean, message: string, image: DynUploadedImage | null) {
    this.ok = ok;
    this.message = message;
    this.image = image;
  }
}

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

  // ===== 图文动态发布（协议对齐 PiliPlus lib/http/msg.dart uploadBfs + lib/http/dynamics.dart createDynamic） =====

  /** upload_bfs 响应解析（纯函数，QA 直接测）：code=0 且返回了 image_url 才算成功。 */
  static parseUploadResponse(json: Record<string, Object>): DynUploadResult {
    const code: number = asNumber(json['code'], -1);
    const serverMessage: string = str(json, 'message', str(json, 'msg', ''));
    if (code !== 0) {
      return new DynUploadResult(false,
        serverMessage.length > 0 ? serverMessage : '图片上传失败 (' + String(code) + ')', null);
    }
    const data: Record<string, Object> = asObject(json['data']);
    const url: string = str(data, 'image_url', '');
    if (url.length === 0) {
      return new DynUploadResult(false, '图片上传响应缺少地址', null);
    }
    const image: DynUploadedImage = new DynUploadedImage();
    image.imgSrc = url;
    image.imgWidth = asNumber(data['image_width'], 0);
    image.imgHeight = asNumber(data['image_height'], 0);
    image.imgSize = asNumber(data['img_size'], 0);
    return new DynUploadResult(true, '上传成功', image);
  }

  /** 上传一张动态图片（multipart → bfs 存储），返回可发布图片对象。 */
  static async uploadDynImage(data: ArrayBuffer, fileName: string, mimeType: string): Promise<DynUploadResult> {
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return new DynUploadResult(false, '登录状态缺少 CSRF，请重新登录', null);
    const boundary: string = 'BiliHarmonyForm' + randomString(16);
    const fields: Array<MultipartField> = [
      new MultipartField('category', 'daily'),
      new MultipartField('biz', 'new_dyn'),
      new MultipartField('csrf', csrf),
    ];
    const files: Array<MultipartFile> = [new MultipartFile('file_up', fileName, mimeType, data)];
    const request: MultipartRequest = buildMultipart(fields, files, boundary);
    const resp: HttpResponse = await HttpClient.postBinary(Api.uploadBfs, request.contentType, request.body,
      Constants.webHeaders, RequestPriority.HIGH);
    if (DEBUG) {
      hilog.info(0x0000, 'DynPub', 'upload resp %{public}d body=%{public}s', resp.status,
        resp.body.substring(0, Math.min(240, resp.body.length)));
    }
    if (!resp.ok) {
      return new DynUploadResult(false, '图片上传失败 (' + String(resp.status) + ')', null);
    }
    return DynamicApi.parseUploadResponse(resp.json());
  }

  /** 图文动态 dyn_req 构建（纯函数，QA 直接测）：scene=2，文本放 contents、图片放 pics。 */
  static buildImageDynReq(text: string, images: Array<DynUploadedImage>, uploadId: string): Record<string, Object> {
    const contents: Array<Object> = [];
    if (text.length > 0) {
      const textEntry: Record<string, Object> = { 'raw_text': text, 'type': 1, 'biz_id': '' };
      contents.push(textEntry);
    }
    const pics: Array<Object> = [];
    for (let i: number = 0; i < images.length; i++) {
      const pic: Record<string, Object> = {
        'img_src': images[i].imgSrc,
        'img_width': images[i].imgWidth,
        'img_height': images[i].imgHeight,
        'img_size': images[i].imgSize,
      };
      pics.push(pic);
    }
    const contentObj: Record<string, Object> = { 'contents': contents };
    const appMeta: Record<string, Object> = { 'from': 'create.dynamic.web', 'mobi_app': 'web' };
    const metaObj: Record<string, Object> = { 'app_meta': appMeta };
    const dynReqObj: Record<string, Object> = {
      'content': contentObj,
      'scene': 2,
      'pics': pics,
      'upload_id': uploadId,
      'meta': metaObj,
    };
    return dynReqObj;
  }

  /**
   * 发布图文动态。文本可空（纯图动态）。
   * create/dyn 的 scene=2 分支要求 JSON body（form 的 dyn_req 字符串会被 -400 拒绝，
   * 2026-09 实测；csrf 走 query，对齐 PiliPlus lib/http/dynamics.dart createDynamic）。
   */
  static async publishWithImages(text: string, images: Array<DynUploadedImage>): Promise<ActionResult> {
    if (images.length === 0) return DynamicApi.publish(text);
    const trimmed: string = text.trim();
    if (trimmed.length > 2000) return new ActionResult(false, '动态内容过长（最多 2000 字）');
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '发布成功', '动态发布失败',
      (csrf: string): Promise<HttpResponse> => {
        const uploadId: string = '0_' + String(Math.floor(Date.now() / 1000)) + '_' +
          String(Math.floor(Math.random() * 9000) + 1000);
        const dynReqObj: Record<string, Object> = DynamicApi.buildImageDynReq(trimmed, images, uploadId);
        const bodyObj: Record<string, Object> = { 'dyn_req': dynReqObj };
        const query: Record<string, string> = {
          'platform': 'web',
          'csrf': csrf,
          'x-bili-device-req-json': '{"platform":"web","device":"pc"}',
          'x-bili-web-req-json': '{"spm_id":"333.999"}',
        };
        const headers: Record<string, string> = HttpClient.merge(Constants.webHeaders,
          { 'Content-Type': 'application/json' });
        return HttpClient.post(Api.createDynamic + '?' + HttpClient.buildQuery(query),
          JSON.stringify(bodyObj), headers)
          .then((resp: HttpResponse): HttpResponse => {
            if (DEBUG) {
              hilog.info(0x0000, 'DynPub', 'publish resp %{public}d body=%{public}s', resp.status,
                resp.body.substring(0, Math.min(240, resp.body.length)));
            }
            return resp;
          });
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
    const resp: HttpResponse = await webGetSigned(Api.memberDynamic, params,
      'https://space.bilibili.com/' + String(mid) + '/dynamic',
      { 'Origin': 'https://space.bilibili.com' });
    return DynamicApi.parseDynamicPage(resp);
  }

  private static parseDynamicPage(resp: HttpResponse): DynamicPageData {
    const data: Record<string, Object> | null = getData(resp);
    const result: DynamicPageData = new DynamicPageData();
    if (data === null) {
      const code: number = asNumber(resp.json()['code'], -1);
      console.warn('[DynamicFeed] failed status=' + String(resp.status) + ' code=' + String(code) +
        ' transport=' + String(resp.transportCode));
      if (resp.status < 0) throw new Error(resp.transportMessage);
      throw new Error(code === -101 ? '登录已失效，请重新登录后查看动态' : '动态加载失败，请稍后重试');
    }
    if (!Array.isArray(data['items'])) throw new Error('动态响应格式异常，请稍后重试');
    const items: Array<Object> = asArray(data['items']);
    for (let i: number = 0; i < items.length; i++) {
      result.items.push(DynamicItem.from(items[i]));
    }
    result.offset = str(data, 'offset', '');
    result.hasMore = asBool(data['has_more'], result.offset.length > 0 && items.length > 0);
    return result;
  }
}
