/**
 * 全局用户状态（登录态缓存）
 */
import { UserInfo, UserSpaceInfo } from '../model/Models';
import { BiliApi, CookiePair } from '../api/BiliApi';
import { HttpClient } from './HttpClient';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class UserStore {
  private static readonly COOKIE_STORAGE_KEY: string = 'loginCookieJar';
  private static readonly AUTH_PREFERENCES_NAME: string = 'bili_auth_state';
  private static user: UserInfo | null = null;
  private static loaded: boolean = false;
  private static authPreferences: preferences.Preferences | null = null;
  private static persistenceReady: Promise<void> | null = null;

  static get current(): UserInfo | null {
    return UserStore.user;
  }

  static get isLogin(): boolean {
    return (UserStore.user !== null && UserStore.user.isLogin) || HttpClient.getCookie('SESSDATA').length > 0;
  }

  /** 必须在页面创建前调用：恢复上次登录 Cookie，避免重启后清晰度和个性装扮退回游客态。 */
  static initPersistence(context: common.UIAbilityContext): void {
    PersistentStorage.persistProp<string>(UserStore.COOKIE_STORAGE_KEY, '');
    PersistentStorage.persistProp<string>('userAvatar', '');
    PersistentStorage.persistProp<string>('userPendant', '');
    const raw: string = AppStorage.get<string>(UserStore.COOKIE_STORAGE_KEY) ?? '';
    HttpClient.importCookieJson(raw);
    UserStore.persistenceReady = UserStore.restoreCookies(context, raw);
  }

  /**
   * Preferences 是登录态的权威副本；PersistentStorage 仅保留给页面响应式状态。
   * 启动请求必须等待这里完成，防止 nav/playurl 先以游客身份发出。
   */
  private static async restoreCookies(context: common.UIAbilityContext, legacyRaw: string): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, {
        name: UserStore.AUTH_PREFERENCES_NAME,
      });
      UserStore.authPreferences = store;
      const diskRaw: string = store.getSync(UserStore.COOKIE_STORAGE_KEY, '') as string;
      const effectiveRaw: string = diskRaw.length > 0 ? diskRaw : legacyRaw;
      HttpClient.importCookieJson(effectiveRaw);

      // 从旧版 PersistentStorage 无损迁移到显式落盘的 Preferences。
      if (diskRaw.length === 0 && legacyRaw.length > 0) {
        store.putSync(UserStore.COOKIE_STORAGE_KEY, legacyRaw);
        await store.flush();
      }
    } catch (e) {
      // Preferences 不可用时仍可沿用已导入的旧缓存，不阻断应用启动。
    }
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

  static async ensureLoaded(): Promise<UserInfo> {
    await UserStore.waitForPersistence();
    if (UserStore.loaded && UserStore.user !== null) return UserStore.user;
    return UserStore.refresh();
  }

  /** 刷新登录态（nav 接口） */
  static async refresh(): Promise<UserInfo> {
    const u: UserInfo = await BiliApi.getNav();
    UserStore.user = u;
    UserStore.loaded = true;
    AppStorage.setOrCreate<string>('userAvatar', u.isLogin ? u.face : '');
    AppStorage.setOrCreate<string>('userPendant', u.isLogin ? u.pendant : '');
    // nav 通常不返回头像挂件：先恢复登录与头像，再异步补齐空间装扮，避免阻塞首页首屏。
    if (u.isLogin && u.mid > 0 && u.pendant.length === 0) {
      BiliApi.getUserSpaceInfo(u.mid).then((space: UserSpaceInfo | null) => {
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
  static async applyLoginCookies(cookies: Array<CookiePair>): Promise<void> {
    for (let i: number = 0; i < cookies.length; i++) {
      HttpClient.setCookie(cookies[i].name, cookies[i].value);
    }
    await UserStore.persistCookies(HttpClient.exportCookieJson());
    await UserStore.refresh();
    AppStorage.setOrCreate<number>('loginVersion', Date.now());
  }

  static async logout(): Promise<void> {
    // 从 cookie 罐中真正删除关键 cookie（置空串会让 SESSDATA=; bili_jct=; 空值对继续随请求发出）
    HttpClient.removeCookie('SESSDATA');
    HttpClient.removeCookie('bili_jct');
    HttpClient.removeCookie('DedeUserID');
    HttpClient.removeCookie('DedeUserID__ckMd5');
    await UserStore.persistCookies('');
    UserStore.user = null;
    UserStore.loaded = false;
    AppStorage.setOrCreate<string>('userAvatar', '');
    AppStorage.setOrCreate<string>('userPendant', '');
    AppStorage.setOrCreate<number>('loginVersion', Date.now());
  }
}
