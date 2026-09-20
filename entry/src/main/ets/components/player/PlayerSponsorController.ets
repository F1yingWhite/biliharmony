/**
 * 播放器空降（SponsorBlock）运行时域：片段加载、进度命中判定、跳段/静音执行、
 * 提示卡状态机与投票。从 PlayerView 抽出，组件通过 access 闭包接入 @State 与播放器动作。
 * 提交草稿、用户面板属于设置页域，仍留在 PlayerView；本文件不 import 任何 struct。
 */
import { SponsorBlockApi, SponsorBlockResult } from '../../api/SponsorBlockApi';
import { SponsorBlockCategory, SponsorBlockMode, SponsorBlockSegment, SponsorBlockStore,
  sponsorBlockActionLabel, sponsorBlockCategory } from '../../common/SponsorBlock';
import { formatDuration } from '../../common/Utils';

/** 提示卡的渲染数据：控制器组装，页面经 applyNotice 落到 @State（null 表示收起）。 */
export interface SponsorNoticeUi {
  title: string;
  detail: string;
  color: string;
  manual: boolean;
  canUndo: boolean;
  canVote: boolean;
}

/** 页面读写面：@State 留在页面，控制器经闭包读写（成员用属性+箭头函数语法）。 */
export interface PlayerSponsorAccess {
  isDestroyed: () => boolean;
  getSegments: () => Array<SponsorBlockSegment>;
  setSegments: (segments: Array<SponsorBlockSegment>) => void;
  getSponsorSkipEnabled: () => boolean;
  getPlayhead: () => number;
  applyNotice: (ui: SponsorNoticeUi | null) => void;
  onFullLabel: (label: string, color: string) => void;
  seekTo: (seconds: number, precise: boolean) => void;
  muteImmediately: () => void;
  restoreUserVolume: () => void;
  /** 首帧静音武装期间不恢复音量，避免与起播静音互踩。 */
  isFirstFrameMuteArmed: () => boolean;
  toast: (message: string) => void;
  getBvid: () => string;
  getCid: () => number;
}

export class PlayerSponsorController {
  private readonly access: PlayerSponsorAccess;
  private noticeSegment: SponsorBlockSegment | null = null;
  private noticeTimer: number = -1;
  private noticeVisible: boolean = false;
  private noticeManual: boolean = false;
  private noticeCanUndo: boolean = false;
  private undoTime: number = -1;
  private muted: boolean = false;
  private readonly handled: Set<string> = new Set<string>();
  private readonly dismissed: Set<string> = new Set<string>();
  private readonly viewed: Set<string> = new Set<string>();
  private fullLabel: string = '';
  private fullColor: string = '#008A5C';

  constructor(access: PlayerSponsorAccess) {
    this.access = access;
  }

  private sponsorKey(segment: SponsorBlockSegment): string {
    return segment.uuid.length > 0 ? segment.uuid : segment.category + ':' +
      segment.start.toFixed(3) + ':' + segment.end.toFixed(3);
  }

  resetRuntime(): void {
    this.handled.clear();
    this.dismissed.clear();
    this.viewed.clear();
    this.setMuted(false);
    this.undoTime = -1;
    this.fullLabel = '';
    this.hideNotice(false);
  }

  /** 换源立即作废旧视频的空降数据：片段清空 + 运行时复位 + 全视频标签刷新。 */
  invalidateForSourceChange(): void {
    this.access.setSegments([]);
    this.resetRuntime();
    this.refreshFullLabel();
  }

  clearNoticeTimer(): void {
    if (this.noticeTimer >= 0) {
      clearTimeout(this.noticeTimer);
      this.noticeTimer = -1;
    }
  }

  refreshFullLabel(): void {
    let label: string = '';
    let color: string = '#008A5C';
    const segments: Array<SponsorBlockSegment> = this.access.getSegments();
    for (let i: number = 0; i < segments.length; i++) {
      const segment: SponsorBlockSegment = segments[i];
      if (segment.actionType === 'full' && SponsorBlockStore.modeFor(segment.category) !== SponsorBlockMode.DISABLED) {
        const category: SponsorBlockCategory = sponsorBlockCategory(segment.category);
        label = category.label;
        color = category.color;
        break;
      }
    }
    if (label === this.fullLabel && color === this.fullColor) return;
    this.fullLabel = label;
    this.fullColor = color;
    // 全视频标签不再画在画面上：交给详情页显示在标题前（全屏时无标题，自然隐藏）。
    this.access.onFullLabel(label, color);
  }

  private showNotice(segment: SponsorBlockSegment, manual: boolean, canUndo: boolean): void {
    this.clearNoticeTimer();
    this.noticeSegment = segment;
    this.noticeManual = manual;
    this.noticeCanUndo = canUndo;
    const category: SponsorBlockCategory = sponsorBlockCategory(segment.category);
    this.access.applyNotice({
      title: (canUndo ? '已空降 ' : '') + category.label,
      detail: sponsorBlockActionLabel(segment.actionType) + ' · ' +
        formatDuration(segment.start) + ' - ' + formatDuration(segment.end),
      color: category.color,
      manual: manual,
      canUndo: canUndo,
      canVote: segment.uuid.length > 0,
    });
    this.noticeVisible = true;
    const autoCloseDelay: number = manual ? 6000 : (canUndo ? 5000 : 3500);
    this.noticeTimer = setTimeout(() => {
      this.noticeTimer = -1;
      // 手动提示超时等同于用户关闭，防止仍处于片段内时下一次进度回调立即重弹。
      this.hideNotice(manual);
    }, autoCloseDelay);
  }

  hideNotice(dismiss: boolean = true): void {
    this.clearNoticeTimer();
    if (dismiss && this.noticeSegment !== null) {
      this.dismissed.add(this.sponsorKey(this.noticeSegment));
    }
    this.access.applyNotice(null);
    this.noticeVisible = false;
    this.noticeManual = false;
    this.noticeCanUndo = false;
    this.noticeSegment = null;
  }

  private setMuted(muted: boolean): void {
    if (this.muted === muted) return;
    this.muted = muted;
    if (muted) this.access.muteImmediately();
    else if (!this.access.isFirstFrameMuteArmed()) this.access.restoreUserVolume();
  }

  isMuted(): boolean {
    return this.muted;
  }

  private recordView(segment: SponsorBlockSegment, seconds: number): void {
    const key: string = this.sponsorKey(segment);
    if (this.viewed.has(key)) return;
    this.viewed.add(key);
    if (seconds > 0) SponsorBlockStore.recordSkip(seconds);
    SponsorBlockApi.reportViewed(segment.uuid).catch(() => {});
  }

  private executeSegment(segment: SponsorBlockSegment, now: number): void {
    const key: string = this.sponsorKey(segment);
    this.handled.add(key);
    this.dismissed.delete(key);
    if (segment.actionType === 'mute') {
      this.undoTime = now;
      this.setMuted(true);
      this.showNotice(segment, false, true);
      return;
    }
    if (segment.actionType === 'poi') {
      this.undoTime = now;
      this.access.seekTo(segment.start, true);
      this.showNotice(segment, false, true);
      return;
    }
    if (segment.actionType === 'full') {
      this.showNotice(segment, false, false);
      return;
    }
    this.undoTime = now;
    this.access.seekTo(segment.end + 0.01, true);
    this.recordView(segment, Math.max(0, segment.end - now));
    this.showNotice(segment, false, true);
  }

  maybeSkipSponsor(now: number): boolean {
    if (!this.access.getSponsorSkipEnabled() || this.access.getSegments().length === 0) {
      this.setMuted(false);
      return false;
    }
    const segments: Array<SponsorBlockSegment> = this.access.getSegments();
    let keepMuted: boolean = false;
    let activeManual: boolean = false;
    for (let i: number = 0; i < segments.length; i++) {
      const segment: SponsorBlockSegment = segments[i];
      const mode: number = SponsorBlockStore.modeFor(segment.category);
      if (mode === SponsorBlockMode.DISABLED || segment.actionType === 'full' || segment.actionType === 'poi') continue;
      const inside: boolean = now >= segment.start && now < segment.end - 0.04;
      if (!inside) continue;
      const key: string = this.sponsorKey(segment);
      if (segment.actionType === 'mute' && (mode === SponsorBlockMode.AUTO || this.handled.has(key))) {
        keepMuted = true;
      }
      if (this.handled.has(key) || this.dismissed.has(key)) continue;
      if (mode === SponsorBlockMode.AUTO) {
        this.executeSegment(segment, now);
        this.setMuted(segment.actionType === 'mute');
        return segment.actionType === 'skip';
      }
      if (mode === SponsorBlockMode.MANUAL) {
        activeManual = true;
        if (!this.noticeVisible || this.noticeSegment === null ||
          this.sponsorKey(this.noticeSegment) !== key) {
          this.showNotice(segment, true, false);
        }
      }
    }
    this.setMuted(keepMuted);
    if (!activeManual && this.noticeManual) this.hideNotice(false);
    return false;
  }

  undoNotice(): void {
    const segment: SponsorBlockSegment | null = this.noticeSegment;
    if (segment === null) return;
    if (segment.actionType === 'mute') {
      this.setMuted(false);
    } else if (this.undoTime >= 0) {
      this.access.seekTo(this.undoTime, true);
    }
    this.handled.add(this.sponsorKey(segment));
    this.hideNotice(false);
  }

  noticePrimary(): void {
    const segment: SponsorBlockSegment | null = this.noticeSegment;
    if (segment === null) return;
    if (this.noticeCanUndo) this.undoNotice();
    else this.executeSegment(segment, this.access.getPlayhead());
  }

  voteNotice(type: number): void {
    const segment: SponsorBlockSegment | null = this.noticeSegment;
    if (segment === null) return;
    this.voteSegment(segment, type);
  }

  voteSegment(segment: SponsorBlockSegment, type: number): void {
    SponsorBlockApi.vote(segment.uuid, type).then((result: SponsorBlockResult) => {
      this.access.toast(result.message);
      if (!result.ok) return;
      segment.votes += type === 1 ? 1 : -1;
      if (type === 0) {
        const key: string = this.sponsorKey(segment);
        this.access.setSegments(this.access.getSegments().filter((item: SponsorBlockSegment) =>
          this.sponsorKey(item) !== key));
        this.setMuted(false);
        this.hideNotice(false);
      } else {
        this.access.setSegments(this.access.getSegments().slice());
      }
    }).catch(() => this.access.toast('投票失败，请稍后重试'));
  }

  /** 设置页片段列表点击定位：先标记已处理，避免定位后自动跳走。 */
  markHandled(segment: SponsorBlockSegment): void {
    this.handled.add(this.sponsorKey(segment));
  }

  /** 关闭空降开关：立即解除静音并收起提示卡（不清理已处理集合）。 */
  deactivate(): void {
    this.setMuted(false);
    this.hideNotice(false);
  }

  /** 单集重播：允许片段重新触发，解除静音并收起提示卡。 */
  resetForReplay(): void {
    this.handled.clear();
    this.dismissed.clear();
    this.setMuted(false);
    this.hideNotice(false);
  }

  async loadSponsorSegments(ignoreCache: boolean = false): Promise<void> {
    const bvid: string = this.access.getBvid();
    const cid: number = this.access.getCid();
    this.access.setSegments([]);
    this.resetRuntime();
    try {
      const segments: Array<SponsorBlockSegment> = await SponsorBlockApi.getSegments(bvid, cid, ignoreCache);
      if (this.access.isDestroyed() || this.access.getBvid() !== bvid || this.access.getCid() !== cid) return;
      this.access.setSegments(segments);
      this.refreshFullLabel();
    } catch (e) {
      // 空降数据是增强能力，请求失败不能影响播放器主流程。
    }
  }
}
