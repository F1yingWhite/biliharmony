/**
 * 登录与认证 API：TV 扫码、密码登录和短信登录。
 */
import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { appSign } from '../common/AppSign';
import { Api, Constants } from '../common/Constants';
import { md5Hex } from '../common/Md5';
import { RsaUtil } from '../common/RsaUtil';
import { asArray, asNumber, asObject, asString, randomString } from '../common/Utils';
import { getData } from './internal/ApiCommon';

export class CookiePair {
  name: string;
  value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

export class TVCodeResult {
  authCode: string = '';
  url: string = '';
}

export class TVPollResult {
  code: number = 0;
  message: string = '';
  cookies: Array<CookiePair> = [];
  mid: number = 0;
  accessToken: string = '';
}

export class WebQrCode {
  qrcodeKey: string = '';
  url: string = '';
}

export class WebQrPollResult {
  code: number = -1;
  message: string = '';
  /** 登录成功时下发，Cookie 自动续期（CookieRefresher）必需。 */
  refreshToken: string = '';
}

export class LoginWebKey {
  hash: string = '';
  key: string = '';
}

export class LoginResult {
  code: number = -1;
  message: string = '';
  dataStatus: number = 0;
  cookies: Array<CookiePair> = [];
  accessToken: string = '';
}

export class SmsSendResult {
  code: number = -1;
  message: string = '';
  captchaKey: string = '';
  needCaptcha: boolean = false;
  /** -352 类风控时下发的验证凭证：走 gaia-vgate + 极验滑块后携 grisk_id 重试。 */
  vVoucher: string = '';
}

export class GaiaRegisterResult {
  token: string = '';
  gt: string = '';
  challenge: string = '';
}

export class GaiaValidateResult {
  ok: boolean = false;
  griskId: string = '';
}

/** 极验校验三元组（滑块通过后由 Web 容器回传）。 */
export class GeetestAnswer {
  challenge: string = '';
  validate: string = '';
  seccode: string = '';
}

export class AuthApi {
  /**
   * Web 扫码登录：与 TV 扫码相比，轮询确认后经 Set-Cookie 下发完整 Web Cookie，
   * 并在响应体返回 refresh_token —— 这是 Cookie 自动续期（CookieRefresher）的前提。
   */
  static async getWebQRCode(): Promise<WebQrCode | null> {
    const resp: HttpResponse = await HttpClient.get(Api.webQrGenerate, Constants.webHeaders);
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return null;
    const result: WebQrCode = new WebQrCode();
    result.url = asString(data['url'], '');
    result.qrcodeKey = asString(data['qrcode_key'], '');
    return result.url.length > 0 && result.qrcodeKey.length > 0 ? result : null;
  }

  static async pollWebQRCode(qrcodeKey: string): Promise<WebQrPollResult> {
    const result: WebQrPollResult = new WebQrPollResult();
    const resp: HttpResponse = await HttpClient.get(
      Api.webQrPoll + '?' + HttpClient.buildQuery({ 'qrcode_key': qrcodeKey }), Constants.webHeaders);
    if (!resp.ok) {
      result.message = resp.status < 0 ? resp.transportMessage : '网络请求失败 (' + String(resp.status) + ')';
      return result;
    }
    const json: Record<string, Object> = resp.json();
    const data: Record<string, Object> = asObject(json['data']);
    result.code = asNumber(data['code'], -1);
    result.message = asString(data['message'], '');
    if (result.code === 0) {
      result.refreshToken = asString(data['refresh_token'], '');
    }
    return result;
  }

  static async getTVCode(): Promise<TVCodeResult | null> {
    const params: Record<string, string> = {
      'local_id': '0', 'platform': 'android', 'mobi_app': 'android_hd',
    };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.getTVCode, HttpClient.buildQuery(params),
      HttpClient.merge(Constants.appHeaders, {}));
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return null;
    const result: TVCodeResult = new TVCodeResult();
    result.authCode = asString(data['auth_code'], '');
    result.url = asString(data['url'], '');
    return result;
  }

  static async pollTVCode(authCode: string): Promise<TVPollResult> {
    const params: Record<string, string> = { 'auth_code': authCode, 'local_id': '0' };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.qrcodePoll, HttpClient.buildQuery(params),
      HttpClient.merge(Constants.appHeaders, {}));
    if (!resp.ok) {
      const result: TVPollResult = new TVPollResult();
      // code 默认 0 会被调用方（Login.poll 以 code===0 判定登录成功）误判，网络失败必须置非 0。
      result.code = resp.status < 0 ? -1 : resp.status;
      result.message = resp.status < 0 ? resp.transportMessage : '网络请求失败 (' + String(resp.status) + ')';
      return result;
    }
    const json: Record<string, Object> = resp.json();
    const result: TVPollResult = new TVPollResult();
    result.code = asNumber(json['code'], -1);
    result.message = asString(json['message'], '');
    const data: Record<string, Object> = asObject(json['data']);
    result.mid = asNumber(data['mid'], 0);
    result.accessToken = asString(data['access_token'], asString(asObject(data['token_info'])['access_token'], ''));
    const cookies: Array<Object> = asArray(asObject(data['cookie_info'])['cookies']);
    for (let i: number = 0; i < cookies.length; i++) {
      const cookie: Record<string, Object> = asObject(cookies[i]);
      result.cookies.push(new CookiePair(asString(cookie['name'], ''), asString(cookie['value'], '')));
    }
    return result;
  }

  static async getLoginWebKey(): Promise<LoginWebKey | null> {
    const resp: HttpResponse = await HttpClient.get(Api.loginWebKey, AuthApi.loginHeaders());
    const data: Record<string, Object> | null = getData(resp);
    if (data === null) return null;
    const result: LoginWebKey = new LoginWebKey();
    result.hash = asString(data['hash'], '');
    result.key = asString(data['key'], '');
    return result.key.length === 0 ? null : result;
  }

  static async loginByPassword(username: string, password: string): Promise<LoginResult> {
    const result: LoginResult = new LoginResult();
    const webKey: LoginWebKey | null = await AuthApi.getLoginWebKey();
    if (webKey === null) {
      result.message = '获取登录密钥失败，请检查网络';
      return result;
    }
    let encryptedPassword: string = '';
    let deviceToken: string = '';
    try {
      encryptedPassword = await RsaUtil.encryptWithPublicKey(webKey.key, webKey.hash + password);
      deviceToken = await RsaUtil.encryptWithPublicKey(webKey.key, randomString(16));
    } catch (e) {
      result.message = '密码加密失败';
      return result;
    }
    const deviceId: string = await getLoginDeviceId();
    const buvid: string = HttpClient.buvid;
    const params: Record<string, string> = {
      'bili_local_id': deviceId, 'build': '2001100', 'buvid': buvid, 'c_locale': 'zh_CN',
      'channel': 'master', 'device': 'phone', 'device_id': deviceId, 'device_name': 'HarmonyOS',
      'device_platform': 'HarmonyOS', 'disable_rcmd': '0', 'dt': deviceToken,
      'from_pv': 'main.homepage.avatar-nologin.all.click', 'from_url': 'bilibili://pegasus/promo',
      'local_id': buvid, 'mobi_app': 'android_hd', 'password': encryptedPassword, 'permission': 'ALL',
      'platform': 'android', 's_locale': 'zh_CN', 'statistics': Constants.statistics, 'username': username,
    };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.loginByPassword, HttpClient.buildQuery(params),
      AuthApi.loginHeaders());
    return parseLoginResult(resp, result);
  }

  static async sendSmsCode(tel: string, gaiaToken: string = '',
    geetest: GeetestAnswer | null = null): Promise<SmsSendResult> {
    const result: SmsSendResult = new SmsSendResult();
    const buvid: string = HttpClient.buvid;
    const params: Record<string, string> = {
      'build': '2001100', 'buvid': buvid, 'c_locale': 'zh_CN', 'channel': 'master', 'cid': '86',
      'disable_rcmd': '0', 'local_id': buvid, 'login_session_id': await md5Hex(buvid + String(Date.now())),
      'mobi_app': 'android_hd', 'platform': 'android', 's_locale': 'zh_CN',
      'statistics': Constants.statistics, 'tel': tel,
    };
    if (gaiaToken.length > 0) params['recaptcha_token'] = gaiaToken;
    if (geetest !== null) {
      params['gee_challenge'] = geetest.challenge;
      params['gee_validate'] = geetest.validate;
      params['gee_seccode'] = geetest.seccode;
    }
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.smsSend, HttpClient.buildQuery(params), AuthApi.loginHeaders());
    if (!resp.ok) {
      // 网络失败时 resp.json() 静默返回 {}，必须先行拦截给出可读文案（code 保持默认 -1 即失败）。
      result.message = resp.status < 0 ? resp.transportMessage : '网络请求失败 (' + String(resp.status) + ')';
      return result;
    }
    const json: Record<string, Object> = resp.json();
    result.code = asNumber(json['code'], -1);
    result.message = asString(json['message'], '');
    const data: Record<string, Object> = asObject(json['data']);
    result.needCaptcha = asString(data['recaptcha_url'], '').length > 0;
    result.vVoucher = asString(data['v_voucher'], '');
    if (result.code === 0 && !result.needCaptcha) result.captchaKey = asString(data['captcha_key'], '');
    return result;
  }

  /** gaia-vgate 注册：用风控响应里的 v_voucher 换取极验 gt/challenge 与验证 token。 */
  static async gaiaVgateRegister(vVoucher: string): Promise<GaiaRegisterResult | null> {
    for (let i: number = 0; i < Api.gaiaVgateRegisterList.length; i++) {
      const resp: HttpResponse = await HttpClient.post(Api.gaiaVgateRegisterList[i],
        HttpClient.buildQuery({ 'v_voucher': vVoucher }), AuthApi.loginHeaders());
      if (!resp.ok) continue;
      const json: Record<string, Object> = resp.json();
      const code: number = asNumber(json['code'], -1);
      if (code === -404) continue;
      if (code !== 0) return null;
      const data: Record<string, Object> = asObject(json['data']);
      const geetest: Record<string, Object> = asObject(data['geetest']);
      const result: GaiaRegisterResult = new GaiaRegisterResult();
      result.token = asString(data['token'], '');
      result.gt = asString(geetest['gt'], '');
      result.challenge = asString(geetest['challenge'], '');
      if (result.token.length > 0 && result.gt.length > 0 && result.challenge.length > 0) return result;
      return null;
    }
    return null;
  }

  /** gaia-vgate 校验：滑块答案换取 grisk_id（重试原请求时作为 recaptcha_token 携带）。 */
  static async gaiaVgateValidate(token: string, answer: GeetestAnswer): Promise<GaiaValidateResult> {
    const result: GaiaValidateResult = new GaiaValidateResult();
    const params: Record<string, string> = {
      'challenge': answer.challenge, 'seccode': answer.seccode,
      'token': token, 'validate': answer.validate,
    };
    for (let i: number = 0; i < Api.gaiaVgateValidateList.length; i++) {
      const resp: HttpResponse = await HttpClient.post(Api.gaiaVgateValidateList[i],
        HttpClient.buildQuery(params), AuthApi.loginHeaders());
      if (!resp.ok) continue;
      const json: Record<string, Object> = resp.json();
      const code: number = asNumber(json['code'], -1);
      if (code === -404) continue;
      if (code !== 0) return result;
      const data: Record<string, Object> = asObject(json['data']);
      result.ok = asNumber(data['is_valid'], 0) === 1;
      result.griskId = asString(data['grisk_id'], '');
      return result;
    }
    return result;
  }

  static async loginBySms(tel: string, code: string, captchaKey: string): Promise<LoginResult> {
    const result: LoginResult = new LoginResult();
    let deviceToken: string = '';
    const webKey: LoginWebKey | null = await AuthApi.getLoginWebKey();
    if (webKey !== null) {
      try {
        deviceToken = await RsaUtil.encryptWithPublicKey(webKey.key, randomString(16));
      } catch (e) {
        // 设备令牌不是短信登录的必填参数。
      }
    }
    const deviceId: string = await getLoginDeviceId();
    const buvid: string = HttpClient.buvid;
    const params: Record<string, string> = {
      'bili_local_id': deviceId, 'build': '2001100', 'buvid': buvid, 'c_locale': 'zh_CN',
      'captcha_key': captchaKey, 'channel': 'master', 'cid': '86', 'code': code, 'device': 'phone',
      'device_id': deviceId, 'device_name': 'HarmonyOS', 'device_platform': 'HarmonyOS',
      'disable_rcmd': '0', 'dt': deviceToken, 'from_pv': 'main.my-information.my-login.0.click',
      'from_url': 'bilibili://user_center/mine', 'local_id': buvid, 'mobi_app': 'android_hd',
      'platform': 'android', 's_locale': 'zh_CN', 'statistics': Constants.statistics, 'tel': tel,
    };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.loginBySms, HttpClient.buildQuery(params), AuthApi.loginHeaders());
    return parseLoginResult(resp, result);
  }

  private static loginHeaders(): Record<string, string> {
    return HttpClient.merge(Constants.appHeaders, { 'buvid': HttpClient.buvid });
  }
}

let loginDeviceId: string = '';

async function getLoginDeviceId(): Promise<string> {
  if (loginDeviceId.length === 0) loginDeviceId = await md5Hex(randomString(64));
  return loginDeviceId;
}

function parseLoginResult(resp: HttpResponse, result: LoginResult): LoginResult {
  if (!resp.ok) {
    // 网络失败时 resp.json() 静默返回 {}，会表现为“空白错误”；拦截后透出真实原因（code 保持默认 -1）。
    result.message = resp.status < 0 ? resp.transportMessage : '网络请求失败 (' + String(resp.status) + ')';
    return result;
  }
  const json: Record<string, Object> = resp.json();
  result.code = asNumber(json['code'], -1);
  result.message = asString(json['message'], '');
  const data: Record<string, Object> = asObject(json['data']);
  result.dataStatus = asNumber(data['status'], 0);
  result.accessToken = asString(asObject(data['token_info'])['access_token'], '');
  const cookies: Array<Object> = asArray(asObject(data['cookie_info'])['cookies']);
  for (let i: number = 0; i < cookies.length; i++) {
    const cookie: Record<string, Object> = asObject(cookies[i]);
    result.cookies.push(new CookiePair(asString(cookie['name'], ''), asString(cookie['value'], '')));
  }
  return result;
}
