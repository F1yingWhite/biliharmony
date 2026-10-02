import { BiliApi, VideoTagInfo } from '../../api/BiliApi';
import { UserApi } from '../../api/UserApi';
import { ImageColor, ImagePalette } from '../../common/ImageColor';
import { RequestEpoch } from '../../common/RequestEpoch';
import { SpaceArcData, UserStat, VideoDetail } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';

export interface VideoDetailTarget {
  readonly aid: number;
  readonly bvid: string;
  readonly epId: number;
}

export interface VideoDetailStatus {
  readonly loading: boolean;
  readonly error: string;
}

/** 公开资料整体发布；互动按钮和播放状态不属于这个快照。 */
export interface VideoDetailMetadata {
  readonly followers: number;
  readonly videos: number;
  readonly tags: Array<VideoTagInfo>;
  readonly tint: string;
}

export interface VideoDetailHost {
  isAlive: () => boolean;
  waitEntrance: () => Promise<void>;
  publishStatus: (state: VideoDetailStatus) => void;
  publishMetadata: (state: VideoDetailMetadata) => void;
  onLoaded: (detail: VideoDetail) => void;
}

/** 详情与公开附属资料的请求归属；播放、推荐、评论由页面交给各自控制器。 */
export class VideoDetailController {
  private readonly host: VideoDetailHost;
  private epoch: RequestEpoch = new RequestEpoch();
  private followers: number = -1;
  private videos: number = -1;
  private tags: Array<VideoTagInfo> = [];
  private tint: string = '#FB7299';

  constructor(host: VideoDetailHost) {
    this.host = host;
  }

  dispose(): void {
    this.epoch.invalidate();
  }

  async load(target: VideoDetailTarget): Promise<void> {
    if (!this.host.isAlive()) return;
    const request: number = this.epoch.next();
    const account: number = AuthSession.version;
    // 参数只在调用时读取，之后不再回看可被导航修改的页面 param。
    const aid: number = target.aid;
    const bvid: string = target.bvid;
    const epId: number = target.epId;
    this.followers = -1;
    this.videos = -1;
    this.tags = [];
    this.tint = '#FB7299';
    this.publishMetadata();
    this.host.publishStatus({ loading: true, error: '' });
    let error: string = '';
    try {
      const detail: VideoDetail | null = await BiliApi.getVideoDetail(aid, bvid, epId);
      // 网络与 hero 飞行动画并行，只有接收详情的这一刻等待入场闸门。
      await this.host.waitEntrance();
      if (!this.isCurrent(request) || account !== AuthSession.version) return;
      if (detail === null) {
        error = '视频不存在或已失效';
        return;
      }
      this.host.onLoaded(detail);
      if (this.isCurrent(request)) this.loadMetadata(detail, request);
    } catch (e) {
      if (account === AuthSession.version) error = '加载失败，请检查网络后重试';
    } finally {
      if (this.isCurrent(request)) this.host.publishStatus({ loading: false, error: error });
    }
  }

  private loadMetadata(detail: VideoDetail, request: number): void {
    if (detail.upMid <= 0) {
      this.followers = 0;
      this.videos = 0;
      this.publishMetadata();
    } else {
      UserApi.getUserStat(detail.upMid).then((stat: UserStat) => {
        if (!this.isCurrent(request)) return;
        this.followers = stat.follower;
        this.publishMetadata();
      }).catch(() => {}); // 统计失败保留 --，不把接口失败伪装成 0。
      UserApi.getUserSpaceArcs(detail.upMid, 1, 'pubdate').then((arcs: SpaceArcData) => {
        if (!this.isCurrent(request)) return;
        this.videos = arcs.total;
        this.publishMetadata();
      }).catch(() => {});
    }
    BiliApi.getVideoTags(detail.aid, detail.bvid).then((tags: Array<VideoTagInfo>) => {
      if (!this.isCurrent(request)) return;
      this.tags = tags.slice();
      this.publishMetadata();
    }).catch(() => {});
    ImageColor.extract(detail.cover).then((palette: ImagePalette) => {
      if (!this.isCurrent(request)) return;
      this.tint = palette.dominant;
      this.publishMetadata();
    }).catch(() => {});
  }

  private isCurrent(request: number): boolean {
    return this.host.isAlive() && this.epoch.isCurrent(request);
  }

  private publishMetadata(): void {
    this.host.publishMetadata({ followers: this.followers, videos: this.videos,
      tags: this.tags.slice(), tint: this.tint });
  }
}
