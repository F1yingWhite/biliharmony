import { media } from '@kit.MediaKit';
import { BiliApi } from '../../api/BiliApi';
import { PlayUrlInfo, VideoQualityOption } from '../../model/Models';
import { PlayerQualityPreference } from '../../common/PlayerQualityPreference';
import { PlayerPlaybackSource, PlayerPlaybackState, PlayerPlaybackPolicy, PlayerPlaybackEvent,
  PlayerPlaybackObserver } from './PlayerPlaybackState';
import { PlayerTrackPair, PlayerTrackEvent } from './PlayerTrackPair';
import { PlayerAudioSync } from './PlayerAudioSync';
import { PlayerSeekController } from './PlayerSeekController';
import { PlayerSpeedController } from './PlayerSpeedController';
import { PlayerPlaybackConfig } from './PlayerPlaybackConfig';

/** 双轨播放会话：UI 只提交命令与策略，原生资源不会越过此边界。 */
export class PlayerPlaybackSession {
  private readonly observer: PlayerPlaybackObserver;
  private readonly state: PlayerPlaybackState = new PlayerPlaybackState();
  private readonly pair: PlayerTrackPair;
  private readonly audioSync: PlayerAudioSync;
  private readonly seek: PlayerSeekController;
  private readonly speed: PlayerSpeedController;
  private source: PlayerPlaybackSource = new PlayerPlaybackSource();
  private bound: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private sourceRequest: number = 0;
  private surface: string = '';
  private sourceIndex: number = 0;
  private audioSourceIndex: number = 0;
  private retryingSource: boolean = false;
  private resumeAfterPrepare: number = -1;
  private shouldPlayAfterPrepare: boolean = true;
  private backgroundVideoResumePending: boolean = false;
  private seekRecoveryAttempts: number = 0;
  private volumeRestoreTimer: number = -1;

  constructor(observer: PlayerPlaybackObserver) {
    this.observer = observer;
    this.pair = new PlayerTrackPair((event: PlayerTrackEvent) => this.onTrackEvent(event));
    this.audioSync = new PlayerAudioSync(this.pair, this.state, {
      canPlay: (): boolean => this.canPlay(),
      muted: (): boolean => this.observer.policy().muted,
      isSeeking: (): boolean => this.seek.seekInFlight,
      changed: (): void => this.publish(),
      clock: (action: string): void => this.event('clock.' + action),
      rate: (rate: number): void => this.event('rate', rate),
      resync: (targetMs: number): void => {
        if (this.state.playing && this.canPlay() && !this.state.seekLocked && !this.state.backgroundAudioOnly) {
          this.seekTo(targetMs / 1000, true, false);
        }
      },
      error: (audio: media.AVPlayer, message: string): void => {
        if (this.pair.audio === audio) this.recoverSource(true, message);
      },
    });
    this.seek = new PlayerSeekController(
      (): media.AVPlayer | null => this.pair.video,
      (): media.AVPlayer | null => this.pair.audio,
      (): boolean => this.pair.prepared,
      (): boolean => this.pair.audioPrepared,
      (target: number, resume: boolean): void => {
        this.audioSync.beforeSeek(target, resume);
        this.event('seek.dispatch', target);
        this.event('clock.stop');
        this.publish();
      },
      (on: boolean): void => {
        this.state.buffering = on;
        if (on) this.state.seekRecoveryCoverVisible = true;
        this.publish();
      },
      (resume: boolean, target: number): void => this.finishSeek(resume, target),
      (video: media.AVPlayer | null, target: number): void => {
        if (video !== null && video === this.pair.video) this.recoverSeek(target);
      },
      (): Promise<void> | null => this.audioSync.pendingAudioPausePlayer === this.pair.audio ?
        this.audioSync.pendingAudioPause : null,
    );
    this.speed = new PlayerSpeedController((rate: number): void => this.audioSync.applyTemporarySpeed(rate),
      (active: boolean): void => { this.state.holdSpeedActive = active; this.publish(); });
  }

  get ready(): boolean { return this.pair.prepared; }
  get isFrameMuted(): boolean { return this.audioSync.firstFrameMuteArmed; }
  get hasSurface(): boolean { return this.surface.length > 0; }
  get sourceUrl(): string { return PlayerPlaybackConfig.sourceUrl(this.source.urls, this.sourceIndex); }

  activate(source: PlayerPlaybackSource): void {
    this.active = true;
    const sameSource: boolean = this.bound && this.source.aid === source.aid && this.source.bvid === source.bvid &&
      this.source.cid === source.cid && this.source.epId === source.epId && this.source.version === source.version;
    if (!sameSource) {
      this.adoptSource(source);
      this.resumeAfterPrepare = source.initialSeek > 0 ? source.initialSeek : -1;
      this.state.position = Math.max(0, source.initialSeek);
      this.state.duration = 0;
      this.state.errorText = '';
      this.shouldPlayAfterPrepare = true;
    }
    this.publish();
    // 页面返回已有 Surface 时恢复当前位置并保持暂停。
    if (this.surface.length > 0 && !this.pair.exists) {
      this.shouldPlayAfterPrepare = !sameSource;
      this.state.buffering = true;
      this.start();
    }
  }

  async setSurface(surface: string): Promise<void> {
    const changed: boolean = this.surface.length > 0 && this.surface !== surface;
    this.surface = surface;
    if (changed && this.pair.exists) {
      this.resumeAfterPrepare = this.state.position;
      this.shouldPlayAfterPrepare = this.resumeIntent();
      const generation: number = this.resetTracks();
      this.state.buffering = true;
      this.publish();
      this.event('clock.pause');
      await this.pair.release();
      if (this.current(generation)) await this.start();
      return;
    }
    await this.start();
  }

  async replaceSource(source: PlayerPlaybackSource): Promise<void> {
    if (!this.active) return;
    ++this.sourceRequest;
    const generation: number = this.resetTracks();
    this.adoptSource(source);
    this.resumeAfterPrepare = -1;
    this.shouldPlayAfterPrepare = true;
    this.state.position = 0;
    this.state.duration = 0;
    this.state.qualityLoading = false;
    this.state.errorText = '';
    this.state.buffering = true;
    this.publish();
    this.event('source');
    await this.pair.release();
    if (this.current(generation)) await this.start();
  }

  private adoptSource(source: PlayerPlaybackSource): void {
    const value: PlayerPlaybackSource = new PlayerPlaybackSource();
    value.aid = source.aid; value.bvid = source.bvid; value.cid = source.cid; value.epId = source.epId;
    value.version = source.version; value.urls = source.urls.slice(); value.audioUrls = source.audioUrls.slice();
    value.qualities = source.qualities.slice(); value.quality = source.quality;
    value.initialSeek = source.initialSeek; value.preview = source.preview;
    this.source = value;
    this.bound = true;
    this.sourceIndex = 0;
    this.audioSourceIndex = 0;
    this.state.activeQuality = value.quality;
    this.state.qualities = value.qualities;
    this.state.preview = value.preview;
  }

  updateQualities(options: Array<VideoQualityOption>): void {
    if (options.length > 0) { this.state.qualities = options.slice(); this.publish(); }
  }

  async changeQuality(qn: number): Promise<void> {
    if (!this.active || this.state.qualityLoading) return;
    if (qn === this.state.activeQuality) { PlayerQualityPreference.remember(qn); this.event('closePanels'); return; }
    const request: number = ++this.sourceRequest;
    const source: PlayerPlaybackSource = this.source;
    this.state.qualityLoading = true;
    this.publish();
    try {
      const info: PlayUrlInfo | null = await BiliApi.getPlayUrl(source.aid, source.bvid, source.cid, qn, source.epId);
      if (!this.active || request !== this.sourceRequest || this.source !== source) return;
      if (info === null || info.urls.length === 0) { this.state.errorText = '该清晰度暂时不可用'; return; }
      PlayerQualityPreference.remember(qn);
      this.resumeAfterPrepare = this.state.position;
      this.shouldPlayAfterPrepare = this.resumeIntent();
      const generation: number = this.resetTracks();
      source.urls = info.urls.slice(); source.audioUrls = info.audioUrls.slice();
      this.sourceIndex = 0; this.audioSourceIndex = 0;
      this.state.preview = info.isPreview;
      if (info.qualities.length > 0) this.state.qualities = info.qualities.slice();
      this.state.activeQuality = info.quality;
      this.state.buffering = true;
      this.event('closePanels'); this.event('clock.stop'); this.publish();
      await this.pair.release();
      if (this.current(generation) && request === this.sourceRequest) await this.start();
    } catch (e) {
      if (this.active && request === this.sourceRequest) this.state.errorText = '切换清晰度失败，请重试';
    } finally {
      if (this.active && request === this.sourceRequest) { this.state.qualityLoading = false; this.publish(); }
    }
  }

  private async start(): Promise<void> {
    if (!this.active || this.surface.length === 0) return;
    await this.pair.open(PlayerPlaybackConfig.sourceUrl(this.source.urls, this.sourceIndex),
      PlayerPlaybackConfig.sourceUrl(this.source.audioUrls, this.audioSourceIndex), this.surface,
      this.resumeAfterPrepare <= 0 && this.source.initialSeek <= 0);
  }

  private onTrackEvent(event: PlayerTrackEvent): void {
    if (!this.active) return;
    switch (event.kind) {
      case 'state': this.onTrackState(event.audio, event.state); break;
      case 'error': this.recoverSource(event.audio, event.message); break;
      case 'frame': this.revealFirstFrame(); this.audioSync.tryStartGatedAudio(); break;
      case 'time': this.onTime(event.value, event.audio); break;
      case 'duration': this.state.duration = event.value / 1000; this.publish(); this.event('duration'); break;
      case 'size': this.event('size', event.value, event.second); break;
      case 'buffer': this.audioSync.onBuffer(event.value); break;
      case 'seek': {
        if (event.audio) {
          const audio: media.AVPlayer | null = this.pair.audio;
          if (audio !== null) this.seek.onAudioSeekDone(audio, event.value);
        } else if (this.pair.video !== null) this.seek.onVideoSeekDone(this.pair.video, event.value);
        break;
      }
    }
  }

  private onTrackState(audio: boolean, state: string): void {
    const player: media.AVPlayer | null = audio ? this.pair.audio : this.pair.video;
    if (player === null) return;
    if (state === 'prepared') {
      this.state.prepared = this.pair.prepared;
      this.state.errorText = '';
      try { player.setPlaybackRate(this.state.playbackRate); player.setVolume(this.observer.policy().muted ? 0 : 1); }
      catch (e) {}
      this.publish(); this.startPrepared(); return;
    }
    if (state === 'playing' && (!this.canPlay() || !this.shouldPlayAfterPrepare)) {
      this.shouldPlayAfterPrepare = false;
      this.audioSync.cancelAudioGate();
      try { player.pause().catch(() => {}); } catch (e) {}
      if (!audio) {
        this.state.playing = false; this.state.buffering = false;
        this.audioSync.cancelFirstFrameMute(true);
        const sound: media.AVPlayer | null = this.pair.audio;
        if (sound !== null && this.pair.audioPrepared && sound.state === 'playing') {
          try { sound.pause().catch(() => {}); } catch (e) {}
        }
        this.publish(); this.event('paused'); this.event('clock.pause');
      }
      return;
    }
    if (audio) {
      if (state === 'completed' && this.state.backgroundAudioOnly) this.complete();
      return;
    }
    if (state === 'playing') {
      this.backgroundVideoResumePending = false;
      this.state.playing = true; this.state.buffering = false;
      this.publish(); this.event('started'); this.revealFirstFrame(); this.event('clock.start');
    } else if (state === 'paused' && (this.state.backgroundAudioOnly || this.backgroundVideoResumePending ||
      this.seek.seekInFlight || this.audioSync.seekRecoveryActive)) {
      this.event('clock.pause');
    } else if (state === 'paused' || state === 'completed') {
      this.shouldPlayAfterPrepare = false;
      this.seek.seekResumePlaying = false;
      this.state.playing = false; this.publish(); this.event('paused'); this.event('clock.pause');
      if (state === 'completed') this.event('ended');
    }
  }

  private complete(): void {
    this.shouldPlayAfterPrepare = false;
    this.state.playing = false; this.publish(); this.event('paused'); this.event('ended', 1);
  }

  private onTime(time: number, audio: boolean): void {
    if (audio !== this.state.backgroundAudioOnly || this.state.seekLocked) return;
    if (!audio && this.audioSync.canReleaseFrameMute(time)) this.audioSync.disarmFirstFrameMute();
    const seconds: number = time / 1000;
    const changed: boolean = Math.floor(seconds) !== Math.floor(this.state.position);
    this.state.position = seconds;
    if (!audio && this.audioSync.audioStartPending && seconds > 0.05) this.audioSync.tryStartGatedAudio();
    if (changed) this.publish();
    if (this.observer.progress(seconds, audio)) return;
    if (!audio) this.audioSync.checkAudioSync(time);
  }

  private revealFirstFrame(): void {
    if (this.state.firstFrameShown || !this.state.playing || !this.pair.firstRenderReady) return;
    this.state.firstFrameShown = true; this.publish(); this.event('firstFrame');
  }

  private startPrepared(): void {
    const video: media.AVPlayer | null = this.pair.video;
    if (video === null || !this.pair.ready) return;
    if (!this.canPlay()) this.shouldPlayAfterPrepare = false;
    this.audioSync.disarmFirstFrameMute();
    if (this.resumeAfterPrepare > 0) {
      const target: number = this.resumeAfterPrepare;
      const resume: boolean = this.shouldPlayAfterPrepare;
      const recovering: boolean = this.seekRecoveryAttempts > 0;
      this.resumeAfterPrepare = -1; this.shouldPlayAfterPrepare = false;
      this.seek.seekResumePlaying = resume;
      this.seekTo(target, !recovering, !recovering);
      return;
    }
    this.resumeAfterPrepare = -1;
    if (this.shouldPlayAfterPrepare) {
      this.audioSync.armFirstFrameMute();
      this.playTrack(video, false);
      this.audioSync.gateAudioStart();
    }
  }

  toggle(): void {
    const video: media.AVPlayer | null = this.pair.video;
    if (video === null || !this.pair.prepared) return;
    if (this.state.playing) { this.pause(); return; }
    if (!this.canPlay()) return;
    this.shouldPlayAfterPrepare = true;
    // 自动同步/用户跳转尚未完成时只更新意图，不能提前启动任一播放头。
    if (this.state.seekLocked) {
      this.seek.seekResumePlaying = true;
      this.state.playing = true;
      this.publish(); this.event('playing');
      return;
    }
    const policy: PlayerPlaybackPolicy = this.observer.policy();
    if (policy.background && !policy.pipVisible && this.pair.audio !== null && this.pair.audioPrepared) {
      this.state.backgroundAudioOnly = true;
      this.playTrack(this.pair.audio, true);
      this.state.playing = true; this.publish(); this.event('playing'); return;
    }
    this.event('resume');
    this.audioSync.armFirstFrameMute(Math.max(0, video.currentTime), 1200);
    this.playTrack(video, false); this.audioSync.gateAudioStart();
    this.state.playing = true; this.publish(); this.event('playing');
  }

  pause(): void {
    this.shouldPlayAfterPrepare = false;
    this.seek.seekResumePlaying = false;
    this.audioSync.seekRecoveryActive = false;
    this.audioSync.cancelAudioGate(); this.audioSync.cancelFirstFrameMute(true);
    try {
      if (this.pair.video !== null && this.pair.prepared && !this.state.backgroundAudioOnly) this.pair.video.pause().catch(() => {});
      if (this.pair.audio !== null && this.pair.audioPrepared) this.pair.audio.pause().catch(() => {});
    } catch (e) {}
    this.state.playing = false; this.publish(); this.event('clock.pause'); this.event('paused');
  }

  stopForNavigation(): void {
    const video: media.AVPlayer | null = this.pair.video;
    const audio: media.AVPlayer | null = this.pair.audio;
    this.shouldPlayAfterPrepare = false; this.seek.seekResumePlaying = false;
    this.seek.cancel();
    if (this.state.seekLocked) this.event('seek.finished');
    this.state.seekLocked = false; this.state.buffering = false;
    this.audioSync.muteImmediately(); this.audioSync.reset();
    try {
      if (video !== null && this.pair.prepared) video.pause().catch(() => {});
      if (audio !== null && this.pair.audioPrepared) audio.pause().catch(() => {});
    } catch (e) {}
    this.state.playing = false; this.publish(); this.event('paused'); this.event('clock.pause');
    if (this.volumeRestoreTimer >= 0) clearTimeout(this.volumeRestoreTimer);
    const generation: number = this.generation;
    this.volumeRestoreTimer = setTimeout(() => {
      if (!this.current(generation)) return;
      this.volumeRestoreTimer = -1;
      if (this.current(generation) && video === this.pair.video && audio === this.pair.audio) this.audioSync.restoreUserVolume();
    }, 100);
  }

  seekTo(position: number, precise: boolean = true, resetRecovery: boolean = true): void {
    if (!this.active || this.pair.video === null || !this.pair.prepared) return;
    const raw: number = Math.max(0, Math.min(this.state.duration > 0 ? this.state.duration : position, position));
    const target: number = this.state.duration > 0 && raw >= this.state.duration ? Math.max(0, this.state.duration - 0.5) : raw;
    this.state.position = target; this.state.seekLocked = true;
    this.audioSync.lastAudioSyncAtMs = -1;
    if (resetRecovery) this.seekRecoveryAttempts = 0;
    this.publish(); this.event('seek', target);
    this.seek.request(Math.round(target * 1000), precise, this.state.playing);
  }

  replay(): void {
    if (!this.pair.prepared) return;
    this.event('resume');
    this.seek.seekResumePlaying = true;
    this.seekTo(0);
  }

  private finishSeek(resume: boolean, target: number): void {
    this.seekRecoveryAttempts = 0;
    const video: media.AVPlayer | null = this.pair.video;
    const allowed: boolean = resume && this.canPlay();
    this.shouldPlayAfterPrepare = allowed;
    if (allowed && video !== null && this.pair.prepared) {
      this.audioSync.armFirstFrameMute(video.currentTime >= 0 ? video.currentTime : target, 1800);
      if (video.state !== 'playing') this.playTrack(video, false);
      if (this.pair.audio !== null && this.pair.audioPrepared) this.playTrack(this.pair.audio, true);
    } else {
      this.audioSync.seekRecoveryActive = false;
      this.state.seekRecoveryCoverVisible = false; this.state.buffering = false;
      this.audioSync.restoreUserVolume();
    }
    this.state.seekLocked = false; this.publish(); this.event('seek.finished');
  }

  private async recoverSeek(target: number): Promise<void> {
    const video: media.AVPlayer | null = this.pair.video;
    if (video === null) return;
    const resume: boolean = this.seek.seekResumePlaying && this.canPlay();
    this.shouldPlayAfterPrepare = resume;
    if (this.seekRecoveryAttempts >= 1) {
      this.seek.cancel(); this.audioSync.reset(); this.audioSync.restoreUserVolume();
      this.state.seekLocked = false; this.state.buffering = false; this.seekRecoveryAttempts = 0;
      this.publish(); this.event('seek.finished');
      if (resume && this.pair.prepared) { if (video.state !== 'playing') this.playTrack(video, false); this.audioSync.gateAudioStart(); }
      return;
    }
    this.seekRecoveryAttempts++;
    const generation: number = this.resetTracks();
    this.resumeAfterPrepare = Math.max(0, target / 1000); this.shouldPlayAfterPrepare = resume;
    this.state.buffering = true; this.publish(); this.event('seek.finished');
    await this.pair.release();
    if (this.current(generation)) await this.start();
  }

  private async recoverSource(audio: boolean, message: string): Promise<void> {
    if (!this.active || this.retryingSource) return;
    const hasBackup: boolean = audio ? this.audioSourceIndex + 1 < this.source.audioUrls.length :
      this.sourceIndex + 1 < this.source.urls.length;
    if (!hasBackup) {
      this.state.errorText = (audio ? '音频播放出错：' : '播放出错：') + message.substring(0, 120);
      this.state.buffering = false;
      this.release(); this.event('fatal'); return;
    }
    this.resumeAfterPrepare = this.state.position; this.shouldPlayAfterPrepare = this.resumeIntent();
    const generation: number = this.resetTracks();
    this.retryingSource = true;
    this.state.buffering = audio;
    this.state.errorText = '当前线路不可用，正在切换备用 CDN…'; this.publish();
    await this.pair.release();
    if (!this.current(generation)) return;
    if (audio) this.audioSourceIndex++; else this.sourceIndex++;
    this.retryingSource = false; await this.start();
  }

  onBackgroundChanged(): void {
    if (!this.active) return;
    const policy: PlayerPlaybackPolicy = this.observer.policy();
    if (policy.background) {
      this.event('clock.pause');
      if (policy.pipKeepsAlive) return;
      if (policy.allowBackground) this.enterBackgroundAudio();
      else { this.shouldPlayAfterPrepare = false; this.seek.seekResumePlaying = false;
        if (this.state.playing) this.pause(); else this.audioSync.cancelAudioGate(); }
    } else this.leaveBackgroundAudio();
  }

  private enterBackgroundAudio(): void {
    const video: media.AVPlayer | null = this.pair.video, audio: media.AVPlayer | null = this.pair.audio;
    if (!this.state.playing || !this.pair.ready || video === null || audio === null) return;
    this.state.backgroundAudioOnly = true; this.backgroundVideoResumePending = false;
    this.audioSync.cancelAudioGate(); this.audioSync.disarmFirstFrameMute();
    try { video.pause().catch(() => {}); this.playTrack(audio, true); }
    catch (e) { this.state.backgroundAudioOnly = false; }
    this.publish(); this.event('backgroundAudio');
  }

  private leaveBackgroundAudio(): void {
    if (!this.state.backgroundAudioOnly) return;
    const resume: boolean = this.state.playing;
    const target: number = this.pair.audio !== null ? this.pair.audio.currentTime : this.state.position * 1000;
    this.state.backgroundAudioOnly = false; this.backgroundVideoResumePending = resume;
    if (this.pair.video === null || !this.pair.prepared) { this.backgroundVideoResumePending = false; this.publish(); return; }
    this.state.position = Math.max(0, target / 1000); this.state.seekLocked = true; this.state.playing = false;
    this.audioSync.lastAudioSyncAtMs = -1;
    this.publish(); this.event('foregroundSeek', this.state.position);
    this.seek.request(target, true, resume);
  }

  setSpeed(rate: number): void { this.audioSync.setPlaybackSpeed(rate); this.publish(); }
  beginHold(): void { if (this.state.playing && this.pair.prepared) this.speed.beginHold(this.state.playbackRate); }
  endHold(): void { this.speed.endHold(); }
  mute(): void { this.audioSync.muteImmediately(); }
  restoreVolume(): void { this.audioSync.restoreUserVolume(); }

  deactivate(): void {
    this.resumeAfterPrepare = this.state.position; this.shouldPlayAfterPrepare = false;
    this.audioSync.muteImmediately(); this.active = false; this.release();
  }

  release(): void {
    ++this.sourceRequest;
    this.resetTracks();
    this.state.qualityLoading = false;
    this.pair.release();
    this.publish();
  }

  private resetTracks(): number {
    ++this.generation; this.retryingSource = false;
    this.seek.cancel(); this.audioSync.reset(); this.speed.endHold();
    if (this.volumeRestoreTimer >= 0) clearTimeout(this.volumeRestoreTimer);
    this.volumeRestoreTimer = -1;
    this.backgroundVideoResumePending = false;
    this.state.backgroundAudioOnly = false;
    if (this.state.seekLocked) this.event('seek.finished');
    this.state.seekLocked = false; this.state.prepared = false; this.state.playing = false;
    this.state.firstFrameShown = false;
    return this.generation;
  }

  private playTrack(player: media.AVPlayer, audio: boolean): void {
    const generation: number = this.generation;
    try {
      player.play().catch(() => {
        if (this.current(generation) && (audio ? this.pair.audio : this.pair.video) === player) this.recoverSource(audio, '播放器启动失败');
      });
    } catch (e) { if (this.current(generation)) this.recoverSource(audio, '播放器启动失败'); }
  }

  private canPlay(): boolean {
    const policy: PlayerPlaybackPolicy = this.observer.policy();
    return this.active && (!policy.background || policy.allowBackground || policy.pipKeepsAlive);
  }
  private resumeIntent(): boolean {
    return (this.state.playing || this.shouldPlayAfterPrepare || this.seek.seekResumePlaying) && this.canPlay();
  }
  private current(generation: number): boolean { return this.active && generation === this.generation; }
  private publish(): void { if (this.active) this.observer.state(this.state.copy()); }
  private event(kind: string, value: number = 0, second: number = 0): void {
    if (this.active) this.observer.event(new PlayerPlaybackEvent(kind, value, second));
  }
}
