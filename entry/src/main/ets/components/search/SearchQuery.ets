import { VIDEO_DURATION_OPTIONS, VIDEO_PUBTIME_OPTIONS } from '../../model/Models';

export enum SearchCategory {
  All = 0, Video = 1, Bangumi = 2, Film = 3, Live = 4, Article = 5, User = 6
}

/** 已提交搜索的选项；输入框草稿由页面单独持有。 */
export class SearchQuery {
  videoOrder: string = 'totalrank';
  userOrder: string = '';
  userType: number = 0;
  liveOrder: string = 'online';
  duration: number = 0;
  pubtime: number = 0;
  tids: number = 0;

  copy(): SearchQuery {
    const out: SearchQuery = new SearchQuery();
    out.videoOrder = this.videoOrder;
    out.userOrder = this.userOrder;
    out.userType = this.userType;
    out.liveOrder = this.liveOrder;
    out.duration = this.duration;
    out.pubtime = this.pubtime;
    out.tids = this.tids;
    return out;
  }

  key(keyword: string, tab: SearchCategory): string {
    let options: string = '';
    if (tab === SearchCategory.All || tab === SearchCategory.Video) {
      options = this.videoOrder + ':' + this.duration + ':' + this.pubtime + ':' + this.tids;
    } else if (tab === SearchCategory.User) {
      options = this.userOrder + ':' + this.userType;
    } else if (tab === SearchCategory.Live) {
      options = this.liveOrder;
    }
    return keyword + '\u0000' + options;
  }

  durationValue(): number {
    return VIDEO_DURATION_OPTIONS[this.duration]?.value ?? 0;
  }

  pubtimeBegin(): number {
    const seconds: number = VIDEO_PUBTIME_OPTIONS[this.pubtime]?.value ?? 0;
    return seconds > 0 ? Math.floor(Date.now() / 1000) - seconds : 0;
  }

  hasVideoFilter(): boolean {
    return this.duration > 0 || this.pubtime > 0 || this.tids > 0;
  }
}
