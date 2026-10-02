import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { asArray, asNumber, asObject, str } from '../common/Utils';
import { ActionResult, actionWithCsrf, failureText, webGet, webPost } from './internal/ApiCommon';

export class VideoReportReason {
  aid: number = 0;
  id: number = 0;
  name: string = '';
  hint: string = '';
  type: string = '';
  officialUrl: string = '';

  canSubmit(description: string): boolean {
    return this.aid > 0 && this.id > 0 && this.type === 'normal' &&
      this.officialUrl.length === 0 && description.trim().length > 0;
  }
}

export class VideoReportApi {
  static async reasons(aid: number): Promise<Array<VideoReportReason>> {
    if (!Number.isSafeInteger(aid) || aid <= 0) throw new Error('当前视频不支持举报');
    const response: HttpResponse = await webGet('https://api.bilibili.com/x/web-interface/appeal/v2/tags', {
      'from': 'web', 'aid': String(aid), 'version': 'v1',
    });
    const json: Record<string, Object> = response.json();
    if (!response.ok || asNumber(json['code'], -1) !== 0) {
      throw new Error(failureText(response, '举报原因加载失败'));
    }
    const reasons: Array<VideoReportReason> = [];
    const data: Record<string, Object> = asObject(json['data']);
    const author: Record<string, Object> = asObject(data['author']);
    const mid: number = asNumber(author['mid'], 0);
    const seen: Set<number> = new Set<number>();
    for (const groupValue of asArray(data['tags'])) {
      const group: Record<string, Object> = asObject(groupValue);
      if (asNumber(group['state'], 0) !== 1) continue;
      for (const value of asArray(group['sub_tag'])) {
        const row: Record<string, Object> = asObject(value);
        const type: string = str(row, 'type', '');
        if (asNumber(row['state'], 0) !== 1 || (type !== 'normal' && type !== 'jump')) continue;
        const reason: VideoReportReason = new VideoReportReason();
        reason.aid = aid;
        reason.id = asNumber(row['tid'], 0);
        reason.name = str(row, 'name', '');
        reason.type = type;
        if (!Number.isSafeInteger(reason.id) || reason.id <= 0 || reason.name.length === 0 || seen.has(reason.id)) continue;
        const attr: Record<string, Object> = asObject(row['attr']);
        reason.hint = str(attr, 'description', '请描述问题及其出现位置');
        if (type === 'jump') {
          reason.officialUrl = VideoReportApi.officialFormUrl(str(attr, 'url', ''), aid, mid);
        } else if (reason.id === 52 || asArray(row['controls']).length > 0) {
          // 官方表单的“转载/自制错误”还需要 meta 出处；专用凭证交给官方流程填写。
          reason.officialUrl = VideoReportApi.officialPageUrl(aid);
        }
        seen.add(reason.id);
        reasons.push(reason);
      }
    }
    if (reasons.length === 0) throw new Error('暂无可用举报原因，请稍后重试');
    return reasons;
  }

  private static officialPageUrl(aid: number): string {
    return 'https://www.bilibili.com/appeal/?avid=' + String(aid);
  }

  private static officialFormUrl(url: string, aid: number, mid: number): string {
    // 官方当前跳转均在 www.bilibili.com；未知地址回落官方举报页，不打开任意服务端 URL。
    if (!url.startsWith('https://www.bilibili.com/')) return VideoReportApi.officialPageUrl(aid);
    const hashIndex: number = url.indexOf('#');
    const base: string = hashIndex < 0 ? url : url.substring(0, hashIndex);
    const hash: string = hashIndex < 0 ? '' : url.substring(hashIndex);
    return base + (base.includes('?') ? '&' : '?') + HttpClient.buildQuery({
      'aid': String(aid), 'mid': mid > 0 ? String(mid) : '', 'version': 'new',
    }) + hash;
  }

  static async submit(aid: number, reason: VideoReportReason, description: string): Promise<ActionResult> {
    if (reason.type === 'jump' || reason.officialUrl.length > 0) {
      return new ActionResult(false, '此类型需要前往官方申诉页面填写');
    }
    if (!Number.isSafeInteger(aid) || aid <= 0 || reason.aid !== aid || !reason.canSubmit(description)) {
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
          'aid': String(aid), 'tid': String(reason.id), 'desc': description.trim(), 'csrf': csrf,
          'attach': '', 'meta': '', 'block_author': 'false',
        }, 'https://www.bilibili.com/', { 'buid': buid });
      });
  }
}
