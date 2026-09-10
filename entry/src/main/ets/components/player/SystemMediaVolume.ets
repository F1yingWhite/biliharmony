import { audio } from '@kit.AudioKit';

/** 系统媒体音量读数与档位换算。写入由可见播放器中的 AVVolumePanel 完成。 */
export class SystemMediaVolume {
  private manager: audio.AudioVolumeManager = audio.getAudioManager().getVolumeManager();
  private usage: audio.StreamUsage = audio.StreamUsage.STREAM_USAGE_MOVIE;
  private listening: boolean = false;
  private onChange: (percent: number) => void = () => {};
  private changed: (event: audio.StreamVolumeEvent) => void = (event: audio.StreamVolumeEvent): void => {
    if (this.listening) this.onChange(this.percent());
  };

  level(): number { return this.manager.getVolumeByStream(this.usage); }

  percent(): number {
    try {
      const min: number = this.manager.getMinVolumeByStream(this.usage);
      const max: number = this.manager.getMaxVolumeByStream(this.usage);
      return max > min ? Math.round((this.level() - min) * 100 / (max - min)) : 0;
    } catch (e) { return -1; }
  }

  levelForPercent(percent: number): number {
    const min: number = this.manager.getMinVolumeByStream(this.usage);
    const max: number = this.manager.getMaxVolumeByStream(this.usage);
    return Math.round(min + Math.max(0, Math.min(100, percent)) * (max - min) / 100);
  }

  start(onChange: (percent: number) => void): void {
    this.stop();
    this.onChange = onChange;
    try {
      this.manager.on('streamVolumeChange', this.usage, this.changed);
      this.listening = true;
    } catch (e) {}
  }

  stop(): void {
    if (this.listening) {
      this.listening = false;
      try { this.manager.off('streamVolumeChange', this.changed); } catch (e) {}
    }
  }
}
