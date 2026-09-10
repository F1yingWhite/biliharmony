/**
 * 沉浸式窗口工具（Telegram 式边到边）：
 * 状态栏/导航栏透明 + 内容背景一路延伸到屏幕最顶端，图标深浅随主题。
 */
import { display, window } from '@kit.ArkUI';

export class Immersive {
  static readonly STATUS_BAR_HEIGHT_KEY: string = 'windowStatusBarHeight';
  private static mainWindow: window.Window | null = null;
  private static cachedStatusBarHeight: number = -1;
  private static cachedBottomInset: number = -1;
  private static brightnessPending: number = -2;
  private static brightnessApplying: boolean = false;

  /** 由 EntryAbility 在窗口创建时注入 */
  static attach(windowStage: window.WindowStage): void {
    try {
      Immersive.mainWindow = windowStage.getMainWindowSync();
    } catch (e) {
      Immersive.mainWindow = null;
    }
    const win: window.Window | null = Immersive.mainWindow;
    if (win !== null) {
      // 系统栏隐藏、恢复和旋转都是异步操作；完成事件必须通知保活的首页重排。
      win.on('avoidAreaChange', () => Immersive.publishInsets());
      win.on('windowSizeChange', () => Immersive.publishInsets());
    }
    Immersive.publishInsets();
  }

  private static publishInsets(): void {
    Immersive.invalidate();
    AppStorage.setOrCreate<number>(Immersive.STATUS_BAR_HEIGHT_KEY, Immersive.statusBarHeight());
  }

  /** avoidArea 缓存失效：窗口/系统栏/方向变化后调用，下次取值时重新计算 */
  static invalidate(): void {
    Immersive.cachedStatusBarHeight = -1;
    Immersive.cachedBottomInset = -1;
  }

  private static barProperties(statusIconLight: boolean, navIconLight: boolean): window.SystemBarProperties {
    return {
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: statusIconLight ? '#FFFFFF' : '#000000',
      navigationBarContentColor: navIconLight ? '#FFFFFF' : '#000000',
    };
  }

  /**
   * 开启边到边沉浸：布局全屏 + 系统栏透明
   * @param statusIconLight 状态栏图标是否浅色
   * @param navIconLight 导航栏图标是否浅色
   */
  static enableImmersive(statusIconLight: boolean, navIconLight: boolean): void {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return;
    }
    try {
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarProperties(Immersive.barProperties(statusIconLight, navIconLight));
    } catch (e) {
      // ignore
    }
    Immersive.invalidate();
  }

  /** 播放视频时保持屏幕常亮；暂停/离场时恢复。 */
  static setKeepScreenOn(on: boolean): void {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) return;
    try {
      win.setWindowKeepScreenOn(on);
    } catch (e) {
      // 部分设备/窗口阶段不支持常亮，忽略即可。
    }
  }

  /** 仅更新系统栏图标深浅（背景保持透明） */
  static setBarIcons(statusIconLight: boolean, navIconLight: boolean): void {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return;
    }
    try {
      win.setWindowSystemBarProperties(Immersive.barProperties(statusIconLight, navIconLight));
    } catch (e) {
      // ignore
    }
    Immersive.invalidate();
  }

  /** 状态栏高度（vp）。进程内缓存，避免 build 路径反复同步调 getWindowAvoidArea；窗口变化由 invalidate 刷新 */
  static statusBarHeight(): number {
    if (Immersive.cachedStatusBarHeight >= 0) {
      return Immersive.cachedStatusBarHeight;
    }
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return 0;
    }
    let height: number = 0;
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const h: number = Immersive.pxToVp(area.topRect.height);
      if (h > 0 && h <= 100) {
        height = h;
      }
    } catch (e) {
      height = 0;
    }
    Immersive.cachedStatusBarHeight = height;
    return height;
  }

  /** 底部导航区高度（vp）。同样走进程内缓存，窗口变化由 invalidate 刷新 */
  static bottomInset(): number {
    if (Immersive.cachedBottomInset >= 0) {
      return Immersive.cachedBottomInset;
    }
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return 0;
    }
    let height: number = 0;
    try {
      // TYPE_SYSTEM 只保证覆盖三键导航；手势导航的小白条使用
      // TYPE_NAVIGATION_INDICATOR。两者取最大值，兼容两种系统导航模式。
      const systemArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const systemHeight: number = Immersive.pxToVp(systemArea.bottomRect.height);
      if (systemHeight > 0 && systemHeight <= 80) height = systemHeight;
      try {
        const indicatorArea: window.AvoidArea =
          win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const indicatorHeight: number = Immersive.pxToVp(indicatorArea.bottomRect.height);
        if (indicatorHeight > 0 && indicatorHeight <= 80) height = Math.max(height, indicatorHeight);
      } catch (e) {
        // 旧系统不支持 TYPE_NAVIGATION_INDICATOR 时沿用 TYPE_SYSTEM。
      }
    } catch (e) {
      height = 0;
    }
    Immersive.cachedBottomInset = height;
    return height;
  }


  /** 避免区原始 px 转 vp：px / 屏幕密度。替代已废弃的全局 px2vp。 */
  private static pxToVp(px: number): number {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      return density > 0 ? px / density : 0;
    } catch (e) {
      return 0;
    }
  }

  /** 播放器手势读取当前窗口亮度；-1 表示仍跟随系统。 */
  static windowBrightness(): number {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) return -1;
    try {
      return win.getWindowProperties().brightness;
    } catch (e) {
      return -1;
    }
  }

  /** 仅调整当前应用窗口亮度，不修改系统全局亮度。 */
  static setWindowBrightness(value: number): void {
    Immersive.brightnessPending = Math.max(0.02, Math.min(1, value));
    Immersive.flushWindowBrightness();
  }

  static restoreWindowBrightness(): void {
    Immersive.brightnessPending = -1;
    Immersive.flushWindowBrightness();
  }

  private static flushWindowBrightness(): void {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null || Immersive.brightnessApplying || Immersive.brightnessPending < -1) return;
    const target: number = Immersive.brightnessPending;
    Immersive.brightnessPending = -2;
    Immersive.brightnessApplying = true;
    win.setWindowBrightness(target).then(() => {
      Immersive.completeBrightnessApply();
    }).catch(() => {
      Immersive.completeBrightnessApply();
    });
  }

  private static completeBrightnessApply(): void {
    Immersive.brightnessApplying = false;
    // 手指移动速度快于系统窗口 API 时只提交最新值，避免旧 Promise 排队造成明显延迟。
    if (Immersive.brightnessPending >= -1) Immersive.flushWindowBrightness();
  }

  /**
   * 把应用侧过渡与系统竖屏旋转对齐：WILL_ROTATE 开始收起，DID_ROTATE 只做收尾。
   * 返回取消函数，组件销毁时可立即移除监听与兜底定时器。
   */
  static duringPortraitRotation(onStart: () => void, onFinish: () => void,
    fallbackMs: number = 900): () => void {
    const win: window.Window | null = Immersive.mainWindow;
    let active: boolean = true;
    let started: boolean = false;
    let fallbackTimer: number = -1;
    let rotationCallback: ((info: window.RotationChangeInfo) => void) | null = null;
    const cleanup = (): void => {
      if (!active) return;
      active = false;
      if (fallbackTimer >= 0) {
        clearTimeout(fallbackTimer);
        fallbackTimer = -1;
      }
      if (win !== null && rotationCallback !== null) {
        try {
          win.off('rotationChange', rotationCallback);
        } catch (e) {
          // 不支持 rotationChange 的旧设备会走超时兜底。
        }
      }
    };
    const start = (): void => {
      if (!active || started) return;
      started = true;
      onStart();
    };
    const finish = (): void => {
      if (!active) return;
      start();
      cleanup();
      onFinish();
    };
    if (win === null) {
      fallbackTimer = setTimeout(() => finish(), 0);
      return cleanup;
    }
    try {
      const rect: window.Rect = win.getWindowProperties().windowRect;
      if (rect.height >= rect.width) {
        // 竖屏视频本来就不旋转：下一帧开始收起，但仍给外层裁剪窗口完整的过渡时间。
        fallbackTimer = setTimeout(() => {
          start();
          fallbackTimer = setTimeout(() => finish(), 300);
        }, 16);
        return cleanup;
      }
      rotationCallback = (info: window.RotationChangeInfo): void => {
        const portrait: boolean = info.orientation === 0 || info.orientation === 2 ||
          info.displayRect.height >= info.displayRect.width;
        if (!portrait) return;
        if (info.type === window.RotationChangeType.WINDOW_WILL_ROTATE) {
          start();
        } else if (info.type === window.RotationChangeType.WINDOW_DID_ROTATE) {
          finish();
        }
      };
      win.on('rotationChange', rotationCallback);
    } catch (e) {
      // 注册失败仍由超时兜底恢复详情布局。
    }
    fallbackTimer = setTimeout(() => finish(), Math.max(300, fallbackMs));
    return cleanup;
  }

  /** 视频播放页全屏：隐藏系统栏；退出恢复。keepPortrait 为竖屏视频保持竖屏全屏（不转横屏）。 */
  static setFullscreen(landscape: boolean, keepPortrait: boolean = false): void {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return;
    }
    if (landscape) {
      try {
        win.setWindowSystemBarEnable([]);
      } catch (e) {
        // ignore
      }
      try {
        win.setPreferredOrientation(keepPortrait ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE);
      } catch (e) {
        // ignore
      }
    } else {
      try {
        win.setWindowSystemBarEnable(['status', 'navigation']);
      } catch (e) {
        // ignore
      }
      try {
        win.setPreferredOrientation(window.Orientation.PORTRAIT);
      } catch (e) {
        // ignore
      }
    }
    Immersive.invalidate();
  }
}
