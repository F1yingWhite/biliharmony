import { FeedApi } from '../../api/FeedApi';
import { LiveApi } from '../../api/LiveApi';
import { UserApi } from '../../api/UserApi';
import { VideoItem } from '../../model/Models';
import { LiveRoomItem } from '../../model/LiveModels';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { LocalVideoFilter } from '../../common/LocalVideoFilter';
import { UserStore } from '../../services/auth/UserStore';
import { AuthSession } from '../../services/auth/AuthSession';
import { freshHomeVideos, HomeExposureWindow } from './HomeFeedItems';

export class HomeFeedChannel {
  count: number = 0;
  settled: boolean = false;
  refreshing: boolean = false;
  loading: boolean = false;
  hasMore: boolean = true;
  error: string = '';
  page: number = 1;
  retryReset: boolean = false;
}

export enum HomeFeedPhase { LOADING, EMPTY, ERROR, CONTENT }

/** Pagination availability is independent from whether an empty request has finished. */
export function homeFeedPhase(channel: HomeFeedChannel): HomeFeedPhase {
  if (channel.count > 0) return HomeFeedPhase.CONTENT;
  if (channel.loading || channel.refreshing) return HomeFeedPhase.LOADING;
  if (channel.error.length > 0) return HomeFeedPhase.ERROR;
  return channel.settled ? HomeFeedPhase.EMPTY : HomeFeedPhase.LOADING;
}

export interface HomeFeedSnapshot {
  channels: Array<HomeFeedChannel>;
  followedLiveRefresh: number;
}

/** Three home domains share lifecycle dispatch, but retain independent cursors and request ownership. */
export class HomeFeedController {
  readonly recommend: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  readonly hot: BasicDataSource<VideoItem> = new BasicDataSource<VideoItem>();
  readonly live: BasicDataSource<LiveRoomItem> = new BasicDataSource<LiveRoomItem>();
  readonly exposure: HomeExposureWindow = new HomeExposureWindow();
  private channels: Array<HomeFeedChannel> = [new HomeFeedChannel(), new HomeFeedChannel(), new HomeFeedChannel()];
  private requests: Array<RequestEpoch> = [new RequestEpoch(), new RequestEpoch(), new RequestEpoch()];
  private lifecycle: number = 0;
  private active: boolean = false;
  private account: number = AuthSession.version;
  private followedLiveRefresh: number = 0;
  private readonly publish: (state: HomeFeedSnapshot) => void;

  constructor(publish: (state: HomeFeedSnapshot) => void) { this.publish = publish; }

  async activate(selectedChannel: number = 0): Promise<void> {
    this.invalidateRequests();
    this.active = true;
    const lifecycle: number = ++this.lifecycle;
    this.account = AuthSession.version;
    this.emit();
    try {
      await UserStore.ensureLoaded();
      if (!this.active || lifecycle !== this.lifecycle) return;
      this.account = AuthSession.version;
      await this.load(selectedChannel, true);
    } catch (_) {
      if (this.active && lifecycle === this.lifecycle) {
        this.channels[selectedChannel].error = '内容加载失败，请检查网络后重试';
        this.channels[selectedChannel].settled = true;
        this.channels[selectedChannel].retryReset = true;
        this.emit();
      }
    }
  }

  dispose(): void {
    this.active = false;
    ++this.lifecycle;
    this.invalidateRequests();
  }

  async accountChanged(selectedChannel: number = 0): Promise<void> {
    this.invalidateRequests();
    this.account = AuthSession.version;
    this.recommend.clear(); this.hot.clear(); this.live.clear();
    this.channels = [new HomeFeedChannel(), new HomeFeedChannel(), new HomeFeedChannel()];
    this.exposure.clear();
    FeedApi.resetRecommendSession();
    if (this.active) await this.activate(selectedChannel);
  }

  async recommendModeChanged(): Promise<void> {
    this.requests[0].invalidate();
    this.recommend.clear();
    this.channels[0] = new HomeFeedChannel();
    this.exposure.clear();
    FeedApi.resetRecommendSession();
    await this.load(0, true);
  }

  async load(channel: number, reset: boolean, retry: boolean = false): Promise<void> {
    if (channel < 0 || channel > 2 || !this.active || this.account !== AuthSession.version) return;
    const state: HomeFeedChannel = this.channels[channel];
    if (!reset && (state.loading || state.refreshing || !state.hasMore || (!retry && state.error.length > 0))) return;
    const request: number = this.requests[channel].next();
    const account: number = this.account;
    state.refreshing = reset;
    state.loading = !reset;
    state.error = '';
    state.retryReset = reset;
    if (channel === 2 && reset) ++this.followedLiveRefresh;
    this.emit();
    try {
      if (channel === 0) await this.loadRecommend(reset, request, account);
      else if (channel === 1) await this.loadHot(reset, request, account);
      else await this.loadLive(reset, request, account);
    } catch (_) {
      if (this.current(channel, request, account)) {
        state.error = channel === 0 ? '推荐加载失败，请检查网络后重试' :
          (channel === 1 ? '热门加载失败，点击重试' : '直播列表加载失败，点击重试');
      }
    } finally {
      if (this.current(channel, request, account)) {
        state.loading = false;
        state.refreshing = false;
        state.settled = true;
        this.emit();
      }
    }
  }

  retry(channel: number): Promise<void> {
    return this.load(channel, this.channels[channel].retryReset, true);
  }

  retryEmpty(channel: number): Promise<void> {
    // Filtered/hidden rows must not trap the user on page one; an exhausted feed starts over.
    return this.load(channel, !this.channels[channel].hasMore, true);
  }

  hide(item: VideoItem, channel: number): boolean {
    if (item.aid <= 0 || channel < 0 || channel > 1) return false;
    const source: BasicDataSource<VideoItem> = channel === 0 ? this.recommend : this.hot;
    for (let i: number = source.totalCount() - 1; i >= 0; i--) {
      if (source.getData(i).aid === item.aid) source.removeAt(i);
    }
    this.channels[channel].count = source.totalCount();
    this.emit();
    LocalVideoFilter.hide(item.aid).catch(() => {});
    return true;
  }

  private async loadRecommend(reset: boolean, request: number, account: number): Promise<void> {
    const state: HomeFeedChannel = this.channels[0];
    state.hasMore = true;
    for (let attempt: number = 0; attempt < 3; attempt++) {
      const rows: Array<VideoItem> = await FeedApi.getRecommend(reset && attempt === 0);
      if (!this.current(0, request, account)) return;
      const fresh: Array<VideoItem> = freshHomeVideos(reset ? [] : this.recommend.getAll(), this.exposure.filter(rows));
      if (fresh.length === 0) continue;
      UserApi.loadFeedFollowStates(fresh).catch(() => {});
      if (reset) this.recommend.reset(fresh);
      else this.recommend.append(fresh);
      state.count = this.recommend.totalCount();
      return;
    }
    state.error = this.recommend.isEmpty() ? '' : '暂时没有新推荐，点击重试';
  }

  private async loadHot(reset: boolean, request: number, account: number): Promise<void> {
    const state: HomeFeedChannel = this.channels[1];
    const page: number = reset ? 1 : state.page;
    const rows: Array<VideoItem> = await FeedApi.getHot(page, 20);
    if (!this.current(1, request, account)) return;
    const fresh: Array<VideoItem> = freshHomeVideos(reset ? [] : this.hot.getAll(), rows);
    if (reset) this.hot.reset(fresh); else this.hot.append(fresh);
    state.count = this.hot.totalCount();
    state.hasMore = rows.length >= 20;
    if (rows.length > 0) state.page = page + 1;
    if (this.hot.isEmpty() && rows.length === 0) {
      state.retryReset = true;
    }
    UserApi.loadFeedFollowStates(fresh).catch(() => {});
  }

  private async loadLive(reset: boolean, request: number, account: number): Promise<void> {
    const state: HomeFeedChannel = this.channels[2];
    const page: number = reset ? 1 : state.page;
    const rows: Array<LiveRoomItem> = await LiveApi.getLiveRooms(page, 20);
    if (!this.current(2, request, account)) return;
    const seen: Set<number> = new Set<number>();
    if (!reset) for (const room of this.live.getAll()) seen.add(room.roomId);
    const fresh: Array<LiveRoomItem> = [];
    for (const room of rows) {
      if (seen.has(room.roomId)) continue;
      seen.add(room.roomId); fresh.push(room);
    }
    if (reset) this.live.reset(fresh); else this.live.append(fresh);
    state.count = this.live.totalCount();
    state.hasMore = rows.length >= 20;
    if (rows.length > 0) state.page = page + 1;
    if (this.live.isEmpty() && rows.length === 0) {
      state.retryReset = true;
    }
  }

  private current(channel: number, request: number, account: number): boolean {
    return this.active && account === AuthSession.version && this.requests[channel].isCurrent(request);
  }

  private invalidateRequests(): void {
    for (let i: number = 0; i < 3; i++) {
      this.requests[i].invalidate();
      this.channels[i].loading = false;
      this.channels[i].refreshing = false;
    }
  }

  private emit(): void {
    if (!this.active) return;
    const channels: Array<HomeFeedChannel> = this.channels.map((state: HomeFeedChannel): HomeFeedChannel => {
      const value: HomeFeedChannel = new HomeFeedChannel();
      value.count = state.count; value.loading = state.loading; value.refreshing = state.refreshing;
      value.settled = state.settled;
      value.hasMore = state.hasMore; value.error = state.error; value.page = state.page; value.retryReset = state.retryReset;
      return value;
    });
    this.publish({ channels: channels, followedLiveRefresh: this.followedLiveRefresh });
  }
}
