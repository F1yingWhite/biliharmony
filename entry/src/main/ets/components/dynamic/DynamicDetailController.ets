import { DynamicApi } from '../../api/DynamicApi';
import { RequestEpoch } from '../../common/RequestEpoch';
import { DynamicItem } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';

export interface DynamicDetailStatus {
  readonly loading: boolean;
  readonly failed: boolean;
}

export interface DynamicDetailHost {
  isAlive: () => boolean;
  publish: (status: DynamicDetailStatus) => void;
  onLoaded: (item: DynamicItem) => void;
}

/** feed 快照可以立即展示；补全正文的请求只向当前动态与账号提交一次结果。 */
export class DynamicDetailController {
  private readonly host: DynamicDetailHost;
  private epoch: RequestEpoch = new RequestEpoch();

  constructor(host: DynamicDetailHost) {
    this.host = host;
  }

  dispose(): void {
    this.epoch.invalidate();
  }

  async load(dynId: string): Promise<void> {
    if (!this.host.isAlive()) return;
    const request: number = this.epoch.next();
    const account: number = AuthSession.version;
    if (dynId.length === 0) {
      this.host.publish({ loading: false, failed: false });
      return;
    }
    this.host.publish({ loading: true, failed: false });
    let failed: boolean = false;
    try {
      const detail: DynamicItem | null = await DynamicApi.getDynamicDetail(dynId);
      if (!this.isCurrent(request) || account !== AuthSession.version) return;
      if (detail === null) failed = true;
      else this.host.onLoaded(detail);
    } catch (e) {
      if (account === AuthSession.version) failed = true;
    } finally {
      if (this.isCurrent(request)) this.host.publish({ loading: false, failed: failed });
    }
  }

  private isCurrent(request: number): boolean {
    return this.host.isAlive() && this.epoch.isCurrent(request);
  }
}
