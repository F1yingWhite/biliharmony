import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { PlayerPlaybackConfig } from './PlayerPlaybackConfig';

export class PlayerTrackEvent {
  kind: string;
  audio: boolean;
  value: number = 0;
  second: number = 0;
  state: string = '';
  message: string = '';
  constructor(kind: string, audio: boolean = false) { this.kind = kind; this.audio = audio; }
}

/** 原生双轨唯一资源所有者：创建、监听和释放都在这里，页面不持有 AVPlayer。 */
export class PlayerTrackPair {
  video: media.AVPlayer | null = null;
  audio: media.AVPlayer | null = null;
  prepared: boolean = false;
  audioPrepared: boolean = false;
  audioExpected: boolean = false;
  firstRenderReady: boolean = false;
  private generation: number = 0;
  private creating: boolean = false;
  private lastSyncSampleAtMs: number = 0;
  private releases: Array<Promise<void>> = [];
  private readonly notify: (event: PlayerTrackEvent) => void;

  constructor(notify: (event: PlayerTrackEvent) => void) { this.notify = notify; }

  get ready(): boolean { return this.prepared && (!this.audioExpected || this.audioPrepared); }
  get exists(): boolean { return this.video !== null || this.creating; }

  async open(videoUrl: string, audioUrl: string, surfaceId: string, showFirstFrame: boolean): Promise<void> {
    if (this.exists || surfaceId.length === 0) return;
    const generation: number = ++this.generation;
    this.creating = true;
    this.lastSyncSampleAtMs = 0;
    this.audioExpected = audioUrl.length > 0;
    // 同一 Surface 在旧 release 真正完成前不能绑定新的解码器。
    await Promise.all(this.releases.slice());
    if (generation !== this.generation) return;
    try {
      const video: media.AVPlayer = await media.createAVPlayer();
      if (generation !== this.generation) { await this.retire(video); return; }
      this.video = video;
      this.bind(video, false, generation, surfaceId);
      if (videoUrl.length === 0) { this.error(false, '播放地址为空'); return; }
      // 两路资源握手并行；audioExpected 在任何 prepared 之前置位，不能先单轨起播。
      if (this.audioExpected) this.openAudio(audioUrl, generation).catch(() => {});
      await video.setMediaSource(media.createMediaSourceWithUrl(videoUrl, PlayerPlaybackConfig.playbackHeaders()),
        PlayerPlaybackConfig.videoStrategy(showFirstFrame));
    } catch (e) {
      if (generation === this.generation) this.error(false, (e as Error).message ?? '视频资源加载失败');
    } finally {
      if (generation === this.generation) this.creating = false;
    }
  }

  private async openAudio(url: string, generation: number): Promise<void> {
    try {
      const audio: media.AVPlayer = await media.createAVPlayer();
      if (generation !== this.generation || this.video === null) { await this.retire(audio); return; }
      this.audio = audio;
      this.bind(audio, true, generation, '');
      await audio.setMediaSource(media.createMediaSourceWithUrl(url, PlayerPlaybackConfig.playbackHeaders()),
        PlayerPlaybackConfig.audioStrategy());
    } catch (e) {
      if (generation === this.generation) this.error(true, '音轨资源加载失败');
    }
  }

  private bind(player: media.AVPlayer, audio: boolean, generation: number, surface: string): void {
    const current = (): boolean => generation === this.generation && (audio ? this.audio : this.video) === player;
    player.on('stateChange', (state: media.AVPlayerState) => {
      if (!current()) return;
      if (DEBUG) {
        hilog.info(0x0000, 'BiliPlayback', '%{public}s.state.change state=%{public}s currentTime=%{public}d',
          audio ? 'audio' : 'video', state, player.currentTime);
      }
      if (!audio && state === 'idle') this.lastSyncSampleAtMs = 0;
      if (state === 'initialized') {
        if (!audio) player.surfaceId = surface;
        try { player.prepare().catch(() => { if (current()) this.error(audio, '播放器准备失败'); }); }
        catch (e) { this.error(audio, '播放器准备失败'); }
        return;
      }
      if (state === 'prepared') {
        if (audio) this.audioPrepared = true;
        else {
          this.prepared = true;
          player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
          if (player.width > 0 && player.height > 0) this.emit('size', false, player.width, player.height);
        }
      }
      const event: PlayerTrackEvent = new PlayerTrackEvent('state', audio);
      event.state = state;
      this.notify(event);
    });
    player.on('error', (error: BusinessError) => { if (current()) this.error(audio, error.message); });
    player.on('seekDone', (position: number) => {
      if (!current()) return;
      if (DEBUG) {
        hilog.info(0x0000, 'BiliPlayback', '%{public}s.seek.done position=%{public}d currentTime=%{public}d',
          audio ? 'audio' : 'video', position, player.currentTime);
      }
      this.emit('seek', audio, position);
    });
    player.on('timeUpdate', (time: number) => {
      if (!current()) return;
      if (!audio) this.sampleSync();
      this.emit('time', audio, time);
    });
    player.on('playbackRateDone', (rate: number) => {
      if (!current() || !DEBUG) return;
      hilog.info(0x0000, 'BiliPlayback', '%{public}s.rate.done rate=%{public}s position=%{public}d',
        audio ? 'audio' : 'video', String(rate), player.currentTime);
    });
    player.on('bufferingUpdate', (kind: media.BufferingInfoType, value: number) => {
      if (!current()) return;
      if (DEBUG && (kind === media.BufferingInfoType.BUFFERING_START || kind === media.BufferingInfoType.BUFFERING_END)) {
        hilog.info(0x0000, 'BiliPlayback', '%{public}s.buffering kind=%{public}d value=%{public}d currentTime=%{public}d',
          audio ? 'audio' : 'video', kind, value, player.currentTime);
      }
      if (!audio) this.emit('buffer', false, kind, value);
    });
    if (audio) return;
    player.onMetricsEvent((events: Array<media.AVMetricsEvent>) => {
      if (!current() || !DEBUG) return;
      for (let i: number = 0; i < events.length; i++) {
        // 与旧诊断一致，仅记录类型/位置，不泄漏播放地址、鉴权参数或事件载荷。
        hilog.info(0x0000, 'BiliPlayback', 'video.metric type=%{public}d position=%{public}d',
          events[i].event, events[i].playbackPosition);
      }
    });
    player.on('durationUpdate', (duration: number) => { if (current()) this.emit('duration', false, duration); });
    player.on('startRenderFrame', () => {
      if (!current()) return;
      this.firstRenderReady = true;
      this.emit('frame');
    });
    player.on('videoSizeChange', (width: number, height: number) => {
      if (current() && width > 0 && height > 0) this.emit('size', false, width, height);
    });
  }

  /** 同步摘除引用和回调归属；所有调用者共享 release 屏障，失败也能继续清理。 */
  release(): Promise<void> {
    this.generation++;
    this.creating = false;
    const video: media.AVPlayer | null = this.video;
    const audio: media.AVPlayer | null = this.audio;
    this.video = null;
    this.audio = null;
    this.prepared = false;
    this.audioPrepared = false;
    this.audioExpected = false;
    this.firstRenderReady = false;
    this.lastSyncSampleAtMs = 0;
    if (video !== null) this.retire(video);
    if (audio !== null) this.retire(audio);
    return Promise.all(this.releases.slice()).then(() => {});
  }

  private retire(player: media.AVPlayer): Promise<void> {
    let pending: Promise<void>;
    try { pending = player.release().catch(() => {}); } catch (e) { pending = Promise.resolve(); }
    this.releases.push(pending);
    pending.then(() => {
      const index: number = this.releases.indexOf(pending);
      if (index >= 0) this.releases.splice(index, 1);
    });
    return pending;
  }

  private sampleSync(): void {
    if (!DEBUG || !this.prepared || !this.audioPrepared || this.video === null || this.audio === null) return;
    const nowMs: number = Date.now();
    if (nowMs - this.lastSyncSampleAtMs < 1000) return;
    this.lastSyncSampleAtMs = nowMs;
    const cachedVideoMs: number = this.video.currentTime;
    const cachedAudioMs: number = this.audio.currentTime;
    let videoMs: number;
    let audioMs: number;
    const queryStartedAtMs: number = Date.now();
    try {
      videoMs = this.video.getPlaybackPosition();
      audioMs = this.audio.getPlaybackPosition();
    } catch (e) {
      return;
    }
    const queryCostMs: number = Date.now() - queryStartedAtMs;
    hilog.info(0x0000, 'BiliPlayback',
      'avsync.sample videoMs=%{public}d audioMs=%{public}d driftMs=%{public}d cachedVideoMs=%{public}d cachedAudioMs=%{public}d cachedDriftMs=%{public}d queryCostMs=%{public}d videoState=%{public}s audioState=%{public}s',
      videoMs, audioMs, audioMs - videoMs, cachedVideoMs, cachedAudioMs, cachedAudioMs - cachedVideoMs,
      queryCostMs, this.video.state, this.audio.state);
  }

  private error(audio: boolean, message: string): void {
    const event: PlayerTrackEvent = new PlayerTrackEvent('error', audio);
    event.message = message;
    this.notify(event);
  }

  private emit(kind: string, audio: boolean = false, value: number = 0, second: number = 0): void {
    const event: PlayerTrackEvent = new PlayerTrackEvent(kind, audio);
    event.value = value;
    event.second = second;
    this.notify(event);
  }
}
