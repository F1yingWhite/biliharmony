/**
 * 全局用户状态（登录态缓存）
 */
import { UserInfo, UserSpaceInfo } from '../../model/Models';
import { CookiePair } from '../../api/AuthApi';
import { HttpClient } from '../network/HttpClient';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { UserApi } from '../../api/UserApi';
import { AuthSession } from './AuthSession';
import { MsgUnreadStore } from '../message/MsgUnreadStore';
import { CookieRefresher } from './CookieRefresher';

export class UserStore {
  private static readonly COOKIE_STORAGE_KEY: string = 'loginCookieJar';
  private static readonly ACCESS_TOKEN_STORAGE_KEY: string = 'loginAccessToken';
  private static readonly REFRESH_TOKEN_STORAGE_KEY: string = 'webRefreshToken';
  private static readonly AUTH_PREFERENCES_NAME: string = 'bili_auth_state';
  private static user: UserInfo | null = null;
  private static loaded: boolean = false;
  private static authPreferences: preferences.Preferences | null = null;
  private static persistenceReady: Promise<void> | null = null;
  /** Web 端 refresh_token：登录/续期响应体下发，Cookie 自动续期（CookieRefresher）必需。 */
  private static webRefreshToken: string = '';
  /** 登录操作代际：登录/登出会使更早发出的 nav 请求失效，避免旧响应覆盖新状态。 */
  private static authGeneration: number = 0;

  static get current(): UserInfo | null {
    return UserStore.user;
  }

  static get isLogin(): boolean {
    return (UserStore.user !== null && UserStore.user.isLogin) || HttpClient.getCookie('SESSDATA').length > 0;
  }

  static get refreshToken(): string {
    return UserStore.webRefreshToken;
  }

  /** 必须在页面创建前调用：恢复上次登录 Cookie，避免重启后清晰度和个性装扮退回游客态。 */
  static initPersistence(context: common.UIAbilityContext): void {
    PersistentStorage.persistProp<string>(UserStore.COOKIE_STORAGE_KEY, '');
    PersistentStorage.persistProp<string>(UserStore.ACCESS_TOKEN_STORAGE_KEY, '');
    PersistentStorage.persistProp<string>(UserStore.REFRESH_TOKEN_STORAGE_KEY, '');
    PersistentStorage.persistProp<string>('userAvatar', '');
    PersistentStorage.persistProp<string>('userPendant', '');
    const raw: string = AppStorage.get<string>(UserStore.COOKIE_STORAGE_KEY) ?? '';
    const accessToken: string = AppStorage.get<string>(UserStore.ACCESS_TOKEN_STORAGE_KEY) ?? '';
    const refreshToken: string = AppStorage.get<string>(UserStore.REFRESH_TOKEN_STORAGE_KEY) ?? '';
    HttpClient.importCookieJson(raw);
    HttpClient.setAppAccessToken(accessToken);
    UserStore.webRefreshToken = refreshToken;
    // CookieRefresher 刷新成功后经此回调落盘（依赖方向：UserStore → CookieRefresher 单向）。
    CookieRefresher.registerPersister(UserStore.onCookieRefreshed, (): string => UserStore.webRefreshToken);
    UserStore.persistenceReady = UserStore.restoreAuth(context, raw, accessToken, refreshToken);
  }

  /**
   * Preferences 是登录态的权威副本；PersistentStorage 仅保留给页面响应式状态。
   * 启动请求必须等待这里完成，防止 nav/playurl 先以游客身份发出。
   */
  private static async restoreAuth(context: common.UIAbilityContext, legacyRaw: string,
    legacyAccessToken: string, legacyRefreshToken: string): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, {
        name: UserStore.AUTH_PREFERENCES_NAME,
      });
      UserStore.authPreferences = store;
      const diskRaw: string = store.getSync(UserStore.COOKIE_STORAGE_KEY, '') as string;
      const diskAccessToken: string = store.getSync(UserStore.ACCESS_TOKEN_STORAGE_KEY, '') as string;
      const diskRefreshToken: string = store.getSync(UserStore.REFRESH_TOKEN_STORAGE_KEY, '') as string;
      const effectiveRaw: string = diskRaw.length > 0 ? diskRaw : legacyRaw;
      const effectiveAccessToken: string = diskAccessToken.length > 0 ? diskAccessToken : legacyAccessToken;
      const effectiveRefreshToken: string = diskRefreshToken.length > 0 ? diskRefreshToken : legacyRefreshToken;
      HttpClient.importCookieJson(effectiveRaw);
      HttpClient.setAppAccessToken(effectiveAccessToken);
      UserStore.webRefreshToken = effectiveRefreshToken;

      // 从旧版 PersistentStorage 无损迁移到显式落盘的 Preferences。
      let migrated: boolean = false;
      if (diskRaw.length === 0 && legacyRaw.length > 0) {
        store.putSync(UserStore.COOKIE_STORAGE_KEY, legacyRaw);
        migrated = true;
      }
      if (diskAccessToken.length === 0 && legacyAccessToken.length > 0) {
        store.putSync(UserStore.ACCESS_TOKEN_STORAGE_KEY, legacyAccessToken);
        migrated = true;
      }
      if (diskRefreshToken.length === 0 && legacyRefreshToken.length > 0) {
        store.putSync(UserStore.REFRESH_TOKEN_STORAGE_KEY, legacyRefreshToken);
        migrated = true;
      }
      if (migrated) await store.flush();
    } catch (e) {
      // Preferences 不可用时仍可沿用已导入的旧缓存，不阻断应用启动。
    }
  }

  /**
   * CookieRefresher 续期成功回调：cookie 罐已由 HttpClient 吸收，这里落盘 + 保存新
   * refresh_token。不 bump AuthSession（不打断在途请求），随后静默刷新一次 nav。
   */
  private static async onCookieRefreshed(refreshToken: string): Promise<void> {
    UserStore.webRefreshToken = refreshToken;
    await UserStore.waitForPersistence();
    if (UserStore.authPreferences !== null) {
      UserStore.authPreferences.putSync(UserStore.COOKIE_STORAGE_KEY, HttpClient.exportCookieJson());
      UserStore.authPreferences.putSync(UserStore.REFRESH_TOKEN_STORAGE_KEY, refreshToken);
      await UserStore.authPreferences.flush();
    }
    AppStorage.setOrCreate<string>(UserStore.COOKIE_STORAGE_KEY, HttpClient.exportCookieJson());
    AppStorage.setOrCreate<string>(UserStore.REFRESH_TOKEN_STORAGE_KEY, refreshToken);
    UserStore.refresh().catch(() => {
      // nav 刷新失败不影响已续期的 Cookie。
    });
  }

  private static async waitForPersistence(): Promise<void> {
    if (UserStore.persistenceReady !== null) {
      await UserStore.persistenceReady;
    }
  }

  private static async persistCookies(raw: string): Promise<void> {
    AppStorage.setOrCreate<string>(UserStore.COOKIE_STORAGE_KEY, raw);
    await UserStore.waitForPersistence();
    if (UserStore.authPreferences !== null) {
      UserStore.authPreferences.putSync(UserStore.COOKIE_STORAGE_KEY, raw);
      // 必须等 flush 完成，防止安装/重启杀进程时 Cookie 仍只在内存。
      await UserStore.authPreferences.flush();
    }
  }

  private static async persistAccessToken(value: string): Promise<void> {
    AppStorage.setOrCreate<string>(UserStore.ACCESS_TOKEN_STORAGE_KEY, value);
    await UserStore.waitForPersistence();
    if (UserStore.authPreferences !== null) {
      UserStore.authPreferences.putSync(UserStore.ACCESS_TOKEN_STORAGE_KEY, value);
      await UserStore.authPreferences.flush();
    }
  }

  static async ensureLoaded(): Promise<UserInfo> {
    await UserStore.waitForPersistence();
    if (UserStore.loaded && UserStore.user !== null) return UserStore.user;
    return UserStore.refresh();
  }

  /** 刷新登录态（nav 接口） */
  static async refresh(): Promise<UserInfo> {
    const generation: number = UserStore.authGeneration;
    const u: UserInfo = await UserApi.getNav();
    if (generation !== UserStore.authGeneration) {
      return UserStore.user ?? new UserInfo();
    }
    UserStore.user = u;
    UserStore.loaded = true;
    AppStorage.setOrCreate<string>('userAvatar', u.isLogin ? u.face : '');
    AppStorage.setOrCreate<string>('userPendant', u.isLogin ? u.pendant : '');
    // nav 通常不返回头像挂件：先恢复登录与头像，再异步补齐空间装扮，避免阻塞首页首屏。
    if (u.isLogin && u.mid > 0 && u.pendant.length === 0) {
      UserApi.getUserSpaceInfo(u.mid).then((space: UserSpaceInfo | null) => {
        if (space === null || space.pendant.length === 0 || UserStore.user !== u) return;
        u.pendant = space.pendant;
        AppStorage.setOrCreate<string>('userPendant', space.pendant);
      }).catch(() => {
        // 空间装扮拉取失败不影响登录态，下次刷新再补齐。
      });
    }
    return u;
  }

  /** 写入登录 cookie 并刷新状态；广播 loginVersion 让各页面重载（Tabs 保活的视图不会再次 aboutToAppear） */
  static async applyLoginCookies(cookies: Array<CookiePair>, accessToken: string = '',
    refreshToken: string = ''): Promise<void> {
    UserStore.authGeneration++;
    AuthSession.advance();
    MsgUnreadStore.resetSession();
    const generation: number = UserStore.authGeneration;
    UserStore.user = null;
    UserStore.loaded = false;
    for (let i: number = 0; i < cookies.length; i++) {
      HttpClient.setCookie(cookies[i].name, cookies[i].value);
    }
    HttpClient.setAppAccessToken(accessToken);
    if (refreshToken.length > 0) UserStore.webRefreshToken = refreshToken;
    CookieRefresher.noteLogin();
    await UserStore.persistCookies(HttpClient.exportCookieJson());
    if (generation !== UserStore.authGeneration) return;
    await UserStore.persistAccessToken(accessToken);
    if (generation !== UserStore.authGeneration) return;
    if (refreshToken.length > 0) await UserStore.persistRefreshToken(refreshToken);
    if (generation !== UserStore.authGeneration) return;
    await UserStore.refresh();
    if (generation !== UserStore.authGeneration) return;
    AppStorage.setOrCreate<number>('loginVersion', Date.now());
  }

  private static async persistRefreshToken(value: string): Promise<void> {
    AppStorage.setOrCreate<string>(UserStore.REFRESH_TOKEN_STORAGE_KEY, value);
    await UserStore.waitForPersistence();
    if (UserStore.authPreferences !== null) {
      UserStore.authPreferences.putSync(UserStore.REFRESH_TOKEN_STORAGE_KEY, value);
      await UserStore.authPreferences.flush();
    }
  }

  static async logout(): Promise<void> {
    // 先使在途 nav 请求失效；必须早于任何持久化 await。
    UserStore.authGeneration++;
    AuthSession.advance();
    MsgUnreadStore.resetSession();
    const generation: number = UserStore.authGeneration;
    // 从 cookie 罐中真正删除关键 cookie（置空串会让 SESSDATA=; bili_jct=; 空值对继续随请求发出）
    HttpClient.removeCookie('SESSDATA');
    HttpClient.removeCookie('bili_jct');
    HttpClient.removeCookie('DedeUserID');
    HttpClient.removeCookie('DedeUserID__ckMd5');
    HttpClient.setAppAccessToken('');
    UserStore.webRefreshToken = '';
    CookieRefresher.logout();
    // 内存与响应式状态立即退出，磁盘 flush 不应延长“仍显示已登录”的窗口。
    UserStore.user = null;
    UserStore.loaded = false;
    AppStorage.setOrCreate<string>('userAvatar', '');
    AppStorage.setOrCreate<string>('userPendant', '');
    await UserStore.persistCookies('');
    if (generation !== UserStore.authGeneration) return;
    await UserStore.persistAccessToken('');
    if (generation !== UserStore.authGeneration) return;
    await UserStore.persistRefreshToken('');
    if (generation !== UserStore.authGeneration) return;
    AppStorage.setOrCreate<number>('loginVersion', Date.now());
  }
}
