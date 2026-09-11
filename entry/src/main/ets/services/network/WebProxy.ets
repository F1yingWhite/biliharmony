/**
 * ArkWeb 代理下发。
 *
 * ArkWeb 内的 Chromium 使用独立网络栈，`@ohos.net.http` 的 `usingProxy` 不会作用于它，
 * 因此网络受限环境必须在启动时单独调用 `ProxyController.applyProxyOverride`。
 * 注意该静态方法在 `webview.ProxyController` 上，不在 `ProxyConfig` 上；
 * `ProxyConfig` 只是承载代理/绕过规则的参数对象。
 *
 * 仅在启动参数带 `netProxy` 时调用：默认空值不触碰任何 ArkWeb 接口，
 * ArkWeb 行为与历史版本一致。该调用对应用内所有 Web 生效。
 */
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';

export class WebProxy {
  /**
   * 把 `http://主机:端口` 归一成 ArkWeb 规则需要的 `scheme://host:port`。
   * ArkWeb 只接受 http / https / socks 三种协议，其余取值返回空串（拒绝下发而不是猜一个协议）。
   * 缺省端口与 HttpClient 保持一致（http 8080 / socks 1080），避免两条网络栈指向不同端口。
   */
  static rule(raw: string): string {
    let rest: string = raw.trim();
    if (rest.length === 0) return '';
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
    if (host.length === 0) return '';
    if (scheme === 'socks5') scheme = 'socks';
    if (scheme !== 'http' && scheme !== 'https' && scheme !== 'socks') return '';
    if (port === 0) port = scheme === 'socks' ? 1080 : 8080;
    return scheme + '://' + host + ':' + port;
  }

  /** 下发 ArkWeb 代理；空值或无法解析的取值一律不下发并返回 false。 */
  static apply(raw: string): boolean {
    const rule: string = WebProxy.rule(raw);
    if (rule.length === 0) return false;
    try {
      const config: webview.ProxyConfig = new webview.ProxyConfig();
      config.insertProxyRule(rule, webview.ProxySchemeFilter.MATCH_ALL_SCHEMES);
      webview.ProxyController.applyProxyOverride(config, () => {});
      return true;
    } catch (e) {
      const code: number = (e as BusinessError).code;
      console.warn('[WebProxy] ArkWeb proxy override failed code=' + String(code));
      return false;
    }
  }
}
