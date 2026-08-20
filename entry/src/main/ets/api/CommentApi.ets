/**
 * 评论域 API：主评论列表 / 发布 / 点赞 / 点踩 / 表情包 / 楼中楼。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asArray, asObject } from '../common/Utils';
import { BiliEmotePackage, ReplyData } from '../model/Models';
import { ActionResult, getData, postVideoAction, webGet, webPost } from './internal/ApiCommon';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class CommentApi {
  // ===== 评论（游客模式，WBI 签名 /wbi/main） =====
  static async getReplies(oid: number, type: number, cursor: string, mode: number = 3): Promise<ReplyData> {
    // 登录态用传统分页端点：它能稳定返回完整主评论总量；游客态继续使用 /main 的 next_offset。
    if (HttpClient.getCookie('SESSDATA').length > 0) {
      const pageNumber: number = Math.max(1, Number(cursor.length > 0 ? cursor : '1'));
      const legacyParams: Record<string, string> = {
        'oid': String(oid), 'type': String(type), 'pn': String(pageNumber), 'ps': '20',
        'sort': mode === 3 ? '1' : '0',
      };
      const legacyResp: HttpResponse = await webGet(Api.replyList, legacyParams, 'https://www.bilibili.com/');
      const legacyData: Record<string, Object> | null = getData(legacyResp);
      if (legacyData !== null) return ReplyData.fromLegacy(legacyData, pageNumber);
    }
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'mode': String(mode),
      'pagination_str': JSON.stringify({ 'offset': cursor }),
    };
    // 对齐当前 PiliPlus：游客/通用评论流使用 /main 与 next_offset，不对该端点追加 WBI 参数。
    const resp: HttpResponse = await webGet(Api.replyList + '/main', params, 'https://www.bilibili.com/');
    let data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      // 部分网络会对匿名 /main 返回 -352；回退到签名端点，避免评论区完全不可用。
      const fallback: Record<string, string> = {
        'oid': String(oid), 'type': String(type), 'mode': String(mode),
        'pagination_str': JSON.stringify({ 'offset': cursor }), 'web_location': '1315875',
      };
      await WbiSign.encWbi(fallback);
      const fallbackResp: HttpResponse = await webGet(Api.replyList + '/wbi/main', fallback, 'https://www.bilibili.com/');
      data = getData(fallbackResp);
    }
    if (data === null) {
      return new ReplyData();
    }
    return ReplyData.from(data);
  }

  static async addReply(oid: number, type: number, message: string, root: number = 0, parent: number = 0): Promise<ActionResult> {
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'message': message,
      'plat': '1',
    };
    if (root > 0) params['root'] = String(root);
    if (parent > 0) params['parent'] = String(parent);
    return postVideoAction(Api.replyAdd, params);
  }

  static async likeReply(oid: number, type: number, rpid: number, liked: boolean): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) return new ActionResult(false, '评论参数无效');
    return postVideoAction(Api.replyLike, {
      'oid': String(oid),
      'type': String(type),
      'rpid': String(rpid),
      'action': liked ? '1' : '0',
    });
  }

  /** 评论点踩/取消踩：action 1 踩、0 取消。 */
  static async hateReply(oid: number, type: number, rpid: number, hate: boolean): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) return new ActionResult(false, '评论参数无效');
    return postVideoAction(Api.replyHate, {
      'oid': String(oid),
      'type': String(type),
      'rpid': String(rpid),
      'action': hate ? '1' : '0',
    });
  }

  /** 删除自己的评论/回复（type 为评论类型、oid 评论对象、rpid 评论 id，均与服务端一致）。 */
  static async deleteReply(oid: number, type: number, rpid: number): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) return new ActionResult(false, '评论参数无效');
    return postVideoAction(Api.replyDel, {
      'oid': String(oid),
      'type': String(type),
      'rpid': String(rpid),
    });
  }

  /** 评论举报（需登录；reason 参考网页端：21 违法违规 22 色情低俗…统一走 21 细分，传入具体 reason）。 */
  static async reportReply(oid: number, type: number, rpid: number, reason: string): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) return new ActionResult(false, '评论参数无效');
    if (HttpClient.getCookie('SESSDATA').length === 0) {
      return new ActionResult(false, '登录状态已失效，请重新登录', -101);
    }
    const csrf: string = HttpClient.getCookie('bili_jct');
    if (csrf.length === 0) return new ActionResult(false, '登录状态缺少 CSRF，请重新登录', -111);
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'rpid': String(rpid),
      'reason': reason,
      'content': '',
      'csrf': csrf,
      'platform': 'web',
      'web_location': '1315875',
    };
    await WbiSign.encWbi(params);
    const resp: HttpResponse = await webPost(Api.replyReport, params);
    if (!resp.ok) return new ActionResult(false, '网络请求失败 (' + String(resp.status) + ')', resp.status);
    const json: Record<string, Object> = resp.json();
    const code: number = Number(json['code'] ?? -1);
    const ok: boolean = code === 0;
    return new ActionResult(ok, ok ? '已提交举报，感谢反馈' :
      (String(json['message'] ?? '举报失败') + ' (' + String(code) + ')'), code);
  }

  // ===== 当前账号可用的 B 站表情包（评论/动态共用官方素材 URL） =====
  static async getUserEmotes(business: string = 'reply'): Promise<Array<BiliEmotePackage>> {
    const params: Record<string, string> = {
      'business': business,
      'web_location': '333.1245',
    };
    const resp: HttpResponse = await webGet(Api.userEmotes, params, 'https://www.bilibili.com/');
    if (!resp.ok) {
      // 诊断日志：区分"网络/HTTP 失败"与"业务 code 失败"，此前失败全静默无法排查。
      hilog.warn(0x0000, 'BiliApi', 'getUserEmotes http failed: business=%{public}s status=%{public}d',
        business, resp.status);
      return [];
    }
    const json: Record<string, Object> = resp.json();
    const code: number = Number(json['code'] ?? -1);
    if (code !== 0) {
      hilog.warn(0x0000, 'BiliApi', 'getUserEmotes biz failed: business=%{public}s code=%{public}d message=%{public}s',
        business, code, String(json['message'] ?? ''));
      return [];
    }
    const data: Record<string, Object> = asObject(json['data']);
    const packages: Array<Object> = asArray(data['packages']);
    const result: Array<BiliEmotePackage> = [];
    let droppedEmpty: number = 0;
    for (let i: number = 0; i < packages.length; i++) {
      const pkg: BiliEmotePackage = BiliEmotePackage.from(packages[i]);
      if (pkg.emotes.length > 0) {
        result.push(pkg);
      } else {
        droppedEmpty++;
      }
    }
    hilog.info(0x0000, 'BiliApi',
      'getUserEmotes ok: business=%{public}s packages=%{public}d kept=%{public}d droppedEmpty=%{public}d',
      business, packages.length, result.length, droppedEmpty);
    return result;
  }

  // ===== 单条评论的完整回复列表（楼中楼） =====
  // 老端点 /x/v2/reply/reply（pn 分页）近期被风控（-352/空列表），导致"显示有 N 条回复、点开却是空的"。
  // 改走与主列表同款 /x/v2/reply/main：pagination_str 带 root + type:10（取根评论的全部子回复），
  // 用 next_offset 游标翻页；匿名 -352 时回退 WBI 签名端点（与 getReplies 一致）。
  static async getReplyReplies(oid: number, type: number, root: number, cursor: string): Promise<ReplyData> {
    const paginationObj: Record<string, Object> = {
      'root': root,
      'offset': cursor,
      'next': true,
      'sort': 1,
      'type': 10,
    };
    const pagination: string = JSON.stringify(paginationObj);
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'mode': '3',
      'pagination_str': pagination,
    };
    const resp: HttpResponse = await webGet(Api.replyList + '/main', params, 'https://www.bilibili.com/');
    let data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      hilog.warn(0x0000, 'BiliApi',
        'getReplyReplies /main failed oid=%{public}d root=%{public}d cursorLen=%{public}d; try wbi fallback',
        oid, root, cursor.length);
      const fallback: Record<string, string> = {
        'oid': String(oid),
        'type': String(type),
        'mode': '3',
        'pagination_str': pagination,
        'web_location': '1315875',
      };
      await WbiSign.encWbi(fallback);
      const fallbackResp: HttpResponse = await webGet(Api.replyList + '/wbi/main', fallback, 'https://www.bilibili.com/');
      data = getData(fallbackResp);
    }
    if (data === null) {
      hilog.warn(0x0000, 'BiliApi',
        'getReplyReplies both /main and /wbi/main failed oid=%{public}d root=%{public}d', oid, root);
      return new ReplyData();
    }
    return ReplyData.from(data);
  }
}
