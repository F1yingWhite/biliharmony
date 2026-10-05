import { asBool, asObject, str, toHttps } from '../../common/Utils';

/** Comments carry either a dynamic vote reference or the comment section's vote_card. */
export class ReplyVoteSource {
  oid: number = 0;
  type: number = 1;
  rpid: number = 0;
  sourceKey: string = '';
}

export class ReplyVoteOption {
  id: number = 0;
  text: string = '';
  count: number = 0;
  imageUrl: string = '';

  clone(): ReplyVoteOption {
    const result: ReplyVoteOption = new ReplyVoteOption();
    result.id = this.id;
    result.text = this.text;
    result.count = this.count;
    result.imageUrl = this.imageUrl;
    return result;
  }
}

export class ReplyVoteCard {
  kind: string = 'dynamic';
  id: string = '';
  title: string = '';
  count: number = 0;
  options: Array<ReplyVoteOption> = [];
  selectedIds: Array<number> = [];
  maxSelect: number = 0;
  endTime: number = 0;
  ended: boolean = false;
  deleted: boolean = false;
  loaded: boolean = false;
  publisherMid: number = 0;

  clone(): ReplyVoteCard {
    const result: ReplyVoteCard = new ReplyVoteCard();
    result.kind = this.kind;
    result.id = this.id;
    result.title = this.title;
    result.count = this.count;
    result.options = this.options.map((option: ReplyVoteOption): ReplyVoteOption => option.clone());
    result.selectedIds = this.selectedIds.slice();
    result.maxSelect = this.maxSelect;
    result.endTime = this.endTime;
    result.ended = this.ended;
    result.deleted = this.deleted;
    result.loaded = this.loaded;
    result.publisherMid = this.publisherMid;
    return result;
  }

  /** Keep decimal identifiers exact; never accept an already rounded JSON number. */
  static readId(value: Object | undefined | null): string {
    if (typeof value === 'number') return Number.isSafeInteger(value) && value > 0 ? String(value) : '';
    if (typeof value === 'string' && /^[1-9][0-9]{0,19}$/.test(value)) return value;
    return '';
  }

  static fromContent(value: Object | undefined | null): ReplyVoteCard | null {
    if (!ReplyVoteCard.isObject(value)) return null;
    const data: Record<string, Object> = asObject(value);
    const id: string = ReplyVoteCard.readId(data['id']);
    if (id.length === 0) return null;
    const result: ReplyVoteCard = new ReplyVoteCard();
    result.id = id;
    result.title = str(data, 'title');
    result.count = ReplyVoteCard.countValue(data['cnt']);
    result.deleted = asBool(data['deleted'], false);
    return result;
  }

  static fromReplyCard(value: Object | undefined | null): ReplyVoteCard | null {
    if (!ReplyVoteCard.isObject(value)) return null;
    const data: Record<string, Object> = asObject(value);
    const id: string = ReplyVoteCard.readId(data['vote_id']);
    if (id.length === 0 || !Array.isArray(data['options'])) return null;
    const result: ReplyVoteCard = new ReplyVoteCard();
    result.id = id;
    result.title = str(data, 'title');
    result.count = ReplyVoteCard.countValue(data['count']);
    result.options = ReplyVoteCard.parseOptions(data['options'] as Array<Object>, false);
    if (result.options.length < 2) return null;
    // The official comments component posts only its two-choice duel inline. Other
    // cards open the dynamic-vote page, whose choice_cnt can permit multiple answers.
    result.kind = result.options.length === 2 ? 'reply' : 'dynamic';
    result.maxSelect = result.kind === 'reply' ? 1 : 0;
    const selected: number = ReplyVoteCard.positiveInteger(data['my_vote_option']);
    if (result.options.some((option: ReplyVoteOption): boolean => option.id === selected)) {
      result.selectedIds = [selected];
    }
    return result;
  }

  static fromDynamic(value: Object | undefined | null, selected: Object | undefined,
    kind: string = 'dynamic'): ReplyVoteCard | null {
    if (!ReplyVoteCard.isObject(value)) return null;
    const data: Record<string, Object> = asObject(value);
    const result: ReplyVoteCard = new ReplyVoteCard();
    result.id = ReplyVoteCard.readId(data['vote_id']);
    result.title = str(data, 'title');
    if (result.id.length === 0 || !Array.isArray(data['options'])) return null;
    result.options = ReplyVoteCard.parseOptions(data['options'] as Array<Object>, true);
    const choices: number = ReplyVoteCard.positiveInteger(data['choice_cnt']);
    const endTime: number = ReplyVoteCard.positiveInteger(data['end_time']);
    if (result.options.length < 2 || choices === 0 || choices > result.options.length || endTime === 0) return null;
    result.kind = kind === 'reply' ? 'reply' : 'dynamic';
    result.maxSelect = result.kind === 'reply' ? 1 : choices;
    result.count = ReplyVoteCard.countValue(data['join_num']);
    result.endTime = endTime;
    result.ended = endTime * 1000 <= Date.now();
    result.publisherMid = ReplyVoteCard.positiveInteger(data['vote_publisher']);
    result.loaded = true;
    const ids: Object | undefined = selected === undefined ? data['my_votes'] : selected;
    if (ids !== undefined && ids !== null && !Array.isArray(ids)) return null;
    if (Array.isArray(ids)) {
      for (const raw of ids as Array<Object>) {
        const id: number = ReplyVoteCard.positiveInteger(raw);
        if (result.options.some((option: ReplyVoteOption): boolean => option.id === id) &&
          !result.selectedIds.includes(id)) result.selectedIds.push(id);
      }
    }
    return result;
  }

  private static parseOptions(rawOptions: Array<Object>, dynamic: boolean): Array<ReplyVoteOption> {
    const options: Array<ReplyVoteOption> = [];
    for (const raw of rawOptions) {
      if (!ReplyVoteCard.isObject(raw)) continue;
      const data: Record<string, Object> = asObject(raw);
      const id: number = ReplyVoteCard.positiveInteger(data[dynamic ? 'opt_idx' : 'idx']);
      const text: string = str(data, dynamic ? 'opt_desc' : 'desc');
      if (id === 0 || text.length === 0 || options.some((option: ReplyVoteOption): boolean => option.id === id)) continue;
      const option: ReplyVoteOption = new ReplyVoteOption();
      option.id = id;
      option.text = text;
      option.count = ReplyVoteCard.countValue(data[dynamic ? 'cnt' : 'count']);
      option.imageUrl = toHttps(str(data, 'img_url'));
      options.push(option);
    }
    return options;
  }

  private static positiveInteger(value: Object | undefined): number {
    if (typeof value !== 'number' && typeof value !== 'string') return 0;
    const number: number = Number(value);
    return Number.isSafeInteger(number) && number > 0 ? number : 0;
  }

  private static countValue(value: Object | undefined): number {
    if (typeof value !== 'number' && typeof value !== 'string') return 0;
    const number: number = Number(value);
    return Number.isSafeInteger(number) && number >= 0 ? number : 0;
  }

  private static isObject(value: Object | undefined | null): boolean {
    return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value);
  }
}

export class ReplyVoteResult {
  ok: boolean;
  message: string;
  code: number;
  card: ReplyVoteCard | null;

  constructor(ok: boolean, message: string, code: number = 0, card: ReplyVoteCard | null = null) {
    this.ok = ok;
    this.message = message;
    this.code = code;
    this.card = card;
  }
}
