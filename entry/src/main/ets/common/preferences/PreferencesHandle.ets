/**
 * Preferences 单值句柄：把 UserStore / SponsorBlock / EmoteResolver 各自手写的
 * 「open → getSync → putSync → flush」单例样板收敛为一处。
 *
 * 统一约定：
 * - 布尔固定 'true'/'false' 序列化，数值经 String() 落盘、Number() 读回并做 NaN 兜底；
 * - 普通写入（putString/putBool/putNumber）走尾部防抖 flush（与 AppTheme 先例一致）；
 * - 关键写入（putStringNow/flushNow）立即 flush 并等它完成——登录 Cookie 这类
 *   「必须存活到磁盘」的状态不能接受 400ms 的丢失窗口；
 * - open(name) 按文件名缓存句柄：同一个 Preferences 文件全局只 open 一次。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class PreferencesHandle {
  /** flush 尾部防抖（毫秒）。 */
  private static readonly FLUSH_DEBOUNCE_MS: number = 400;
  /** 已创建句柄缓存：键为 Preferences 文件名。 */
  private static readonly opened: Map<string, PreferencesHandle> = new Map<string, PreferencesHandle>();

  private readonly prefName: string;
  private store: preferences.Preferences | null = null;
  private flushTimer: number = -1;

  private constructor(prefName: string) {
    this.prefName = prefName;
  }

  /** 取（或建）指定 Preferences 文件的句柄；随后用 bind 完成实际打开。 */
  static open(name: string): PreferencesHandle {
    const existing: PreferencesHandle | undefined = PreferencesHandle.opened.get(name);
    if (existing !== undefined) return existing;
    const handle: PreferencesHandle = new PreferencesHandle(name);
    PreferencesHandle.opened.set(name, handle);
    return handle;
  }

  /** 异步打开（启动路径）；返回 false 表示 Preferences 不可用，后续读写全部按空值兜底。 */
  async bind(context: common.UIAbilityContext): Promise<boolean> {
    if (this.store !== null) return true;
    try {
      this.store = await preferences.getPreferences(context, { name: this.prefName });
      return true;
    } catch (e) {
      this.store = null;
      return false;
    }
  }

  /** 是否已成功打开：未绑定时写入是 no-op、读取返回空/兜底值。 */
  isBound(): boolean {
    return this.store !== null;
  }

  /** 读字符串：未绑定或缺键返回空串（空串即「无值」，与 getSync 缺省 '' 的口径一致）。 */
  getString(key: string): string {
    const store: preferences.Preferences | null = this.store;
    if (store === null) return '';
    try {
      return store.getSync(key, '') as string;
    } catch (e) {
      return '';
    }
  }

  /** 读布尔（'true'/'false' 序列化约定）：缺键返回 null，调用方据此保留默认值。 */
  getBool(key: string): boolean | null {
    const raw: string = this.getString(key);
    if (raw.length === 0) return null;
    return raw === 'true';
  }

  /** 读数值：空串/NaN 一律回落到兜底值（沿用 Number() + isNaN 的统计口径）。 */
  getNumber(key: string, fallback: number): number {
    const raw: string = this.getString(key);
    if (raw.length === 0) return fallback;
    const value: number = Number(raw);
    return Number.isNaN(value) ? fallback : value;
  }

  /** 写字符串并调度防抖 flush；Preferences 未绑定时静默跳过。 */
  putString(key: string, value: string): void {
    const store: preferences.Preferences | null = this.store;
    if (store === null) return;
    try {
      store.putSync(key, value);
    } catch (e) {
      return;
    }
    this.scheduleFlush();
  }

  /** 写布尔：固定 'true'/'false' 序列化。 */
  putBool(key: string, value: boolean): void {
    this.putString(key, value ? 'true' : 'false');
  }

  /** 写数值：String() 序列化。 */
  putNumber(key: string, value: number): void {
    this.putString(key, String(value));
  }

  /** 写字符串并立即等 flush 完成：登录态等关键写入用，防止杀进程时只落在内存。 */
  async putStringNow(key: string, value: string): Promise<void> {
    const store: preferences.Preferences | null = this.store;
    if (store === null) return;
    try {
      store.putSync(key, value);
    } catch (e) {
      return;
    }
    await this.flushNow();
  }

  /** 立即 flush 并等它完成（取消挂起的防抖，避免同一次落盘做两遍）。 */
  async flushNow(): Promise<void> {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    const store: preferences.Preferences | null = this.store;
    if (store === null) return;
    try {
      await store.flush();
    } catch (e) {
      // flush 失败内存副本仍在；关键状态由下一次写入重试落盘。
    }
  }

  private scheduleFlush(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      const target: preferences.Preferences | null = this.store;
      if (target === null) return;
      try {
        target.flush().catch(() => {
          // 磁盘同步失败只丢一次落盘时机，Preferences 内存副本仍是新的。
        });
      } catch (e) {
        // 同上：写盘失败不影响内存态。
      }
    }, PreferencesHandle.FLUSH_DEBOUNCE_MS);
  }
}
