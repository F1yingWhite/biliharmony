/**
 * 主题管理器：动态取色 + 明暗模式，通过 AppStorage 驱动全局 UI 响应式刷新
 * 对应 PiliPlus 的 Material You 动态色彩与明暗主题
 */
import { tonalPalette, isDarkColor } from './ColorUtil';
import { Constants } from './Constants';
import { uiMaterial } from '@kit.ArkUI';

export class AppTheme {
  /** 预设主题色（用户自选） */
  static readonly PRESET_COLORS: Array<string> = [
    '#FB7299', '#008AC5', '#43A047', '#FF8F00', '#8E24AA', '#E53935', '#00897B', '#FFCC00',
  ];
  static readonly KEY_ACCENT: string = 'accentColor';
  static readonly KEY_DARK: string = 'isDarkMode';
  static readonly KEY_THEME_MODE: string = 'themeMode';
  static readonly KEY_SYSTEM_DARK: string = 'systemDarkMode';
  static readonly MODE_SYSTEM: string = 'system';
  static readonly MODE_LIGHT: string = 'light';
  static readonly MODE_DARK: string = 'dark';
  static readonly KEY_HEADER_FADE: string = 'headerFade';
  static readonly KEY_GLASS_ENABLED: string = 'glassEnabled';
  private static nativeModeApplier: ((mode: string) => void) | null = null;

  /** 初始化主题状态 */
  static init(): void {
    PersistentStorage.persistProp<string>(AppTheme.KEY_THEME_MODE, AppTheme.MODE_SYSTEM);
    PersistentStorage.persistProp<string>(AppTheme.KEY_ACCENT, Constants.brandPink);
    PersistentStorage.persistProp<boolean>(AppTheme.KEY_DARK, false);
    PersistentStorage.persistProp<boolean>(AppTheme.KEY_GLASS_ENABLED, true);
    if (AppStorage.get<string>(AppTheme.KEY_ACCENT) === undefined) {
      AppStorage.setOrCreate<string>(AppTheme.KEY_ACCENT, Constants.brandPink);
    }
    if (AppStorage.get<boolean>(AppTheme.KEY_DARK) === undefined) {
      AppStorage.setOrCreate<boolean>(AppTheme.KEY_DARK, false);
    }
    if (AppStorage.get<string>(AppTheme.KEY_THEME_MODE) === undefined) {
      AppStorage.setOrCreate<string>(AppTheme.KEY_THEME_MODE, AppTheme.MODE_SYSTEM);
    }
    if (AppStorage.get<boolean>(AppTheme.KEY_SYSTEM_DARK) === undefined) {
      AppStorage.setOrCreate<boolean>(AppTheme.KEY_SYSTEM_DARK, false);
    }
    if (AppStorage.get<number>(AppTheme.KEY_HEADER_FADE) === undefined) {
      AppStorage.setOrCreate<number>(AppTheme.KEY_HEADER_FADE, 0);
    }
    if (AppStorage.get<boolean>(AppTheme.KEY_GLASS_ENABLED) === undefined) {
      AppStorage.setOrCreate<boolean>(AppTheme.KEY_GLASS_ENABLED, true);
    }
  }

  /** 滚动累积偏移（vp）：List.onScroll 上报的是单帧增量，需累积后计算头栏淡出 */
  private static scrollAccum: number = 0;

  /** 根据滚动增量更新头部淡出程度（0..1）：正反方向都连续过渡，避免反向滚动时头栏瞬间跳回。 */
  static updateHeaderFade(offset: number): void {
    AppTheme.scrollAccum = Math.min(70, Math.max(0, AppTheme.scrollAccum + offset));
    const f: number = Math.min(1, Math.max(0, AppTheme.scrollAccum / 70));
    const cur: number | undefined = AppStorage.get<number>(AppTheme.KEY_HEADER_FADE);
    if (cur === undefined || Math.abs(cur - f) > 0.015 || f === 0 || f === 1) {
      AppStorage.setOrCreate<number>(AppTheme.KEY_HEADER_FADE, f);
    }
  }

  static resetHeaderFade(): void {
    AppTheme.scrollAccum = 0;
    AppStorage.setOrCreate<number>(AppTheme.KEY_HEADER_FADE, 0);
  }

  /** 设置主题强调色（取色结果） */
  static setAccent(hex: string): void {
    AppStorage.setOrCreate<string>(AppTheme.KEY_ACCENT, hex);
  }

  static getAccent(): string {
    const v: string | undefined = AppStorage.get<string>(AppTheme.KEY_ACCENT);
    return v ?? Constants.brandPink;
  }

  static isDark(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(AppTheme.KEY_DARK);
    return v ?? false;
  }

  static setDark(dark: boolean): void {
    AppStorage.setOrCreate<boolean>(AppTheme.KEY_DARK, dark);
  }

  static toggleDark(): void {
    AppTheme.setMode(AppTheme.isDark() ? AppTheme.MODE_LIGHT : AppTheme.MODE_DARK);
  }

  static getMode(): string {
    const mode: string = AppStorage.get<string>(AppTheme.KEY_THEME_MODE) ?? AppTheme.MODE_SYSTEM;
    if (mode === AppTheme.MODE_LIGHT || mode === AppTheme.MODE_DARK) return mode;
    return AppTheme.MODE_SYSTEM;
  }

  static bindNativeModeApplier(applier: (mode: string) => void): void {
    AppTheme.nativeModeApplier = applier;
  }

  static applyCurrentMode(): void {
    const mode: string = AppTheme.getMode();
    const applier: ((mode: string) => void) | null = AppTheme.nativeModeApplier;
    if (applier !== null) applier(mode);
    if (mode === AppTheme.MODE_DARK) {
      AppTheme.setDark(true);
    } else if (mode === AppTheme.MODE_LIGHT) {
      AppTheme.setDark(false);
    } else {
      AppTheme.setDark(AppStorage.get<boolean>(AppTheme.KEY_SYSTEM_DARK) ?? false);
    }
  }

  static setMode(mode: string): void {
    const next: string = mode === AppTheme.MODE_LIGHT || mode === AppTheme.MODE_DARK ? mode : AppTheme.MODE_SYSTEM;
    AppStorage.setOrCreate<string>(AppTheme.KEY_THEME_MODE, next);
    AppTheme.applyCurrentMode();
  }

  static updateSystemDark(dark: boolean): void {
    AppStorage.setOrCreate<boolean>(AppTheme.KEY_SYSTEM_DARK, dark);
    if (AppTheme.getMode() === AppTheme.MODE_SYSTEM) AppTheme.setDark(dark);
  }

  /** 生成当前模式下的色调板 */
  static palette(): Record<string, string> {
    return tonalPalette(AppTheme.getAccent(), AppTheme.isDark());
  }

  /** 背景色（主题氛围背景） */
  static background(): string {
    const p: Record<string, string> = AppTheme.palette();
    return p['background'];
  }

  /** 强调色是否属于深色 */
  static accentIsDark(): boolean {
    return isDarkColor(AppTheme.getAccent());
  }

  // ===== 模糊材质（设计规范 §3.2：可开关，强度跟随系统标准档） =====

  static isGlassEnabled(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(AppTheme.KEY_GLASS_ENABLED);
    return v ?? true;
  }

  static setGlassEnabled(on: boolean): void {
    AppStorage.setOrCreate<boolean>(AppTheme.KEY_GLASS_ENABLED, on);
  }

  /** L2 浮层（顶栏/TabBar/搜索胶囊）模糊材质；总开关关闭时返回 undefined（backgroundBlurStyle 传 undefined 即无模糊） */
  static floatBlur(on: boolean): BlurStyle | undefined {
    return on ? BlurStyle.BACKGROUND_REGULAR : undefined;
  }

  /** L3 弹层（筛选面板/菜单）模糊材质：比浮层高一档；总开关关闭时返回 undefined */
  static sheetBlur(on: boolean): BlurStyle | undefined {
    return on ? BlurStyle.BACKGROUND_THICK : undefined;
  }

  /** L2 浮层底色：开模糊时半透明（内容透出），关模糊时退化为高不透明度实底 */
  static floatBg(isDark: boolean, on: boolean): string {
    if (on) {
      return isDark ? '#8A202123' : '#8AFFFFFF';
    }
    return isDark ? '#F5141418' : '#F5FFFFFF';
  }

  /** L3 弹层底色：规则同 floatBg，开模糊时更不透明一档 */
  static sheetBg(isDark: boolean, on: boolean): string {
    if (on) {
      return isDark ? '#E62A2C31' : '#E6FFFFFF';
    }
    return isDark ? '#F5141418' : '#F5FFFFFF';
  }

  /**
   * L2 浮层原生沉浸光感材质（systemMaterial 用）；总开关关闭时返回 undefined（退化为 floatBg 实底）。
   * interactive 按压弹性形变 + lightEffect 触控光晕，即原生光感交互反馈。
   */
  static floatMaterial(on: boolean): uiMaterial.ImmersiveMaterial | undefined {
    if (!on) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      interactive: true,
      lightEffect: { color: Color.White },
    });
  }
}
