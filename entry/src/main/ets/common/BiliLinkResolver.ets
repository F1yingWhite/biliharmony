import { http } from '@kit.NetworkKit';
import { BiliLinkTarget, isBiliShortLink, normalizeBiliWebUrl, parseBiliLink } from './BiliLinkParser';
import { Constants } from './Constants';
import { asObject, asString } from './Utils';
import { HttpClient } from '../services/network/HttpClient';

/** Resolve only b23 redirects anonymously. Never follow a redirect with account headers. */
export class BiliLinkResolver {
  static async resolve(value: string): Promise<BiliLinkTarget | null> {
    const direct: BiliLinkTarget | null = parseBiliLink(value);
    if (direct !== null) return direct;
    let current: string = normalizeBiliWebUrl(value).replace(/^http:/i, 'https:');
    for (let hop: number = 0; hop < 3 && isBiliShortLink(current); hop++) {
      const request: http.HttpRequest = http.createHttp();
      try {
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
          header: { 'User-Agent': Constants.webHeaders['User-Agent'] },
          connectTimeout: 5000, readTimeout: 5000, maxRedirects: 0,
        };
        const proxy = HttpClient.proxyConfig();
        if (proxy !== null) options.usingProxy = proxy;
        const response: http.HttpResponse = await request.request(current, options);
        if ([301, 302, 303, 307, 308].indexOf(response.responseCode) < 0) return null;
        const headers: Record<string, Object> = asObject(response.header);
        let location: string = '';
        for (const key of Object.keys(headers)) {
          if (key.toLowerCase() === 'location') {
            const value: Object = headers[key];
            location = Array.isArray(value) ? asString((value as Array<Object>)[0]) : asString(value);
          }
        }
        if (location.startsWith('/') && !location.startsWith('//')) location = 'https://b23.tv' + location;
        current = normalizeBiliWebUrl(location).replace(/^http:/i, 'https:');
        const target: BiliLinkTarget | null = parseBiliLink(current);
        if (target !== null) return target;
      } catch (e) {
        return null;
      } finally {
        request.destroy();
      }
    }
    return null;
  }
}
