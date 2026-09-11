import { RequestEpoch } from './RequestEpoch';
import { AppTheme } from './AppTheme';

/**
 * 顶层「平台」状态：哔哩哔哩与 YouTube 是同级内容源，而不是主 Tab 里的一个频道。
 *
 * 为什么需要它：YouTube 原先作为底部 Dock 的第 4 个 Tab 存在，导致
 * `currentTab !== 3` 这类魔数在主框架里出现两次，且 `FloatingTabs`/`PlainTabs`
 * 必须为它分叉。提升为平台状态后，底部 Dock 归各平台自己所有，加平台不需要
 * 再动主框架的判断。
 *
 * 底栏归属：`mainTabIndex` 广播的始终是**哔哩哔哩侧**的 Tab 下标，
 * YouTube 激活时不再广播（哔哩哔哩的 Tabs 此时没有宿主）。
 */
export class PlatformStore {
  static readonly BILI: string = 'bili';
  static readonly YOUTUBE: string = 'youtube';

  /** 当前平台，由 Index 通过 @StorageProp 订阅。 */
  static readonly KEY_PLATFORM: string = 'platform';
  /** 哔哩哔哩侧主 Tab 下标（Index 广播给「我的」页等宿主的既有键）。 */
  static readonly KEY_MAIN_TAB: string = 'mainTabIndex';

  /**
   * 平台代际：切平台时递增，让切走那一刻仍在途的请求提交结果前先失效。
   * 对齐易错清单第 11/16 条：切换后旧回调不得写新状态。
   */
  private static readonly epoch: RequestEpoch = new RequestEpoch();

  static init(): void {
    // 重启后回到上次的平台，与主题偏好的持久化方式一致。
    PersistentStorage.persistProp<string>(PlatformStore.KEY_PLATFORM, PlatformStore.BILI);
  }

  /**
   * 冷启动时按当前平台定强调色。必须在 AppTheme.init 之后调用：
   * 那边负责把持久化的生效值读回来，这里只负责按平台纠正它。
   */
  static syncAccent(): void {
    AppTheme.applyPlatformAccent(PlatformStore.isYouTube());
  }

  static current(): string {
    const value: string = AppStorage.get<string>(PlatformStore.KEY_PLATFORM) ?? PlatformStore.BILI;
    return value === PlatformStore.YOUTUBE ? PlatformStore.YOUTUBE : PlatformStore.BILI;
  }

  static isYouTube(): boolean {
    return PlatformStore.current() === PlatformStore.YOUTUBE;
  }

  /**
   * 切换平台。返回是否有实际变化，方便调用方决定要不要做副作用
   * （暂停播放、退出全屏等）。
   */
  static switchTo(platform: string): boolean {
    const next: string = platform === PlatformStore.YOUTUBE ? PlatformStore.YOUTUBE : PlatformStore.BILI;
    if (next === PlatformStore.current()) return false;
    PlatformStore.epoch.invalidate();
    // 先失效在途请求，再广播平台变化。
    AppStorage.setOrCreate<string>(PlatformStore.KEY_PLATFORM, next);
    // 强调色跟着平台走：YouTube 红 / 哔哩哔哩用户自选色。
    AppTheme.applyPlatformAccent(next === PlatformStore.YOUTUBE);
    return true;
  }

  static toggle(): boolean {
    return PlatformStore.switchTo(PlatformStore.isYouTube() ? PlatformStore.BILI : PlatformStore.YOUTUBE);
  }

  /** 异步请求开工前取号；平台切换后 isCurrent 会为 false。 */
  static nextRequest(): number {
    return PlatformStore.epoch.next();
  }

  static isCurrentRequest(token: number): boolean {
    return PlatformStore.epoch.isCurrent(token);
  }
}
