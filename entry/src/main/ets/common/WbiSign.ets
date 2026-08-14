/**
 * WBI 签名：用于 REST API 的 w_rid / wts 字段
 * 移植自 PiliPlus lib/utils/wbi_sign.dart
 * 参考: https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/wbi.md
 */
import { md5Hex } from './Md5';
import { HttpClient, HttpResponse } from './HttpClient';
import { Api } from './Constants';
import { asObject, str } from './Utils';

export class WbiSign {
  private static mixinKey: string = '';
  private static cacheDay: number = -1;
  private static pending: Promise<string> | null = null;

  private static readonly mixinKeyEncTab: Array<number> = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  ];

  // 对 imgKey/subKey 拼接串做字符重排
  private static computeMixinKey(orig: string): string {
    let result: string = '';
    for (let i: number = 0; i < WbiSign.mixinKeyEncTab.length; i++) {
      const idx: number = WbiSign.mixinKeyEncTab[i];
      result += orig.charAt(idx);
    }
    return result;
  }

  // 从 url 提取不带扩展名的文件名
  private static fileNameWithoutExt(url: string): string {
    let u: string = url;
    const qIdx: number = u.indexOf('?');
    if (qIdx >= 0) {
      u = u.substring(0, qIdx);
    }
    const parts: Array<string> = u.split('/');
    const last: string = parts[parts.length - 1];
    const dotIdx: number = last.indexOf('.');
    return dotIdx >= 0 ? last.substring(0, dotIdx) : last;
  }

  // 从 nav 接口获取 wbi 密钥
  private static async fetchWbiKeys(): Promise<string> {
    const resp: HttpResponse = await HttpClient.get(Api.userInfo, undefined);
    const json: Record<string, Object> = resp.json();
    const data: Record<string, Object> = asObject(json['data']);
    const wbiImg: Record<string, Object> = asObject(data['wbi_img']);
    const imgUrl: string = str(wbiImg, 'img_url', '');
    const subUrl: string = str(wbiImg, 'sub_url', '');
    if (imgUrl.length === 0 || subUrl.length === 0) {
      return '';
    }
    const orig: string = WbiSign.fileNameWithoutExt(imgUrl) + WbiSign.fileNameWithoutExt(subUrl);
    const mixin: string = WbiSign.computeMixinKey(orig);
    WbiSign.mixinKey = mixin;
    WbiSign.cacheDay = new Date().getDate();
    return mixin;
  }

  /** 获取 mixinKey（带日级缓存） */
  static async getMixinKey(): Promise<string> {
    const today: number = new Date().getDate();
    if (WbiSign.mixinKey.length > 0 && WbiSign.cacheDay === today) {
      return WbiSign.mixinKey;
    }
    if (WbiSign.pending !== null) {
      return WbiSign.pending;
    }
    WbiSign.pending = WbiSign.fetchWbiKeys().finally(() => {
      WbiSign.pending = null;
    });
    return WbiSign.pending;
  }

  // 为参数做 wbi 签名（原地修改 params，加入 wts / w_rid）
  static async encWbi(params: Record<string, string>): Promise<void> {
    const mixinKey: string = await WbiSign.getMixinKey();
    if (mixinKey.length === 0) {
      return;
    }
    params['wts'] = String(Math.floor(Date.now() / 1000));
    const keys: Array<string> = Object.keys(params).sort();
    let query: string = '';
    for (let i: number = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (i > 0) {
        query += '&';
      }
      const raw: string = params[k] ?? '';
      const filtered: string = raw.replace(/[!'()*]/g, '');
      query += encodeURIComponent(k) + '=' + encodeURIComponent(filtered);
    }
    params['w_rid'] = await md5Hex(query + mixinKey);
  }
}
