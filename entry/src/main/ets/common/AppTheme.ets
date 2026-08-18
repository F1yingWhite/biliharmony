/**
 * 主题管理器：动态取色 + 明暗模式，通过 AppStorage 驱动全局 UI 响应式刷新
 * 对应 PiliPlus 的 Material You 动态色彩与明暗主题
 */
import { tonalPalette, isDarkColor } from './ColorUtil';
import { Constants } from './Constants';
import { uiMaterial } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';

export class AppTheme {
  /** 预设主题色（用户自选） */
  static readonly PRESET_COLORS: Array<string> = [
    '#FB7299', '#008AC5', '#43A047', '#FF8F00', '#8E24AA', '#E53935', '#00897B', '#FFCC00',
  ];
  /** 危险/删除/清空等否定操作的统一红，取代历史遗留的 #FA4B4B / #FB4A4A 两套红。 */
  static readonly DANGER: string = '#FB4A4A';
  static readonly KEY_ACCENT: string = 'accentColor';
  static readonly KEY_DARK: string = 'isDarkMode';
  static readonly KEY_THEME_MODE: string = 'themeMode';
  static readonly KEY_SYSTEM_DARK: string = 'systemDarkMode';
  static readonly MODE_SYSTEM: string = 'system';
  static readonly MODE_LIGHT: string = 'light';
  static readonly MODE_DARK: string = 'dark';
  static readonly KEY_HEADER_FADE: string = 'headerFade';
  static readonly KEY_GLASS_ENABLED: string = 'glassEnabled';
  static readonly KEY_AUTO_DARK: string = 'autoDarkEnabled';
  static readonly KEY_AUTO_DARK_START: string = 'autoDarkStart';
  static readonly KEY_AUTO_DARK_END: string = 'autoDarkEnd';
  private static nativeModeApplier: ((mode: string) => void) | null = null;
  /** 显式落盘的主题偏好（PersistentStorage 只负责 AppStorage 响应式联动）。 */
  private static themePreferences: preferences.Preferences | null = null;

  /** 初始化主题状态 */
  static init(context: common.UIAbilityContext): void {
    // persistentProp 负责将偏好持久化到 AppStorage；ensure* 只补启动首帧默认值，
    // 避免 13 段 if (AppStorage.get(...) === undefined) 样板。
    PersistentStorage.persistProp<string>(AppTheme.KEY_THEME_MODE, AppTheme.MODE_SYSTEM);
    PersistentStorage.persistProp<string>(AppTheme.KEY_ACCENT, Constants.brandPink);
    PersistentStorage.persistProp<boolean>(AppTheme.KEY_DARK, false);
    PersistentStorage.persistProp<boolean>(AppTheme.KEY_GLASS_ENABLED, true);
    AppTheme.ensureString(AppTheme.KEY_THEME_MODE, AppTheme.MODE_SYSTEM);
    AppTheme.ensureString(AppTheme.KEY_ACCENT, Constants.brandPink);
    AppTheme.ensureBool(AppTheme.KEY_DARK, false);
    AppTheme.ensureBool(AppTheme.KEY_SYSTEM_DARK, false);
    AppTheme.ensureNumber(AppTheme.KEY_HEADER_FADE, 0);
    AppTheme.ensureBool(AppTheme.KEY_GLASS_ENABLED, true);
    AppTheme.ensureBool('autoContinuePlay', true);
    AppTheme.ensureBool('sponsorSkipEnabled', true);
    // 定时深色：默认关闭；时段默认 19:00 - 07:00（跨午夜）。
    PersistentStorage.persistProp<boolean>(AppTheme.KEY_AUTO_DARK, false);
    PersistentStorage.persistProp<string>(AppTheme.KEY_AUTO_DARK_START, '19:00');
    PersistentStorage.persistProp<string>(AppTheme.KEY_AUTO_DARK_END, '07:00');
    AppTheme.ensureBool(AppTheme.KEY_AUTO_DARK, false);
    AppTheme.ensureString(AppTheme.KEY_AUTO_DARK_START, '19:00');
    AppTheme.ensureString(AppTheme.KEY_AUTO_DARK_END, '07:00');
  }

  private static ensureString(key: string, value: string): void {
    if (AppStorage.get<string>(key) === undefined) {
      AppStorage.setOrCreate<string>(key, value);
    }
  }

  private static ensureBool(key: string, value: boolean): void {
    if (AppStorage.get<boolean>(key) === undefined) {
      AppStorage.setOrCreate<boolean>(key, value);
    }
  }

  private static ensureNumber(key: string, value: number): void {
    if (AppStorage.get<number>(key) === undefined) {
      AppStorage.setOrCreate<number>(key, value);
    }
  }

  /** 显式 Preferences 落盘（与 UserStore 同机制，绕开 PersistentStorage 的启动竞态）。 */
  static async initThemeStore(context: common.UIAbilityContext): Promise<void> {
    try {
      AppTheme.themePreferences = await preferences.getPreferences(context, { name: 'bili_theme_state' });
      const mode: string = AppTheme.themePreferences.getSync(AppTheme.KEY_THEME_MODE, '') as string;
      const dark: string = AppTheme.themePreferences.getSync(AppTheme.KEY_DARK, '') as string;
      if (mode.length > 0) {
        // Preferences 是权威副本：恢复后回写 AppStorage（PersistentStorage 已联动）。
        AppStorage.setOrCreate<string>(AppTheme.KEY_THEME_MODE, mode);
        if (mode === AppTheme.MODE_DARK) {
          AppStorage.setOrCreate<boolean>(AppTheme.KEY_DARK, true);
        } else if (mode === AppTheme.MODE_LIGHT) {
          AppStorage.setOrCreate<boolean>(AppTheme.KEY_DARK, false);
        }
      } else if (dark.length > 0) {
        AppStorage.setOrCreate<boolean>(AppTheme.KEY_DARK, dark === 'true');
      }
      // 播放器偏好同样显式恢复（自动连播、广告空降）。
      const auto: string = AppTheme.themePreferences.getSync('autoContinuePlay', '') as string;
      if (auto.length > 0) AppStorage.setOrCreate<boolean>('autoContinuePlay', auto === 'true');
      const sponsor: string = AppTheme.themePreferences.getSync('sponsorSkipEnabled', '') as string;
      if (sponsor.length > 0) AppStorage.setOrCreate<boolean>('sponsorSkipEnabled', sponsor === 'true');
      AppTheme.applyCurrentMode();
    } catch (e) {
      // 恢复失败保留默认态，不影响启动。
    }
  }

  /** 把播放器布尔偏好写入 Preferences（切换即落盘，重启还原）。 */
  private static syncBooleanPref(key: string, value: boolean): void {
    const store: preferences.Preferences | null = AppTheme.themePreferences;
    if (store === null) return;
    try {
      store.putSync(key, value ? 'true' : 'false');
      store.flush();
    } catch (e) {
      // 写盘失败只丢最后一次偏好。
    }
  }

  /** 自动连播开关写 Preferences。 */
  static persistAutoContinue(on: boolean): void {
    AppTheme.syncBooleanPref('autoContinuePlay', on);
  }

  /** 广告空降开关写 Preferences。 */
  static persistSponsorSkip(on: boolean): void {
    AppTheme.syncBooleanPref('sponsorSkipEnabled', on);
  }

  /** 把当前主题模式写 Preferences（切换即同步落盘，重启还原）。 */
  private static syncThemeToPrefs(mode: string, dark: boolean): void {
    const store: preferences.Preferences | null = AppTheme.themePreferences;
    if (store === null) return;
    try {
      store.putSync(AppTheme.KEY_THEME_MODE, mode);
      store.putSync(AppTheme.KEY_DARK, dark ? 'true' : 'false');
      store.flush();
    } catch (e) {
      // 写盘失败只丢最后一次偏好。
    }
  }

  /** 滚动累积偏移（vp）：List.onScroll 上报的是单帧增量，累积后计算头栏淡出 */
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
    } else if (AppTheme.isAutoDarkEnabled()) {
      // 定时深色优先于系统明暗：跟随系统模式下按时间段自动切换明暗。
      AppTheme.setDark(AppTheme.inAutoDarkWindow(new Date()));
    } else {
      AppTheme.setDark(AppStorage.get<boolean>(AppTheme.KEY_SYSTEM_DARK) ?? false);
    }
  }

  static setMode(mode: string): void {
    const next: string = mode === AppTheme.MODE_LIGHT || mode === AppTheme.MODE_DARK ? mode : AppTheme.MODE_SYSTEM;
    AppStorage.setOrCreate<string>(AppTheme.KEY_THEME_MODE, next);
    AppTheme.applyCurrentMode();
    AppTheme.syncThemeToPrefs(next, next === AppTheme.MODE_DARK);
  }

  static updateSystemDark(dark: boolean): void {
    AppStorage.setOrCreate<boolean>(AppTheme.KEY_SYSTEM_DARK, dark);
    if (AppTheme.getMode() === AppTheme.MODE_SYSTEM && !AppTheme.isAutoDarkEnabled()) {
      AppTheme.setDark(dark);
    }
  }

  // ===== 定时深色（跟随系统模式下按时间段强制切换） =====

  static isAutoDarkEnabled(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(AppTheme.KEY_AUTO_DARK);
    return v ?? false;
  }

  static setAutoDarkEnabled(on: boolean): void {
    AppStorage.setOrCreate<boolean>(AppTheme.KEY_AUTO_DARK, on);
    if (on && AppTheme.getMode() === AppTheme.MODE_SYSTEM) {
      AppTheme.applyAutoDark();
    }
  }

  static getAutoDarkStart(): string {
    return AppStorage.get<string>(AppTheme.KEY_AUTO_DARK_START) ?? '19:00';
  }

  static getAutoDarkEnd(): string {
    return AppStorage.get<string>(AppTheme.KEY_AUTO_DARK_END) ?? '07:00';
  }

  static setAutoDarkWindow(start: string, end: string): void {
    AppStorage.setOrCreate<string>(AppTheme.KEY_AUTO_DARK_START, start);
    AppStorage.setOrCreate<string>(AppTheme.KEY_AUTO_DARK_END, end);
    if (AppTheme.isAutoDarkEnabled() && AppTheme.getMode() === AppTheme.MODE_SYSTEM) {
      AppTheme.applyAutoDark();
    }
  }

  /** 当前时刻（分钟数）是否落在 [start, end) 时段，支持跨午夜（start > end）。 */
  static inAutoDarkWindow(date: Date): boolean {
    const mins: number = date.getHours() * 60 + date.getMinutes();
    const s: number = AppTheme.parseMinutes(AppTheme.getAutoDarkStart());
    const e: number = AppTheme.parseMinutes(AppTheme.getAutoDarkEnd());
    if (s === e) {
      return false;
    }
    if (s < e) {
      return mins >= s && mins < e;
    }
    return mins >= s || mins < e;
  }

  private static parseMinutes(hhmm: string): number {
    const parts: Array<string> = hhmm.split(':');
    const h: number = parts.length > 0 ? Number(parts[0]) : 0;
    const m: number = parts.length > 1 ? Number(parts[1]) : 0;
    return (Number.isNaN(h) ? 0 : h) * 60 + (Number.isNaN(m) ? 0 : m);
  }

  /** 依据当前时间刷新深色状态（定时开关开启且为跟随系统模式时生效），定时器周期调用。 */
  static applyAutoDark(): void {
    if (!AppTheme.isAutoDarkEnabled() || AppTheme.getMode() !== AppTheme.MODE_SYSTEM) {
      return;
    }
    AppTheme.setDark(AppTheme.inAutoDarkWindow(new Date()));
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

  /** 卡片/分组底色（从当前封面主题种子派生，替代散落的硬编码 #FFFFFF/#2A2C31）。 */
  static surface(): string {
    return AppTheme.palette()['surface'];
  }

  /** 次要卡片/暗色块底色 */
  static surfaceAlt(): string {
    return AppTheme.palette()['surfaceAlt'];
  }

  /** 主文字色 */
  static onSurface(): string {
    return AppTheme.palette()['onSurface'];
  }

  /** 次要文字色 */
  static onSurfaceSub(): string {
    return AppTheme.palette()['onSurfaceSub'];
  }

  /** 分割线色 */
  static divider(): string {
    return AppTheme.palette()['line'];
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
   * API 26 才提供 barFloatingStyle/systemMaterial/uiMaterial.ImmersiveStyle；低版本需退化为普通实底样式。
   */
  static isImmersiveUiSupported(): boolean {
    return deviceInfo.apiAvailable('26.0.0');
  }

  /**
   * L2 浮层原生沉浸光感材质（systemMaterial 用）；总开关关闭或低版本时返回 undefined（退化为 floatBg 实底）。
   * interactive 按压弹性形变 + lightEffect 触控光晕，即原生光感交互反馈。
   */
  static floatMaterial(on: boolean): uiMaterial.ImmersiveMaterial | undefined {
    if (!on || !AppTheme.isImmersiveUiSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      interactive: true,
      lightEffect: { color: Color.White },
    });
  }
}
