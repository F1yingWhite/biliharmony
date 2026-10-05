import { BiliApi } from '../../api/BiliApi';
import { AuthSession } from '../../services/auth/AuthSession';

export interface VideoDanmakuTarget {
  aid: number;
  bvid: string;
  cid: number;
  version: number;
}

export interface VideoDanmakuSubmissionHost {
  isDestroyed: () => boolean;
  getTarget: () => VideoDanmakuTarget;
  getProgress: () => number;
  getDraft: () => string;
  getDraftVersion: () => number;
  setDraft: (value: string) => void;
  setSending: (value: boolean) => void;
  ensureLogin: () => boolean;
  showLocal: (message: string, seconds: number, id: string) => void;
  toast: (message: string) => void;
}

/** Confirmed local echoes belong to the submitted video, account and page lifetime. */
export class VideoDanmakuSubmissionController {
  private readonly host: VideoDanmakuSubmissionHost;
  private generation: number = 0;
  private context: string = '';
  private busy: boolean = false;

  constructor(host: VideoDanmakuSubmissionHost) {
    this.host = host;
  }

  reset(): void {
    ++this.generation;
    this.context = this.contextKey();
    this.busy = false;
    if (!this.host.isDestroyed()) this.host.setSending(false);
  }

  private contextKey(): string {
    const target: VideoDanmakuTarget = this.host.getTarget();
    return String(AuthSession.version) + '|' + String(target.version) + '|' +
      String(target.aid) + '|' + target.bvid + '|' + String(target.cid);
  }

  private current(generation: number, context: string): boolean {
    return !this.host.isDestroyed() && generation === this.generation &&
      context === this.context && context === this.contextKey();
  }

  async send(): Promise<void> {
    if (this.host.isDestroyed()) return;
    if (this.context !== this.contextKey()) this.reset();
    const draft: string = this.host.getDraft();
    const draftVersion: number = this.host.getDraftVersion();
    const message: string = draft.trim();
    const target: VideoDanmakuTarget = this.host.getTarget();
    if (message.length === 0 || this.busy || target.cid <= 0 || !this.host.ensureLogin()) return;
    const progress: number = this.host.getProgress();
    const seconds: number = Number.isFinite(progress) && progress >= 0 ? progress : 0;
    const generation: number = this.generation;
    const context: string = this.context;
    this.busy = true;
    this.host.setSending(true);
    try {
      const result = await BiliApi.sendDanmaku(target.aid, target.bvid, target.cid, seconds, message);
      if (!this.current(generation, context)) return;
      if (!result.ok) {
        this.host.toast(result.message);
        return;
      }
      // Typing the next message while a request is pending must preserve that draft.
      if (this.host.getDraftVersion() === draftVersion && this.host.getDraft() === draft) this.host.setDraft('');
      const rawId: Object | undefined = result.data['dmid_str'] ?? result.data['dmid'];
      const id: string = typeof rawId === 'string' && /^[1-9][0-9]*$/.test(rawId) ? rawId :
        typeof rawId === 'number' && Number.isSafeInteger(rawId) && rawId > 0 ? String(rawId) : '';
      this.host.showLocal(message, seconds, id);
      this.host.toast('弹幕发送成功');
    } catch (_) {
      if (this.current(generation, context)) this.host.toast('网络异常，发送失败');
    } finally {
      if (this.current(generation, context)) {
        this.busy = false;
        this.host.setSending(false);
      }
    }
  }
}
