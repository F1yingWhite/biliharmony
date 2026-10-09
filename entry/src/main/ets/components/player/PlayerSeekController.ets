/** 单原生时间线的 seek 串行队列：合并手势请求，过滤旧回调，并对无响应定位限时恢复。 */
import { PlayerEngine, PlayerSeekMode } from './PlayerEngine';

const SEEK_COALESCE_MS: number = 60;
const SEEK_SPINNER_MS: number = 180;
const SEEK_TIMEOUT_MS: number = 4000;

export class PlayerSeekController {
  private pendingSeekMs: number = -1;
  private pendingSeekPrecise: boolean = true;
  private activeSeekMs: number = -1;
  private seekInFlight: boolean = false;
  seekResumePlaying: boolean = false;

  private generation: number = 0;
  private dispatchTimer: number = -1;
  private seekSpinnerTimer: number = -1;
  private seekWatchdogTimer: number = -1;
  private activeEngine: PlayerEngine | null = null;
  private readonly getEngine: () => PlayerEngine | null;
  private readonly isPrepared: () => boolean;
  private readonly onBeforeDispatch: (targetMs: number) => void;
  private readonly onSpinner: (on: boolean) => void;
  private readonly onCompleted: (resumePlaying: boolean, positionMs: number) => void;
  private readonly onStall: (engine: PlayerEngine | null, targetMs: number) => void;

  constructor(
    getEngine: () => PlayerEngine | null,
    isPrepared: () => boolean,
    onBeforeDispatch: (targetMs: number) => void,
    onSpinner: (on: boolean) => void,
    onCompleted: (resumePlaying: boolean, positionMs: number) => void,
    onStall: (engine: PlayerEngine | null, targetMs: number) => void,
  ) {
    this.getEngine = getEngine;
    this.isPrepared = isPrepared;
    this.onBeforeDispatch = onBeforeDispatch;
    this.onSpinner = onSpinner;
    this.onCompleted = onCompleted;
    this.onStall = onStall;
  }

  request(targetMs: number, precise: boolean, resumePlaying: boolean): void {
    this.pendingSeekMs = targetMs;
    this.pendingSeekPrecise = precise;
    this.seekResumePlaying = this.seekResumePlaying || resumePlaying;
    if (this.seekInFlight) return;
    if (this.dispatchTimer >= 0) clearTimeout(this.dispatchTimer);
    this.dispatchTimer = setTimeout(() => {
      this.dispatchTimer = -1;
      this.dispatchPendingSeek();
    }, SEEK_COALESCE_MS);
  }

  cancel(): void {
    this.generation++;
    if (this.dispatchTimer >= 0) clearTimeout(this.dispatchTimer);
    this.dispatchTimer = -1;
    this.clearTimers();
    this.pendingSeekMs = -1;
    this.pendingSeekPrecise = true;
    this.seekInFlight = false;
    this.activeSeekMs = -1;
    this.activeEngine = null;
    this.seekResumePlaying = false;
  }

  private dispatchPendingSeek(): void {
    const engine: PlayerEngine | null = this.getEngine();
    if (engine === null || !this.isPrepared() || this.pendingSeekMs < 0) return;
    const targetMs: number = this.pendingSeekMs;
    const precise: boolean = this.pendingSeekPrecise;
    const generation: number = ++this.generation;
    this.pendingSeekMs = -1;
    this.activeSeekMs = targetMs;
    this.activeEngine = engine;
    this.seekInFlight = true;
    this.onBeforeDispatch(targetMs);
    this.seekSpinnerTimer = setTimeout(() => {
      this.seekSpinnerTimer = -1;
      if (generation === this.generation && this.seekInFlight && this.getEngine() === engine) this.onSpinner(true);
    }, SEEK_SPINNER_MS);
    this.seekWatchdogTimer = setTimeout(() => {
      this.seekWatchdogTimer = -1;
      if (generation !== this.generation || this.activeEngine !== engine || !this.seekInFlight) return;
      const latestTarget: number = this.pendingSeekMs >= 0 ? this.pendingSeekMs : targetMs;
      this.pendingSeekMs = -1;
      this.onStall(engine, latestTarget);
    }, SEEK_TIMEOUT_MS);
    try {
      // libmpv 在播放状态统一定位音视频；额外 pause/play 会破坏流畅性。
      engine.seek(targetMs, precise ? PlayerSeekMode.CLOSEST : PlayerSeekMode.PREVIOUS_KEYFRAME);
    } catch (e) {
      this.clearTimers();
      this.onStall(engine, targetMs);
    }
  }

  onSeekDone(engine: PlayerEngine, requestedMs: number, actualMs: number = -1): void {
    if (this.activeEngine !== engine || !this.seekInFlight || this.getEngine() !== engine) return;
    // 适配器回报 seek 请求值和实际落点；±500ms 会误收相邻旧请求的回调。
    if (Math.abs(requestedMs - this.activeSeekMs) > 1) return;
    let positionMs: number = actualMs;
    if (!Number.isFinite(positionMs) || positionMs < 0) {
      positionMs = engine.currentTime;
    }
    if (!Number.isFinite(positionMs) || positionMs < 0) positionMs = requestedMs;
    this.clearTimers();
    this.generation++;
    this.seekInFlight = false;
    this.activeSeekMs = -1;
    this.activeEngine = null;
    if (this.pendingSeekMs >= 0) {
      this.dispatchPendingSeek();
      return;
    }
    const resume: boolean = this.seekResumePlaying;
    this.seekResumePlaying = false;
    this.onCompleted(resume, positionMs);
  }

  private clearTimers(): void {
    if (this.seekSpinnerTimer >= 0) clearTimeout(this.seekSpinnerTimer);
    if (this.seekWatchdogTimer >= 0) clearTimeout(this.seekWatchdogTimer);
    this.seekSpinnerTimer = -1;
    this.seekWatchdogTimer = -1;
  }
}
