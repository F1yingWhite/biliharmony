/**
 * 播放器手势控制器：横滑 seek、左侧亮度、右侧音量。
 * 从 PlayerView 抽出，只保留手势数学与本地模式，UI 状态由回调写回组件 @State。
 */
import { Immersive } from '../common/Immersive';

export class PlayerGestureController {
  panStartTime: number = 0;
  panStartX: number = 0;
  panStartBrightness: number = 0.5;
  panStartVolume: number = 100;
  gestureBrightness: number = 0.5;
  gestureVolume: number = 100;
  panGestureActive: boolean = false;
  panMode: string = '';
  private lastGestureApplyMs: number = 0;

  private onSeekPreview: (value: number) => void;
  private onSeek: (value: number) => void;
  private onAdjust: (kind: string, percent: number) => void;
  private onVolume: (value: number) => void;
  private onVolumeApply: (value: number) => void;
  private onBrightness: (value: number) => void;
  private onBrightnessApply: (value: number) => void;

  constructor(
    onSeekPreview: (value: number) => void,
    onSeek: (value: number) => void,
    onAdjust: (kind: string, percent: number) => void,
    onVolume: (value: number) => void,
    onVolumeApply: (value: number) => void,
    onBrightness: (value: number) => void,
    onBrightnessApply: (value: number) => void,
  ) {
    this.onSeekPreview = onSeekPreview;
    this.onSeek = onSeek;
    this.onAdjust = onAdjust;
    this.onVolume = onVolume;
    this.onVolumeApply = onVolumeApply;
    this.onBrightness = onBrightness;
    this.onBrightnessApply = onBrightnessApply;
  }

  loadInitials(): void {
    const brightness: number = Immersive.windowBrightness();
    if (brightness >= 0) this.gestureBrightness = brightness;
  }

  beginPan(eventX: number, viewWidth: number, playheadSec: number, duration: number): void {
    if (duration <= 0) return;
    this.panStartTime = playheadSec;
    this.panStartX = eventX;
    this.panGestureActive = false;
    this.panMode = '';
    this.panStartBrightness = this.gestureBrightness;
    this.panStartVolume = this.gestureVolume;
    this.onSeekPreview(-1);
    this.onAdjust('', -1);
  }

  updatePan(offsetX: number, offsetY: number, viewWidth: number, duration: number): void {
    if (this.panMode.length === 0) {
      const absX: number = Math.abs(offsetX);
      const absY: number = Math.abs(offsetY);
      if (absX > absY * 1.15) {
        this.panMode = 'seek';
      } else if (absY > absX * 1.15) {
        this.panMode = this.panStartX < viewWidth / 2 ? 'brightness' : 'volume';
      }
    }
    if (this.panMode === 'seek') {
      this.panGestureActive = true;
      // 横滑 seek 应“一个屏幕宽度 ≈ 拖动整个视频”，而不是用一个近似常数 1.6vp
      // 把小幅度手势放大成首/尾跳变。viewWidth 是手势所在区域的 vp 宽度。
      const secondsPerVp: number = viewWidth > 0 ? duration / viewWidth : duration;
      // 手势 seek 目标最多到结尾前 0.5s：拖到头不触发"自然播完"，防止误切下一个视频。
      const maxPreview: number = duration > 0 ? Math.max(0, duration - 0.5) : duration;
      const preview: number = Math.max(0, Math.min(maxPreview, this.panStartTime + offsetX * secondsPerVp));
      this.onSeekPreview(preview);
      return;
    }
    if (this.panMode === 'brightness') {
      this.panGestureActive = false;
      // travel 兜底：viewWidth 在播放器尚未完成布局时为 0/1（弹幕引擎初始值），
      // 直接乘 0.8 会把任何微小 offsetY 的都按 0.8 除 → 亮度瞬间 clamp 到最亮/最暗。
      // 下限 160vp 保证灵敏度有上限：即使视口未知，轻抖最多偏移几个百分点。
      const travel: number = Math.max(160, viewWidth * 0.8);
      const value: number = Math.max(0.02, Math.min(1, this.panStartBrightness - offsetY / travel));
      this.gestureBrightness = value;
      // 提示气泡展示整数百分比（0~100），不能把原始小数/偏移量直接拼进文本。
      this.onAdjust('brightness', Math.round(value * 100));
      this.onBrightness(value);
      const now: number = Date.now();
      // 节奏限制：最多每 16ms 提交一次真实窗口亮度，避免手势高频回调排队；
      // 只记录“实际应用”的时间点，且应用后立即刷新，保证最新值总会被提交。
      if (now - this.lastGestureApplyMs >= 16) {
        this.lastGestureApplyMs = now;
        this.onBrightnessApply(value);
      }
      return;
    }
    if (this.panMode === 'volume') {
      this.panGestureActive = false;
      // 与亮度共用 travel 下限：viewWidth 未就绪时避免音量一步跳满/归零。
      const travel: number = Math.max(160, viewWidth * 0.8);
      const value: number = Math.max(0, Math.min(100, this.panStartVolume - offsetY * 100 / travel));
      this.gestureVolume = value;
      this.onAdjust('volume', Math.round(value));
      this.onVolume(value);
      const now: number = Date.now();
      if (now - this.lastGestureApplyMs >= 16) {
        this.lastGestureApplyMs = now;
        this.onVolumeApply(value);
      }
      return;
    }
  }

  endPan(): void {
    if (this.panMode === 'seek') {
      this.onSeek(-1);
    }
    this.panMode = '';
    this.panGestureActive = false;
  }

  /**
   * 计算当前进度展示值：拖动中用预览值，否则用播放头。
   */
  displayTime(current: number): number {
    return this.panGestureActive ? current : current;
  }
}
