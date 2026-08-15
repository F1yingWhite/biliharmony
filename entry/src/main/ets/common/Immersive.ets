/**
 * 沉浸式窗口工具（Telegram 式边到边）：
 * 状态栏/导航栏透明 + 内容背景一路延伸到屏幕最顶端，图标深浅随主题。
 */
import { window } from '@kit.ArkUI';

export class Immersive {
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
    Immersive.invalidate();
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
      const h: number = px2vp(area.topRect.height);
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
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const h: number = px2vp(area.bottomRect.height);
      if (h > 0 && h <= 60) {
        height = h;
      }
    } catch (e) {
      height = 0;
    }
    Immersive.cachedBottomInset = height;
    return height;
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

  /** 视频播放页全屏：隐藏系统栏；退出恢复 */
  static setFullscreen(landscape: boolean): void {
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
        win.setPreferredOrientation(window.Orientation.LANDSCAPE);
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
