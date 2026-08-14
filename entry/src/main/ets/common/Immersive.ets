/**
 * 沉浸式窗口工具（Telegram 式边到边）：
 * 状态栏/导航栏透明 + 内容背景一路延伸到屏幕最顶端，图标深浅随主题。
 */
import { window } from '@kit.ArkUI';

export class Immersive {
  private static mainWindow: window.Window | null = null;

  /** 由 EntryAbility 在窗口创建时注入 */
  static attach(windowStage: window.WindowStage): void {
    try {
      Immersive.mainWindow = windowStage.getMainWindowSync();
    } catch (e) {
      Immersive.mainWindow = null;
    }
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
      const props: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: statusIconLight ? '#FFFFFF' : '#000000',
        navigationBarContentColor: navIconLight ? '#FFFFFF' : '#000000',
      };
      win.setWindowSystemBarProperties(props);
    } catch (e) {
      // ignore
    }
  }

  /** 仅更新系统栏图标深浅（背景保持透明） */
  static setBarIcons(statusIconLight: boolean, navIconLight: boolean): void {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return;
    }
    try {
      const props: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: statusIconLight ? '#FFFFFF' : '#000000',
        navigationBarContentColor: navIconLight ? '#FFFFFF' : '#000000',
      };
      win.setWindowSystemBarProperties(props);
    } catch (e) {
      // ignore
    }
  }

  /** 状态栏高度（vp）。getWindowAvoidArea 返回 px，需 px2vp 换算；夹紧到安全范围，无窗口时返回 0 */
  static statusBarHeight(): number {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return 0;
    }
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const h: number = px2vp(area.topRect.height);
      if (h <= 0 || h > 100) {
        return 0;
      }
      return h;
    } catch (e) {
      return 0;
    }
  }

  /** 底部导航区高度（vp）。getWindowAvoidArea 返回 px，需 px2vp 换算；夹紧到安全范围 */
  static bottomInset(): number {
    const win: window.Window | null = Immersive.mainWindow;
    if (win === null) {
      return 0;
    }
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const h: number = px2vp(area.bottomRect.height);
      if (h <= 0 || h > 60) {
        return 0;
      }
      return h;
    } catch (e) {
      return 0;
    }
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
      win.setPreferredOrientation(window.Orientation.LANDSCAPE);
    } else {
      try {
        win.setWindowSystemBarEnable(['status', 'navigation']);
      } catch (e) {
        // ignore
      }
      win.setPreferredOrientation(window.Orientation.PORTRAIT);
    }
  }
}
