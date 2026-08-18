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
    // 注意：不能在这里刷新 lastGestureApplyMs，否则下面的 16ms 节流永假，
    // onBrightnessApply/onVolumeApply 永远触发不到（亮度调节失效的根因）。
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
      const travel: number = viewWidth * 0.8;
      const value: number = Math.max(0.02, Math.min(1, this.panStartBrightness - offsetY / travel));
      this.gestureBrightness = value;
      // 提示气泡展示整数百分比（0~100），不能把原始小数/偏移量直接拼进文本。
      this.onAdjust('brightness', Math.round(value * 100));
      this.onBrightness(value);
      const now: number = Date.now();
      if (now - this.lastGestureApplyMs >= 16) {
        this.lastGestureApplyMs = now;
        this.onBrightnessApply(value);
      }
      return;
    }
    if (this.panMode === 'volume') {
      this.panGestureActive = false;
      const travel: number = viewWidth * 0.8;
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
