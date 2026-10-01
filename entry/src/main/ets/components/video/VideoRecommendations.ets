import { BiliApi } from '../../api/BiliApi';
import { FeedApi } from '../../api/FeedApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { LocalVideoFilter } from '../../common/LocalVideoFilter';
import { RequestEpoch } from '../../common/RequestEpoch';
import { UgcSeasonEpisode, VideoDetail, VideoItem } from '../../model/Models';

export class RelatedVideoStatus {
  loading: boolean = false;
  error: string = '';
  count: number = 0;
}

/** 相关推荐与合集共享的候选模型；独立维护去重、分页及结束画面的排列规则。 */
export class VideoRecommendations {
  readonly related: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  readonly episodes: BasicDataSource<UgcSeasonEpisode> = new BasicDataSource<UgcSeasonEpisode>();
  private epoch: RequestEpoch = new RequestEpoch();
  private loading: boolean = false;
  private error: string = '';
  private readonly isDestroyed: () => boolean;
  private readonly getDetail: () => VideoDetail;
  private readonly publish: (status: RelatedVideoStatus) => void;

  constructor(isDestroyed: () => boolean, getDetail: () => VideoDetail,
    publish: (status: RelatedVideoStatus) => void) {
    this.isDestroyed = isDestroyed;
    this.getDetail = getDetail;
    this.publish = publish;
  }

  reset(): void {
    this.epoch.invalidate();
    this.loading = false;
    this.related.clear();
    this.publishStatus('');
  }

  dispose(): void {
    this.epoch.invalidate();
    this.loading = false;
  }

  /** 当前页面隐藏候选，只通知被删除的行，保留分页的加载与错误状态。 */
  hide(item: VideoItem): void {
    for (let i: number = this.related.totalCount() - 1; i >= 0; i--) {
      const candidate: VideoItem = this.related.getData(i);
      if ((item.aid > 0 && candidate.aid === item.aid) ||
        (item.bvid.length > 0 && candidate.bvid === item.bvid)) this.related.removeAt(i);
    }
    this.publishStatus(this.error);
  }

  setEpisodes(detail: VideoDetail): void {
    const list: Array<UgcSeasonEpisode> = [];
    const season = detail.ugcSeason;
    if (season !== null) {
      for (let i: number = 0; i < season.sections.length; i++) {
        const section = season.sections[i];
        for (let j: number = 0; j < section.episodes.length; j++) {
          const episode: UgcSeasonEpisode = section.episodes[j];
          episode.sectionTitle = section.title;
          list.push(episode);
        }
      }
    }
    this.episodes.reset(list);
  }

  currentEpisodeIndex(detail: VideoDetail, cid: number): number {
    const list: Array<UgcSeasonEpisode> = this.episodes.getAll();
    for (let i: number = 0; i < list.length; i++) {
      const episode: UgcSeasonEpisode = list[i];
      if (episode.cid === cid && episode.bvid === detail.bvid) return i;
      if (episode.cid === cid && episode.aid === detail.aid && episode.bvid.length === 0) return i;
    }
    return -1;
  }

  nextEpisode(detail: VideoDetail, cid: number): UgcSeasonEpisode | null {
    if (detail.ugcSeason === null || this.episodes.isEmpty()) return null;
    const index: number = this.currentEpisodeIndex(detail, cid);
    return index >= 0 && index + 1 < this.episodes.totalCount() ? this.episodes.getData(index + 1) : null;
  }

  /** 优先合集下一集，再补相关视频；aid/bvid 任一重复即跳过，最多 8 条。 */
  endList(detail: VideoDetail, cid: number): Array<VideoItem> {
    const list: Array<VideoItem> = [];
    const next: UgcSeasonEpisode | null = this.nextEpisode(detail, cid);
    if (next !== null) {
      const item: VideoItem = new VideoItem();
      item.aid = next.aid;
      item.bvid = next.bvid;
      item.cid = next.cid;
      item.title = next.title;
      item.cover = next.cover;
      item.upName = detail.upName;
      list.push(item);
    }
    const pool: Array<VideoItem> = this.related.getAll();
    for (let i: number = 0; i < pool.length && list.length < 8; i++) {
      const item: VideoItem = pool[i];
      if (item.aid <= 0 && item.bvid.length === 0) continue;
      if (list.some((existing: VideoItem) => (item.aid > 0 && existing.aid === item.aid) ||
        (item.bvid.length > 0 && existing.bvid === item.bvid))) continue;
      list.push(item);
    }
    return list;
  }

  async loadInitial(aid: number, bvid: string): Promise<void> {
    if (this.loading) return;
    const request: number = this.beginLoad();
    let error: string = '';
    try {
      const list: Array<VideoItem> = await BiliApi.getRelated(aid, bvid);
      if (!this.isCurrent(request)) return;
      this.appendUnique(list);
      if (this.related.isEmpty()) error = '相关推荐加载失败，点击刷新';
    } catch (e) {
      error = '相关推荐加载失败，点击刷新';
    } finally {
      this.finishLoad(request, error);
    }
  }

  async loadMore(): Promise<void> {
    if (this.loading) return;
    const request: number = this.beginLoad();
    let error: string = '';
    try {
      // FeedApi 管理推荐会话游标，与首页共享去重信号。
      const list: Array<VideoItem> = await FeedApi.getRecommend(false);
      if (!this.isCurrent(request)) return;
      if (list.length === 0) error = '暂时没有刷新到新推荐，点击重试';
      else if (this.appendUnique(list) === 0) error = '这批推荐已看过，点击继续刷新';
    } catch (e) {
      error = '刷新推荐失败，点击重试';
    } finally {
      this.finishLoad(request, error);
    }
  }

  private appendUnique(incoming: Array<VideoItem>): number {
    const detail: VideoDetail = this.getDetail();
    const current: Array<VideoItem> = this.related.getAll();
    const seenAid: Set<number> = new Set<number>();
    const seenBvid: Set<string> = new Set<string>();
    if (detail.aid > 0) seenAid.add(detail.aid);
    if (detail.bvid.length > 0) seenBvid.add(detail.bvid);
    for (let i: number = 0; i < current.length; i++) {
      if (current[i].aid > 0) seenAid.add(current[i].aid);
      if (current[i].bvid.length > 0) seenBvid.add(current[i].bvid);
    }
    const appended: Array<VideoItem> = [];
    for (let i: number = 0; i < incoming.length; i++) {
      const item: VideoItem = incoming[i];
      if (item.aid <= 0 && item.bvid.length === 0) continue;
      if ((item.aid > 0 && seenAid.has(item.aid)) ||
        (item.bvid.length > 0 && seenBvid.has(item.bvid))) continue;
      if (item.aid > 0) seenAid.add(item.aid);
      if (item.bvid.length > 0) seenBvid.add(item.bvid);
      if (LocalVideoFilter.contains(item.aid)) continue;
      appended.push(item);
    }
    this.related.append(appended);
    return appended.length;
  }

  private beginLoad(): number {
    const request: number = this.epoch.next();
    this.loading = true;
    this.publishStatus('');
    return request;
  }

  private isCurrent(request: number): boolean {
    return !this.isDestroyed() && this.epoch.isCurrent(request);
  }

  private finishLoad(request: number, error: string): void {
    if (!this.isCurrent(request)) return;
    this.loading = false;
    this.publishStatus(error);
  }

  private publishStatus(error: string): void {
    this.error = error;
    const status: RelatedVideoStatus = new RelatedVideoStatus();
    status.loading = this.loading;
    status.error = error;
    status.count = this.related.totalCount();
    this.publish(status);
  }
}
