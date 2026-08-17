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
    this.lastGestureApplyMs = Date.now();
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
      const secondsPerVp: number = duration / 1.6;
      const preview: number = Math.max(0, Math.min(duration, this.panStartTime + offsetX * secondsPerVp));
      this.onSeekPreview(preview);
      return;
    }
    if (this.panMode === 'brightness') {
      this.panGestureActive = false;
      this.onAdjust('brightness', Math.abs(offsetY / 100));
      const travel: number = viewWidth * 0.8;
      const value: number = Math.max(0.02, Math.min(1, this.panStartBrightness - offsetY / travel));
      this.gestureBrightness = value;
      this.onBrightness(value);
      const now: number = Date.now();
      if (now - this.lastGestureApplyMs >= 16) this.onBrightnessApply(value);
      return;
    }
    if (this.panMode === 'volume') {
      this.panGestureActive = false;
      this.onAdjust('volume', offsetY / 100);
      const travel: number = viewWidth * 0.8;
      const value: number = Math.max(0, Math.min(100, this.panStartVolume - offsetY * 100 / travel));
      this.gestureVolume = value;
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
