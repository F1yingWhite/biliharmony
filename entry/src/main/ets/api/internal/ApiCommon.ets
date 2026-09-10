/**
 * API 层共享基础设施：统一响应解析（code/data）与 CSRF 互动骨架。
 * 仅允许被 api/ 下的域模块与 BiliApi facade 依赖，禁止反向依赖任何域模块。
 */
import { HttpClient, HttpResponse } from '../../services/network/HttpClient';
import { Constants } from '../../common/Constants';
import { asNumber, asObject, str } from '../../common/Utils';
import { ApiResult, ApiErrorKind } from '../../services/network/ApiResult';

/** 保留传输、登录、业务与解析错误，让列表明确区分失败和空结果。 */
export function parseDataResult(resp: HttpResponse): ApiResult<Record<string, Object>> {
  if (!resp.ok) {
    return new ApiResult<Record<string, Object>>(null, '网络请求失败，请重试 (' + String(resp.status) + ')',
      ApiErrorKind.Network, resp.status);
  }
  const json: Record<string, Object> = resp.json();
  if (typeof json['code'] !== 'number') {
    return new ApiResult<Record<string, Object>>(null, '响应格式异常，请重试', ApiErrorKind.Parse);
  }
  const code: number = asNumber(json['code'], -1);
  if (code !== 0) {
    const auth: boolean = code === -101 || code === -111;
    return new ApiResult<Record<string, Object>>(null,
      auth ? '登录状态已失效，请重新登录' : failureText(resp, '加载失败'),
      auth ? ApiErrorKind.Auth : ApiErrorKind.Business, code);
  }
  const data: Object = json['data'];
  if (data === null || data === undefined || typeof data !== 'object' || Array.isArray(data)) {
    return new ApiResult<Record<string, Object>>(null, '响应数据缺失，请重试', ApiErrorKind.Parse);
  }
  return new ApiResult<Record<string, Object>>(asObject(data));
}

export class ActionResult {
  ok: boolean = false;
  message: string = '';
  code: number = 0;
  /** 接口成功时返回的 data；评论发布需要其中的 rpid 立即构造本地楼层。 */
  data: Record<string, Object> = {};

  constructor(ok: boolean, message: string, code: number = 0, data: Record<string, Object> = {}) {
    this.ok = ok;
    this.message = message;
    this.code = code;
    this.data = data;
  }
}

// ===== 通用：解析 code/data =====
export function getData(resp: HttpResponse): Record<string, Object> | null {
  if (!resp.ok) {
    return null;
  }
  const json: Record<string, Object> = resp.json();
  const code: number = asNumber(json['code'], -1);
  if (code !== 0) {
    return null;
  }
  return asObject(json['data']);
}

/**
 * 统一的失败原因文案：网络层失败（!resp.ok）与业务失败（code != 0）区分，
 * 供各域方法在 getData 返回 null 时透出到 UI 的 error 字段。
 * undefined = 失败但无需细分（调用方可直接返回默认结果）。
 */
export function failureText(resp: HttpResponse, fallback: string): string {
  if (!resp.ok) {
    return '网络请求失败 (' + String(resp.status) + ')';
  }
  const json: Record<string, Object> = resp.json();
  const serverMessage: string = str(json, 'message', str(json, 'msg', ''));
  if (serverMessage.length > 0 && serverMessage !== '0') {
    return serverMessage;
  }
  const code: number = asNumber(json['code'], -1);
  return fallback + ' (' + String(code) + ')';
}

/** 互动接口公共骨架：取 bili_jct 判空 → 发请求 → ok/code/message 统一转结果文案。 */
export async function actionWithCsrf(csrfError: string, okMessage: string, failMessage: string,
  doRequest: (csrf: string) => Promise<HttpResponse>): Promise<ActionResult> {
  if (HttpClient.getCookie('SESSDATA').length === 0) {
    return new ActionResult(false, '登录状态已失效，请重新登录', -101);
  }
  const csrf: string = HttpClient.getCookie('bili_jct');
  if (csrf.length === 0) return new ActionResult(false, csrfError, -111);
  const resp: HttpResponse = await doRequest(csrf);
  if (!resp.ok) return new ActionResult(false, '网络请求失败 (' + String(resp.status) + ')', resp.status);
  const json: Record<string, Object> = resp.json();
  const code: number = asNumber(json['code'], -1);
  const ok: boolean = code === 0;
  const serverMessage: string = str(json, 'message', '');
  const message: string = ok ? okMessage :
    ((serverMessage.length > 0 && serverMessage !== '0' ? serverMessage : failMessage) + ' (' + String(code) + ')');
  return new ActionResult(ok, message, code, ok ? asObject(json['data']) : {});
}

export async function postVideoAction(url: string, params: Record<string, string>): Promise<ActionResult> {
  return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '操作成功', '操作失败',
    (csrf: string): Promise<HttpResponse> => {
      params['csrf'] = csrf;
      return HttpClient.post(url, HttpClient.buildQuery(params), Constants.webHeaders);
    });
}

// ===== Web 域请求脚手架：统一“拼 query + web 头 + 可选 Referer/自定义头” =====

/** 拼接 headers：Web 头 + 可选 Referer + 可选额外头。 */
function webHeaders(referer?: string, extra?: Record<string, string>): Record<string, string> {
  const headers: Record<string, string> = Constants.webHeaders;
  const needExtra: boolean = (referer !== undefined && referer.length > 0) || (extra !== undefined);
  if (!needExtra) {
    return headers;
  }
  const merged: Record<string, string> = HttpClient.merge(headers, {});
  if (referer !== undefined && referer.length > 0) {
    merged['Referer'] = referer;
  }
  if (extra !== undefined) {
    const keys: Array<string> = Object.keys(extra);
    for (let i: number = 0; i < keys.length; i++) {
      merged[keys[i]] = extra[keys[i]];
    }
  }
  return merged;
}

/** 带上 query 的 GET（query 为空时保持原 URL）。 */
function withQuery(url: string, params?: Record<string, string>): string {
  if (params === undefined || Object.keys(params).length === 0) {
    return url;
  }
  return url + '?' + HttpClient.buildQuery(params);
}

/** Web 域 GET：params 拼 query，headers = webHeaders + 可选 Referer/extra。 */
export function webGet(url: string, params?: Record<string, string>, referer?: string,
  extra?: Record<string, string>): Promise<HttpResponse> {
  return HttpClient.get(withQuery(url, params), webHeaders(referer, extra));
}

/** Web 域 POST（x-www-form-urlencoded）：body 由 params 构造；headers 同 webGet。 */
export function webPost(url: string, params?: Record<string, string>, referer?: string,
  extra?: Record<string, string>): Promise<HttpResponse> {
  const body: string = params === undefined ? '' : HttpClient.buildQuery(params);
  return HttpClient.post(url, body, webHeaders(referer, extra));
}
