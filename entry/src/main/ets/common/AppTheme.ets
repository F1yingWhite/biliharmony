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

/** 弹幕设置全量快照：规范默认值即播放器初始态，首开/恢复默认/持久化读取兜底都以此为准。 */
export class DanmakuSettings {
  enabled: boolean = true;
  frameRate: number = 60;
  opacity: number = 0.85;
  speed: number = 1.0;
  fontScale: number = 1.0;
  spacing: number = 1.0;
  density: number = 22;
  blockLevel: number = 0;
  blockScroll: boolean = false;
  blockTop: boolean = false;
  blockBottom: boolean = false;
  blockColor: boolean = false;
}

export class AppTheme {
  /** 预设主题色（用户自选） */
  static readonly PRESET_COLORS: Array<string> = [
    '#FB7299', '#008AC5', '#43A047', '#FF8F00', '#8E24AA', '#E53935', '#00897B', '#FFCC00',
  ];
  /** 危险/删除/清空等否定操作的统一红，取代历史遗留的 #FA4B4B / #FB4A4A 两套红。 */
  static readonly DANGER: string = '#FB4A4A';
  /** 生效强调色：全局组件读它；YouTube 平台下由 applyPlatformAccent 接管为红色。 */
  static readonly KEY_ACCENT: string = 'accentColor';
  /** 用户自选主题色：只在哔哩哔哩侧生效，切平台不会改写它。 */
  static readonly KEY_USER_ACCENT: string = 'userAccentColor';
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
  private static readonly KEY_DM_ENABLED: string = 'danmakuEnabled';
  private static readonly KEY_DM_FRAME_RATE: string = 'danmakuFrameRate';
  private static readonly KEY_DM_OPACITY: string = 'danmakuOpacity';
  private static readonly KEY_DM_SPEED: string = 'danmakuSpeed';
  private static readonly KEY_DM_FONT_SCALE: string = 'danmakuFontScale';
  private static readonly KEY_DM_SPACING: string = 'danmakuSpacing';
  private static readonly KEY_DM_DENSITY: string = 'danmakuDensity';
  private static readonly KEY_DM_BLOCK_LEVEL: string = 'danmakuBlockLevel';
  private static readonly KEY_DM_BLOCK_SCROLL: string = 'danmakuBlockScroll';
  private static readonly KEY_DM_BLOCK_TOP: string = 'danmakuBlockTop';
  private static readonly KEY_DM_BLOCK_BOTTOM: string = 'danmakuBlockBottom';
  private static readonly KEY_DM_BLOCK_COLOR: string = 'danmakuBlockColor';
  /** 弹幕设置 flush 尾部防抖定时器（滑条拖动期间高频变更不能每次都落盘）。 */
  private static danmakuFlushTimer: number = -1;
  private static nativeModeApplier: ((mode: string) => void) | null = null;
  /** 显式落盘的主题偏好（PersistentStorage 只负责 AppStorage 响应式联动）。 */
  private static themePreferences: preferences.Preferences | null = null;

  /** 初始化主题状态 */
  static init(context: common.UIAbilityContext): void {
    // persistentProp 负责将偏好持久化到 AppStorage；ensure* 只补启动首帧默认值，
    // 避免 13 段 if (AppStorage.get(...) === undefined) 样板。
    PersistentStorage.persistProp<string>(AppTheme.KEY_THEME_MODE, AppTheme.MODE_SYSTEM);
    PersistentStorage.persistProp<string>(AppTheme.KEY_ACCENT, Constants.brandPink);
    PersistentStorage.persistProp<string>(AppTheme.KEY_USER_ACCENT, Constants.brandPink);
    PersistentStorage.persistProp<boolean>(AppTheme.KEY_DARK, false);
    PersistentStorage.persistProp<boolean>(AppTheme.KEY_GLASS_ENABLED, true);
    PersistentStorage.persistProp<number>('videoQualityPref', 0);
    PersistentStorage.persistProp<number>('videoManualQuality', 0);
    AppTheme.ensureString(AppTheme.KEY_THEME_MODE, AppTheme.MODE_SYSTEM);
    AppTheme.ensureString(AppTheme.KEY_ACCENT, Constants.brandPink);
    // 迁移：老版本只持久化过 accentColor（那就是用户自选值），首次升级时把它迁到新键，
    // 之后平台强调色只改生效值，不再动自选值。
    AppTheme.ensureString(AppTheme.KEY_USER_ACCENT,
      AppStorage.get<string>(AppTheme.KEY_ACCENT) ?? Constants.brandPink);
    AppTheme.ensureBool(AppTheme.KEY_DARK, false);
    AppTheme.ensureBool(AppTheme.KEY_SYSTEM_DARK, false);
    AppTheme.ensureNumber(AppTheme.KEY_HEADER_FADE, 0);
    AppTheme.ensureBool(AppTheme.KEY_GLASS_ENABLED, true);
    AppTheme.ensureBool('autoContinuePlay', true);
    PersistentStorage.persistProp<boolean>('backgroundPlaybackEnabled', false);
    AppTheme.ensureBool('backgroundPlaybackEnabled', false);
    AppTheme.ensureBool('sponsorSkipEnabled', true);
    AppTheme.ensureNumber('videoQualityPref', 0);
    AppTheme.ensureNumber('videoManualQuality', 0);
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
      const background: string = AppTheme.themePreferences.getSync('backgroundPlaybackEnabled', '') as string;
      if (background.length > 0) AppStorage.setOrCreate<boolean>('backgroundPlaybackEnabled', background === 'true');
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

  static persistBackgroundPlayback(on: boolean): void {
    AppTheme.syncBooleanPref('backgroundPlaybackEnabled', on);
  }

  /** 广告空降开关写 Preferences。 */
  static persistSponsorSkip(on: boolean): void {
    AppTheme.syncBooleanPref('sponsorSkipEnabled', on);
  }

  private static readonly KEY_LAST_BRIGHTNESS: string = 'lastWindowBrightness';
  private static brightnessFlushTimer: number = -1;

  /** 上次手势设置的窗口亮度；窗口跟随系统（-1）时作为亮度滑动手势的起点，避免新视频首次上滑固定从 50% 起跳。 */
  static loadLastBrightness(): number {
    const store: preferences.Preferences | null = AppTheme.themePreferences;
    if (store === null) return -1;
    return AppTheme.readNumberPref(store, AppTheme.KEY_LAST_BRIGHTNESS, -1);
  }

  /** 手势亮度变化即记录（putSync 仅内存，flush 尾部防抖，拖动期间不落盘风暴）。 */
  static saveLastBrightness(value: number): void {
    if (value < 0 || value > 1) return;
    const store: preferences.Preferences | null = AppTheme.themePreferences;
    if (store === null) return;
    try {
      store.putSync(AppTheme.KEY_LAST_BRIGHTNESS, String(value));
    } catch (e) {
      return;
    }
    if (AppTheme.brightnessFlushTimer >= 0) {
      clearTimeout(AppTheme.brightnessFlushTimer);
    }
    AppTheme.brightnessFlushTimer = setTimeout(() => {
      AppTheme.brightnessFlushTimer = -1;
      const target: preferences.Preferences | null = AppTheme.themePreferences;
      if (target === null) return;
      try {
        target.flush();
      } catch (e) {
        // 写盘失败只丢最后一次偏好。
      }
    }, 400);
  }

  /** 读取弹幕设置：无落盘项或启动早期（Preferences 未就绪）返回规范默认值。 */
  static loadDanmakuSettings(): DanmakuSettings {
    const out: DanmakuSettings = new DanmakuSettings();
    const store: preferences.Preferences | null = AppTheme.themePreferences;
    if (store === null) return out;
    try {
      const on: string = store.getSync(AppTheme.KEY_DM_ENABLED, '') as string;
      if (on.length > 0) out.enabled = on === 'true';
      out.frameRate = Math.max(24, Math.min(120,
        Math.round(AppTheme.readNumberPref(store, AppTheme.KEY_DM_FRAME_RATE, out.frameRate))));
      out.opacity = AppTheme.readNumberPref(store, AppTheme.KEY_DM_OPACITY, out.opacity);
      out.speed = AppTheme.readNumberPref(store, AppTheme.KEY_DM_SPEED, out.speed);
      out.fontScale = AppTheme.readNumberPref(store, AppTheme.KEY_DM_FONT_SCALE, out.fontScale);
      out.spacing = Math.max(0.5, Math.min(2, AppTheme.readNumberPref(store, AppTheme.KEY_DM_SPACING, out.spacing)));
      out.density = Math.round(AppTheme.readNumberPref(store, AppTheme.KEY_DM_DENSITY, out.density));
      out.blockLevel = Math.round(AppTheme.readNumberPref(store, AppTheme.KEY_DM_BLOCK_LEVEL, out.blockLevel));
      out.blockScroll = (store.getSync(AppTheme.KEY_DM_BLOCK_SCROLL, '') as string) === 'true';
      out.blockTop = (store.getSync(AppTheme.KEY_DM_BLOCK_TOP, '') as string) === 'true';
      out.blockBottom = (store.getSync(AppTheme.KEY_DM_BLOCK_BOTTOM, '') as string) === 'true';
      out.blockColor = (store.getSync(AppTheme.KEY_DM_BLOCK_COLOR, '') as string) === 'true';
    } catch (e) {
      // 恢复失败保留默认态。
    }
    return out;
  }

  /** 弹幕设置全量落盘：putSync 即时写入（内存），flush 尾部防抖——滑条拖动期间每秒触发多次，不能每次都写盘。 */
  static persistDanmakuSettings(s: DanmakuSettings): void {
    const store: preferences.Preferences | null = AppTheme.themePreferences;
    if (store === null) return;
    try {
      store.putSync(AppTheme.KEY_DM_ENABLED, s.enabled ? 'true' : 'false');
      store.putSync(AppTheme.KEY_DM_FRAME_RATE, String(s.frameRate));
      store.putSync(AppTheme.KEY_DM_OPACITY, String(s.opacity));
      store.putSync(AppTheme.KEY_DM_SPEED, String(s.speed));
      store.putSync(AppTheme.KEY_DM_FONT_SCALE, String(s.fontScale));
      store.putSync(AppTheme.KEY_DM_SPACING, String(s.spacing));
      store.putSync(AppTheme.KEY_DM_DENSITY, String(s.density));
      store.putSync(AppTheme.KEY_DM_BLOCK_LEVEL, String(s.blockLevel));
      store.putSync(AppTheme.KEY_DM_BLOCK_SCROLL, s.blockScroll ? 'true' : 'false');
      store.putSync(AppTheme.KEY_DM_BLOCK_TOP, s.blockTop ? 'true' : 'false');
      store.putSync(AppTheme.KEY_DM_BLOCK_BOTTOM, s.blockBottom ? 'true' : 'false');
      store.putSync(AppTheme.KEY_DM_BLOCK_COLOR, s.blockColor ? 'true' : 'false');
    } catch (e) {
      return;
    }
    if (AppTheme.danmakuFlushTimer >= 0) {
      clearTimeout(AppTheme.danmakuFlushTimer);
    }
    AppTheme.danmakuFlushTimer = setTimeout(() => {
      AppTheme.danmakuFlushTimer = -1;
      const target: preferences.Preferences | null = AppTheme.themePreferences;
      if (target === null) return;
      try {
        target.flush();
      } catch (e) {
        // 写盘失败只丢最后一次偏好。
      }
    }, 400);
  }

  private static readNumberPref(store: preferences.Preferences, key: string, fallback: number): number {
    const raw: string = store.getSync(key, '') as string;
    if (raw.length === 0) return fallback;
    const value: number = Number(raw);
    return Number.isNaN(value) ? fallback : value;
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
    // 收起仍保留 70vp 的完整行程；反向下拉时用更短的恢复行程，避免搜索栏刚出现却仍只有
    // 一两成不透明度。这里改变的是交互进度，不额外套动画，因此不会产生跟手延迟。
    const responsiveOffset: number = offset < 0 ? offset * 3 : offset;
    AppTheme.scrollAccum = Math.min(70, Math.max(0, AppTheme.scrollAccum + responsiveOffset));
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

  /** 用户选择主题色：记为自选值并立即生效（YouTube 平台下仍以红色为准）。 */
  static setAccent(hex: string): void {
    AppStorage.setOrCreate<string>(AppTheme.KEY_USER_ACCENT, hex);
    AppStorage.setOrCreate<string>(AppTheme.KEY_ACCENT, hex);
  }

  /** 用户自选主题色（哔哩哔哩侧强调色）。 */
  static userAccent(): string {
    const v: string | undefined = AppStorage.get<string>(AppTheme.KEY_USER_ACCENT);
    return v === undefined || v.length === 0 ? Constants.brandPink : v;
  }

  /**
   * 平台强调色：切到 YouTube 时全局主题色变红（与搜索按钮、Dock 同一支红），
   * 切回哔哩哔哩恢复用户自选色。只改生效值，不写自选值，来回切换不污染用户偏好。
   */
  static applyPlatformAccent(isYouTube: boolean): void {
    AppStorage.setOrCreate<string>(AppTheme.KEY_ACCENT, isYouTube ? AppTheme.DANGER : AppTheme.userAccent());
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

  // ===== 模糊材质（设计规范 §3.2：可开关，效果跟随系统沉浸光感设置） =====

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
      // 不指定 style/materialColor：使用 SDK 默认 REGULAR 基材，最终强弱由系统沉浸光感设置调节。
      interactive: true,
      lightEffect: { color: Color.White },
    });
  }
}
