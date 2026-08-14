/**
 * 通用工具：JSON 安全访问、数字/时间格式化等
 */

// ===== JSON 安全访问辅助 =====
// ArkTS 严格类型下，JSON.parse 返回 Object，需要显式转换后再索引

export function asObject(v: Object | null | undefined): Record<string, Object> {
  return (v ?? {}) as Record<string, Object>;
}

export function asArray(v: Object | null | undefined): Array<Object> {
  return (v ?? []) as Array<Object>;
}

export function asString(v: Object | null | undefined, def: string = ''): string {
  return (v === null || v === undefined) ? def : String(v);
}

export function asNumber(v: Object | null | undefined, def: number = 0): number {
  if (v === null || v === undefined) {
    return def;
  }
  const n: number = Number(v);
  return Number.isNaN(n) ? def : n;
}

export function asBool(v: Object | null | undefined, def: boolean = false): boolean {
  if (v === null || v === undefined) {
    return def;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  const n: number = Number(v);
  return n === 1;
}

/** ArkUI 八位颜色使用 #AARRGGBB；为动态主题色安全添加透明度。 */
export function colorWithAlpha(color: string, alpha: string): string {
  const raw: string = color.startsWith('#') ? color.substring(1) : color;
  const rgb: string = raw.length >= 6 ? raw.substring(raw.length - 6) : 'FB7299';
  return '#' + alpha + rgb;
}

// 从 JSON 对象中取子对象
export function obj(o: Object, key: string): Record<string, Object> {
  return asObject((o as Record<string, Object>)[key]);
}

// 从 JSON 对象中取子数组
export function arr(o: Object, key: string): Array<Object> {
  return asArray((o as Record<string, Object>)[key]);
}

// 从 JSON 对象中取字符串
export function str(o: Object, key: string, def: string = ''): string {
  return asString((o as Record<string, Object>)[key], def);
}

// 从 JSON 对象中取数字
export function num(o: Object, key: string, def: number = 0): number {
  return asNumber((o as Record<string, Object>)[key], def);
}

// ===== 数字格式化 =====
// 播放量等以 万/亿 显示
export function formatCount(n: number): string {
  if (n >= 100000000) {
    return (n / 100000000).toFixed(1) + '亿';
  }
  if (n >= 10000) {
    return (n / 10000).toFixed(1) + '万';
  }
  return String(Math.floor(n));
}

// 时长 mm:ss 或 hh:mm:ss
export function formatDuration(seconds: number): string {
  const s: number = Math.floor(seconds);
  const h: number = Math.floor(s / 3600);
  const m: number = Math.floor((s % 3600) / 60);
  const sec: number = s % 60;
  if (h > 0) {
    return h + ':' + pad2(m) + ':' + pad2(sec);
  }
  return m + ':' + pad2(sec);
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

// 时间戳(秒) → 相对时间
export function formatRelativeTime(timestamp: number): string {
  const now: number = Math.floor(Date.now() / 1000);
  const diff: number = now - timestamp;
  if (diff < 0) {
    return '刚刚';
  }
  if (diff < 60) {
    return '刚刚';
  }
  if (diff < 3600) {
    return Math.floor(diff / 60) + '分钟前';
  }
  if (diff < 86400) {
    return Math.floor(diff / 3600) + '小时前';
  }
  if (diff < 2592000) {
    return Math.floor(diff / 86400) + '天前';
  }
  const d: Date = new Date(timestamp * 1000);
  return (d.getFullYear()) + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

// 时间戳(秒) → 完整日期
export function formatDate(timestamp: number): string {
  const d: Date = new Date(timestamp * 1000);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

// 生成随机字符串（用于 buvid 等）
export function randomString(len: number): string {
  const chars: string = '0123456789abcdef';
  let result: string = '';
  for (let i: number = 0; i < len; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

// 简单 buvid 生成（真实 buvid 算法较复杂，此处模拟格式）
export function generateBuvid(): string {
  const rand: string = randomString(32);
  return 'XX' + rand.toUpperCase();
}

// URL 编码（与 encodeURIComponent 一致，用于签名）
export function urlEncode(s: string): string {
  return encodeURIComponent(s);
}

// http → https（鸿蒙默认安全网络策略，且 B 站 CDN 支持 https）
export function toHttps(url: string): string {
  // 搜索接口的 pic/face 经常返回 //i0.hdslb.com/...；ArkUI Image 不会自动补协议。
  if (url.startsWith('//')) {
    return 'https:' + url;
  }
  if (url.startsWith('http://')) {
    return 'https://' + url.substring(7);
  }
  return url;
}
