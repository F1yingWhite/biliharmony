import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { PlayerTrackPair } from './PlayerTrackPair';
import { PlayerPlaybackState } from './PlayerPlaybackState';

export interface PlayerAudioSyncEvents {
  canPlay: () => boolean;
  muted: () => boolean;
  isSeeking: () => boolean;
  changed: () => void;
  clock: (action: string) => void;
  rate: (value: number) => void;
  error: (audio: media.AVPlayer, message: string) => void;
}

/** 双轨时间和出声边界。只操作所属 pair；创建/换源/释放由 pair/session 管理。 */
export class PlayerAudioSync {
  private readonly pair: PlayerTrackPair;
  private readonly state: PlayerPlaybackState;
  private readonly host: PlayerAudioSyncEvents;
  pendingAudioPause: Promise<void> | null = null;
  pendingAudioPausePlayer: media.AVPlayer | null = null;
  lastAudioSyncAtMs: number = -1;
  audioDriftSamples: number = 0;
  audioStartPending: boolean = false;
  audioGateSeekPending: boolean = false;
  audioGateSeekTargetMs: number = -1;
  private audioGateTimer: number = -1;
  firstFrameMuteArmed: boolean = false;
  private firstFrameMuteTimer: number = -1;
  private firstFrameMuteTargetMs: number = -1;
  private muteGeneration: number = 0;
  seekRecoveryActive: boolean = false;
  speedTransitionUntilMs: number = 0;
  private audioSyncRate: number = -1;
  private audioSyncPlayer: media.AVPlayer | null = null;
  private bufferingAudioPause: Promise<void> | null = null;
  private bufferingAudioGeneration: number = -1;
  private bufferGeneration: number = 0;
  private speedBufferTimer: number = -1;

  constructor(pair: PlayerTrackPair, state: PlayerPlaybackState, host: PlayerAudioSyncEvents) {
    this.pair = pair;
    this.state = state;
    this.host = host;
  }

  reset(): void {
    this.cancelAudioGate();
    this.cancelFirstFrameMute(false);
    this.seekRecoveryActive = false;
    this.state.seekRecoveryCoverVisible = false;
    this.bufferGeneration++;
    this.bufferingAudioPause = null;
    if (this.speedBufferTimer >= 0) clearTimeout(this.speedBufferTimer);
    this.speedBufferTimer = -1;
  }

  beforeSeek(targetMs: number, resume: boolean): void {
    this.cancelFirstFrameMute(false);
    this.cancelAudioGate();
    this.audioDriftSamples = 0;
    this.seekRecoveryActive = resume;
    this.state.seekRecoveryCoverVisible = false;
    if (resume) this.muteImmediately();
  }

  onAudioSeekDone(position: number): boolean {
    const audio: media.AVPlayer | null = this.pair.audio;
    if (audio === null || !this.audioGateSeekPending) return false;
    if (this.audioGateSeekTargetMs >= 0 && Math.abs(position - this.audioGateSeekTargetMs) <= 500) {
      this.finishGatedAudioStart(audio);
    }
    return true;
  }

  onBuffer(kind: media.BufferingInfoType): void {
    const video: media.AVPlayer | null = this.pair.video;
    if (video === null || this.state.backgroundAudioOnly) return;
    if (kind === media.BufferingInfoType.BUFFERING_START) {
      this.bufferGeneration++;
      if (Date.now() < this.speedTransitionUntilMs) {
        if (this.speedBufferTimer < 0) this.speedBufferTimer = setTimeout(() => {
          this.speedBufferTimer = -1;
          if (this.pair.video === video && !this.state.backgroundAudioOnly) this.pauseForBuffer(video);
        }, 180);
      } else this.pauseForBuffer(video);
    } else if (kind === media.BufferingInfoType.BUFFERING_END) {
      if (this.speedBufferTimer >= 0) clearTimeout(this.speedBufferTimer);
      this.speedBufferTimer = -1;
      const completed: number = this.bufferGeneration;
      const audioGeneration: number = this.bufferingAudioGeneration;
      const paused: Promise<void> | null = this.bufferingAudioPause;
      this.bufferingAudioPause = null;
      if (paused !== null) paused.then(() => {
        if (this.pair.video !== video || completed !== this.bufferGeneration || !this.state.playing ||
          audioGeneration !== this.audioGateGeneration || this.state.backgroundAudioOnly || this.state.seekLocked) return;
        this.gateAudioStart();
        this.tryStartGatedAudio();
      });
      if (!this.host.isSeeking() && !this.seekRecoveryActive) {
        this.state.buffering = false;
        this.host.clock('start');
        this.host.changed();
      }
    }
  }

  private pauseForBuffer(video: media.AVPlayer): void {
    if (this.state.seekLocked || this.host.isSeeking()) return;
    this.state.buffering = true;
    this.host.clock('pause');
    this.host.changed();
    const audio: media.AVPlayer | null = this.pair.audio;
    if (audio === null || !this.pair.audioPrepared || !this.state.playing || this.bufferingAudioPause !== null) return;
    this.cancelAudioGate();
    const generation: number = this.audioGateGeneration;
    this.bufferingAudioGeneration = generation;
    try {
      audio.setVolume(0);
      this.bufferingAudioPause = this.pauseAudioForSync(audio).catch(() => {
        if (this.pair.video === video && this.pair.audio === audio && generation === this.audioGateGeneration) {
          this.host.error(audio, '缓冲暂停失败');
        }
      });
    } catch (e) { this.host.error(audio, '缓冲暂停失败'); }
  }

  muteImmediately(): void {
    try {
      if (this.pair.video !== null && this.pair.prepared) this.pair.video.setVolume(0);
      if (this.pair.audio !== null && this.pair.audioPrepared) this.pair.audio.setVolume(0);
    } catch (e) {
      // 播放器正处于切源/释放边界时无需重复处理。
    }
  }

  restoreUserVolume(): void {
    try {
      const restoreVolume: number = this.host.muted() ? 0 : 1;
      if (this.pair.video !== null && this.pair.prepared) this.pair.video.setVolume(restoreVolume);
      if (this.pair.audio !== null && this.pair.audioPrepared) this.pair.audio.setVolume(restoreVolume);
    } catch (e) {
      // 播放器正处于切源/释放边界时无需重复处理。
    }
  }

  /** 起播/恢复播放前调用：双轨静音并等目标附近的首个 timeUpdate，超时后安全恢复。 */
  armFirstFrameMute(targetMs: number = -1, fallbackMs: number = 900): void {
    const generation: number = ++this.muteGeneration;
    if (this.firstFrameMuteTimer >= 0) clearTimeout(this.firstFrameMuteTimer);
    this.firstFrameMuteArmed = true;
    this.firstFrameMuteTargetMs = targetMs;
    this.muteImmediately();
    this.firstFrameMuteTimer = setTimeout(() => {
      if (generation !== this.muteGeneration) return;
      this.firstFrameMuteTimer = -1;
      this.disarmFirstFrameMute();
    }, fallbackMs);
  }

  cancelFirstFrameMute(restore: boolean): void {
    this.muteGeneration++;
    if (this.firstFrameMuteTimer >= 0) {
      clearTimeout(this.firstFrameMuteTimer);
      this.firstFrameMuteTimer = -1;
    }
    this.firstFrameMuteArmed = false;
    this.firstFrameMuteTargetMs = -1;
    if (restore) this.restoreUserVolume();
  }

  /** 过滤 seek 前排队的旧 timeUpdate；关键帧定位允许与请求位置存在一个 GOP 的偏差。 */
  canReleaseFrameMute(timeMs: number): boolean {
    if (!this.firstFrameMuteArmed) return false;
    if (this.firstFrameMuteTargetMs < 0) return timeMs > 50;
    return Math.abs(timeMs - this.firstFrameMuteTargetMs) <= 1200;
  }

  /** 首帧已上屏（或兜底超时）：恢复用户手势音量。未武装时不写音量，避免与离页临时静音互踩。 */
  disarmFirstFrameMute(): void {
    if (!this.firstFrameMuteArmed) return;
    this.cancelFirstFrameMute(true);
    if (this.seekRecoveryActive) {
      this.seekRecoveryActive = false;
      this.state.seekRecoveryCoverVisible = false;
      this.state.buffering = false;
      if (this.state.playing) this.host.clock('start');
      this.host.changed();
    }
  }

  private resetAudioSyncRate(): void {
    const audio: media.AVPlayer | null = this.pair.audio;
    if (audio !== null && audio === this.audioSyncPlayer && this.audioSyncRate >= 0 && this.pair.audioPrepared) {
      try { audio.setPlaybackRate(this.state.playbackRate); } catch (e) {}
    }
    this.audioSyncRate = -1;
    this.audioSyncPlayer = null;
  }

  checkAudioSync(videoTimeMs: number): void {
    // 两轨倍速切换异步生效；稳定期间不依据瞬时钟差再次切速。
    if (Date.now() < this.speedTransitionUntilMs) {
      this.audioDriftSamples = 0;
      return;
    }
    const audio: media.AVPlayer | null = this.pair.audio;
    if (this.state.holdSpeedActive) {
      // 临时倍速由手势控制器接管，不能在 timeUpdate 中改回设置页倍速。
      this.audioSyncRate = -1;
      this.audioSyncPlayer = null;
      this.audioDriftSamples = 0;
      return;
    }
    if (!this.state.playing || this.state.backgroundAudioOnly || this.state.buffering || this.firstFrameMuteArmed ||
      this.audioStartPending || this.audioGateSeekPending || this.state.seekLocked ||
      this.host.isSeeking() || audio === null || !this.pair.audioPrepared || audio.state !== 'playing') {
      this.audioDriftSamples = 0;
      this.resetAudioSyncRate();
      return;
    }
    const driftMs: number = audio.currentTime - (this.pair.video?.currentTime ?? videoTimeMs);
    if (Math.abs(driftMs) <= 100) {
      this.audioDriftSamples = 0;
      this.resetAudioSyncRate();
      return;
    }
    // 350ms 才开始调整，回到 100ms 内停止，避免时钟回调抖动导致来回切速。
    if (Math.abs(driftMs) <= 350 && this.audioSyncRate < 0) {
      this.audioDriftSamples = 0;
      return;
    }
    this.audioDriftSamples++;
    const nowMs: number = Date.now();
    if (this.audioDriftSamples < 3 || nowMs - this.lastAudioSyncAtMs < 3000) return;
    this.audioDriftSamples = 0;
    // 连续播放期间不再静音、pause 或 seek；以最多 3% 的速度差逐步收敛。
    const rate: number = Math.max(0.125, Math.min(8, this.state.playbackRate * (driftMs > 0 ? 0.97 : 1.03)));
    this.lastAudioSyncAtMs = nowMs;
    if (this.audioSyncPlayer === audio && Math.abs(this.audioSyncRate - rate) < 0.001) return;
    try {
      audio.setPlaybackRate(rate);
      this.audioSyncPlayer = audio;
      this.audioSyncRate = rate;
    } catch (e) {
      // 设备不支持微调时保留连续播放，不能退回循环暂停/定位。
      this.resetAudioSyncRate();
    }
  }

  /** 起播时先等待视频播放头推进，禁止超时后绕过画面门控单独播放音频。 */
  gateAudioStart(): void {
    const audio: media.AVPlayer | null = this.pair.audio;
    if (audio === null || !this.pair.audioPrepared) return;
    this.cancelAudioGate();
    this.audioStartPending = true;
  }

  /** 视频已开始推进：先把尚未播放的 DASH 音轨定位到当前视频时间，再在 seekDone 后启动。 */
  tryStartGatedAudio(): void {
    if (!this.audioStartPending || this.audioGateSeekPending || !this.state.playing) return;
    if (this.state.buffering || this.state.seekLocked || this.state.backgroundAudioOnly ||
      this.host.isSeeking()) return;
    const video: media.AVPlayer | null = this.pair.video;
    const audio: media.AVPlayer | null = this.pair.audio;
    if (video === null || !this.pair.prepared || audio === null || !this.pair.audioPrepared) return;
    const targetMs: number = Math.max(0, video.currentTime);
    if (Math.abs(audio.currentTime - targetMs) > 80) {
      this.alignGatedAudio(video, audio);
      return;
    }
    this.finishGatedAudioStart(audio);
  }

  private audioGateGeneration: number = 0;

  /** 自动恢复只暂停、定位音轨；用户拖动仍由双轨 seek 状态机处理。 */
  private async alignGatedAudio(video: media.AVPlayer, audio: media.AVPlayer): Promise<void> {
    const generation: number = this.audioGateGeneration;
    this.audioGateSeekPending = true;
    try {
      audio.setVolume(0);
      await this.pauseAudioForSync(audio);
      if (generation !== this.audioGateGeneration || this.pair.video !== video || this.pair.audio !== audio ||
        !this.state.playing || this.state.seekLocked || this.state.backgroundAudioOnly) return;
      this.audioGateSeekTargetMs = Math.max(0, video.currentTime);
      audio.seek(this.audioGateSeekTargetMs);
      this.audioGateTimer = setTimeout(() => {
        if (generation !== this.audioGateGeneration || this.pair.audio !== audio || !this.audioGateSeekPending) return;
        this.audioGateTimer = -1;
        if (Math.abs(audio.currentTime - this.audioGateSeekTargetMs) <= 500) {
          this.finishGatedAudioStart(audio);
        } else {
          this.cancelAudioGate();
          this.host.error(audio, '音轨定位超时');
        }
      }, 1500);
    } catch (e) {
      if (generation !== this.audioGateGeneration || this.pair.audio !== audio) return;
      this.cancelAudioGate();
      this.host.error(audio, '音轨同步失败');
    }
  }

  finishGatedAudioStart(audio: media.AVPlayer): void {
    if (this.audioGateTimer >= 0) {
      clearTimeout(this.audioGateTimer);
      this.audioGateTimer = -1;
    }
    this.audioGateSeekPending = false;
    this.audioGateSeekTargetMs = -1;
    this.audioStartPending = false;
    if (this.pair.audio !== audio || !this.pair.audioPrepared || !this.state.playing || !this.host.canPlay()) return;
    try {
      this.restoreUserVolume();
      audio.play().catch(() => { if (this.pair.audio === audio) this.host.error(audio, '音轨启动失败'); });
    } catch (e) {
    }
  }

  /** 所有自动音轨暂停共用屏障，用户 seek 必须等旧暂停真正完成。 */
  pauseAudioForSync(audio: media.AVPlayer): Promise<void> {
    if (this.pendingAudioPausePlayer === audio && this.pendingAudioPause !== null) return this.pendingAudioPause;
    const pending: Promise<void> = audio.state === 'playing' ? audio.pause() : Promise.resolve();
    this.pendingAudioPause = pending;
    this.pendingAudioPausePlayer = audio;
    const clearPending = (): void => {
      if (this.pendingAudioPause === pending) {
        this.pendingAudioPause = null;
        this.pendingAudioPausePlayer = null;
      }
    };
    pending.then(clearPending, clearPending);
    return pending;
  }

  cancelAudioGate(): void {
    this.resetAudioSyncRate();
    this.audioGateGeneration++;
    if (this.audioGateTimer >= 0) {
      clearTimeout(this.audioGateTimer);
      this.audioGateTimer = -1;
    }
    this.audioGateSeekPending = false;
    this.audioGateSeekTargetMs = -1;
    this.audioStartPending = false;
  }

  setPlaybackSpeed(rate: number): void {
    this.audioSyncRate = -1;
    this.audioSyncPlayer = null;
    this.audioDriftSamples = 0;
    this.lastAudioSyncAtMs = Date.now();
    this.speedTransitionUntilMs = this.lastAudioSyncAtMs + 1500;
    this.state.playbackRate = rate;
    this.host.rate(rate);

    const p: media.AVPlayer | null = this.pair.video;
    if (p !== null && this.pair.prepared) {
      try {
        p.setPlaybackRate(rate);
        if (this.pair.audio !== null && this.pair.audioPrepared) this.pair.audio.setPlaybackRate(rate);
      } catch (e) {
        this.state.playbackRate = 1.0;
        this.host.rate(1.0);
        try { p.setPlaybackRate(1.0); } catch (e) {}
        try { if (this.pair.audio !== null && this.pair.audioPrepared) this.pair.audio.setPlaybackRate(1.0); } catch (e) {}
      }
    }
  }

  applyTemporarySpeed(rate: number): void {
    // 直接覆盖微调速率，不能先恢复旧倍速再设置目标倍速，造成一次手势两次重配。
    this.audioSyncRate = -1;
    this.audioSyncPlayer = null;
    this.audioDriftSamples = 0;
    this.lastAudioSyncAtMs = Date.now();
    this.speedTransitionUntilMs = this.lastAudioSyncAtMs + 1500;
    let videoApplied: boolean = false;
    let audioApplied: boolean = false;
    try {
      if (this.pair.video !== null && this.pair.prepared) {
        this.pair.video.setPlaybackRate(rate);
        videoApplied = true;
      }
    } catch (e) {
      if (DEBUG) {
        hilog.error(0x0000, 'BiliPlayback',
          'holdSpeed.video.failed rate=%{public}s', String(rate));
      }
    }
    try {
      if (this.pair.audio !== null && this.pair.audioPrepared) {
        this.pair.audio.setPlaybackRate(rate);
        audioApplied = true;
      }
    } catch (e) {
      if (DEBUG) {
        hilog.error(0x0000, 'BiliPlayback',
          'holdSpeed.audio.failed rate=%{public}s', String(rate));
      }
    }
    if (DEBUG) {
      hilog.info(0x0000, 'BiliPlayback',
        'holdSpeed.apply rate=%{public}s video=%{public}s audio=%{public}s',
        String(rate), videoApplied ? 'true' : 'false', audioApplied ? 'true' : 'false');
    }
    // 弹幕设置速度保持不变，仅让滚动位移跟随视频当前实际倍速。
    if (videoApplied) this.host.rate(rate);
  }

}
