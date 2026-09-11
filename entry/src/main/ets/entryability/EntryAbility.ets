import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { AppTheme } from '../common/AppTheme';
import { Immersive } from '../common/Immersive';
import { UserStore } from '../services/auth/UserStore';
import { SearchHistoryStore } from '../common/SearchHistoryStore';
import { PlatformStore } from '../common/PlatformStore';
import { EmoteResolver } from '../common/EmoteResolver';
import { RemoteAssetCache } from '../services/cache/RemoteAssetCache';
import { SponsorBlockStore } from '../common/SponsorBlock';
import { HttpClient } from '../services/network/HttpClient';
import { WebProxy } from '../services/network/WebProxy';

const DOMAIN: number = 0x0000;
const TAG: string = 'BiliHarmony';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate<boolean>('appInBackground', false);
    UserStore.initPersistence(this.context);
    SearchHistoryStore.init(this.context);
    // 顶层平台（哔哩哔哩 / YouTube）持久化：冷启动即确定首帧渲染哪个外壳。
    PlatformStore.init();
    this.applyLaunchProxy(want);
    // 表情占位符映射表磁盘缓存：冷启动即恢复，不依赖网络。
    EmoteResolver.attach(this.context);
    // 表情、用户装扮与典藏卡资源的 cacheDir 落盘入口，并回收旧版头像及评论分享缓存。
    RemoteAssetCache.attach(this.context);
    AppTheme.init(this.context);
    AppTheme.initThemeStore(this.context).catch(() => {
      // 主题偏好恢复失败不影响启动；PersistentStorage 默认值兜底。
    });
    SponsorBlockStore.init(this.context).catch(() => {
      // 空降助手设置恢复失败时使用上游默认分类策略。
    });
    AppTheme.bindNativeModeApplier((mode: string) => this.applyNativeThemeMode(mode));
    AppTheme.applyCurrentMode();
    if (DEBUG) hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  /**
   * 可选 HTTP 代理：仅当启动参数带 `netProxy` 时启用（如
   * `aa start -a EntryAbility -b <bundle> --ps netProxy http://127.0.0.1:7897`）。
   * 不传时保持空值，HttpClient 不设置 usingProxy，行为与历史版本一致。
   * ArkWeb 播放器使用独立网络栈，同一取值必须单独下发（见 WebProxy）。
   */
  private applyLaunchProxy(want: Want): void {
    // QA 探针开关（默认关）：仅用于在播放层被风控挡住时验证 ArkWeb 全屏/返回联动。
    const probe: string = want.parameters === undefined ? '' : String(want.parameters['ytPlayerProbe'] ?? '');
    if (probe === '1') AppStorage.setOrCreate<boolean>('ytPlayerProbe', true);
    const value: string = want.parameters === undefined ? '' : String(want.parameters['netProxy'] ?? '');
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
    if (DEBUG) hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
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
