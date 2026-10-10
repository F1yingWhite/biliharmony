/** 真实进度样本的轻量通道，避免以媒体采样频率刷新整个播放器。 */
export interface PlayerProgressTarget {
  updateProgress: (value: number, smooth: boolean) => void;
}

export class PlayerProgressController {
  private targets: Set<PlayerProgressTarget> = new Set<PlayerProgressTarget>();
  private latestValue: number = -1;

  attach(target: PlayerProgressTarget): void {
    if (this.targets.has(target)) return;
    this.targets.add(target);
    // 控件重新出现时直接落在最新样本，不从上一次出现的位置播放入场动画。
    if (this.latestValue >= 0) target.updateProgress(this.latestValue, false);
  }

  detach(target: PlayerProgressTarget): void {
    this.targets.delete(target);
  }

  publish(seconds: number, smooth: boolean): void {
    if (!Number.isFinite(seconds) || seconds < 0) return;
    if (smooth && seconds === this.latestValue) return;
    this.latestValue = seconds;
    // false 也发布相同样本，让暂停/缓冲对齐最新真实进度；原生同目标可能沿用已有过渡。
    this.targets.forEach((target: PlayerProgressTarget) => target.updateProgress(seconds, smooth));
  }
}
