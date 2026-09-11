/**
 * HTTP 客户端封装：基于 @ohos.net.http，附带简单 Cookie 罐
 */
import { http } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { asObject, asString } from '../../common/Utils';
import { Constants } from '../../common/Constants';
import { CredentialPolicy } from './CredentialPolicy';
import { AuthSession } from '../auth/AuthSession';

export class HttpResponse {
  status: number;
  body: string;
  headers: Record<string, string>;
  /** 平台网络错误码；HTTP/业务失败与账号切换不使用此字段。 */
  transportCode: number;

  constructor(status: number, body: string, headers: Record<string, string>, transportCode: number = 0) {
    this.status = status;
    this.body = body;
    this.headers = headers;
    this.transportCode = transportCode;
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  get transportMessage(): string {
    switch (this.transportCode) {
      case 2300005:
      case 2300006:
        return '无法解析服务器地址，请检查网络后重试';
      case 2300007:
        return '无法连接服务器，请稍后重试';
      case 2300028:
        return '请求超时，请稍后重试';
      case 2300058:
      case 2300060:
      case 2300077:
        return '安全连接验证失败，请检查系统时间与网络';
      case 2300063:
        return '返回内容过大，暂时无法加载';
      default:
        return '网络请求失败，请稍后重试';
    }
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

/** 每次请求独立保存错误，避免并发请求覆盖诊断信息。 */
class HttpExecution {
  response: http.HttpResponse | null;
  transportCode: number;

  constructor(response: http.HttpResponse | null, transportCode: number = 0) {
    this.response = response;
    this.transportCode = transportCode;
  }
}

export class HttpClient {
  /**
   * 可选 HTTP 代理（形如 `http://127.0.0.1:7897`），供网络受限环境下访问境外站点。
   * 以 AppStorage 的 `netProxy` 为准，**默认为空 → 完全不设置 usingProxy**，
   * 因此不配置代理时所有请求行为与历史版本逐字节一致。
   */
  static readonly KEY_PROXY: string = 'netProxy';

  static proxy(): string {
    try {
      const value: string | undefined = AppStorage.get<string>(HttpClient.KEY_PROXY);
      return value === undefined ? '' : value;
    } catch (e) {
      return '';
    }
  }

  static setProxy(value: string): void {
    AppStorage.setOrCreate<string>(HttpClient.KEY_PROXY, value.trim());
  }

  /**
   * 把 `http://主机:端口` 解析为 HttpProxy 所需的 host / port。
   * 公开给同样需要出网的非 HttpClient 通道（如 AssetDownload 的流式缓存下载）：
   * 代理解析规则只此一份，避免各通道各写一套导致行为不一致。
   * 注意 HttpProxy.host 只接受主机名，协议前缀会在匹配时被忽略，
   * 端口必须通过 port 字段单独给出，因此不能把整个 URL 塞进 host。
   * 缺省端口按协议取常见值（http 8080 / socks 1080），显式端口始终优先。
   */
  static proxyConfig(): connection.HttpProxy | null {
    const raw: string = HttpClient.proxy();
    if (raw.length === 0) return null;
    let rest: string = raw;
    let scheme: string = 'http';
    const schemeAt: number = rest.indexOf('://');
    if (schemeAt > 0) {
      scheme = rest.substring(0, schemeAt).toLowerCase();
      rest = rest.substring(schemeAt + 3);
    }
    // 去掉可能存在的路径部分
    const slashAt: number = rest.indexOf('/');
    if (slashAt >= 0) rest = rest.substring(0, slashAt);
    let host: string = rest;
    let port: number = 0;
    const colonAt: number = rest.lastIndexOf(':');
    if (colonAt > 0) {
      const parsed: number = Number.parseInt(rest.substring(colonAt + 1), 10);
      if (!Number.isNaN(parsed) && parsed > 0 && parsed <= 65535) {
        port = parsed;
        host = rest.substring(0, colonAt);
      }
    }
    if (host.length === 0) return null;
    if (port === 0) port = scheme.indexOf('socks') === 0 ? 1080 : 8080;
    return { host: host, port: port, exclusionList: [] };
  }

  private static cookieJar: Record<string, string> = {};
  // App 端互动接口（如视频点踩）使用 access_key，不能混入 Web Cookie 头。
  private static appAccessToken: string = '';
  private static initialized: boolean = false;
  private static buvidReady: boolean = false;
  /** 并发请求共用同一次 SPI 拉取；调用方必须等待 Promise 完成。 */
  private static buvidPromise: Promise<void> | null = null;

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

  private static isFallbackBuvid(value: string): boolean {
    return value.length === 34 && value.startsWith('in') && /^[A-Za-z0-9]+$/.test(value.substring(2));
  }

  private static async fetchBuvid(): Promise<void> {
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
    }
  }

  /** 从官方 spi 接口拉取真实 buvid3/buvid4（acc/info 等接口无真实 buvid 会被 -352 风控拒绝）。 */
  private static async ensureBuvid(): Promise<void> {
    if (HttpClient.buvidReady) return;
    if (HttpClient.buvidPromise !== null) {
      await HttpClient.buvidPromise;
      return;
    }
    const task: Promise<void> = HttpClient.fetchBuvid();
    HttpClient.buvidPromise = task;
    try {
      await task;
    } finally {
      if (HttpClient.buvidPromise === task) HttpClient.buvidPromise = null;
    }
  }

  /** 设置单个 cookie */
  static setCookie(name: string, value: string): void {
    HttpClient.ensureInit();
    HttpClient.cookieJar[name] = value;
    if (name === 'buvid3' && value.length > 0 && !HttpClient.isFallbackBuvid(value)) {
      HttpClient.buvidReady = true;
    }
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
      const savedBuvid3: string = asString(saved['buvid3'], '');
      HttpClient.buvidReady = savedBuvid3.length > 0 && !HttpClient.isFallbackBuvid(savedBuvid3);
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

  /** CDN 使用带签名的下载 URL；只发送 UA/Referer，不向媒体域或重定向目标暴露登录 Cookie。 */
  static getDownloadHeaders(referer: string): Record<string, string> {
    const headers: Record<string, string> = {
      'User-Agent': Constants.browserUa,
      'Referer': referer.length > 0 ? referer : 'https://www.bilibili.com/',
      'Origin': 'https://www.bilibili.com',
    };
    return headers;
  }

  private static mergeHeaders(extra?: Record<string, string>, includeCookie: boolean = false): Record<string, string> {
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

  /** 保留平台错误码；不记录可能包含 Cookie、签名或个人数据的异常文本和 URL。 */
  private static async execute(url: string, method: http.RequestMethod, dataType: http.HttpDataType,
    extraHeaders?: Record<string, string>, body?: string): Promise<HttpExecution> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const trusted: boolean = CredentialPolicy.allows(url);
      const headers: Record<string, string> = CredentialPolicy.filter(url,
        HttpClient.mergeHeaders(extraHeaders, trusted));
      if (method === http.RequestMethod.POST && headers['Content-Type'] === undefined &&
        headers['content-type'] === undefined) {
        headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8';
      }
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: 12000,
        readTimeout: 20000,
        expectDataType: dataType,
        // 带凭证的 API 禁止自动跨域重定向；公共资源仍可使用 CDN 重定向。
        maxRedirects: trusted ? 0 : 5,
      };
      if (body !== undefined) {
        options.extraData = body;
      }
      // 仅在显式配置代理时启用，默认路径不写 usingProxy（避免影响既有请求语义）。
      const proxy: connection.HttpProxy | null = HttpClient.proxyConfig();
      if (proxy !== null) {
        options.usingProxy = proxy;
      }
      return new HttpExecution(await request.request(url, options));
    } catch (e) {
      const code: number = (e as BusinessError).code;
      const transportCode: number = typeof code === 'number' && Number.isFinite(code) ? code : 0;
      console.warn('[HttpClient] transport failure code=' + String(transportCode));
      return new HttpExecution(null, transportCode);
    } finally {
      request.destroy();
    }
  }

  static async get(url: string, extraHeaders?: Record<string, string>): Promise<HttpResponse> {
    HttpClient.ensureInit();
    const trusted: boolean = CredentialPolicy.allows(url);
    const session: number = AuthSession.version;
    if (trusted) await HttpClient.ensureBuvid();
    if (trusted && session !== AuthSession.version) return new HttpResponse(-1, '', {});
    const execution: HttpExecution =
      await HttpClient.execute(url, http.RequestMethod.GET, http.HttpDataType.STRING, extraHeaders);
    const resp: http.HttpResponse | null = execution.response;
    if (resp === null) {
      return new HttpResponse(-1, '', {}, execution.transportCode);
    }
    if (trusted && session !== AuthSession.version) return new HttpResponse(-1, '', {});
    if (trusted) HttpClient.absorbCookies(resp.header);
    return new HttpResponse(resp.responseCode, resp.result as string, asObject(resp.header) as Record<string, string>);
  }

  static async post(url: string, body?: string, extraHeaders?: Record<string, string>): Promise<HttpResponse> {
    HttpClient.ensureInit();
    const trusted: boolean = CredentialPolicy.allows(url);
    const session: number = AuthSession.version;
    if (trusted) await HttpClient.ensureBuvid();
    if (trusted && session !== AuthSession.version) return new HttpResponse(-1, '', {});
    const execution: HttpExecution =
      await HttpClient.execute(url, http.RequestMethod.POST, http.HttpDataType.STRING, extraHeaders, body ?? '');
    const resp: http.HttpResponse | null = execution.response;
    if (resp === null) {
      return new HttpResponse(-1, '', {}, execution.transportCode);
    }
    if (trusted && session !== AuthSession.version) return new HttpResponse(-1, '', {});
    if (trusted) HttpClient.absorbCookies(resp.header);
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
    const execution: HttpExecution =
      await HttpClient.execute(url, http.RequestMethod.GET, http.HttpDataType.ARRAY_BUFFER, extraHeaders);
    const resp: http.HttpResponse | null = execution.response;
    return resp === null ? new ArrayBuffer(0) : resp.result as ArrayBuffer;
  }

  /** 下载二进制数据并校验 HTTP 状态（弹幕分段等需要区分失败以回退的场景）；失败返回 null */
  static async getBinary(url: string, extraHeaders?: Record<string, string>): Promise<ArrayBuffer | null> {
    HttpClient.ensureInit();
    const execution: HttpExecution =
      await HttpClient.execute(url, http.RequestMethod.GET, http.HttpDataType.ARRAY_BUFFER, extraHeaders);
    const resp: http.HttpResponse | null = execution.response;
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
