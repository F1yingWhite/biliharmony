/**
 * 播放器 seek 串行状态机：合并短时间请求、并行音频/视频 seek、看门狗与超时重建。
 * 从 PlayerView 抽出，组件通过回调接入 AVPlayer 与 UI 状态。
 */
import { media } from '@kit.MediaKit';

export class PlayerSeekController {
  pendingSeekMs: number = -1;
  pendingSeekPrecise: boolean = true;
  activeSeekMs: number = -1;
  activeAudioSeekMs: number = -1;
  seekInFlight: boolean = false;
  videoSeekDone: boolean = true;
  audioSeekDone: boolean = true;
  seekResumePlaying: boolean = false;

  private generation: number = 0;
  private activePrecise: boolean = true;
  private dispatchTimer: number = -1;
  private seekSpinnerTimer: number = -1;
  private seekWatchdogTimer: number = -1;
  private audioSettleTimer: number = -1;
  private activeVideo: media.AVPlayer | null = null;
  private activeAudio: media.AVPlayer | null = null;

  private getVideo: () => media.AVPlayer | null;
  private getAudio: () => media.AVPlayer | null;
  private isPrepared: () => boolean;
  private isAudioPrepared: () => boolean;
  private onBeforeDispatch: (targetMs: number, resumePlaying: boolean) => void;
  private onSpinner: (on: boolean) => void;
  private onSeekDone: (resumePlaying: boolean, targetMs: number) => void;
  private onStall: (video: media.AVPlayer | null, targetMs: number) => void;

  constructor(
    getVideo: () => media.AVPlayer | null,
    getAudio: () => media.AVPlayer | null,
    isPrepared: () => boolean,
    isAudioPrepared: () => boolean,
    onBeforeDispatch: (targetMs: number, resumePlaying: boolean) => void,
    onSpinner: (on: boolean) => void,
    onSeekDone: (resumePlaying: boolean, targetMs: number) => void,
    onStall: (video: media.AVPlayer | null, targetMs: number) => void,
  ) {
    this.getVideo = getVideo;
    this.getAudio = getAudio;
    this.isPrepared = isPrepared;
    this.isAudioPrepared = isAudioPrepared;
    this.onBeforeDispatch = onBeforeDispatch;
    this.onSpinner = onSpinner;
    this.onSeekDone = onSeekDone;
    this.onStall = onStall;
  }

  /** 外部收到一次 seek 请求，先合并到 pending；若已有 seek 在途则等待完成后再调度。 */
  request(targetMs: number, precise: boolean, resumePlaying: boolean): void {
    this.pendingSeekMs = targetMs;
    this.pendingSeekPrecise = precise;
    this.seekResumePlaying = this.seekResumePlaying || resumePlaying;
    if (this.seekInFlight) return;
    if (this.dispatchTimer >= 0) clearTimeout(this.dispatchTimer);
    this.dispatchTimer = setTimeout(() => {
      this.dispatchTimer = -1;
      this.dispatchPendingSeek();
    }, 60);
  }

  cancel(): void {
    this.generation++;
    if (this.dispatchTimer >= 0) clearTimeout(this.dispatchTimer);
    this.dispatchTimer = -1;
    this.clearSeekSpinner();
    this.clearWatchdog();
    this.clearAudioSettleTimer();
    this.pendingSeekMs = -1;
    this.pendingSeekPrecise = true;
    this.seekInFlight = false;
    this.activeSeekMs = -1;
    this.activeAudioSeekMs = -1;
    this.activeVideo = null;
    this.activeAudio = null;
    this.videoSeekDone = true;
    this.audioSeekDone = true;
    this.seekResumePlaying = false;
  }

  private async dispatchPendingSeek(): Promise<void> {
    const video: media.AVPlayer | null = this.getVideo();
    if (video === null || !this.isPrepared() || this.pendingSeekMs < 0) return;
    let targetMs: number = this.pendingSeekMs;
    const generation: number = ++this.generation;
    let precise: boolean = this.pendingSeekPrecise;
    this.pendingSeekMs = -1;
    this.activeSeekMs = targetMs;
    this.activeAudioSeekMs = -1;
    this.activeVideo = video;
    this.videoSeekDone = false;
    const audio: media.AVPlayer | null = this.getAudio();
    this.activeAudio = audio;
    this.audioSeekDone = audio === null || !this.isAudioPrepared();
    this.seekInFlight = true;
    this.onBeforeDispatch(targetMs, this.seekResumePlaying);
    // pause 是异步操作；两轨均暂停后才能定位，避免迟到的 pause 把恢复播放再次打断。
    this.armWatchdog(video, targetMs);
    try {
      const pauses: Array<Promise<void>> = [];
      if (video.state === 'playing') pauses.push(video.pause());
      if (audio !== null && this.isAudioPrepared() && audio.state === 'playing') pauses.push(audio.pause());
      await Promise.all(pauses);
    } catch (e) {
      if (generation === this.generation && this.seekInFlight) this.onStall(video, targetMs);
      return;
    }
    if (generation !== this.generation || !this.seekInFlight || this.getVideo() !== video) return;
    // 暂停期间到达的新手势直接替换目标，不必先解码已经过期的位置。
    if (this.pendingSeekMs >= 0) {
      targetMs = this.pendingSeekMs;
      precise = this.pendingSeekPrecise;
      this.pendingSeekMs = -1;
      this.activeSeekMs = targetMs;
      this.onBeforeDispatch(targetMs, this.seekResumePlaying);
    }
    this.activePrecise = precise;
    const mode: media.SeekMode = precise ? media.SeekMode.SEEK_CLOSEST : media.SeekMode.SEEK_PREV_SYNC;
    if (audio !== null && this.isAudioPrepared()) {
      try {
        this.activeAudioSeekMs = targetMs;
        this.audioSeekDone = false;
        // Media Kit 的 SeekMode 只用于视频关键帧；音频传 mode 会在部分设备上导致 seekDone 丢失。
        audio.seek(targetMs);
        // 个别设备丢失音轨 seekDone 时用播放头补充验证；仍未到达则继续等待看门狗恢复。
        this.audioSettleTimer = setTimeout(() => {
          this.audioSettleTimer = -1;
          if (this.activeAudio === audio && this.seekInFlight && !this.audioSeekDone) {
            // 无回调时必须以播放头验证，不能将仍在旧位置的音轨视为定位完成。
            if (Math.abs(audio.currentTime - this.activeAudioSeekMs) <= 150) {
              this.audioSeekDone = true;
              this.finishSeek();
            }
          }
        }, 900);
      } catch (e) {
        this.onStall(video, targetMs);
        return;
      }
    }
    try {
      video.seek(targetMs, mode);
    } catch (e) {
      this.seekInFlight = false;
      this.onStall(video, targetMs);
      return;
    }
    if (this.seekSpinnerTimer >= 0) clearTimeout(this.seekSpinnerTimer);
    this.seekSpinnerTimer = setTimeout(() => {
      this.seekSpinnerTimer = -1;
      if (this.seekInFlight && this.getVideo() === video) this.onSpinner(true);
    }, 180);
    this.armWatchdog(video, targetMs);
  }

  onVideoSeekDone(video: media.AVPlayer, positionMs: number): void {
    if (this.activeVideo !== video || !this.seekInFlight) return;
    // seekDone 回报的是本次请求位置。过滤同一 AVPlayer 上延迟到达的旧回调，避免提前恢复。
    if (this.activePrecise && this.activeSeekMs >= 0 && Math.abs(positionMs - this.activeSeekMs) > 500) return;
    // 关键帧恢复的实际落点可能偏离请求数秒；音频必须跟随实际视频位置。
    if (!this.activePrecise && this.activeAudio !== null && Math.abs(positionMs - this.activeAudioSeekMs) > 150) {
      this.activeAudioSeekMs = positionMs;
      this.audioSeekDone = false;
      try {
        this.activeAudio.seek(positionMs);
      } catch (e) {
        this.onStall(video, positionMs);
        return;
      }
    }
    this.activeSeekMs = positionMs;
    this.videoSeekDone = true;
    this.finishSeek();
  }

  onAudioSeekDone(audio: media.AVPlayer, positionMs: number): void {
    if (this.activeAudio !== audio || !this.seekInFlight || this.activeAudioSeekMs < 0) return;
    if (Math.abs(positionMs - this.activeAudioSeekMs) > 500) return;
    this.clearAudioSettleTimer();
    this.audioSeekDone = true;
    this.finishSeek();
  }

  private finishSeek(): void {
    if (!this.seekInFlight || !this.videoSeekDone || !this.audioSeekDone) return;
    this.clearWatchdog();
    this.clearSeekSpinner();
    this.clearAudioSettleTimer();
    const completedTargetMs: number = this.activeSeekMs;
    this.generation++;
    this.seekInFlight = false;
    this.activeSeekMs = -1;
    this.activeAudioSeekMs = -1;
    this.activeVideo = null;
    this.activeAudio = null;
    if (this.pendingSeekMs >= 0) {
      this.dispatchPendingSeek();
      return;
    }
    const resume: boolean = this.seekResumePlaying;
    this.seekResumePlaying = false;
    this.onSeekDone(resume, completedTargetMs);
  }

  private armWatchdog(video: media.AVPlayer, targetMs: number): void {
    this.clearWatchdog();
    this.seekWatchdogTimer = setTimeout(() => {
      this.seekWatchdogTimer = -1;
      if (this.activeVideo === video && this.seekInFlight) {
        const latestTarget: number = this.pendingSeekMs >= 0 ? this.pendingSeekMs : targetMs;
        this.pendingSeekMs = -1;
        this.onStall(video, latestTarget);
      }
    }, 4000);
  }

  private clearWatchdog(): void {
    if (this.seekWatchdogTimer >= 0) {
      clearTimeout(this.seekWatchdogTimer);
      this.seekWatchdogTimer = -1;
    }
  }

  private clearSeekSpinner(): void {
    if (this.seekSpinnerTimer >= 0) {
      clearTimeout(this.seekSpinnerTimer);
      this.seekSpinnerTimer = -1;
    }
  }

  private clearAudioSettleTimer(): void {
    if (this.audioSettleTimer >= 0) {
      clearTimeout(this.audioSettleTimer);
      this.audioSettleTimer = -1;
    }
  }

}
