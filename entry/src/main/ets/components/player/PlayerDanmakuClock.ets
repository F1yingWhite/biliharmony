/**
 * 播放器弹幕时钟：DisplaySync 驱动的按帧推进与异常 ROM 的 setInterval 兜底。
 * 从 PlayerView 抽出，播放状态/帧率/引擎经 access 闭包接入；只负责"何时画下一帧"，
 * 弹幕设置（透明度/速度/屏蔽等）仍由页面管理。
 */
import { displaySync } from '@kit.ArkGraphics2D';
import { PlayerDanmakuEngine } from './PlayerDanmakuEngine';

/** 页面读写面（成员用属性+箭头函数语法，满足 ArkTS 对象字面量检查）。 */
export interface PlayerDanmakuClockAccess {
  isPlaying: () => boolean;
  isDanmakuOn: () => boolean;
  getFrameRate: () => number;
  getEngine: () => PlayerDanmakuEngine;
  /** stop(clearActive=true) 时一并收起置顶弹幕浮层。 */
  clearPinned: () => void;
}

export class PlayerDanmakuClock {
  private readonly access: PlayerDanmakuClockAccess;
  private running: boolean = false;
  private lastFrameMs: number = 0;
  private displaySync: displaySync.DisplaySync | null = null;
  private fallbackTick: number = -1;

  constructor(access: PlayerDanmakuClockAccess) {
    this.access = access;
  }

  isRunning(): boolean {
    return this.running;
  }

  /** 暂停/缓冲时只停时钟，保留已上屏弹幕；恢复播放后从当前帧继续推进。 */
  pause(): void {
    this.stopClock();
    this.access.getEngine().lastDrawMs = 0;
  }

  stop(clearActive: boolean): void {
    this.stopClock();
    this.access.getEngine().lastDrawMs = 0;
    if (clearActive) {
      this.access.getEngine().clearActive();
      this.access.clearPinned();
    } else {
      this.access.getEngine().clearCanvas();
    }
  }

  start(): void {
    const engine: PlayerDanmakuEngine = this.access.getEngine();
    if (this.running || !this.access.isDanmakuOn() || engine.active.length === 0) {
      return;
    }
    engine.lastDrawMs = 0;
    this.lastFrameMs = 0;
    this.running = true;
    try {
      if (this.displaySync === null) {
        const sync: displaySync.DisplaySync = displaySync.create();
        sync.setExpectedFrameRateRange(this.expectedFrameRateRange());
        sync.on('frame', (info: displaySync.IntervalInfo): void => {
          if (this.running && this.access.isPlaying() && this.access.isDanmakuOn() &&
            this.access.getEngine().active.length > 0) {
            const frameTimeMs: number = info.timestamp / 1_000_000;
            if (this.shouldRenderFrame(frameTimeMs)) this.renderFrame(true, frameTimeMs);
          }
        });
        this.displaySync = sync;
      }
      this.displaySync.start();
    } catch (e) {
      // API 26 正常走 DisplaySync；仅为异常 ROM 保留可播放兜底。
      this.fallbackTick = setInterval(() => {
        if (this.running && this.access.isPlaying() && this.access.isDanmakuOn() &&
          this.access.getEngine().active.length > 0) {
          const frameTimeMs: number = Date.now();
          if (this.shouldRenderFrame(frameTimeMs)) this.renderFrame(true, frameTimeMs);
        }
      }, 16);
    }
  }

  /** 用户改帧率后同步时钟：清空节拍基准并按新目标重设 DisplaySync 档位。 */
  frameRateChanged(): void {
    this.lastFrameMs = 0;
    if (this.displaySync !== null) {
      try {
        this.displaySync.setExpectedFrameRateRange(this.expectedFrameRateRange());
      } catch (e) {
        // 系统不接受高于屏幕刷新率的目标值时，DisplaySync 会继续使用设备可用帧率。
      }
    }
  }

  release(): void {
    this.stopClock();
    if (this.displaySync !== null) {
      try {
        this.displaySync.off('frame');
      } catch (e) {
      }
      this.displaySync = null;
    }
  }

  /** 统一绘制入口：画布上已经没有活动弹幕时顺带停掉定时器。 */
  private renderFrame(advance: boolean = true, frameTimeMs: number = Date.now()): void {
    this.access.getEngine().drawFrame(advance, frameTimeMs);
    if (this.access.getEngine().active.length === 0) this.stop(false);
  }

  private stopClock(): void {
    this.running = false;
    this.lastFrameMs = 0;
    if (this.displaySync !== null) {
      try {
        this.displaySync.stop();
      } catch (e) {
      }
    }
    if (this.fallbackTick >= 0) {
      clearInterval(this.fallbackTick);
      this.fallbackTick = -1;
    }
  }

  private shouldRenderFrame(frameTimeMs: number): boolean {
    // 不再因弹幕密度或长按倍速暗中降到 30/20fps；用户选择的帧率是唯一上限。
    // 实际位移仍按两次绘制的真实时间差推进，设备刷新率不足时不会慢放或失去音画同步。
    const minIntervalMs: number = 1000 / Math.max(24, this.access.getFrameRate());
    if (this.lastFrameMs <= 0) {
      this.lastFrameMs = frameTimeMs;
      return true;
    }
    const nextFrameMs: number = this.lastFrameMs + minIntervalMs;
    if (frameTimeMs + 0.5 < nextFrameMs) {
      return false;
    }
    // 按目标时间线累积而不是重置为实际回调时间：120Hz 上选择 90fps 时会以 2/1/1 帧
    // 的节奏逼近 90，而不是每次都从当前帧重算后退化成固定 60fps。
    const overdueMs: number = Math.max(0, frameTimeMs - nextFrameMs);
    this.lastFrameMs = nextFrameMs + Math.floor(overdueMs / minIntervalMs) * minIntervalMs;
    return true;
  }

  private expectedFrameRateRange(): ExpectedFrameRateRange {
    const target: number = Math.max(24, Math.min(120, Math.round(this.access.getFrameRate())));
    return { min: Math.min(30, target), max: target, expected: target };
  }
}
