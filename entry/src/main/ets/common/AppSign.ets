/**
 * App 端签名：appkey + ts + 排序参数 + md5(query + appsec)
 * 移植自 PiliPlus lib/utils/app_sign.dart
 */
import { md5Hex } from './Md5';
import { Constants } from './Constants';
// 依赖方向与 WbiSign.ets 一致：common → services/network，无环（HttpClient 不反向依赖 common 的签名模块）。
import { HttpClient } from '../services/network/HttpClient';

/** 对参数进行 app 签名，原地修改 params（加入 appkey/ts/sign） */
export async function appSign(
  params: Record<string, string>,
  appkey: string = Constants.appKey,
  appsec: string = Constants.appSec
): Promise<void> {
  params['appkey'] = appkey;
  params['ts'] = String(Math.floor(Date.now() / 1000));
  // 签名串与实际发送串必须逐字节一致，直接复用 HttpClient.buildQuery（排序/空值/转义只有一份实现）。
  const query: string = HttpClient.buildQuery(params);
  params['sign'] = await md5Hex(query + appsec);
}
