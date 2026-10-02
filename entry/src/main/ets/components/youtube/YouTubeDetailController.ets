import { YouTubeApi, YouTubeComment, YouTubeCommentPage, YouTubeVideo, YouTubeWatchPage } from '../../api/YouTubeApi';
import { BasicDataSource } from '../../common/BasicDataSource';
import { RequestEpoch } from '../../common/RequestEpoch';
import { YouTubeHistoryStore } from '../../common/YouTubeHistoryStore';
import { YouTubeThumbnailCache } from './YouTubeThumbnailCache';

export class YouTubeDetailState {
  video: YouTubeVideo = new YouTubeVideo();
  related: Array<YouTubeVideo> = [];
  detailLoading: boolean = true;
  detailError: string = '';
  coverUri: string = '';
  imageLocal: Map<string, string> = new Map<string, string>();
  commentToken: string = '';
  commentTotal: string = '';
  commentsCount: number = 0;
  commentsLoading: boolean = false;
  commentsLoaded: boolean = false;
  commentsError: string = '';
  commentsMoreLoading: boolean = false;
  commentMoreError: string = '';
}

/** Public watch metadata and comment pagination; the page alone owns its Web controller. */
export class YouTubeDetailController {
  readonly comments: BasicDataSource<YouTubeComment> = new BasicDataSource<YouTubeComment>();
  readonly images: YouTubeThumbnailCache = new YouTubeThumbnailCache((url: string): void => {
    if (url === this.state.video.thumbnail) this.state.coverUri = this.images.resolve(url);
    this.emit();
  });
  private state: YouTubeDetailState = new YouTubeDetailState();
  private request: RequestEpoch = new RequestEpoch();
  private commentRequest: RequestEpoch = new RequestEpoch();
  private active: boolean = false;
  private commentsRequested: boolean = false;
  private initialCommentToken: string = '';
  private readonly publish: (state: YouTubeDetailState) => void;

  constructor(publish: (state: YouTubeDetailState) => void) { this.publish = publish; }

  activate(video: YouTubeVideo): void {
    this.dispose();
    this.active = true;
    this.state = new YouTubeDetailState();
    this.state.video = video;
    this.commentsRequested = false;
    this.initialCommentToken = '';
    this.comments.clear();
    this.images.prime([video.thumbnail]);
    this.emit();
  }

  dispose(): void {
    this.active = false;
    this.request.invalidate();
    this.commentRequest.invalidate();
    this.images.reset();
  }

  async load(): Promise<void> {
    if (!this.active) return;
    const request: number = this.request.next();
    const id: string = this.state.video.id;
    this.state.detailLoading = true;
    this.state.detailError = '';
    this.commentRequest.invalidate();
    this.state.commentsLoading = false;
    this.state.commentsMoreLoading = false;
    this.emit();
    try {
      const page: YouTubeWatchPage = await YouTubeApi.detailPage(id);
      if (!this.current(request)) return;
      this.state.video = page.video;
      this.state.related = page.related;
      this.state.commentToken = page.commentToken;
      this.initialCommentToken = page.commentToken;
      this.comments.clear();
      this.state.commentsLoaded = false;
      this.state.commentsCount = 0;
      this.state.commentsError = '';
      this.state.commentMoreError = '';
      this.state.commentTotal = '';
      const urls: Array<string> = page.related.map((item: YouTubeVideo): string => item.thumbnail);
      urls.push(page.video.thumbnail, page.video.channelAvatar);
      this.images.prime(urls);
    } catch (error) {
      if (this.current(request)) this.state.detailError = (error as Error).message || '详情加载失败';
    } finally {
      if (this.current(request)) {
        this.state.detailLoading = false;
        YouTubeHistoryStore.record(this.state.video);
        this.emit();
        if (this.commentsRequested && this.state.detailError.length === 0) this.ensureComments();
      }
    }
  }

  ensureComments(): void {
    this.commentsRequested = true;
    if (!this.active || this.state.detailLoading || this.state.commentsLoaded || this.state.commentsLoading) return;
    this.loadComments();
  }

  async loadComments(): Promise<void> {
    if (!this.active || this.state.detailLoading) return;
    this.commentRequest.invalidate();
    this.comments.clear();
    this.state.commentsCount = 0;
    this.state.commentsLoaded = false;
    this.state.commentsError = '';
    this.state.commentMoreError = '';
    this.state.commentsMoreLoading = false;
    this.state.commentToken = this.initialCommentToken;
    if (this.initialCommentToken.length === 0) {
      this.state.commentsLoaded = true;
      this.state.commentsLoading = false;
      this.emit();
      return;
    }
    await this.fetchComments(true);
  }

  async loadMoreComments(retry: boolean = false): Promise<void> {
    if (!this.active || this.state.detailLoading || this.state.commentsLoading || this.state.commentsMoreLoading ||
      (!retry && this.state.commentMoreError.length > 0) || this.state.commentToken.length === 0) return;
    await this.fetchComments(false);
  }

  private async fetchComments(reset: boolean): Promise<void> {
    const request: number = this.commentRequest.next();
    const token: string = this.state.commentToken;
    if (reset) this.state.commentsLoading = true;
    else this.state.commentsMoreLoading = true;
    this.state.commentMoreError = '';
    this.emit();
    try {
      const page: YouTubeCommentPage = await YouTubeApi.comments(token);
      if (!this.active || !this.commentRequest.isCurrent(request)) return;
      const seen: Set<string> = new Set<string>();
      for (const item of this.comments.getAll()) seen.add(item.id);
      const fresh: Array<YouTubeComment> = [];
      for (const item of page.comments) {
        if (seen.has(item.id)) continue;
        seen.add(item.id);
        fresh.push(item);
      }
      this.comments.append(fresh);
      this.state.commentsCount = this.comments.totalCount();
      this.state.commentToken = page.continuation === token ? '' : page.continuation;
      if (page.total.length > 0) this.state.commentTotal = page.total;
      this.state.commentsLoaded = true;
      this.images.prime(fresh.map((item: YouTubeComment): string => item.avatar));
    } catch (error) {
      if (this.active && this.commentRequest.isCurrent(request)) {
        const message: string = (error as Error).message || '评论加载失败，请重试';
        if (reset) this.state.commentsError = message;
        else this.state.commentMoreError = message;
      }
    } finally {
      if (this.active && this.commentRequest.isCurrent(request)) {
        this.state.commentsLoading = false;
        this.state.commentsMoreLoading = false;
        this.emit();
      }
    }
  }

  private current(request: number): boolean { return this.active && this.request.isCurrent(request); }

  private emit(): void {
    if (!this.active) return;
    const value: YouTubeDetailState = new YouTubeDetailState();
    value.video = this.state.video;
    value.related = this.state.related.slice();
    value.detailLoading = this.state.detailLoading;
    value.detailError = this.state.detailError;
    value.coverUri = this.state.coverUri;
    value.imageLocal = this.images.snapshot();
    value.commentToken = this.state.commentToken;
    value.commentTotal = this.state.commentTotal;
    value.commentsCount = this.state.commentsCount;
    value.commentsLoading = this.state.commentsLoading;
    value.commentsLoaded = this.state.commentsLoaded;
    value.commentsError = this.state.commentsError;
    value.commentsMoreLoading = this.state.commentsMoreLoading;
    value.commentMoreError = this.state.commentMoreError;
    this.publish(value);
  }
}
