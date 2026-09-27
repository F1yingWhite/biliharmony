/**
 * Web 端 Cookie 自动续期。
 *
 * B 站 Web Cookie（SESSDATA）会随时间与敏感接口访问逐渐失效；B 站网页端自身的续期流程是：
 *  1. GET /x/passport-login/web/cookie/info —— 判断是否需要刷新（data.refresh）；
 *  2. correspondPath = RSA-OAEP(SHA-256)(毫秒时间戳字符串)，公钥来自
 *     GET /x/frontend/finger/spi（data.rsa_key，PEM），密文以 hex 编码拼入 URL；
 *  3. GET https://www.bilibili.com/correspond/1/{correspondPath} —— 返回的 HTML 里
 *     <div id="1-name">…</div> 即 refresh_csrf；
 *  4. POST /x/passport-login/web/cookie/refresh —— 携带旧 csrf/refresh_csrf/refresh_token，
 *     响应 Set-Cookie 下发新 SESSDATA/bili_jct（HttpClient 自动吸收），body 带新 refresh_token；
 *  5. POST /x/passport-login/web/confirm/refresh —— 用新 csrf + 旧 refresh_token 确认，
 *     旧凭证作废。
 *
 * 依赖方向：本类只依赖 HttpClient/RsaUtil/Utils，持久化经 UserStore 注册的回调完成
 * （避免 api 层 ↔ services 层循环依赖）。任何一步失败都安静返回 false——最坏情况
 * 退化为旧行为（-101 提示重新登录），绝不影响正常请求。
 */
import { HttpClient, HttpResponse } from '../network/HttpClient';
import { Constants } from '../../common/Constants';
import { RsaUtil } from '../../common/RsaUtil';
import { asBool, asNumber, asObject, asString } from '../../common/Utils';
import { util } from '@kit.ArkTS';

export class CookieRefresher {
  private static readonly COOKIE_INFO_URL: string = 'https://api.bilibili.com/x/passport-login/web/cookie/info';
  private static readonly SPI_URL: string = 'https://api.bilibili.com/x/frontend/finger/spi';
  private static readonly CORRESPOND_URL: string = 'https://www.bilibili.com/correspond/1/';
  private static readonly REFRESH_URL: string = 'https://passport.bilibili.com/x/passport-login/web/cookie/refresh';
  private static readonly CONFIRM_URL: string = 'https://passport.bilibili.com/x/passport-login/web/confirm/refresh';
  /** 冷却：无论成败 6 小时内不重复例行尝试。 */
  private static readonly THROTTLE_MS: number = 6 * 60 * 60 * 1000;
  private static lastAttemptAt: number = 0;
  private static authFailTriggered: boolean = false;
  private static inflight: Promise<boolean> | null = null;
  /** UserStore 注册：刷新成功后持久化 cookie 罐 + refresh_token；读取已保存的 refresh_token。 */
  private static persister: ((refreshToken: string) => Promise<void>) | null = null;
  private static tokenReader: (() => string) | null = null;

  static registerPersister(persist: (refreshToken: string) => Promise<void>, read: () => string): void {
    CookieRefresher.persister = persist;
    CookieRefresher.tokenReader = read;
  }

  /** 登录成功写入新 refresh_token 后同步节流基线。 */
  static noteLogin(): void {
    CookieRefresher.lastAttemptAt = Date.now();
  }

  static logout(): void {
    CookieRefresher.lastAttemptAt = 0;
    CookieRefresher.authFailTriggered = false;
  }

  /**
   * -101 时触发（每会话一次）：登录态可能只是临近过期而非失效，立即尝试续期。
   * fire-and-forget：调用方照常把 -101 透出到 UI，续期成功后下一次请求自然恢复。
   */
  static onAuthFailure(): void {
    if (CookieRefresher.authFailTriggered) return;
    CookieRefresher.authFailTriggered = true;
    CookieRefresher.maybeRefresh().catch(() => {
    });
  }

  /** 例行检查（节流 6 小时，并发合并）。 */
  static maybeRefresh(): Promise<boolean> {
    if (!CookieRefresher.isLoginCandidate()) return Promise.resolve(false);
    if (Date.now() - CookieRefresher.lastAttemptAt < CookieRefresher.THROTTLE_MS) {
      return Promise.resolve(false);
    }
    if (CookieRefresher.inflight !== null) return CookieRefresher.inflight;
    CookieRefresher.lastAttemptAt = Date.now();
    const task: Promise<boolean> = CookieRefresher.refresh().finally(() => {
      CookieRefresher.inflight = null;
    });
    CookieRefresher.inflight = task;
    return task;
  }

  private static isLoginCandidate(): boolean {
    return HttpClient.getCookie('SESSDATA').length > 0 && HttpClient.getCookie('bili_jct').length > 0;
  }

  private static async refresh(): Promise<boolean> {
    try {
      // 1. 是否需要刷新
      const info: HttpResponse = await HttpClient.get(CookieRefresher.COOKIE_INFO_URL, Constants.webHeaders);
      const infoData: Record<string, Object> | null = CookieRefresher.dataOf(info);
      if (infoData === null || !asBool(infoData['refresh'], false)) return false;

      const oldCsrf: string = HttpClient.getCookie('bili_jct');
      const oldRefreshToken: string = CookieRefresher.tokenReader !== null ? CookieRefresher.tokenReader() : '';
      if (oldCsrf.length === 0 || oldRefreshToken.length === 0) return false;

      // 2+3. correspondPath → refresh_csrf
      const refreshCsrf: string = await CookieRefresher.fetchRefreshCsrf();
      if (refreshCsrf.length === 0) return false;

      // 4. 刷新：新 Cookie 经 Set-Cookie 自动入罐
      const refreshResp: HttpResponse = await HttpClient.post(CookieRefresher.REFRESH_URL,
        HttpClient.buildQuery({
          'csrf': oldCsrf,
          'refresh_csrf': refreshCsrf,
          'refresh_token': oldRefreshToken,
          'source': 'main_web',
        }), Constants.webHeaders);
      if (!refreshResp.ok) return false;
      const refreshData: Record<string, Object> | null = CookieRefresher.dataOf(refreshResp);
      if (refreshData === null) return false;
      const newCsrf: string = HttpClient.getCookie('bili_jct');
      if (newCsrf.length === 0 || newCsrf === oldCsrf) return false;

      // 5. 确认：旧 refresh_token 作废
      const confirmResp: HttpResponse = await HttpClient.post(CookieRefresher.CONFIRM_URL,
        HttpClient.buildQuery({
          'csrf': newCsrf,
          'refresh_token': oldRefreshToken,
        }), Constants.webHeaders);
      if (!confirmResp.ok || asNumber(CookieRefresher.codeOf(confirmResp), -1) !== 0) return false;

      // 持久化：cookie 罐已被 HttpClient 吸收，这里落盘 + 保存新 refresh_token。
      const newRefreshToken: string = asString(refreshData['refresh_token'], '');
      const effectiveToken: string = newRefreshToken.length > 0 ? newRefreshToken : oldRefreshToken;
      if (CookieRefresher.persister !== null) {
        await CookieRefresher.persister(effectiveToken);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 步骤 2+3：RSA-OAEP 加密毫秒时间戳得 correspondPath，请求 correspond 页并抽取 refresh_csrf。 */
  private static async fetchRefreshCsrf(): Promise<string> {
    const pubKey: string = await CookieRefresher.fetchRsaKey();
    if (pubKey.length === 0) return '';
    const cipher: Uint8Array = await RsaUtil.encryptWithPublicKeyOAEP256(pubKey, String(Date.now()));
    if (cipher.length === 0) return '';
    // 密文以 hex 编码拼接；base64 作为个别服务端实现的兼容回退。
    const hexHtml: string = await CookieRefresher.fetchCorrespond(CookieRefresher.toHex(cipher));
    const csrf: string = CookieRefresher.extractCsrf(hexHtml);
    if (csrf.length > 0) return csrf;
    const b64: string = CookieRefresher.toBase64(cipher);
    if (b64.length === 0) return '';
    return CookieRefresher.extractCsrf(await CookieRefresher.fetchCorrespond(b64));
  }

  private static async fetchRsaKey(): Promise<string> {
    const resp: HttpResponse = await HttpClient.get(CookieRefresher.SPI_URL, Constants.webHeaders);
    if (!resp.ok) return '';
    const data: Record<string, Object> | null = CookieRefresher.dataOf(resp);
    if (data === null) return '';
    return asString(data['rsa_key'], '');
  }

  private static async fetchCorrespond(correspondPath: string): Promise<string> {
    const resp: HttpResponse = await HttpClient.get(CookieRefresher.CORRESPOND_URL + correspondPath,
      Constants.webHeaders);
    if (!resp.ok) return '';
    return resp.body;
  }

  private static extractCsrf(html: string): string {
    if (html.length === 0) return '';
    const at: number = html.indexOf('1-name');
    if (at < 0) return '';
    const open: number = html.indexOf('>', at);
    const close: number = html.indexOf('<', open + 1);
    if (open < 0 || close < 0) return '';
    const value: string = html.substring(open + 1, close).trim();
    return value.length > 0 && value.length < 128 ? value : '';
  }

  private static toHex(bytes: Uint8Array): string {
    let out: string = '';
    for (let i: number = 0; i < bytes.length; i++) {
      out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return out;
  }

  private static toBase64(bytes: Uint8Array): string {
    try {
      return new util.Base64Helper().encodeToStringSync(bytes);
    } catch (e) {
      return '';
    }
  }

  private static dataOf(resp: HttpResponse): Record<string, Object> | null {
    if (!resp.ok) return null;
    const json: Record<string, Object> | null = CookieRefresher.jsonOf(resp);
    if (json === null || asNumber(json['code'], -1) !== 0) return null;
    const data: Object = json['data'];
    if (data === null || data === undefined || typeof data !== 'object' || Array.isArray(data)) return null;
    return asObject(data);
  }

  private static codeOf(resp: HttpResponse): number {
    const json: Record<string, Object> | null = CookieRefresher.jsonOf(resp);
    return json === null ? -1 : asNumber(json['code'], -1);
  }

  private static jsonOf(resp: HttpResponse): Record<string, Object> | null {
    try {
      const parsed: Object = JSON.parse(resp.body) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
      return parsed as Record<string, Object>;
    } catch (e) {
      return null;
    }
  }
}
