/**
 * 直播弹幕时钟：DisplaySync 驱动的按帧推进与异常 ROM 的 setInterval 兜底。
 * 与 PlayerDanmakuClock 同构：只负责"何时推进下一帧"，队列/画布状态由 LiveDanmakuRenderer 持有。
 * 独立成 live 侧模块：渲染器只经最小接口（LiveDanmakuFrameClock）注入，不把 DisplaySync 拖进纯逻辑单测环境。
 */
import { displaySync } from '@kit.ArkGraphics2D';

/** 渲染器读写面（成员用属性+箭头函数语法，满足 ArkTS 对象字面量检查）。 */
export interface LiveDanmakuClockAccess {
  /** playing && enabled：暂停/关弹幕时不推进。 */
  canRender: () => boolean;
  /** 还有已上屏弹幕或待喷队列：无事可做时不空转。 */
  hasWork: () => boolean;
  getFrameRate: () => number;
  /** 推进一帧：放队列 + 绘制；画布与队列清空后渲染器会回调 stop() 自停。 */
  renderFrame: (frameTimeMs: number) => void;
}

export class LiveDanmakuClock {
  private readonly access: LiveDanmakuClockAccess;
  private running: boolean = false;
  private lastFrameMs: number = 0;
  private displaySync: displaySync.DisplaySync | null = null;
  private fallbackTick: number = -1;

  constructor(access: LiveDanmakuClockAccess) {
    this.access = access;
  }

  isRunning(): boolean {
    return this.running;
  }

  start(): void {
    if (this.running || !this.access.hasWork()) {
      return;
    }
    this.lastFrameMs = 0;
    this.running = true;
    try {
      if (this.displaySync === null) {
        const sync: displaySync.DisplaySync = displaySync.create();
        sync.setExpectedFrameRateRange(this.expectedFrameRateRange());
        sync.on('frame', (info: displaySync.IntervalInfo): void => {
          if (this.running && this.access.canRender() && this.access.hasWork()) {
            const frameTimeMs: number = info.timestamp / 1_000_000;
            if (this.shouldRenderFrame(frameTimeMs)) this.access.renderFrame(frameTimeMs);
          }
        });
        this.displaySync = sync;
      }
      this.displaySync.start();
    } catch (e) {
      // API 26 正常走 DisplaySync；仅为异常 ROM 保留可播放兜底（与播放器弹幕时钟同构）。
      this.fallbackTick = setInterval(() => {
        if (this.running && this.access.canRender() && this.access.hasWork()) {
          const frameTimeMs: number = Date.now();
          if (this.shouldRenderFrame(frameTimeMs)) this.access.renderFrame(frameTimeMs);
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

  /** 停止推进（保留已上屏弹幕与待喷队列）；清屏/清队等画布状态由渲染器自己完成。 */
  stop(): void {
    this.stopClock();
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
    // 与播放器时钟同款：按用户选择的帧率节流并沿目标时间线累积，
    // 实际位移按两次绘制的真实时间差推进，刷新率不足时不会慢放。
    const minIntervalMs: number = 1000 / Math.max(24, this.access.getFrameRate());
    if (this.lastFrameMs <= 0) {
      this.lastFrameMs = frameTimeMs;
      return true;
    }
    const nextFrameMs: number = this.lastFrameMs + minIntervalMs;
    if (frameTimeMs + 0.5 < nextFrameMs) {
      return false;
    }
    const overdueMs: number = Math.max(0, frameTimeMs - nextFrameMs);
    this.lastFrameMs = nextFrameMs + Math.floor(overdueMs / minIntervalMs) * minIntervalMs;
    return true;
  }

  private expectedFrameRateRange(): ExpectedFrameRateRange {
    const target: number = Math.max(24, Math.min(120, Math.round(this.access.getFrameRate())));
    return { min: Math.min(30, target), max: target, expected: target };
  }
}
