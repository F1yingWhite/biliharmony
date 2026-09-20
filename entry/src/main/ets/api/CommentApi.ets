/**
 * 评论域 API：主评论列表 / 发布 / 点赞 / 点踩 / 表情包 / 楼中楼。
 */
import { HttpClient, HttpResponse, RequestPriority } from '../services/network/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asArray, asObject } from '../common/Utils';
import { BiliEmotePackage, ReplyData, ReplyItem } from '../model/Models';
import { ActionResult, getData, postVideoAction, webGet, webGetWithPriority,
  webPost } from './internal/ApiCommon';
import { EmotePackageCache } from '../common/EmotePackageCache';
import { CommentLog } from '../common/CommentLog';

export class CommentApi {
  private static isTransientFailure(status: number, code: number): boolean {
    return status < 0 || status === 408 || status === 425 || status === 429 || status >= 500 || code === -500;
  }

  private static waitBeforeRetry(): Promise<void> {
    return new Promise<void>((resolve: () => void) => setTimeout(resolve, 300));
  }

  private static responseCode(resp: HttpResponse): number {
    if (!resp.ok) return resp.status;
    try {
      return Number(resp.json()['code'] ?? -1);
    } catch (e) {
      return -999;
    }
  }

  private static replyResultDetails(requestId: number, path: string, data: ReplyData, startedAt: number): string {
    const first: number = data.replies.length > 0 ? data.replies[0].rpid : 0;
    const last: number = data.replies.length > 0 ? data.replies[data.replies.length - 1].rpid : 0;
    return 'req=' + String(requestId) + ' path=' + path + ' rows=' + String(data.replies.length) +
      ' first=' + String(first) + ' last=' + String(last) + ' cursorLen=' + String(data.cursor.length) +
      ' hasMore=' + String(data.hasMore) + ' ms=' + String(CommentLog.elapsed(startedAt));
  }

  private static async runAction(event: string, details: string,
    task: () => Promise<ActionResult>): Promise<ActionResult> {
    const requestId: number = CommentLog.nextRequestId();
    const startedAt: number = Date.now();
    CommentLog.info(event + '.start', 'req=' + String(requestId) + ' ' + details);
    try {
      const result: ActionResult = await task();
      const resultDetails: string = 'req=' + String(requestId) + ' ok=' + String(result.ok) +
        ' code=' + String(result.code) + ' ms=' + String(CommentLog.elapsed(startedAt));
      if (result.ok) CommentLog.info(event + '.done', resultDetails);
      else CommentLog.warn(event + '.done', resultDetails);
      return result;
    } catch (e) {
      CommentLog.error(event + '.error', 'req=' + String(requestId) + ' ms=' +
        String(CommentLog.elapsed(startedAt)) + ' error=' + CommentLog.errorText(e as Object));
      throw new Error(CommentLog.errorText(e as Object));
    }
  }

  // ===== 评论（游客模式，WBI 签名 /wbi/main） =====
  static async getReplies(oid: number, type: number, cursor: string, mode: number = 3): Promise<ReplyData> {
    const requestId: number = CommentLog.nextRequestId();
    const startedAt: number = Date.now();
    const loggedIn: boolean = HttpClient.getCookie('SESSDATA').length > 0;
    CommentLog.info('api.replies.start', 'req=' + String(requestId) + ' oid=' + String(oid) +
      ' type=' + String(type) + ' mode=' + String(mode) + ' cursorLen=' + String(cursor.length) +
      ' login=' + String(loggedIn));
    try {
      // 登录态用传统分页端点：它能稳定返回完整主评论总量；游客态继续使用 /main 的 next_offset。
      if (loggedIn) {
        const pageNumber: number = Math.max(1, Number(cursor.length > 0 ? cursor : '1'));
        const legacyParams: Record<string, string> = {
          'oid': String(oid), 'type': String(type), 'pn': String(pageNumber), 'ps': '20',
          'sort': mode === 3 ? '1' : '0',
        };
        const legacyResp: HttpResponse = await webGetWithPriority(Api.replyList, legacyParams,
          'https://www.bilibili.com/', RequestPriority.HIGH);
        const legacyData: Record<string, Object> | null = getData(legacyResp);
        CommentLog.info('api.replies.transport', 'req=' + String(requestId) + ' path=legacy page=' +
          String(pageNumber) + ' status=' + String(legacyResp.status) + ' code=' +
          String(CommentApi.responseCode(legacyResp)) + ' data=' + String(legacyData !== null));
        if (legacyData !== null) {
          const result: ReplyData = ReplyData.fromLegacy(legacyData, pageNumber);
          CommentLog.info('api.replies.done', CommentApi.replyResultDetails(requestId, 'legacy', result, startedAt));
          return result;
        }
        CommentLog.warn('api.replies.fallback', 'req=' + String(requestId) + ' from=legacy to=main');
      }
      const params: Record<string, string> = {
        'oid': String(oid),
        'type': String(type),
        'mode': String(mode),
        'pagination_str': JSON.stringify({ 'offset': cursor }),
      };
      // 对齐当前 PiliPlus：游客/通用评论流使用 /main 与 next_offset，不对该端点追加 WBI 参数。
      const resp: HttpResponse = await webGetWithPriority(Api.replyList + '/main', params,
        'https://www.bilibili.com/', RequestPriority.HIGH);
      let data: Record<string, Object> | null = getData(resp);
      let path: string = 'main';
      let failureStatus: number = resp.status;
      let failureCode: number = CommentApi.responseCode(resp);
      let transientFailure: boolean = CommentApi.isTransientFailure(failureStatus, failureCode);
      CommentLog.info('api.replies.transport', 'req=' + String(requestId) + ' path=main status=' +
        String(resp.status) + ' code=' + String(CommentApi.responseCode(resp)) + ' data=' + String(data !== null));
      if (data === null) {
        // 部分网络会对匿名 /main 返回 -352；回退到签名端点，避免评论区完全不可用。
        const fallback: Record<string, string> = {
          'oid': String(oid), 'type': String(type), 'mode': String(mode),
          'pagination_str': JSON.stringify({ 'offset': cursor }), 'web_location': '1315875',
        };
        await WbiSign.encWbi(fallback);
        const fallbackResp: HttpResponse = await webGetWithPriority(Api.replyList + '/wbi/main', fallback,
          'https://www.bilibili.com/', RequestPriority.HIGH);
        data = getData(fallbackResp);
        path = 'wbi-main';
        failureStatus = fallbackResp.status;
        failureCode = CommentApi.responseCode(fallbackResp);
        transientFailure = transientFailure || CommentApi.isTransientFailure(failureStatus, failureCode);
        CommentLog.warn('api.replies.fallback', 'req=' + String(requestId) + ' from=main to=wbi-main status=' +
          String(fallbackResp.status) + ' code=' + String(CommentApi.responseCode(fallbackResp)) +
          ' data=' + String(data !== null));
      }
      if (data === null && transientFailure) {
        await CommentApi.waitBeforeRetry();
        const retryParams: Record<string, string> = {
          'oid': String(oid), 'type': String(type), 'mode': String(mode),
          'pagination_str': JSON.stringify({ 'offset': cursor }), 'web_location': '1315875',
        };
        await WbiSign.encWbi(retryParams);
        const retryResp: HttpResponse = await webGetWithPriority(Api.replyList + '/wbi/main', retryParams,
          'https://www.bilibili.com/', RequestPriority.HIGH);
        data = getData(retryResp);
        path = 'wbi-main-retry';
        failureStatus = retryResp.status;
        failureCode = CommentApi.responseCode(retryResp);
        CommentLog.warn('api.replies.retry', 'req=' + String(requestId) + ' status=' +
          String(retryResp.status) + ' code=' + String(failureCode) + ' data=' + String(data !== null));
      }
      if (data === null) {
        CommentLog.error('api.replies.empty', 'req=' + String(requestId) + ' path=' + path +
          ' status=' + String(failureStatus) + ' code=' + String(failureCode) +
          ' ms=' + String(CommentLog.elapsed(startedAt)));
        // 所有传输路径都失败不等于“真实零评论”。必须抛错，让页面保留已有数据并
        // 展示重试态；只有 code=0 且 replies=[] 才由下方 ReplyData.from 表示空评论。
        throw new Error('评论接口失败：' + path + ' status=' + String(failureStatus) +
          ' code=' + String(failureCode));
      }
      const result: ReplyData = ReplyData.from(data);
      CommentLog.info('api.replies.done', CommentApi.replyResultDetails(requestId, path, result, startedAt));
      return result;
    } catch (e) {
      CommentLog.error('api.replies.error', 'req=' + String(requestId) + ' ms=' +
        String(CommentLog.elapsed(startedAt)) + ' error=' + CommentLog.errorText(e as Object));
      throw new Error(CommentLog.errorText(e as Object));
    }
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
    return CommentApi.runAction('api.add', 'oid=' + String(oid) + ' type=' + String(type) +
      ' root=' + String(root) + ' parent=' + String(parent) + ' messageLen=' + String(message.length),
      (): Promise<ActionResult> => postVideoAction(Api.replyAdd, params));
  }

  static async likeReply(oid: number, type: number, rpid: number, liked: boolean): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) {
      CommentLog.warn('api.like.invalid', 'oid=' + String(oid) + ' type=' + String(type) + ' rpid=' + String(rpid));
      return new ActionResult(false, '评论参数无效');
    }
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'rpid': String(rpid),
      'action': liked ? '1' : '0',
    };
    return CommentApi.runAction('api.like', 'oid=' + String(oid) + ' type=' + String(type) +
      ' rpid=' + String(rpid) + ' action=' + String(liked),
      (): Promise<ActionResult> => postVideoAction(Api.replyLike, params));
  }

  /** 评论点踩/取消踩：action 1 踩、0 取消。 */
  static async hateReply(oid: number, type: number, rpid: number, hate: boolean): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) {
      CommentLog.warn('api.dislike.invalid', 'oid=' + String(oid) + ' type=' + String(type) + ' rpid=' + String(rpid));
      return new ActionResult(false, '评论参数无效');
    }
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'rpid': String(rpid),
      'action': hate ? '1' : '0',
    };
    return CommentApi.runAction('api.dislike', 'oid=' + String(oid) + ' type=' + String(type) +
      ' rpid=' + String(rpid) + ' action=' + String(hate),
      (): Promise<ActionResult> => postVideoAction(Api.replyHate, params));
  }

  /** 删除自己的评论/回复（type 为评论类型、oid 评论对象、rpid 评论 id，均与服务端一致）。 */
  static async deleteReply(oid: number, type: number, rpid: number): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) {
      CommentLog.warn('api.delete.invalid', 'oid=' + String(oid) + ' type=' + String(type) + ' rpid=' + String(rpid));
      return new ActionResult(false, '评论参数无效');
    }
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'rpid': String(rpid),
    };
    return CommentApi.runAction('api.delete', 'oid=' + String(oid) + ' type=' + String(type) +
      ' rpid=' + String(rpid), (): Promise<ActionResult> => postVideoAction(Api.replyDel, params));
  }

  /** 评论举报（需登录；reason 参考网页端：21 违法违规 22 色情低俗…统一走 21 细分，传入具体 reason）。 */
  static async reportReply(oid: number, type: number, rpid: number, reason: string): Promise<ActionResult> {
    if (oid <= 0 || type <= 0 || rpid <= 0) {
      CommentLog.warn('api.report.invalid', 'oid=' + String(oid) + ' type=' + String(type) + ' rpid=' + String(rpid));
      return new ActionResult(false, '评论参数无效');
    }
    return CommentApi.runAction('api.report', 'oid=' + String(oid) + ' type=' + String(type) +
      ' rpid=' + String(rpid) + ' reason=' + reason, async (): Promise<ActionResult> => {
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
      });
  }

  // ===== 当前账号可用的 B 站表情包（评论/动态共用官方素材 URL） =====
  static async getUserEmotes(business: string = 'reply'): Promise<Array<BiliEmotePackage>> {
    const account: string = HttpClient.getCookie('DedeUserID') || 'guest';
    // 缓存返回已解析并校验过的目录（JSON.parse 只在缓存层做一次）。
    const packages: Array<Object> = await EmotePackageCache.get('packages_' + account + '_' + business,
      () => CommentApi.fetchUserEmotes(business));
    const result: Array<BiliEmotePackage> = [];
    for (const value of packages) {
      const pkg: BiliEmotePackage = BiliEmotePackage.from(value);
      if (pkg.emotes.length > 0) result.push(pkg);
    }
    return result;
  }

  private static async fetchUserEmotes(business: string): Promise<string> {
    const params: Record<string, string> = {
      'business': business,
      'web_location': '333.1245',
    };
    const resp: HttpResponse = await webGetWithPriority(Api.userEmotes, params,
      'https://www.bilibili.com/', RequestPriority.LOW);
    if (!resp.ok) {
      // 诊断日志：区分"网络/HTTP 失败"与"业务 code 失败"，此前失败全静默无法排查。
      CommentLog.warn('api.emotes.http', 'business=' + business + ' status=' + String(resp.status));
      return '';
    }
    const json: Record<string, Object> = resp.json();
    const code: number = Number(json['code'] ?? -1);
    if (code !== 0) {
      CommentLog.warn('api.emotes.biz', 'business=' + business + ' code=' + String(code) +
        ' message=' + String(json['message'] ?? ''));
      return '';
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
    CommentLog.info('api.emotes.done', 'business=' + business + ' packages=' + String(packages.length) +
      ' kept=' + String(result.length) + ' droppedEmpty=' + String(droppedEmpty));
    return result.length > 0 ? JSON.stringify(packages) : '';
  }

  // ===== 单条评论的完整回复列表（楼中楼） =====
  // 楼中楼必须使用 /x/v2/reply/reply 的 root + pn 分页。/reply/main 是主评论流，
  // 它不会按 pagination_str 里的 root 可靠过滤；把它用于这里会在预览的几条真实回复后
  // 继续追加主评论，造成“回复详情重复评论区”的数据串流。
  static async getReplyReplies(oid: number, type: number, root: number, cursor: string): Promise<ReplyData> {
    const requestId: number = CommentLog.nextRequestId();
    const startedAt: number = Date.now();
    const parsedPage: number = Number(cursor.length > 0 ? cursor : '1');
    const pageNumber: number = Number.isFinite(parsedPage) && parsedPage >= 1 ? Math.floor(parsedPage) : 1;
    CommentLog.info('api.thread.start', 'req=' + String(requestId) + ' oid=' + String(oid) +
      ' type=' + String(type) + ' root=' + String(root) + ' page=' + String(pageNumber) +
      ' cursorLen=' + String(cursor.length));
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'root': String(root),
      'pn': String(pageNumber),
      'ps': '20',
    };
    const resp: HttpResponse = await webGet(Api.replyReplyList, params, 'https://www.bilibili.com/');
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      CommentLog.error('api.thread.empty', 'req=' + String(requestId) + ' oid=' + String(oid) +
        ' root=' + String(root) + ' page=' + String(pageNumber) + ' status=' + String(resp.status) +
        ' code=' + String(CommentApi.responseCode(resp)) + ' ms=' + String(CommentLog.elapsed(startedAt)));
      // 保留调用页已有的预览回复与 hasMore；传输失败不能伪装成“回复到底”。
      throw new Error('回复接口失败：status=' + String(resp.status) +
        ' code=' + String(CommentApi.responseCode(resp)));
    }
    const result: ReplyData = ReplyData.fromLegacy(data, pageNumber);
    const valid: Array<ReplyItem> = [];
    for (let i: number = 0; i < result.replies.length; i++) {
      const reply: ReplyItem = result.replies[i];
      // 正常 reply/reply 响应的所有子项 root 都等于当前楼层。兼容少数直接回复仅有
      // parent 的响应；root/parent 都不匹配的一律视为主评论串流并丢弃。
      if (reply.rpid !== root && (reply.rootRpid === root || reply.parentRpid === root)) {
        valid.push(reply);
      }
    }
    if (valid.length !== result.replies.length) {
      CommentLog.warn('api.thread.drop', 'req=' + String(requestId) + ' root=' + String(root) +
        ' total=' + String(result.replies.length) + ' valid=' + String(valid.length));
    }
    result.replies = valid;
    CommentLog.info('api.thread.done', CommentApi.replyResultDetails(requestId, 'reply/reply', result, startedAt) +
      ' root=' + String(root) + ' page=' + String(pageNumber));
    return result;
  }
}
