import { BangumiApi } from '../../api/BangumiApi';
import { RequestEpoch } from '../../common/RequestEpoch';
import { BangumiSeason } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';

export interface BangumiDetailStatus {
  readonly loading: boolean;
  readonly error: string;
}

export interface BangumiDetailHost {
  isAlive: () => boolean;
  publish: (status: BangumiDetailStatus) => void;
  onLoaded: (season: BangumiSeason, preferredEpId: number) => void;
}

/** 详情中含账号追番状态，旧账号/旧季响应都不能初始化当前页的追番控制器。 */
export class BangumiDetailController {
  private readonly host: BangumiDetailHost;
  private epoch: RequestEpoch = new RequestEpoch();

  constructor(host: BangumiDetailHost) {
    this.host = host;
  }

  dispose(): void {
    this.epoch.invalidate();
  }

  async load(seasonId: number, epId: number): Promise<void> {
    if (!this.host.isAlive()) return;
    const request: number = this.epoch.next();
    const account: number = AuthSession.version;
    this.host.publish({ loading: true, error: '' });
    let error: string = '';
    try {
      const season: BangumiSeason | null = await BangumiApi.getSeason(seasonId, epId);
      if (!this.isCurrent(request) || account !== AuthSession.version) return;
      if (season === null) error = '详情加载失败，请检查网络后重试';
      else this.host.onLoaded(season, epId);
    } catch (e) {
      if (account === AuthSession.version) error = '详情加载失败，请检查网络后重试';
    } finally {
      if (this.isCurrent(request)) this.host.publish({ loading: false, error: error });
    }
  }

  private isCurrent(request: number): boolean {
    return this.host.isAlive() && this.epoch.isCurrent(request);
  }
}
