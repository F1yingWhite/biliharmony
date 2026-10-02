import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { EmoteImageCache } from '../../common/EmoteImageCache';
import { ReplyItem } from '../../model/Models';
import { AuthSession } from '../../services/auth/AuthSession';
import { ReplyScope, ReplySubject, sameReplySubject } from './ReplyState';
import { getReplyShareBounds, ReplyShareBounds, makeReplyQr, makeReplyShareSnapshot } from './ReplyShareCard';
import { planReplySharePages, resolveReplyShareEmotes, ReplySharePage } from './ReplyShareLayout';
import { ReplyShareImageFile, saveReplyShareImage, showReplyShareImages, removeReplyShareImages } from './ReplyShareExport';

export interface ReplyShareHost extends ReplyScope {
  toast: (message: string) => void;
  getUIContext: () => UIContext;
  buildShareLink: (item: ReplyItem) => string;
  renderShareCard: () => void;
  ensureShareContext: (context: common.UIAbilityContext | undefined) => boolean;
  onShareFailed: (item: ReplyItem, link: string, error: Object) => void;
}

class ReplyShareSession {
  item: ReplyItem = new ReplyItem();
  qr: image.PixelMap | null = null;
  page: ReplySharePage = new ReplySharePage();
  link: string = '';
  subject: ReplySubject = { oid: 0, type: 0 };
  account: number = 0;
  files: Array<ReplyShareImageFile> = [];
  handedOff: boolean = false;
}

let shareSequence: number = 0;

/** 每次导出持有自己的二维码与临时文件；取消或晚到的完成不会释放下一次导出的资源。 */
export class ReplyShareController {
  private readonly host: ReplyShareHost;
  private active: ReplyShareSession | null = null;
  private readonly empty: ReplyShareSession = new ReplyShareSession();

  constructor(host: ReplyShareHost) { this.host = host; }

  get busy(): boolean { return this.active !== null; }
  shareItem(): ReplyItem { return this.active !== null ? this.active.item : this.empty.item; }
  shareQr(): image.PixelMap | null { return this.active !== null ? this.active.qr : null; }
  shareLink(): string { return this.active !== null ? this.active.link : ''; }
  sharePage(): ReplySharePage { return this.active !== null ? this.active.page : this.empty.page; }

  dispose(): void {
    const session: ReplyShareSession | null = this.active;
    this.active = null;
    if (session !== null) {
      this.releaseQr(session);
      if (!session.handedOff) removeReplyShareImages(session.files);
    }
  }

  async share(item: ReplyItem): Promise<void> {
    if (this.busy || this.host.isDestroyed()) return;
    const session: ReplyShareSession = new ReplyShareSession();
    session.item = item.clone();
    const subject: ReplySubject = this.host.getSubject();
    session.subject = { oid: subject.oid, type: subject.type };
    session.account = AuthSession.version;
    session.link = this.host.buildShareLink(session.item);
    this.active = session;
    const sequence: string = String(Date.now()) + '_' + String(++shareSequence);
    try {
      this.host.toast('正在生成分享图片…');
      const ui: UIContext = this.host.getUIContext();
      const context: common.UIAbilityContext | undefined = ui.getHostContext() as common.UIAbilityContext | undefined;
      if (context === undefined || !this.host.ensureShareContext(context)) return;
      if (!/^https:\/\/(www\.|t\.)?bilibili\.com\//.test(session.link)) throw new Error('评论链接无效，无法生成二维码');
      session.qr = await makeReplyQr(session.link);
      if (!this.isCurrent(session)) return;
      const sources: Map<string, string> = await resolveReplyShareEmotes(session.item,
        (url: string): Promise<string> => EmoteImageCache.ensure(url));
      if (!this.isCurrent(session)) return;
      const bounds: ReplyShareBounds = await getReplyShareBounds(ui);
      if (!this.isCurrent(session)) return;
      const widths: Map<string, number> = new Map<string, number>();
      const pages: Array<ReplySharePage> = planReplySharePages(session.item, (text: string, fontSize: number): number => {
        const key: string = String(fontSize) + ':' + text;
        const cached: number | undefined = widths.get(key);
        if (cached !== undefined) return cached;
        const measured: SizeOptions = ui.getMeasureUtils().measureTextSize({ textContent: text, fontSize: String(fontSize) + 'vp' });
        const width: number = ui.px2vp(Number(measured.width));
        if (!Number.isFinite(width)) throw new Error('无法测量评论排版');
        widths.set(key, width);
        return width;
      }, bounds.height, sources, bounds.width);
      for (let i: number = 0; i < pages.length; i++) {
        if (!this.isCurrent(session)) return;
        session.page = pages[i];
        const pixelMap: image.PixelMap = await makeReplyShareSnapshot(ui, (): void => {
          if (!this.isCurrent(session)) throw new Error('分享已取消');
          this.host.renderShareCard();
        }, pages[i].height, pages[i].width);
        if (!this.isCurrent(session)) {
          try { await pixelMap.release(); } catch (ignored) {}
          return;
        }
        const name: string = 'reply_share_' + String(item.rpid) + '_' + sequence + '_' + String(i + 1);
        session.files.push(await saveReplyShareImage(context, pixelMap, name));
      }
      if (!this.isCurrent(session)) return;
      session.handedOff = true;
      await showReplyShareImages(context, session.files);
    } catch (e) {
      session.handedOff = false;
      if (!this.isCurrent(session)) return;
      const message: string = (e as Error).message;
      if (message === '评论图片未加载完整，请稍后重试' || message === '评论图片尺寸不完整，请重试' ||
        message === '当前窗口过小，请放大窗口后生成分享图片') this.host.toast(message);
      else this.host.onShareFailed(session.item, session.link, e as Object);
    } finally {
      this.releaseQr(session);
      if (!session.handedOff) removeReplyShareImages(session.files);
      if (this.active === session) this.active = null;
    }
  }

  private isCurrent(session: ReplyShareSession): boolean {
    return !this.host.isDestroyed() && this.active === session && session.account === AuthSession.version &&
      sameReplySubject(session.subject, this.host.getSubject()) && this.host.buildShareLink(session.item) === session.link;
  }

  private releaseQr(session: ReplyShareSession): void {
    const qr: image.PixelMap | null = session.qr;
    session.qr = null;
    if (qr !== null) { try { qr.release().catch(() => {}); } catch (ignored) {} }
  }
}
