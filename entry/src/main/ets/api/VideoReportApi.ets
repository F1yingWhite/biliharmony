import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { asArray, asNumber, asObject, str } from '../common/Utils';
import { ActionResult, actionWithCsrf, failureText, webGet, webPost } from './internal/ApiCommon';

export class VideoReportReason {
  id: number = 0;
  name: string = '';
  hint: string = '';
}

export class VideoReportApi {
  static async reasons(): Promise<Array<VideoReportReason>> {
    const response: HttpResponse = await webGet('https://api.bilibili.com/x/web-interface/archive/appeal/tags');
    const json: Record<string, Object> = response.json();
    if (!response.ok || asNumber(json['code'], -1) !== 0) {
      throw new Error(failureText(response, '举报原因加载失败'));
    }
    const reasons: Array<VideoReportReason> = [];
    for (const value of asArray(json['data'])) {
      const row: Record<string, Object> = asObject(value);
      // 需要专门版权/撞车凭证的类型留给官方申诉表单，不能漏填必填控件。
      if (asArray(row['controls']).length > 0) continue;
      const reason: VideoReportReason = new VideoReportReason();
      reason.id = asNumber(row['tid'], 0);
      reason.name = str(row, 'name', '');
      reason.hint = str(row, 'remark', '请描述问题及其出现位置');
      if (reason.id > 0 && reason.name.length > 0) reasons.push(reason);
    }
    if (reasons.length === 0) throw new Error('暂无可用举报原因，请稍后重试');
    return reasons;
  }

  static async submit(aid: number, reasonId: number, description: string): Promise<ActionResult> {
    if (aid <= 0 || reasonId <= 0 || description.trim().length === 0) {
      return new ActionResult(false, '请选择举报原因并填写问题描述');
    }
    return actionWithCsrf('登录状态缺少 CSRF，请重新登录', '已提交举报，感谢反馈', '举报失败',
      (csrf: string): Promise<HttpResponse> => {
        let buid: string = HttpClient.getCookie('Buid');
        if (buid.length === 0) {
          buid = Date.now().toString(16) + Math.random().toString(16).substring(2);
          HttpClient.setCookie('Buid', buid);
        }
        return webPost('https://api.bilibili.com/x/web-interface/appeal/v2/submit', {
          'aid': String(aid), 'tid': String(reasonId), 'desc': description.trim(), 'csrf': csrf,
        }, 'https://www.bilibili.com/', { 'buid': buid });
      });
  }
}
