/**
 * 播放器手势控制器：横滑 seek、左侧亮度、右侧音量。
 * 从 PlayerView 抽出，只保留手势数学与本地模式，UI 状态由回调写回组件 @State。
 */
import { Immersive } from '../../common/Immersive';
import { AppTheme } from '../../common/AppTheme';

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
  private panStarted: boolean = false;
  private panSeekWidth: number = 0;
  private panSeekDuration: number = 0;
  private panSeekRange: number = 0;

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
    let brightness: number = Immersive.windowBrightness();
    // 窗口跟随系统（-1）时回退到上次手势设置的亮度：否则每个视频首次上下滑都会从默认 50% 起跳。
    if (brightness < 0) brightness = AppTheme.loadLastBrightness();
    if (brightness >= 0) this.gestureBrightness = Math.max(0.02, Math.min(1, brightness));
  }

  beginPan(eventX: number, viewWidth: number, playheadSec: number, duration: number): void {
    this.loadInitials();
    this.lastGestureApplyMs = 0;
    this.panStarted = true;
    this.panStartTime = Number.isFinite(playheadSec) ? playheadSec : 0;
    this.panStartX = eventX;
    // 一次横滑最多移动 60 秒，长视频的小幅定位不随总时长放大。
    // 起手时固定比例，旋转/布局与时长更新不能让同一次手势突然跳变。
    this.panSeekWidth = Number.isFinite(viewWidth) && viewWidth > 1 ? viewWidth : 0;
    this.panSeekDuration = Number.isFinite(duration) && duration > 0 &&
      Number.isFinite(playheadSec) && playheadSec >= 0 ? duration : 0;
    this.panSeekRange = Math.min(this.panSeekDuration, 60);
    this.panGestureActive = false;
    this.panMode = '';
    this.panStartBrightness = this.gestureBrightness;
    this.panStartVolume = this.gestureVolume;
    this.onSeekPreview(-1);
    this.onAdjust('', -1);
  }

  updatePan(offsetX: number, offsetY: number, viewWidth: number, duration: number): void {
    if (!this.panStarted) return;
    if (!Number.isFinite(offsetX) || !Number.isFinite(offsetY)) {
      this.cancelPan();
      return;
    }
    // 注意：不能在这里刷新 lastGestureApplyMs，否则下面的 16ms 节流永假，
    // onBrightnessApply/onVolumeApply 永远触发不到（亮度调节失效的根因）。
    if (this.panMode.length === 0) {
      const absX: number = Math.abs(offsetX);
      const absY: number = Math.abs(offsetY);
      if (this.panSeekWidth > 0 && this.panSeekRange > 0 && absX > absY * 1.15) {
        this.panMode = 'seek';
      } else if (absY > absX * 1.15) {
        this.panMode = this.panStartX < viewWidth / 2 ? 'brightness' : 'volume';
      }
    }
    if (this.panMode === 'seek') {
      this.panGestureActive = true;
      const ratio: number = Math.max(-1, Math.min(1, offsetX / this.panSeekWidth));
      // 手势 seek 目标最多到结尾前 0.5s：拖到头不触发"自然播完"，防止误切下一个视频。
      const maxPreview: number = Math.max(0, this.panSeekDuration - 0.5);
      const preview: number = Math.max(0, Math.min(maxPreview, this.panStartTime + ratio * this.panSeekRange));
      this.onSeekPreview(preview);
      return;
    }
    if (this.panMode === 'brightness') {
      this.panGestureActive = false;
      // travel 兜底：viewWidth 在播放器尚未完成布局时为 0/1（弹幕引擎初始值），
      // 直接乘 0.8 会把任何微小 offsetY 的都按 0.8 除 → 亮度瞬间 clamp 到最亮/最暗。
      // 下限 160vp 保证灵敏度有上限：即使视口未知，轻抖最多偏移几个百分点。
      const travel: number = Number.isFinite(viewWidth) ? Math.max(160, viewWidth * 0.8) : 160;
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
      const travel: number = Number.isFinite(viewWidth) ? Math.max(160, viewWidth * 0.8) : 160;
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

  isPanInProgress(): boolean {
    return this.panStarted;
  }

  endPan(): void {
    if (!this.panStarted) return;
    const mode: string = this.panMode;
    // 先结束本地状态，回调中的换源/重播或重复 End 不可再次提交旧落点。
    this.panStarted = false;
    this.panMode = '';
    this.panGestureActive = false;
    if (mode === 'seek') {
      this.onSeek(-1);
    }
    if (mode === 'volume') this.onVolumeApply(this.gestureVolume);
    if (mode === 'brightness') this.onBrightnessApply(this.gestureBrightness);
  }

  cancelPan(): void {
    if (!this.panStarted) return;
    this.panStarted = false;
    this.panMode = '';
    this.panGestureActive = false;
    this.onSeekPreview(-1);
    this.onAdjust('', -1);
  }

  /**
   * 计算当前进度展示值：拖动中用预览值，否则用播放头。
   */
  displayTime(current: number): number {
    return this.panGestureActive ? current : current;
  }
}
