import { Api, Constants } from '../common/Constants';
import { decodeVideoInteractionView } from '../common/VideoInteractionProto';
import { SendableVideoCommand } from '../common/VideoInteractionProtoCore';
import { VideoInteractionCard, VideoInteractionOption, VideoInteractionSource } from '../model/video/VideoInteractionModels';
import { AuthSession } from '../services/auth/AuthSession';
import { HttpClient } from '../services/network/HttpClient';
import { ActionResult, postVideoAction } from './internal/ApiCommon';

/** UP-created command cards; protocols match the official web player, independent of ordinary comments. */
export class VideoInteractionApi {
  static async load(source: VideoInteractionSource): Promise<Array<VideoInteractionCard>> {
    if (!VideoInteractionApi.validSource(source)) return [];
    const session: number = AuthSession.version;
    const duration: number = Number.isFinite(source.duration) ? Math.max(0, Math.floor(source.duration)) : 0;
    const query: string = HttpClient.buildQuery({
      'type': '1', 'oid': String(source.cid), 'pid': String(source.aid),
      'duration': String(duration), 'without_subtitle': 'true',
    });
    const buffer: ArrayBuffer | null = await HttpClient.getBinary(Api.danmakuView + '?' + query, Constants.webHeaders);
    if (session !== AuthSession.version) return [];
    if (buffer === null) throw new Error('互动弹幕加载失败，请重试');
    let commands: Array<SendableVideoCommand>;
    try {
      commands = await decodeVideoInteractionView(buffer);
    } catch (e) {
      if (session !== AuthSession.version) return [];
      throw new Error('互动弹幕响应异常，请重试');
    }
    if (session !== AuthSession.version) return [];
    const cards: Array<VideoInteractionCard> = [];
    for (const command of commands) {
      const card: VideoInteractionCard | null = VideoInteractionCard.from(command);
      if (card !== null && !cards.some((item: VideoInteractionCard): boolean => item.id === card.id)) cards.push(card);
    }
    cards.sort((a: VideoInteractionCard, b: VideoInteractionCard): number => a.start - b.start);
    return cards;
  }

  static async submitGrade(source: VideoInteractionSource, card: VideoInteractionCard,
    stars: number, seconds: number): Promise<ActionResult> {
    if (!VideoInteractionApi.validSource(source) || card.kind !== 'grade' ||
      !/^[1-9][0-9]*$/.test(card.gradeId) || !Number.isInteger(stars) || stars < 1 || stars > 5 ||
      card.selectedStars > 0) return new ActionResult(false, '评分参数无效或已评分');
    // Five visible stars are encoded as 2, 4, 6, 8, 10 by the official player.
    const params: Record<string, string> = {
      'aid': String(source.aid), 'cid': String(source.cid),
      'progress': String(VideoInteractionApi.progress(card, seconds)),
      'grade_id': card.gradeId, 'grade_score': String(stars * 2),
      'polaris_app_id': '100', 'polaris_platform': '5',
    };
    return postVideoAction(Api.commandGrade, params);
  }

  static async submitVote(source: VideoInteractionSource, card: VideoInteractionCard,
    optionId: number, seconds: number): Promise<ActionResult> {
    const option: VideoInteractionOption | undefined = card.options.find(
      (item: VideoInteractionOption): boolean => item.id === optionId);
    if (!VideoInteractionApi.validSource(source) || card.kind !== 'vote' ||
      !/^[1-9][0-9]*$/.test(card.voteId) || !/^[1-9][0-9]*$/.test(card.id) ||
      !Number.isSafeInteger(optionId) || optionId <= 0 || option === undefined || option.hasSelfDef ||
      card.selectedOptionId > 0) return new ActionResult(false, '投票参数无效或已投票');
    const params: Record<string, string> = {
      'aid': String(source.aid), 'cid': String(source.cid),
      'progress': String(Math.round(Math.max(0, Number.isFinite(seconds) ? seconds : card.start) * 1000)),
      'vote_id': card.voteId, 'vote_type': String(card.voteType), 'cmd_id_str': card.id,
      'option_id': String(option.id), 'has_self_def': '0',
      'polaris_app_id': '100', 'polaris_platform': '5',
    };
    return postVideoAction(Api.commandVote, params);
  }

  private static validSource(source: VideoInteractionSource): boolean {
    return Number.isSafeInteger(source.aid) && source.aid > 0 && Number.isSafeInteger(source.cid) && source.cid > 0;
  }

  private static progress(card: VideoInteractionCard, seconds: number): number {
    // Official rating rounds to whole playback seconds and keeps progress before the card's endpoint.
    const time: number = Number.isFinite(seconds) ? seconds : card.start;
    return Math.max(0, Math.floor(Math.min(1000 * Math.max(Math.round(time), 1), card.end * 1000 - 100)));
  }
}
