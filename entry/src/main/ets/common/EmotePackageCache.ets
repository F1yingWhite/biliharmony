/** 表情包目录按账号和业务隔离；已有目录立即返回，过期后后台刷新。图片仍由 EmoteImageCache 落盘。 */
export class EmotePackageCache {
  /** 已校验的目录（解析后的数组）：命中后不再解析 raw，调用方也无需二次 JSON.parse。 */
  private static validated: Map<string, Array<Object>> = new Map<string, Array<Object>>();
  /** 目录落盘时间（毫秒）：用于 24h 过期刷新判断，避免每次解析 raw 取 at。 */
  private static storedAt: Map<string, number> = new Map<string, number>();
  private static pending: Map<string, Promise<Array<Object>>> = new Map<string, Promise<Array<Object>>>();
  private static attempted: Map<string, number> = new Map<string, number>();
  private static read: ((key: string) => string) | null = null;
  private static write: ((key: string, value: string) => void) | null = null;

  static configure(read: (key: string) => string, write: (key: string, value: string) => void): void {
    EmotePackageCache.read = read;
    EmotePackageCache.write = write;
  }

  /** 获取表情目录（已解析）。解析/校验只做一次；损坏缓存与刷新失败都返回空数组。 */
  static async get(key: string, fetch: () => Promise<string>): Promise<Array<Object>> {
    const known: Array<Object> | undefined = EmotePackageCache.validated.get(key);
    if (known !== undefined) {
      EmotePackageCache.maybeRefresh(key, fetch);
      return known;
    }
    let raw: string = '';
    if (EmotePackageCache.read !== null) {
      try { raw = EmotePackageCache.read(key); } catch (e) {}
    }
    let cached: string = '';
    let at: number = 0;
    try {
      const record: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      cached = String(record['data'] ?? '');
      at = Number(record['at'] ?? 0);
    } catch (e) { cached = ''; }
    if (cached.length > 0) {
      const parsed: Array<Object> | null = EmotePackageCache.parseCatalog(cached);
      if (parsed !== null) {
        EmotePackageCache.validated.set(key, parsed);
        EmotePackageCache.storedAt.set(key, at);
        EmotePackageCache.maybeRefresh(key, fetch);
        return parsed;
      }
    }
    return EmotePackageCache.refresh(key, fetch);
  }

  /** 目录必须是 JSON 数组；解析失败返回 null。 */
  private static parseCatalog(raw: string): Array<Object> | null {
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      return Array.isArray(parsed) ? parsed as Array<Object> : null;
    } catch (e) {
      return null;
    }
  }

  /** 过期（24h）且距上次尝试超过 60s 时后台刷新；结果立即返回，不阻塞调用方。 */
  private static maybeRefresh(key: string, fetch: () => Promise<string>): void {
    const at: number = EmotePackageCache.storedAt.get(key) ?? 0;
    const now: number = Date.now();
    if (now - at > 24 * 60 * 60 * 1000 && now - (EmotePackageCache.attempted.get(key) ?? 0) > 60000) {
      EmotePackageCache.refresh(key, fetch).catch(() => {});
    }
  }

  private static async refresh(key: string, fetch: () => Promise<string>): Promise<Array<Object>> {
    const running: Promise<Array<Object>> | undefined = EmotePackageCache.pending.get(key);
    if (running !== undefined) return running;
    EmotePackageCache.attempted.set(key, Date.now());
    const task: Promise<Array<Object>> = (async (): Promise<Array<Object>> => {
      const data: string = await fetch();
      // 空结果和错误都不覆盖已有目录，弱网时仍能使用已缓存表情。
      if (data.length > 0) {
        const now: number = Date.now();
        const raw: string = JSON.stringify({ at: now, data: data });
        if (EmotePackageCache.write !== null) {
          try { EmotePackageCache.write(key, raw); } catch (e) {}
        }
        // 只有结构正确的结果才进热缓存；脏数据下次 get 会重新走校验/刷新。
        const parsed: Array<Object> | null = EmotePackageCache.parseCatalog(data);
        if (parsed !== null) {
          EmotePackageCache.validated.set(key, parsed);
          EmotePackageCache.storedAt.set(key, now);
          return parsed;
        }
      }
      // 刷新失败回退旧目录（等待期间可能有别的实例写入）。
      return EmotePackageCache.validated.get(key) ?? [] as Array<Object>;
    })();
    EmotePackageCache.pending.set(key, task);
    try { return await task; } finally { EmotePackageCache.pending.delete(key); }
  }
}
