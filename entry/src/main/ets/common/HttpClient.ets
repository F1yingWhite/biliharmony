/**
 * HTTP 客户端封装：基于 @ohos.net.http，附带简单 Cookie 罐
 */
import { http } from '@kit.NetworkKit';
import { asObject, asString } from './Utils';
import { Constants } from './Constants';

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

  /** 解析 JSON 数组 body；body 非数组（如 JSON 对象）时返回空数组 */
  jsonArray(): Array<Object> {
    try {
      const parsed: Object = JSON.parse(this.body) as Object;
      return Array.isArray(parsed) ? parsed as Array<Object> : [] as Array<Object>;
    } catch (e) {
      return [] as Array<Object>;
    }
  }
}

export class HttpClient {
  private static cookieJar: Record<string, string> = {};
  // App 端互动接口（如视频点踩）使用 access_key，不能混入 Web Cookie 头。
  private static appAccessToken: string = '';
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

  static getAppAccessToken(): string {
    return HttpClient.appAccessToken;
  }

  static setAppAccessToken(value: string): void {
    HttpClient.appAccessToken = value;
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
          'User-Agent': Constants.browserUa,
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

  /** 从 cookie 罐中真正删除（登出用）。ArkTS 对 Record 不用 delete，重建剔除。 */
  static removeCookie(name: string): void {
    HttpClient.ensureInit();
    const jar: Record<string, string> = {};
    const keys: Array<string> = Object.keys(HttpClient.cookieJar);
    for (let i: number = 0; i < keys.length; i++) {
      if (keys[i] !== name) {
        jar[keys[i]] = HttpClient.cookieJar[keys[i]];
      }
    }
    HttpClient.cookieJar = jar;
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
    // 不能按 ',' 直接切：Expires=Wed, 21 Oct 2015 07:28:00 GMT 内含逗号。
    // 真实分隔是“逗号 + 空白 + 新 cookie 的 name=”，lookahead 保证只在 name=value 前断开。
    const parts: Array<string> = setCookie.split(/,\s+(?=[^;,]+=)/);
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
    merged['User-Agent'] = Constants.browserUa;
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

  /** create-try-finally-destroy 公共脚手架：成功返回原始响应，网络异常返回 null */
  private static async execute(url: string, method: http.RequestMethod, dataType: http.HttpDataType,
    extraHeaders?: Record<string, string>, body?: string): Promise<http.HttpResponse | null> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = HttpClient.mergeHeaders(extraHeaders);
      if (method === http.RequestMethod.POST) {
        headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8';
      }
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: 12000,
        readTimeout: 20000,
        expectDataType: dataType,
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      return await request.request(url, options);
    } catch (e) {
      return null;
    } finally {
      request.destroy();
    }
  }

  static async get(url: string, extraHeaders?: Record<string, string>): Promise<HttpResponse> {
    HttpClient.ensureInit();
    await HttpClient.ensureBuvid();
    const resp: http.HttpResponse | null =
      await HttpClient.execute(url, http.RequestMethod.GET, http.HttpDataType.STRING, extraHeaders);
    if (resp === null) {
      return new HttpResponse(-1, '', {});
    }
    HttpClient.absorbCookies(resp.header);
    return new HttpResponse(resp.responseCode, resp.result as string, asObject(resp.header) as Record<string, string>);
  }

  static async post(url: string, body?: string, extraHeaders?: Record<string, string>): Promise<HttpResponse> {
    HttpClient.ensureInit();
    await HttpClient.ensureBuvid();
    const resp: http.HttpResponse | null =
      await HttpClient.execute(url, http.RequestMethod.POST, http.HttpDataType.STRING, extraHeaders, body ?? '');
    if (resp === null) {
      return new HttpResponse(-1, '', {});
    }
    HttpClient.absorbCookies(resp.header);
    return new HttpResponse(resp.responseCode, resp.result as string, asObject(resp.header) as Record<string, string>);
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
    const resp: http.HttpResponse | null =
      await HttpClient.execute(url, http.RequestMethod.GET, http.HttpDataType.ARRAY_BUFFER, extraHeaders);
    return resp === null ? new ArrayBuffer(0) : resp.result as ArrayBuffer;
  }

  /** 下载二进制数据并校验 HTTP 状态（弹幕分段等需要区分失败以回退的场景）；失败返回 null */
  static async getBinary(url: string, extraHeaders?: Record<string, string>): Promise<ArrayBuffer | null> {
    HttpClient.ensureInit();
    const resp: http.HttpResponse | null =
      await HttpClient.execute(url, http.RequestMethod.GET, http.HttpDataType.ARRAY_BUFFER, extraHeaders);
    if (resp === null || resp.responseCode < 200 || resp.responseCode >= 300) {
      return null;
    }
    return resp.result as ArrayBuffer;
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
