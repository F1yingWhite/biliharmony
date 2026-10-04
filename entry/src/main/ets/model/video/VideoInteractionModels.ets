import { asNumber, asString } from '../../common/Utils';

export interface VideoInteractionSource {
  aid: number;
  bvid: string;
  cid: number;
  duration: number;
}

/** DmWebViewReply.command_dms; int64 IDs stay decimal strings. */
export interface VideoInteractionCommand {
  id: string;
  oid: string;
  mid: string;
  command: string;
  content: string;
  progress: number;
  extra: string;
}

export class VideoInteractionOption {
  id: number = 0;
  text: string = '';
  votes: number = 0;
  hasSelfDef: boolean = false;
}

export class VideoInteractionLink {
  aid: number = 0;
  bvid: string = '';
  epId: number = 0;
  title: string = '';
  cover: string = '';
}

/** Official command cards use playback seconds; grade scores use five visible stars. */
export class VideoInteractionCard {
  id: string = '';
  kind: string = '';
  start: number = 0;
  end: number = 0;
  title: string = '';
  gradeId: string = '';
  maxStars: number = 5;
  selectedStars: number = 0;
  averageScore: number = 0;
  count: number = 0;
  voteId: string = '';
  voteType: number = 0;
  selectedOptionId: number = 0;
  options: Array<VideoInteractionOption> = [];
  link: VideoInteractionLink | null = null;

  clone(): VideoInteractionCard {
    const copy: VideoInteractionCard = new VideoInteractionCard();
    copy.id = this.id;
    copy.kind = this.kind;
    copy.start = this.start;
    copy.end = this.end;
    copy.title = this.title;
    copy.gradeId = this.gradeId;
    copy.maxStars = this.maxStars;
    copy.selectedStars = this.selectedStars;
    copy.averageScore = this.averageScore;
    copy.count = this.count;
    copy.voteId = this.voteId;
    copy.voteType = this.voteType;
    copy.selectedOptionId = this.selectedOptionId;
    copy.options = this.options.map((value: VideoInteractionOption): VideoInteractionOption => {
      const option: VideoInteractionOption = new VideoInteractionOption();
      option.id = value.id;
      option.text = value.text;
      option.votes = value.votes;
      option.hasSelfDef = value.hasSelfDef;
      return option;
    });
    if (this.link !== null) {
      copy.link = new VideoInteractionLink();
      copy.link.aid = this.link.aid;
      copy.link.bvid = this.link.bvid;
      copy.link.epId = this.link.epId;
      copy.link.title = this.link.title;
      copy.link.cover = this.link.cover;
    }
    return copy;
  }

  static from(command: VideoInteractionCommand): VideoInteractionCard | null {
    if (!Number.isFinite(command.progress) || command.progress < 0 || command.progress > 2147483647 ||
      !/^[1-9][0-9]*$/.test(command.id)) return null;
    if (command.command !== '#GRADE#' && command.command !== '#VOTE#' && command.command !== '#LINK#') return null;
    let extra: Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(command.extra);
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
      extra = parsed as Record<string, Object>;
    } catch (e) {
      return null;
    }
    const card: VideoInteractionCard = new VideoInteractionCard();
    card.id = command.id;
    card.start = command.progress / 1000;
    const durationMs: number = asNumber(extra['duration'], 0);
    const duration: number = Number.isFinite(durationMs) && durationMs > 0 ? durationMs / 1000 :
      (command.command === '#VOTE#' ? 10 : 5);
    card.end = card.start + duration;
    card.title = command.content;
    if (command.command === '#GRADE#') {
      card.kind = 'grade';
      card.gradeId = asString(extra['grade_id']);
      if (!/^[1-9][0-9]*$/.test(card.gradeId)) return null;
      card.title = asString(extra['msg'], command.content);
      const score: number = asNumber(extra['mid_score'], 0);
      card.selectedStars = Number.isFinite(score) && score > 0 && score <= 10 ? score / 2 : 0;
      card.averageScore = VideoInteractionCard.nonnegative(extra['avg_score']);
      card.count = VideoInteractionCard.nonnegative(extra['count']);
    } else if (command.command === '#VOTE#') {
      card.kind = 'vote';
      card.voteId = asString(extra['vote_id']);
      if (!/^[1-9][0-9]*$/.test(card.voteId) || !Array.isArray(extra['options'])) return null;
      card.title = asString(extra['question'], command.content);
      const type: number = asNumber(extra['vote_type'], 0);
      card.voteType = Number.isInteger(type) && type >= 0 ? type : 0;
      const entries: Array<Object> = extra['options'] as Array<Object>;
      for (const entry of entries) {
        if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) continue;
        const value: Record<string, Object> = entry as Record<string, Object>;
        const id: number = asNumber(value['idx'], 0);
        const text: string = asString(value['desc']);
        if (!Number.isSafeInteger(id) || id <= 0 || text.trim().length === 0 ||
          card.options.some((option: VideoInteractionOption): boolean => option.id === id)) continue;
        const option: VideoInteractionOption = new VideoInteractionOption();
        option.id = id;
        option.text = text;
        option.votes = VideoInteractionCard.nonnegative(value['cnt']);
        option.hasSelfDef = value['has_self_def'] === true || asNumber(value['has_self_def'], 0) === 1;
        card.options.push(option);
      }
      if (card.options.length === 0) return null;
      const selected: number = asNumber(extra['my_vote'], 0);
      card.selectedOptionId = card.options.some((option: VideoInteractionOption): boolean => option.id === selected) ? selected : 0;
    } else {
      card.kind = 'link';
      // The official player routes arc_type=2 to paid classroom, which this app cannot play.
      if (asNumber(extra['arc_type'], 0) === 2) return null;
      const link: VideoInteractionLink = new VideoInteractionLink();
      const aid: number = asNumber(extra['aid'], 0);
      link.aid = Number.isSafeInteger(aid) && aid > 0 ? aid : 0;
      const bvid: string = asString(extra['bvid']);
      link.bvid = /^BV[0-9A-Za-z]+$/.test(bvid) ? bvid : '';
      const episode: string = asString(extra['epid']).replace(/^ep/, '');
      const epId: number = Number(episode);
      link.epId = Number.isSafeInteger(epId) && epId > 0 ? epId : 0;
      if (link.aid <= 0 && link.bvid.length === 0 && link.epId <= 0) return null;
      link.title = card.title;
      link.cover = asString(extra['arc_pic']).replace(/^http:/, 'https:').replace(/^\/\//, 'https://');
      card.link = link;
    }
    return card;
  }

  private static nonnegative(value: Object | undefined): number {
    const number: number = asNumber(value, 0);
    return Number.isFinite(number) && number >= 0 ? number : 0;
  }
}
