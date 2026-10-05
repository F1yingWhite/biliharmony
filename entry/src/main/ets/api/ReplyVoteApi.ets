import { Api, Constants } from '../common/Constants';
import { ReplyVoteCard, ReplyVoteOption, ReplyVoteResult, ReplyVoteSource } from '../model/reply/ReplyVoteModels';
import { ApiResult } from '../services/network/ApiResult';
import { AuthSession } from '../services/auth/AuthSession';
import { UserStore } from '../services/auth/UserStore';
import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { ActionResult, actionWithCsrf, parseDataResult, postVideoAction, webGet, webGetSigned } from './internal/ApiCommon';

interface DynamicVotePayload {
  vote_id: number;
  votes: Array<number>;
  voter_uid: number;
  status: number;
  op_bit: number;
  dynamic_id: number;
}

/** Comment polls are separate from playback command votes. Never auto-share a vote. */
export class ReplyVoteApi {
  static async loadHeader(oid: number, type: number): Promise<ReplyVoteCard | null> {
    if (!Number.isSafeInteger(oid) || oid <= 0 || !Number.isSafeInteger(type) || type <= 0) {
      throw new Error('评论投票来源无效');
    }
    const session: number = AuthSession.version;
    const params: Record<string, string> = {
      'oid': String(oid), 'type': String(type), 'mode': '3', 'pagination_str': '{"offset":""}',
    };
    let response: HttpResponse = await webGet(Api.replyList + '/main', params, 'https://www.bilibili.com/');
    ReplyVoteApi.requireSession(session);
    let parsed: ApiResult<Record<string, Object>> = parseDataResult(response);
    if (!parsed.ok) {
      params['web_location'] = '1315875';
      response = await webGetSigned(Api.replyList + '/wbi/main', params, 'https://www.bilibili.com/');
      ReplyVoteApi.requireSession(session);
      parsed = parseDataResult(response);
    }
    if (!parsed.ok || parsed.data === null) throw new Error(parsed.message);
    const raw: Object | undefined = parsed.data['vote_card'];
    if (raw === undefined || raw === null) return null;
    const card: ReplyVoteCard | null = ReplyVoteCard.fromReplyCard(raw);
    if (card === null) throw new Error('评论投票数据异常，请重试');
    return card;
  }

  static async load(card: ReplyVoteCard): Promise<ReplyVoteCard> {
    if (ReplyVoteCard.readId(card.id).length === 0 || (card.kind !== 'dynamic' && card.kind !== 'reply')) {
      throw new Error('投票编号无效');
    }
    if (card.deleted) {
      const deleted: ReplyVoteCard = card.clone();
      deleted.loaded = true;
      return deleted;
    }
    const session: number = AuthSession.version;
    const response: HttpResponse = await webGet(Api.dynamicVoteInfo, { 'vote_id': card.id }, 'https://t.bilibili.com/');
    ReplyVoteApi.requireSession(session);
    const parsed: ApiResult<Record<string, Object>> = parseDataResult(response);
    if (!parsed.ok || parsed.data === null) throw new Error(parsed.message);
    const result: ReplyVoteCard | null = ReplyVoteCard.fromDynamic(parsed.data['vote_info'],
      parsed.data['my_votes'], card.kind);
    if (result === null || result.id !== card.id) throw new Error('投票详情数据异常，请重试');
    return result;
  }

  static async submit(source: ReplyVoteSource, card: ReplyVoteCard,
    selectedIds: Array<number>): Promise<ReplyVoteResult> {
    if (!ReplyVoteApi.validSubmission(source, card, selectedIds)) {
      return new ReplyVoteResult(false, '投票已结束、已参与或选择无效');
    }
    const session: number = AuthSession.version;
    let action: ActionResult;
    if (card.kind === 'reply') {
      action = await postVideoAction(Api.replyVote, {
        'option': String(selectedIds[0]), 'vote_id': card.id, 'oid': String(source.oid), 'type': String(source.type),
      });
    } else {
      // The H5 protocol encodes vote_id and voter_uid as JSON numbers. Reject IDs
      // outside JS's exact integer range rather than voting on a rounded identifier.
      const voteId: number = Number(card.id);
      const voter: number = ReplyVoteApi.voterMid();
      if (!Number.isSafeInteger(voteId) || voteId <= 0 || voter === 0) {
        return new ReplyVoteResult(false, '投票编号或登录信息无效，请重新登录');
      }
      action = await actionWithCsrf('登录状态缺少 CSRF，请重新登录', '投票成功', '投票失败',
        (csrf: string): Promise<HttpResponse> => {
          const payload: DynamicVotePayload = {
            vote_id: voteId, votes: selectedIds.slice(), voter_uid: voter,
            status: 0, op_bit: 0, dynamic_id: 0,
          };
          return HttpClient.post(Api.dynamicVoteSubmit + '?csrf=' + encodeURIComponent(csrf), JSON.stringify(payload),
            HttpClient.merge(Constants.webHeaders, { 'Content-Type': 'application/json' }));
        });
    }
    if (session !== AuthSession.version) return new ReplyVoteResult(false, '账号已切换，请重新加载投票');
    if (!action.ok) return new ReplyVoteResult(false, action.message, action.code);
    const returned: ReplyVoteCard | null = ReplyVoteCard.fromDynamic(action.data['vote_info'],
      undefined, card.kind);
    if (returned !== null && returned.id === card.id && returned.selectedIds.length > 0) {
      return new ReplyVoteResult(true, '投票成功', action.code, returned);
    }
    // reply/vote/do may return no detail; the H5 client also reloads when do_vote
    // omits vote_info. A failed result reload must not turn a confirmed POST into a retry.
    try {
      const loaded: ReplyVoteCard = await ReplyVoteApi.load(card);
      if (session !== AuthSession.version) return new ReplyVoteResult(false, '账号已切换，请重新加载投票');
      return new ReplyVoteResult(true, '投票成功', action.code, loaded);
    } catch (e) {
      if (session !== AuthSession.version) return new ReplyVoteResult(false, '账号已切换，请重新加载投票');
      return new ReplyVoteResult(true, '投票成功，结果暂未刷新，请重试查看', action.code);
    }
  }

  private static validSubmission(source: ReplyVoteSource, card: ReplyVoteCard, selectedIds: Array<number>): boolean {
    if (!Number.isSafeInteger(source.oid) || source.oid <= 0 || !Number.isSafeInteger(source.type) || source.type <= 0 ||
      !Number.isSafeInteger(source.rpid) || source.rpid < 0 || ReplyVoteCard.readId(card.id).length === 0 ||
      (card.kind !== 'reply' && card.kind !== 'dynamic') || !card.loaded || card.deleted || card.ended ||
      card.endTime <= 0 || card.endTime * 1000 <= Date.now() || card.selectedIds.length > 0 ||
      !Number.isSafeInteger(card.maxSelect) || card.maxSelect <= 0 || selectedIds.length === 0 ||
      selectedIds.length > card.maxSelect || (card.kind === 'reply' && selectedIds.length !== 1)) return false;
    const voter: number = ReplyVoteApi.voterMid();
    if (voter > 0 && voter === card.publisherMid) return false;
    const unique: Set<number> = new Set<number>();
    for (const id of selectedIds) {
      if (!Number.isSafeInteger(id) || id <= 0 || unique.has(id) ||
        !card.options.some((option: ReplyVoteOption): boolean => option.id === id)) return false;
      unique.add(id);
    }
    return true;
  }

  private static voterMid(): number {
    const mid: number = UserStore.current === null ? 0 : UserStore.current.mid;
    if (Number.isSafeInteger(mid) && mid > 0) return mid;
    const cookieMid: number = Number(HttpClient.getCookie('DedeUserID'));
    return Number.isSafeInteger(cookieMid) && cookieMid > 0 ? cookieMid : 0;
  }

  private static requireSession(session: number): void {
    if (session !== AuthSession.version) throw new Error('账号已切换，请重新加载投票');
  }
}
