/**
 * HTTP 客户端封装：基于 @ohos.net.http，附带简单 Cookie 罐
 */
import { http } from '@kit.NetworkKit';
import { asObject, asString } from './Utils';

export class HttpResponse {
  status: number;
  body: string;
  headers: Record<string, string>;

  constructor(status: number, body: string, headers: Record<string, string>) {
    this.status = status;
    this.body = body;
    this.headers = headers;
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  /** 解析 JSON body，失败返回空对象 */
  json(): Record<string, Object> {
    try {
      const parsed: Object = JSON.parse(this.body) as Object;
      return asObject(parsed);
    } catch (e) {
      return {} as Record<string, Object>;
    }
  }

  /** 解析 JSON 数组 body */
  jsonArray(): Array<Object> {
    try {
      const parsed: Object = JSON.parse(this.body) as Object;
      return parsed as Array<Object>;
    } catch (e) {
      return [] as Array<Object>;
    }
  }
}

export class HttpClient {
  private static cookieJar: Record<string, string> = {};
  private static initialized: boolean = false;
  private static buvidReady: boolean = false;
  private static buvidFetching: boolean = false;

  static get buvid(): string {
    return HttpClient.cookieJar['buvid3'] ?? '';
  }

  /** 读取登录流程写入的单个 Cookie（互动接口的 csrf 等场景使用）。 */
  static getCookie(name: string): string {
    HttpClient.ensureInit();
    return HttpClient.cookieJar[name] ?? '';
  }

  private static ensureInit(): void {
    if (!HttpClient.initialized) {
      HttpClient.initialized = true;
      // 兜底占位 buvid3（spi 拉取失败时用；伪造格式过不了风控接口，仅保证字段存在）
      const rand: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      let buv: string = '';
      for (let i: number = 0; i < 32; i++) {
        buv += rand.charAt(Math.floor(Math.random() * rand.length));
      }
      HttpClient.cookieJar['buvid3'] = 'in' + buv;
      HttpClient.cookieJar['buvid4'] = 'in' + buv;
    }
  }

  /** 从官方 spi 接口拉取真实 buvid3/buvid4（acc/info 等接口无真实 buvid 会被 -352 风控拒绝），只拉一次 */
  private static async ensureBuvid(): Promise<void> {
    if (HttpClient.buvidReady || HttpClient.buvidFetching) {
      return;
    }
    HttpClient.buvidFetching = true;
    const request: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await request.request('https://api.bilibili.com/x/frontend/finger/spi', {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
          'Accept': 'application/json, text/plain, */*',
        },
        connectTimeout: 8000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING,
      });
      const json: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
      const data: Record<string, Object> = asObject(json['data']);
      const b3: string = asString(data['b_3'], '');
      const b4: string = asString(data['b_4'], '');
      if (b3.length > 0) {
        HttpClient.cookieJar['buvid3'] = b3;
        HttpClient.cookieJar['buvid4'] = b4;
        HttpClient.buvidReady = true;
      }
    } catch (e) {
      // 失败保持兜底 buvid，下次请求重试
    } finally {
      request.destroy();
      HttpClient.buvidFetching = false;
    }
  }

  /** 设置单个 cookie */
  static setCookie(name: string, value: string): void {
    HttpClient.ensureInit();
    HttpClient.cookieJar[name] = value;
  }

  /** 导入/导出登录 Cookie，交由应用私有 PersistentStorage 保存。 */
  static exportCookieJson(): string {
    HttpClient.ensureInit();
    return JSON.stringify(HttpClient.cookieJar);
  }

  static importCookieJson(raw: string): void {
    HttpClient.ensureInit();
    if (raw.length === 0) return;
    try {
      const saved: Record<string, Object> = asObject(JSON.parse(raw) as Object);
      const keys: Array<string> = Object.keys(saved);
      for (let i: number = 0; i < keys.length; i++) {
        const value: string = asString(saved[keys[i]], '');
        if (value.length > 0) HttpClient.cookieJar[keys[i]] = value;
      }
      if ((HttpClient.cookieJar['buvid3'] ?? '').length > 0) HttpClient.buvidReady = true;
    } catch (e) {
      // 损坏的旧缓存直接忽略，后续登录会覆盖。
    }
  }

  /** 解析 Set-Cookie 头 */
  static parseSetCookie(setCookie: string): void {
    if (setCookie.length === 0) {
      return;
    }
    const parts: Array<string> = setCookie.split(',');
    for (let i: number = 0; i < parts.length; i++) {
      const part: string = parts[i].trim();
      const eq: number = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = part.substring(0, eq);
      let value: string = part.substring(eq + 1);
      const semi: number = value.indexOf(';');
      if (semi >= 0) {
        value = value.substring(0, semi);
      }
      if (value.length > 0) {
        HttpClient.setCookie(name, value);
      }
    }
  }

  private static buildCookieHeader(): string {
    HttpClient.ensureInit();
    const keys: Array<string> = Object.keys(HttpClient.cookieJar);
    let result: string = '';
    for (let i: number = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (i > 0) {
        result += '; ';
      }
      result += k + '=' + HttpClient.cookieJar[k];
    }
    return result;
  }

  private static mergeHeaders(extra?: Record<string, string>, includeCookie: boolean = true): Record<string, string> {
    const merged: Record<string, string> = {};
    // 默认 web 头
    merged['User-Agent'] = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15';
    merged['Accept'] = 'application/json, text/plain, */*';
    if (includeCookie) {
      const cookie: string = HttpClient.buildCookieHeader();
      if (cookie.length > 0) {
        merged['Cookie'] = cookie;
      }
    }
    if (extra) {
      const extraKeys: Array<string> = Object.keys(extra);
      for (let i: number = 0; i < extraKeys.length; i++) {
        merged[extraKeys[i]] = extra[extraKeys[i]];
      }
    }
    return merged;
  }

  /** 从响应头中提取 set-cookie 并合并到 cookie 罐 */
  private static absorbCookies(header: Object): void {
    if (!header) {
      return;
    }
    const h: Record<string, Object> = asObject(header);
    const sc: Object | undefined = h['set-cookie'];
    if (sc !== undefined) {
      HttpClient.parseSetCookie(asString(sc));
    }
  }

  static async get(url: string, extraHeaders?: Record<string, string>): Promise<HttpResponse> {
    HttpClient.ensureInit();
    await HttpClient.ensureBuvid();
    const request: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: HttpClient.mergeHeaders(extraHeaders),
        connectTimeout: 12000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING,
      });
      HttpClient.absorbCookies(resp.header);
      return new HttpResponse(resp.responseCode, resp.result as string, asObject(resp.header) as Record<string, string>);
    } catch (e) {
      return new HttpResponse(-1, '', {});
    } finally {
      request.destroy();
    }
  }

  static async post(url: string, body?: string, extraHeaders?: Record<string, string>): Promise<HttpResponse> {
    HttpClient.ensureInit();
    await HttpClient.ensureBuvid();
    const request: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = HttpClient.mergeHeaders(extraHeaders);
      headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8';
      const resp: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body ?? '',
        connectTimeout: 12000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING,
      });
      HttpClient.absorbCookies(resp.header);
      return new HttpResponse(resp.responseCode, resp.result as string, asObject(resp.header) as Record<string, string>);
    } catch (e) {
      return new HttpResponse(-1, '', {});
    } finally {
      request.destroy();
    }
  }

  /** 合并两个 header 表（ArkTS 不支持对象展开） */
  static merge(base: Record<string, string>, extra: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    const baseKeys: Array<string> = Object.keys(base);
    for (let i: number = 0; i < baseKeys.length; i++) {
      out[baseKeys[i]] = base[baseKeys[i]];
    }
    const extraKeys: Array<string> = Object.keys(extra);
    for (let i: number = 0; i < extraKeys.length; i++) {
      out[extraKeys[i]] = extra[extraKeys[i]];
    }
    return out;
  }

  /** 下载二进制数据（用于图片取色等） */
  static async getBytes(url: string, extraHeaders?: Record<string, string>): Promise<ArrayBuffer> {
    HttpClient.ensureInit();
    const request: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: HttpClient.mergeHeaders(extraHeaders),
        connectTimeout: 12000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      });
      return resp.result as ArrayBuffer;
    } catch (e) {
      return new ArrayBuffer(0);
    } finally {
      request.destroy();
    }
  }

  /** 构造 query string */
  static buildQuery(params: Record<string, string>): string {
    const keys: Array<string> = Object.keys(params).sort();
    let result: string = '';
    for (let i: number = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (i > 0) {
        result += '&';
      }
      result += encodeURIComponent(k) + '=' + encodeURIComponent(params[k] ?? '');
    }
    return result;
  }
}
