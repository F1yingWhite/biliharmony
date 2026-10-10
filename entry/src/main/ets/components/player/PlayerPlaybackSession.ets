import { PlayerEngine, PlayerEngineEvent, PlayerBuffering } from './PlayerEngine';
import { BiliApi } from '../../api/BiliApi';
import { PlayUrlInfo, VideoQualityOption } from '../../model/Models';
import { PlayerQualityPreference } from '../../common/PlayerQualityPreference';
import { PlayerPlaybackSource, PlayerPlaybackState, PlayerPlaybackPolicy, PlayerPlaybackEvent,
  PlayerPlaybackObserver } from './PlayerPlaybackState';
import { PlayerEngineController } from './PlayerEngineController';
import { PlayerSeekController } from './PlayerSeekController';
import { PlayerSpeedController } from './PlayerSpeedController';
import { PlayerPlaybackConfig } from './PlayerPlaybackConfig';

/** 单原生播放会话：音视频共享解码时间线，UI 只提交命令与策略。 */
export class PlayerPlaybackSession {
  private readonly observer: PlayerPlaybackObserver;
  private readonly state: PlayerPlaybackState = new PlayerPlaybackState();
  private readonly core: PlayerEngineController;
  private readonly seek: PlayerSeekController;
  private readonly speed: PlayerSpeedController;
  private source: PlayerPlaybackSource = new PlayerPlaybackSource();
  private bound: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private sourceRequest: number = 0;
  private surface: string = '';
  private surfaceWidth: number = 0;
  private surfaceHeight: number = 0;
  private sourceIndex: number = 0;
  private audioSourceIndex: number = 0;
  private retryingSource: boolean = false;
  private resumeAfterPrepare: number = -1;
  private shouldPlayAfterPrepare: boolean = true;
  private seekRecoveryAttempts: number = 0;
  private nativeBuffering: boolean = false;
  private nativeRate: number = 1;
  private notifiedRate: number = 1;
  private pendingPause: Promise<void> | null = null;
  private pendingPauseEngine: PlayerEngine | null = null;
  private playRequest: number = 0;
  private pendingPauseEvents: number = 0;

  constructor(observer: PlayerPlaybackObserver) {
    this.observer = observer;
    this.core = new PlayerEngineController((event: PlayerEngineEvent) => this.onEngineEvent(event));
    this.seek = new PlayerSeekController(
      (): PlayerEngine | null => this.core.engine,
      (): boolean => this.core.prepared,
      (target: number): void => {
        this.event('seek.dispatch', target);
        this.event('clock.stop');
      },
      (on: boolean): void => {
        this.state.buffering = on || this.nativeBuffering;
        this.state.seekRecoveryCoverVisible = on;
        this.publish();
      },
      (resume: boolean, target: number): void => this.finishSeek(resume, target),
      (engine: PlayerEngine | null, target: number): void => {
        if (engine !== null && engine === this.core.engine) this.recoverSeek(target);
      },
    );
    this.speed = new PlayerSpeedController((rate: number): void => this.applyTemporarySpeed(rate),
      (active: boolean): void => { this.state.holdSpeedActive = active; this.publish(); });
  }

  get ready(): boolean { return this.core.prepared; }
  get hasSurface(): boolean { return this.surface.length > 0; }
  get sourceUrl(): string { return PlayerPlaybackConfig.sourceUrl(this.source.urls, this.sourceIndex); }
  get sourceVersion(): number { return this.source.version; }

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
      this.shouldPlayAfterPrepare = source.autoPlay !== false;
    }
    this.publish();
    // 页面返回已有 Surface 时恢复当前位置并保持暂停。
    if (this.surface.length > 0 && !this.core.exists) {
      this.shouldPlayAfterPrepare = !sameSource && source.autoPlay !== false;
      this.state.buffering = true;
      this.start();
    }
  }

  async setSurface(surface: string): Promise<void> {
    const changed: boolean = this.surface.length > 0 && this.surface !== surface;
    this.surface = surface;
    if (changed && this.core.exists) {
      this.resumeAfterPrepare = this.state.position;
      this.shouldPlayAfterPrepare = this.resumeIntent();
      const generation: number = this.resetEngine();
      this.state.buffering = true;
      this.publish();
      this.event('clock.pause');
      if (!(await this.releaseCore())) return;
      if (this.current(generation)) await this.start();
      return;
    }
    await this.start();
  }

  async replaceSource(source: PlayerPlaybackSource): Promise<void> {
    if (!this.active) return;
    ++this.sourceRequest;
    const generation: number = this.resetEngine();
    this.adoptSource(source);
    const initial: number = Number.isFinite(source.initialSeek) ? Math.max(0, source.initialSeek) : 0;
    this.resumeAfterPrepare = initial > 0 ? initial : -1;
    this.shouldPlayAfterPrepare = source.autoPlay !== false;
    this.state.position = initial;
    this.state.duration = 0;
    this.state.qualityLoading = false;
    this.state.errorText = '';
    this.state.buffering = true;
    this.publish();
    this.event('source');
    if (!(await this.releaseCore())) return;
    if (this.current(generation)) await this.start();
  }

  private adoptSource(source: PlayerPlaybackSource): void {
    const value: PlayerPlaybackSource = new PlayerPlaybackSource();
    value.aid = source.aid; value.bvid = source.bvid; value.cid = source.cid; value.epId = source.epId;
    value.version = source.version; value.urls = source.urls.slice(); value.audioUrls = source.audioUrls.slice();
    value.qualities = source.qualities.slice(); value.quality = source.quality;
    value.initialSeek = source.initialSeek; value.preview = source.preview; value.autoPlay = source.autoPlay !== false;
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
      const generation: number = this.resetEngine();
      source.urls = info.urls.slice(); source.audioUrls = info.audioUrls.slice();
      this.sourceIndex = 0; this.audioSourceIndex = 0;
      source.preview = info.isPreview; source.quality = info.quality;
      if (info.qualities.length > 0) source.qualities = info.qualities.slice();
      this.state.preview = source.preview;
      this.state.qualities = source.qualities.slice();
      this.state.activeQuality = source.quality;
      this.state.buffering = true;
      this.event('closePanels'); this.event('clock.stop'); this.publish();
      if (!(await this.releaseCore())) return;
      if (this.current(generation) && request === this.sourceRequest) await this.start();
    } catch (e) {
      if (this.active && request === this.sourceRequest) this.state.errorText = '切换清晰度失败，请重试';
    } finally {
      if (this.active && request === this.sourceRequest) { this.state.qualityLoading = false; this.publish(); }
    }
  }

  private async start(): Promise<void> {
    if (!this.active || this.surface.length === 0) return;
    await this.core.open(PlayerPlaybackConfig.sourceUrl(this.source.urls, this.sourceIndex),
      PlayerPlaybackConfig.sourceUrl(this.source.audioUrls, this.audioSourceIndex), this.surface);
    if (this.core.engine !== null) this.core.engine.resize(this.surfaceWidth, this.surfaceHeight);
  }

  resize(width: number, height: number): void {
    this.surfaceWidth = width; this.surfaceHeight = height;
    if (this.core.engine !== null) this.core.engine.resize(width, height);
  }

  private onEngineEvent(event: PlayerEngineEvent): void {
    if (!this.active) return;
    switch (event.kind) {
      case 'state': this.onEngineState(event.state); break;
      case 'error': this.recoverSource(false, event.message); break;
      case 'audio-error': this.recoverSource(true, event.message); break;
      case 'interruption': this.pause(); break;
      case 'rate': if (Math.abs(event.value - this.nativeRate) < 0.001) this.notifyRate(event.value); break;
      case 'frame': this.revealFirstFrame(); break;
      case 'time': this.onTime(event.value); break;
      case 'duration': this.state.duration = event.value / 1000; this.publish(); this.event('duration'); break;
      case 'size': this.event('size', event.value, event.second); break;
      case 'buffer': this.onBuffer(event.value); break;
      case 'seek': {
        if (this.core.engine !== null) this.seek.onSeekDone(this.core.engine, event.value, event.second);
        break;
      }
    }
  }

  private onEngineState(state: string): void {
    const engine: PlayerEngine | null = this.core.engine;
    if (engine === null) return;
    const ownPause: boolean = state === 'paused' && this.pendingPauseEvents > 0;
    if (ownPause) this.pendingPauseEvents--;
    if (state === 'prepared') {
      this.state.prepared = this.core.prepared;
      this.state.errorText = '';
      try { engine.setPlaybackRate(this.state.playbackRate); this.nativeRate = this.state.playbackRate; } catch (e) {}
      this.restoreVolume();
      this.publish(); this.startPrepared(); return;
    }
    // 异步 play 完成时再检查当前意图，离页/禁用后台后的迟到回调不能恢复播放。
    if (state === 'playing' && (!this.canPlay() || !this.shouldPlayAfterPrepare)) {
      this.shouldPlayAfterPrepare = false;
      this.pauseEngine(engine);
      this.state.playing = false; this.state.buffering = false;
      this.publish(); this.event('paused'); this.event('clock.pause');
      return;
    }
    if (state === 'playing') {
      this.state.playing = true;
      this.state.backgroundAudioOnly = this.isBackgroundPlayback();
      this.publish(); this.event('started'); this.revealFirstFrame();
      if (!this.observer.policy().background && !this.state.seekLocked && !this.state.buffering) this.event('clock.start');
    } else if (state === 'paused' && ownPause && this.shouldPlayAfterPrepare) {
      // 用户在异步 pause 完成前又按了播放；旧 paused 回调不能撤销新的播放意图。
      this.event('clock.pause');
    } else if (state === 'paused' || state === 'completed') {
      this.state.buffering = false; this.nativeBuffering = false;
      this.shouldPlayAfterPrepare = false;
      this.seek.seekResumePlaying = false;
      this.state.playing = false; this.publish(); this.event('paused'); this.event('clock.pause');
      if (state === 'completed') this.event('ended', this.state.backgroundAudioOnly ? 1 : 0);
    }
  }

  private onBuffer(kind: PlayerBuffering): void {
    if (kind === PlayerBuffering.START) {
      this.nativeBuffering = true; this.state.buffering = true;
      this.event('clock.pause'); this.publish();
    } else if (kind === PlayerBuffering.END) {
      this.nativeBuffering = false;
      if (this.state.seekLocked) return;
      this.state.buffering = false;
      if (this.state.playing && !this.observer.policy().background) this.event('clock.start');
      this.publish();
    }
    // libmpv 同时门控两轨；这里不得暂停、定位或微调某一音轨。
  }

  private onTime(time: number): void {
    if (this.state.seekLocked || this.resumeAfterPrepare > 0) return;
    const seconds: number = time / 1000;
    const changed: boolean = Math.floor(seconds) !== Math.floor(this.state.position);
    this.state.position = seconds;
    if (changed) this.publish();
    this.observer.progress(seconds, this.observer.policy().background);
  }

  private revealFirstFrame(): void {
    if (this.state.firstFrameShown || !this.state.playing || !this.core.firstRenderReady) return;
    this.state.firstFrameShown = true; this.publish(); this.event('firstFrame');
  }

  private startPrepared(): void {
    const engine: PlayerEngine | null = this.core.engine;
    if (engine === null || !this.core.prepared) return;
    this.state.buffering = false; this.nativeBuffering = false;
    if (!this.canPlay()) this.shouldPlayAfterPrepare = false;
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
    this.publish();
    if (this.shouldPlayAfterPrepare) {
      this.state.buffering = false;
      this.state.backgroundAudioOnly = this.isBackgroundPlayback();
      this.playEngine(engine);
    }
  }

  toggle(): void {
    const engine: PlayerEngine | null = this.core.engine;
    if (engine === null || !this.core.prepared) return;
    if (this.state.playing) { this.pause(); return; }
    if (!this.canPlay()) return;
    this.shouldPlayAfterPrepare = true;
    // 定位尚未完成时只更新播放意图，等待当前原生定位回调。
    if (this.state.seekLocked) {
      this.seek.seekResumePlaying = true;
      this.state.playing = true;
      this.publish(); this.event('playing');
      return;
    }
    this.state.backgroundAudioOnly = this.isBackgroundPlayback();
    this.event('resume');
    this.playEngine(engine);
    this.state.playing = true; this.publish(); this.event('playing');
  }

  pause(): void {
    this.speed.endHold();
    this.playRequest++;
    this.state.buffering = false; this.nativeBuffering = false;
    this.shouldPlayAfterPrepare = false;
    this.seek.seekResumePlaying = false;
    try {
      if (this.core.engine !== null && this.core.prepared) this.pauseEngine(this.core.engine);
    } catch (e) {}
    this.state.playing = false; this.publish(); this.event('clock.pause'); this.event('paused');
  }

  stopForNavigation(): void {
    this.speed.endHold(); this.playRequest++; this.nativeBuffering = false;
    this.shouldPlayAfterPrepare = false; this.seek.seekResumePlaying = false;
    this.seek.cancel();
    if (this.state.seekLocked) this.event('seek.finished');
    this.state.seekLocked = false; this.state.buffering = false;
    this.state.seekRecoveryCoverVisible = false;
    this.mute();
    try {
      if (this.core.engine !== null && this.core.prepared) this.pauseEngine(this.core.engine);
    } catch (e) {}
    this.state.playing = false; this.publish(); this.event('paused'); this.event('clock.pause');
  }

  seekTo(position: number, precise: boolean = true, resetRecovery: boolean = true): void {
    if (!this.active || this.core.engine === null || !this.core.prepared) return;
    const raw: number = Math.max(0, Math.min(this.state.duration > 0 ? this.state.duration : position, position));
    const target: number = this.state.duration > 0 && raw >= this.state.duration ? Math.max(0, this.state.duration - 0.5) : raw;
    this.state.position = target; this.state.seekLocked = true;
    if (resetRecovery) this.seekRecoveryAttempts = 0;
    this.publish(); this.event('seek', target);
    this.seek.request(Math.round(target * 1000), precise, this.state.playing);
  }

  replay(): void {
    if (!this.core.prepared) return;
    this.event('resume');
    this.seek.seekResumePlaying = true;
    this.seekTo(0);
  }

  private finishSeek(resume: boolean, target: number): void {
    this.seekRecoveryAttempts = 0;
    const engine: PlayerEngine | null = this.core.engine;
    const allowed: boolean = resume && this.canPlay();
    this.shouldPlayAfterPrepare = allowed;
    const landed: number = Math.max(0, target / 1000);
    const changedLanding: boolean = Math.abs(this.state.position - landed) > 0.001;
    this.state.position = landed;
    this.state.seekRecoveryCoverVisible = false; this.state.buffering = this.nativeBuffering;
    this.state.seekLocked = false;
    if (allowed && engine !== null && this.core.prepared && (engine.state !== 'playing' || this.pendingPauseEngine === engine)) this.playEngine(engine);
    if (allowed && !this.nativeBuffering && !this.observer.policy().background) this.event('clock.start');
    this.publish();
    if (changedLanding) this.event('seek', landed);
    this.event('seek.finished');
  }

  private async recoverSeek(target: number): Promise<void> {
    const engine: PlayerEngine | null = this.core.engine;
    if (engine === null) return;
    const resume: boolean = this.seek.seekResumePlaying && this.canPlay();
    this.shouldPlayAfterPrepare = resume;
    if (this.seekRecoveryAttempts >= 1) {
      this.seek.cancel();
      this.state.seekLocked = false; this.state.seekRecoveryCoverVisible = false;
      this.state.buffering = false; this.nativeBuffering = false; this.seekRecoveryAttempts = 0;
      this.state.errorText = '定位超时，请重新播放或切换清晰度';
      this.pause(); this.publish(); this.event('seek.finished');
      return;
    }
    this.seekRecoveryAttempts++;
    const generation: number = this.resetEngine();
    this.resumeAfterPrepare = Math.max(0, target / 1000); this.shouldPlayAfterPrepare = resume;
    this.state.buffering = true; this.publish(); this.event('seek.finished');
    if (!(await this.releaseCore())) return;
    if (this.current(generation)) await this.start();
  }

  private async recoverSource(audio: boolean, message: string): Promise<void> {
    if (!this.active || this.retryingSource) return;
    const hasBackup: boolean = this.sourceIndex + 1 < this.source.urls.length ||
      this.audioSourceIndex + 1 < Math.max(1, this.source.audioUrls.length);
    if (!hasBackup) {
      this.state.errorText = (audio ? '音频播放出错：' : '播放出错：') + message.substring(0, 120);
      this.state.buffering = false;
      this.release(); this.event('fatal'); return;
    }
    this.resumeAfterPrepare = this.state.position; this.shouldPlayAfterPrepare = this.resumeIntent();
    const generation: number = this.resetEngine();
    this.retryingSource = true;
    this.state.buffering = true;
    this.state.errorText = '当前线路不可用，正在切换备用 CDN…'; this.publish();
    if (!(await this.releaseCore())) return;
    if (!this.current(generation)) return;
    if (audio && this.audioSourceIndex + 1 < this.source.audioUrls.length) this.audioSourceIndex++;
    else if (this.sourceIndex + 1 < this.source.urls.length) this.sourceIndex++;
    else { this.sourceIndex = 0; this.audioSourceIndex++; }
    this.retryingSource = false; await this.start();
  }

  onBackgroundChanged(): void {
    if (!this.active) return;
    const policy: PlayerPlaybackPolicy = this.observer.policy();
    if (policy.background) {
      this.event('clock.pause');
      if (!policy.allowBackground && !policy.pipKeepsAlive) {
        this.shouldPlayAfterPrepare = false; this.seek.seekResumePlaying = false;
        this.pause();
      }
      this.state.backgroundAudioOnly = this.isBackgroundPlayback();
      if (this.state.backgroundAudioOnly) this.event('backgroundAudio');
    } else {
      this.state.backgroundAudioOnly = false;
      if (this.state.playing && !this.state.buffering && !this.state.seekLocked) this.event('clock.start');
    }
    // 后台和前台共享同一原生时间线，返回无需暂停/重建/补一次 seek。
    this.publish();
  }

  private isBackgroundPlayback(): boolean {
    const policy: PlayerPlaybackPolicy = this.observer.policy();
    return policy.background && policy.allowBackground && !policy.pipKeepsAlive;
  }

  setSpeed(rate: number): void {
    const engine: PlayerEngine | null = this.core.engine;
    let accepted: number = rate;
    if (engine !== null && this.core.prepared && !(Math.abs(rate - this.nativeRate) < 0.001)) {
      try { engine.setPlaybackRate(rate); this.nativeRate = rate; }
      catch (e) {
        accepted = 1;
        try { engine.setPlaybackRate(1); this.nativeRate = 1; } catch (e) {}
      }
    }
    this.state.playbackRate = accepted;
    if (!this.state.holdSpeedActive) this.notifyRate(accepted);
    this.publish();
  }

  private applyTemporarySpeed(rate: number): void {
    const engine: PlayerEngine | null = this.core.engine;
    if (engine === null || !this.core.prepared) return;
    try {
      if (!(Math.abs(rate - this.nativeRate) < 0.001)) {
        engine.setPlaybackRate(rate); this.nativeRate = rate;
      }
      this.notifyRate(rate);
    } catch (e) {}
  }

  /** 原生确认可能迟于即时切速通知；同一倍速只更新一次弹幕等消费者。 */
  private notifyRate(rate: number): void {
    if (!this.active || Math.abs(rate - this.notifiedRate) < 0.001) return;
    this.notifiedRate = rate;
    this.event('rate', rate);
  }

  beginHold(): void { if (this.state.playing && this.core.prepared) this.speed.beginHold(this.state.playbackRate); }
  endHold(): void { this.speed.endHold(); }
  mute(): void {
    try { if (this.core.engine !== null && this.core.prepared) this.core.engine.setVolume(0); } catch (e) {}
  }
  restoreVolume(): void {
    try {
      if (this.core.engine !== null && this.core.prepared) this.core.engine.setVolume(this.observer.policy().muted ? 0 : 1);
    } catch (e) {}
  }

  deactivate(): void {
    this.resumeAfterPrepare = this.state.position; this.shouldPlayAfterPrepare = false;
    this.mute(); this.active = false; this.release();
  }

  release(): void {
    ++this.sourceRequest;
    this.resetEngine();
    this.state.qualityLoading = false;
    this.releaseCore();
    this.publish();
  }

  private async releaseCore(): Promise<boolean> {
    try { await this.core.release(); return true; }
    catch (e) {
      this.shouldPlayAfterPrepare = false;
      this.state.playing = false; this.state.prepared = false; this.state.buffering = false;
      this.nativeBuffering = false;
      this.state.errorText = '播放资源未能安全释放，请退出视频后重试';
      this.publish(); this.event('fatal');
      return false;
    }
  }

  private resetEngine(): number {
    ++this.generation; this.retryingSource = false; this.playRequest++; this.nativeBuffering = false;
    this.pendingPause = null; this.pendingPauseEngine = null; this.pendingPauseEvents = 0;
    this.seek.cancel(); this.speed.endHold();
    this.state.seekRecoveryCoverVisible = false;
    this.state.backgroundAudioOnly = false;
    if (this.state.seekLocked) this.event('seek.finished');
    this.state.seekLocked = false; this.state.prepared = false; this.state.playing = false;
    this.state.firstFrameShown = false;
    return this.generation;
  }

  private pauseEngine(engine: PlayerEngine): void {
    if (this.pendingPauseEngine === engine && this.pendingPause !== null) return;
    // prepared/paused 也可能正在等待音频焦点；暂停必须撤销这段时间的起播意图。
    if (engine.state === 'released' || engine.state === 'error' || engine.state === 'idle') return;
    let pending: Promise<void>;
    this.pendingPauseEvents++;
    const generation: number = this.generation;
    const failed: () => void = (): void => {
      if (generation === this.generation) this.pendingPauseEvents = Math.max(0, this.pendingPauseEvents - 1);
    };
    try { pending = engine.pause().catch(failed); } catch (e) { failed(); return; }
    this.pendingPause = pending; this.pendingPauseEngine = engine;
    pending.then(() => {
      if (this.pendingPause === pending) { this.pendingPause = null; this.pendingPauseEngine = null; }
    });
  }

  private playEngine(engine: PlayerEngine): void {
    const generation: number = this.generation;
    const request: number = ++this.playRequest;
    const play: () => void = (): void => {
      if (!this.current(generation) || request !== this.playRequest || this.core.engine !== engine ||
        !this.shouldPlayAfterPrepare || !this.canPlay()) return;
      try {
        this.restoreVolume();
        engine.play().catch(() => {
          if (this.current(generation) && request === this.playRequest && this.shouldPlayAfterPrepare && this.core.engine === engine) this.recoverSource(false, '播放器启动失败');
        });
      } catch (e) { if (this.current(generation) && request === this.playRequest && this.shouldPlayAfterPrepare) this.recoverSource(false, '播放器启动失败'); }
    };
    if (this.pendingPauseEngine === engine && this.pendingPause !== null) this.pendingPause.then(play);
    else play();
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
