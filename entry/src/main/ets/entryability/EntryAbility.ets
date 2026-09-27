import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { App, KeyboardAvoidMode, window } from '@kit.ArkUI';
import { AppTheme } from '../common/AppTheme';
import { Immersive } from '../common/Immersive';
import { UserStore } from '../services/auth/UserStore';
import { SearchHistoryStore } from '../common/SearchHistoryStore';
import { LocalVideoFilter } from '../common/LocalVideoFilter';
import { YouTubeSearchHistoryStore } from '../common/YouTubeSearchHistoryStore';
import { YouTubeWatchLaterStore } from '../common/YouTubeWatchLaterStore';
import { YouTubeHistoryStore } from '../common/YouTubeHistoryStore';
import { PlatformStore } from '../common/PlatformStore';
import { EmoteResolver } from '../common/EmoteResolver';
import { RemoteAssetCache } from '../services/cache/RemoteAssetCache';
import { SponsorBlockStore } from '../common/SponsorBlock';
import { HttpClient } from '../services/network/HttpClient';
import { CookieRefresher } from '../services/auth/CookieRefresher';
import { NetworkSettingsStore } from '../pages/NetworkPrivacyPage';
import { WebProxy } from '../services/network/WebProxy';
import { ContinueWatchingStore } from '../common/ContinueWatchingStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'BiliHarmony';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    EntryAbility.enableImageCaches();
    this.handleCardDeepLink(want);
    AppStorage.setOrCreate<boolean>('appInBackground', false);
    UserStore.initPersistence(this.context);
    SearchHistoryStore.init(this.context);
    // 本地「不想看」：持久化 aid 黑名单，首页/相关推荐入列前过滤。
    LocalVideoFilter.init(this.context);
    // YouTube 侧搜索历史独立存储：两个平台的搜索词不混在一起。
    YouTubeSearchHistoryStore.init(this.context);
    // 本地稍后观看：不需要账号，游客也能用。
    YouTubeWatchLaterStore.init(this.context);
    // 本地观看历史：打开详情即记录，同样不需要账号。
    YouTubeHistoryStore.init(this.context);
    // 顶层平台（哔哩哔哩 / YouTube）持久化：冷启动即确定首帧渲染哪个外壳。
    PlatformStore.init();
    this.applyLaunchProxy(want).catch(() => {
    });
    // 表情占位符映射表磁盘缓存：冷启动即恢复，不依赖网络。
    EmoteResolver.attach(this.context);
    // 表情、用户装扮与典藏卡资源的 cacheDir 落盘入口，并回收旧版头像及评论分享缓存。
    RemoteAssetCache.attach(this.context);
    AppTheme.init(this.context);
    // 冷启动就按平台定强调色：YouTube 红 / 哔哩哔哩用户自选色。
    PlatformStore.syncAccent();
    AppTheme.initThemeStore(this.context).catch(() => {
      // 主题偏好恢复失败不影响启动；PersistentStorage 默认值兜底。
    });
    SponsorBlockStore.init(this.context).catch(() => {
      // 空降助手设置恢复失败时使用上游默认分类策略。
    });
    AppTheme.bindNativeModeApplier((mode: string) => this.applyNativeThemeMode(mode));
    AppTheme.applyCurrentMode();
    // 定时深色的进程级心跳：不依赖用户进过「我的」Tab。
    AppTheme.startAutoDarkTicker();
    if (DEBUG) hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  /**
   * 开启 ArkUI 图片缓存。SDK 明确写着"setImageCacheCount 未设置时应用不缓存任何已解码图片"，
   * 因此默认配置下同一张评论图/头像滚出视口再回来必须重新下载并重新解码；
   * 这里在 onCreate（任何图片加载之前、UI 线程上）一次性打开三级缓存。
   * 必须在 loadContent 之前调用：图片缓存容量只在首次加载图片前生效。
   */
  private static enableImageCaches(): void {
    try {
      // 已解码图片（内存）：评论流 + 信息流滚动回来直接复用，不再重新解码。
      App.setImageCacheCount(256);
      // 解码前原始数据（内存）：同图复用不同尺寸时省掉一次磁盘读。
      App.setImageRawDataCacheSize(48 * 1024 * 1024);
      // 磁盘缓存（默认 100MB）：视频页反复进出的封面与评论图不再重新下载。
      App.setImageFileCacheSize(256 * 1024 * 1024);
    } catch (e) {
      // 缓存属于增强能力：机型不支持时只记录，绝不影响启动。
      if (DEBUG) hilog.warn(DOMAIN, TAG, 'Enable image caches failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 可选 HTTP 代理：仅当启动参数带 `netProxy` 时启用（如
   * `aa start -a EntryAbility -b <bundle> --ps netProxy http://127.0.0.1:7897`）。
   * 不传时保持空值，HttpClient 不设置 usingProxy，行为与历史版本一致。
   * ArkWeb 播放器使用独立网络栈，同一取值必须单独下发（见 WebProxy）。
   */
  private async applyLaunchProxy(want: Want): Promise<void> {
    // QA 探针开关（默认关）：仅用于在播放层被风控挡住时验证 ArkWeb 全屏/返回联动。
    const probe: string = want.parameters === undefined ? '' : String(want.parameters['ytPlayerProbe'] ?? '');
    if (probe === '1') AppStorage.setOrCreate<boolean>('ytPlayerProbe', true);
    let value: string = want.parameters === undefined ? '' : String(want.parameters['netProxy'] ?? '');
    if (value.length === 0) {
      // 设置页保存的代理（网络与隐私）：无启动参数时使用，仍是重启后生效。
      try {
        value = await NetworkSettingsStore.loadProxy(this.context);
      } catch (e) {
        value = '';
      }
    }
    if (value.length === 0) return;
    HttpClient.setProxy(value);
    if (WebProxy.apply(value)) {
      if (DEBUG) hilog.info(DOMAIN, TAG, '%{public}s', 'ArkWeb proxy override applied');
    }
  }

  private applyNativeThemeMode(mode: string): void {
    let nativeMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === AppTheme.MODE_DARK) nativeMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    if (mode === AppTheme.MODE_LIGHT) nativeMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    this.context.getApplicationContext().setColorMode(nativeMode);
    if (mode === AppTheme.MODE_SYSTEM) this.syncSystemTheme();
  }

  private syncSystemTheme(): void {
    const colorMode: number = this.context.resourceManager.getConfigurationSync().colorMode;
    AppTheme.updateSystemDark(colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    if (AppTheme.getMode() === AppTheme.MODE_SYSTEM && newConfig.colorMode !== undefined) {
      AppTheme.updateSystemDark(newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    }
  }

  onDestroy(): void {
    AppTheme.stopAutoDarkTicker();
    if (DEBUG) hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  /** 服务卡片 router 深链：取出目标视频，交由根页在导航栈就绪后打开详情。 */
  private handleCardDeepLink(want: Want): void {
    const params: object | undefined = want.parameters;
    if (params === undefined) return;
    const bvid: string = String(params['bvid'] ?? '');
    const aid: string = String(params['aid'] ?? '0');
    if (bvid.length === 0 && aid === '0') return;
    AppStorage.setOrCreate<string>('pendingCardBvid', bvid);
    AppStorage.setOrCreate<number>('pendingCardAid', Number(aid) || 0);
    ContinueWatchingStore.ensureSync(this.context);
    const record = ContinueWatchingStore.latest();
    const matches: boolean = record !== null && (bvid.length > 0 ? record.bvid === bvid :
      Number(aid) > 0 && record.aid === Number(aid));
    AppStorage.setOrCreate<number>('pendingCardCid', matches && record !== null ? record.cid : 0);
    AppStorage.setOrCreate<number>('pendingCardEpId', matches && record !== null ? record.epId : 0);
    AppStorage.setOrCreate<number>('pendingCardPosition', matches && record !== null &&
      Number.isFinite(record.position) ? Math.max(0, record.position) : 0);
    AppStorage.setOrCreate<number>('pendingCardRevision',
      (AppStorage.get<number>('pendingCardRevision') ?? 0) + 1);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleCardDeepLink(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 注入主窗口并开启边到边沉浸（透明系统栏；图标深浅由头栏按主题同步）
    Immersive.attach(windowStage);
    // 进程可能在横屏全屏中被系统/调试器直接终止，此时不会经过 PlayerView 的退出清理。
    // 新窗口必须显式恢复竖屏和系统栏，避免首页继承上个进程的横屏 preferredOrientation。
    Immersive.setFullscreen(false);
    Immersive.enableImmersive(false, false);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        if (DEBUG) hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // UIContext 只有在页面内容加载完成后才可用；过早同步获取会让部分真机的 Ability 启动失败。
      try {
        // RESIZE 只压缩可用内容区，让底部评论输入栏贴着键盘上移，不再把视频详情整页顶走。
        windowStage.getMainWindowSync().getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      } catch (e) {
        if (DEBUG) hilog.warn(DOMAIN, TAG, 'Set keyboard avoid mode failed: %{public}s', JSON.stringify(e));
      }
      if (DEBUG) hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      // Cookie 自动续期：启动后错峰静默检查一次（内部 6 小时节流，失败不影响任何功能）。
      setTimeout(() => {
        CookieRefresher.maybeRefresh().catch(() => {
        });
      }, 10000);
    });
  }

  onWindowStageDestroy(): void {
    if (DEBUG) hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    AppStorage.setOrCreate<boolean>('appInBackground', false);
    if (AppTheme.getMode() === AppTheme.MODE_SYSTEM) this.syncSystemTheme();
    if (DEBUG) hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    AppStorage.setOrCreate<boolean>('appInBackground', true);
    if (DEBUG) hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
