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
}

export class AuthApi {
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

  static async sendSmsCode(tel: string): Promise<SmsSendResult> {
    const result: SmsSendResult = new SmsSendResult();
    const buvid: string = HttpClient.buvid;
    const params: Record<string, string> = {
      'build': '2001100', 'buvid': buvid, 'c_locale': 'zh_CN', 'channel': 'master', 'cid': '86',
      'disable_rcmd': '0', 'local_id': buvid, 'login_session_id': await md5Hex(buvid + String(Date.now())),
      'mobi_app': 'android_hd', 'platform': 'android', 's_locale': 'zh_CN',
      'statistics': Constants.statistics, 'tel': tel,
    };
    await appSign(params);
    const resp: HttpResponse = await HttpClient.post(Api.smsSend, HttpClient.buildQuery(params), AuthApi.loginHeaders());
    const json: Record<string, Object> = resp.json();
    result.code = asNumber(json['code'], -1);
    result.message = asString(json['message'], '');
    const data: Record<string, Object> = asObject(json['data']);
    result.needCaptcha = asString(data['recaptcha_url'], '').length > 0;
    if (result.code === 0 && !result.needCaptcha) result.captchaKey = asString(data['captcha_key'], '');
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
