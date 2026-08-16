/**
 * API 层共享基础设施：统一响应解析（code/data）与 CSRF 互动骨架。
 * 仅允许被 api/ 下的域模块与 BiliApi facade 依赖，禁止反向依赖任何域模块。
 */
import { HttpClient, HttpResponse } from '../../common/HttpClient';
import { Constants } from '../../common/Constants';
import { asNumber, asObject, str } from '../../common/Utils';

export class ActionResult {
  ok: boolean = false;
  message: string = '';
  code: number = 0;

  constructor(ok: boolean, message: string, code: number = 0) {
    this.ok = ok;
    this.message = message;
    this.code = code;
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
  return new ActionResult(ok, message, code);
}

export async function postVideoAction(url: string, params: Record<string, string>): Promise<ActionResult> {
  return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '操作成功', '操作失败',
    (csrf: string): Promise<HttpResponse> => {
      params['csrf'] = csrf;
      return HttpClient.post(url, HttpClient.buildQuery(params), Constants.webHeaders);
    });
}
