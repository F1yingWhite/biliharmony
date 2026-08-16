/**
 * 评论域 API：主评论列表 / 发布 / 点赞 / 点踩 / 表情包 / 楼中楼。
 */
import { HttpClient, HttpResponse } from '../common/HttpClient';
import { WbiSign } from '../common/WbiSign';
import { Api, Constants } from '../common/Constants';
import { asArray, asObject } from '../common/Utils';
import { BiliEmotePackage, ReplyData, ReplyPageData } from '../model/Models';
import { ActionResult, getData, postVideoAction } from './internal/ApiCommon';

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
      const legacyResp: HttpResponse = await HttpClient.get(Api.replyList + '?' + HttpClient.buildQuery(legacyParams),
        HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://www.bilibili.com/' }));
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
    const url: string = Api.replyList + '/main?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url,
      HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://www.bilibili.com/' }));
    let data: Record<string, Object> | null = getData(resp);
    if (data === null) {
      // 部分网络会对匿名 /main 返回 -352；回退到签名端点，避免评论区完全不可用。
      const fallback: Record<string, string> = {
        'oid': String(oid), 'type': String(type), 'mode': String(mode),
        'pagination_str': JSON.stringify({ 'offset': cursor }), 'web_location': '1315875',
      };
      await WbiSign.encWbi(fallback);
      const fallbackResp: HttpResponse = await HttpClient.get(Api.replyList + '/wbi/main?' + HttpClient.buildQuery(fallback),
        HttpClient.merge(Constants.webHeaders, { 'Referer': 'https://www.bilibili.com/' }));
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

  // ===== 当前账号可用的 B 站表情包（评论/动态共用官方素材 URL） =====
  static async getUserEmotes(business: string = 'reply'): Promise<Array<BiliEmotePackage>> {
    const params: Record<string, string> = {
      'business': business,
      'web_location': '333.1245',
    };
    const resp: HttpResponse = await HttpClient.get(Api.userEmotes + '?' + HttpClient.buildQuery(params),
      Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return [];
    const packages: Array<Object> = asArray(data['packages']);
    const result: Array<BiliEmotePackage> = [];
    for (let i: number = 0; i < packages.length; i++) {
      const pkg: BiliEmotePackage = BiliEmotePackage.from(packages[i]);
      if (pkg.emotes.length > 0) result.push(pkg);
    }
    return result;
  }

  // ===== 单条评论的完整回复列表 =====
  static async getReplyReplies(oid: number, type: number, root: number, page: number): Promise<ReplyPageData> {
    const params: Record<string, string> = {
      'oid': String(oid),
      'type': String(type),
      'root': String(root),
      'pn': String(page),
      'ps': '20',
    };
    const url: string = Api.replyReplyList + '?' + HttpClient.buildQuery(params);
    const resp: HttpResponse = await HttpClient.get(url, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    return data === null ? new ReplyPageData() : ReplyPageData.from(data);
  }
}
