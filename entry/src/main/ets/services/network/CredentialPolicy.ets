/** 登录凭证仅发送到明确使用的 HTTPS API 主机，不信任 URL 的路径、前缀或用户信息。 */
export class CredentialPolicy {
  static allows(url: string): boolean {
    const match: RegExpExecArray | null = /^https:\/\/([a-z0-9.-]+)(?::443)?(?:[/?#]|$)/i.exec(url);
    if (match === null) return false;
    const host: string = match[1].toLowerCase();
    return ['www.bilibili.com', 'api.bilibili.com', 'api.vc.bilibili.com', 'app.bilibili.com',
      'api.live.bilibili.com', 'passport.bilibili.com', 'message.bilibili.com',
      'space.bilibili.com', 's.search.bilibili.com', 'comment.bilibili.com'].indexOf(host) >= 0;
  }

  static filter(url: string, headers: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    const trusted: boolean = CredentialPolicy.allows(url);
    const keys: Array<string> = Object.keys(headers);
    for (let i: number = 0; i < keys.length; i++) {
      const name: string = keys[i].toLowerCase();
      if (!trusted && (name === 'cookie' || name === 'authorization' || name === 'proxy-authorization')) continue;
      out[keys[i]] = headers[keys[i]];
    }
    return out;
  }
}
