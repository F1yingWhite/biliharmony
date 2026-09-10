import { pasteboard } from '@kit.BasicServicesKit';
import { ActionResult, BiliApi, DanmakuItem } from '../../api/BiliApi';
import { UserStore } from '../../services/auth/UserStore';
import { ActiveDm } from './PlayerDanmakuSupport';
import { PlayerDanmakuEngine } from './PlayerDanmakuEngine';

export class DanmakuPinResult {
  handled: boolean = false;
  visible: boolean = false;
  text: string = '';
  x: number = 0;
  y: number = 0;
  width: number = 100;
  height: number = 34;
}

export class PlayerDanmakuInteractionController {
  private engine: PlayerDanmakuEngine;
  private pending: ActiveDm | null = null;

  constructor(engine: PlayerDanmakuEngine) {
    this.engine = engine;
  }

  rememberTouch(x: number, y: number, pinnedVisible: boolean): void {
    if (!pinnedVisible && this.engine.active.length > 0) this.pending = this.engine.hitTestActive(x, y);
  }

  cancelPending(): void {
    this.pending = null;
  }

  handleTap(event: GestureEvent, pinnedVisible: boolean): DanmakuPinResult {
    if (!pinnedVisible && this.pending !== null) {
      const hit: ActiveDm = this.pending;
      this.pending = null;
      if (hit.item !== undefined) return this.pin(hit);
    }
    this.pending = null;
    const finger: FingerInfo | undefined = event.fingerList.length > 0 ? event.fingerList[0] : undefined;
    const x: number = finger !== undefined ? finger.localX : -1;
    const y: number = finger !== undefined ? finger.localY : -1;
    if (x < 0 || y < 0) return new DanmakuPinResult();
    if (pinnedVisible) return this.clearPin();
    const hit: ActiveDm | null = this.engine.hitTestActive(x, y);
    return hit === null ? new DanmakuPinResult() : this.pin(hit);
  }

  clearPin(): DanmakuPinResult {
    this.engine.pin(null);
    const result: DanmakuPinResult = new DanmakuPinResult();
    result.handled = true;
    return result;
  }

  async like(cid: number): Promise<string> {
    const pinned: ActiveDm | null = this.engine.pinned;
    this.engine.pin(null);
    if (pinned === null) return '';
    if (pinned.item.idStr.length === 0) return '该弹幕来自兼容协议，暂不支持点赞';
    if (!UserStore.isLogin) return '请先登录后再点赞弹幕';
    try {
      const result: ActionResult = await BiliApi.likeDanmaku(cid, pinned.item.idStr, 1);
      return result.ok ? '已点赞这条弹幕' : result.message;
    } catch (e) {
      return '点赞失败，请稍后重试';
    }
  }

  async copy(text: string): Promise<string> {
    this.engine.pin(null);
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return '弹幕已复制';
    } catch (e) {
      return '复制失败';
    }
  }

  takeReportItem(): DanmakuItem | null {
    const pinned: ActiveDm | null = this.engine.pinned;
    this.engine.pin(null);
    return pinned === null ? null : pinned.item;
  }

  private pin(hit: ActiveDm): DanmakuPinResult {
    this.engine.pin(hit);
    const rect = this.engine.dmViewportOf(hit);
    const result: DanmakuPinResult = new DanmakuPinResult();
    const gap: number = 8;
    const textTop: number = rect.visualTop > 0 ? rect.visualTop : rect.y;
    const textBottom: number = rect.visualBottom > 0 ? rect.visualBottom : rect.y + rect.h;
    const maxX: number = Math.max(130, this.engine.width - result.width - 4);
    const bottomLimit: number = Math.max(result.height + 4, this.engine.height - result.height - 4);
    result.handled = true;
    result.visible = true;
    result.text = hit.renderText;
    result.x = Math.max(4, Math.min(rect.x + rect.w / 2 - result.width / 2, maxX));
    result.y = textTop - gap - result.height;
    if (result.y < 22) result.y = textBottom + gap;
    result.y = Math.max(4, Math.min(result.y, bottomLimit));
    return result;
  }
}
