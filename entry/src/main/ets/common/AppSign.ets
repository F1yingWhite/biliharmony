/**
 * App 端签名：appkey + ts + 排序参数 + md5(query + appsec)
 * 移植自 PiliPlus lib/utils/app_sign.dart
 */
import { md5Hex } from './Md5';
import { Constants } from './Constants';

function encodeComponent(s: string): string {
  return encodeURIComponent(s);
}

function makeQuery(sortedKeys: Array<string>, params: Record<string, string>): string {
  let result: string = '';
  let separator: string = '';
  for (const key of sortedKeys) {
    const value: string = params[key] ?? '';
    result += separator;
    separator = '&';
    // 与 HttpClient.buildQuery 的实际发送串保持一致：空值参数也写作 key=
    result += encodeComponent(key) + '=' + encodeComponent(value);
  }
  return result;
}

/** 对参数进行 app 签名，原地修改 params（加入 appkey/ts/sign） */
export async function appSign(
  params: Record<string, string>,
  appkey: string = Constants.appKey,
  appsec: string = Constants.appSec
): Promise<void> {
  params['appkey'] = appkey;
  params['ts'] = String(Math.floor(Date.now() / 1000));
  const keys: Array<string> = Object.keys(params).sort();
  const query: string = makeQuery(keys, params);
  params['sign'] = await md5Hex(query + appsec);
}
