import { BiliLinkResolver } from '../../common/BiliLinkResolver';
import { BiliLinkTarget, isBiliShortLink, normalizeBiliWebUrl } from '../../common/BiliLinkParser';
import { BiliLinkNavigation, createBiliLinkNavigation } from '../../common/BiliLinkRouter';
import { AuthSession } from '../../services/auth/AuthSession';

export interface ReplyLinkHost {
  isAlive: () => boolean;
  getSourceKey: () => string;
  navigate: (navigation: BiliLinkNavigation) => void;
  openExternal: (url: string) => void;
  stopPlayer: () => void;
  toast: (message: string) => void;
}

/** Comment reuse, leaving a page and later clicks invalidate outstanding short-link/detail reads. */
export class ReplyLinkController {
  private readonly host: ReplyLinkHost;
  private request: number = 0;

  constructor(host: ReplyLinkHost) { this.host = host; }

  dispose(): void { ++this.request; }

  async open(value: string, title: string): Promise<boolean> {
    if (!this.host.isAlive()) return false;
    const request: number = ++this.request;
    const source: string = this.host.getSourceKey();
    const account: number = AuthSession.version;
    const url: string = normalizeBiliWebUrl(value);
    if (url.length === 0) return false;
    try {
      const target: BiliLinkTarget | null = await BiliLinkResolver.resolve(url);
      if (!this.current(request, source, account)) return false;
      if (target === null) {
        if (isBiliShortLink(url)) {
          this.host.toast('短链接暂时无法解析，请稍后重试');
          return false;
        }
        this.host.stopPlayer();
        this.host.openExternal(url);
      } else {
        const navigation: BiliLinkNavigation = await createBiliLinkNavigation(target, title);
        if (!this.current(request, source, account) || navigation.name.length === 0) return false;
        this.host.stopPlayer();
        this.host.navigate(navigation);
      }
      return true;
    } catch (e) {
      if (this.current(request, source, account)) this.host.toast('链接打开失败，请稍后重试');
      return false;
    }
  }

  private current(request: number, source: string, account: number): boolean {
    return this.host.isAlive() && request === this.request && source === this.host.getSourceKey() && account === AuthSession.version;
  }
}
