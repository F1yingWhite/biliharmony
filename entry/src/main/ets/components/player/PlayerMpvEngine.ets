import mpv, { MpvState, MpvEvent } from 'libbilimpv.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';
import { PlayerAudioFocus } from './PlayerAudioFocus';
import { PlayerMpvResources } from './PlayerMpvResources';
import { PlayerEngine, PlayerEngineEvent, PlayerSeekMode, PlayerBuffering } from './PlayerEngine';

const STATE_POLL_MS: number = 150;
const DIAGNOSTICS_INTERVAL_MS: number = 5000;
const RATE_DIAGNOSTICS_POLL_MS: number = 30;
const RATE_DIAGNOSTICS_DURATION_MS: number = 1200;

/** libmpv 适配器只翻译命令和原生事件，不下载媒体、不计算音画偏差或预测播放时钟。 */
export class PlayerMpvEngine implements PlayerEngine {
  state: string = 'idle';
  currentTime: number = 0;
  private handle: number = 0;
  private generation: number = 0;
  private timer: number = -1;
  private opening: Promise<void> | null = null;
  private closing: Promise<void> | null = null;
  private loaded: boolean = false;
  private buffering: boolean = false;
  private eof: boolean = false;
  private duration: number = -1;
  private width: number = 0;
  private height: number = 0;
  private rate: number = 1;
  private diagnosticsAt: number = 0;
  private colorDiagnosticsAt: number = 0;
  private timeEmittedAt: number = 0;
  private rateDiagnosticsRequestedAt: number = 0;
  private rateDiagnosticsUntil: number = 0;
  private playIntent: number = 0;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private readonly notify: (event: PlayerEngineEvent) => void;
  private readonly focus: PlayerAudioFocus;

  constructor(notify: (event: PlayerEngineEvent) => void) {
    this.notify = notify;
    this.focus = new PlayerAudioFocus((): void => this.emit('interruption'));
  }

  open(surfaceId: string, videoUrl: string, audioUrl: string, headers: Record<string, string>): Promise<void> {
    const opening: Promise<void> = this.openResource(surfaceId, videoUrl, audioUrl, headers);
    this.opening = opening;
    return opening;
  }

  private async openResource(surfaceId: string, videoUrl: string, audioUrl: string,
    headers: Record<string, string>): Promise<void> {
    const generation: number = ++this.generation;
    ++this.playIntent;
    const caFile: string = await PlayerMpvResources.caFile();
    if (generation !== this.generation) return;
    const handle: number = await mpv.create(surfaceId, caFile);
    if (generation !== this.generation) { await mpv.release(handle); return; }
    this.handle = handle;
    if (this.viewportWidth > 0 && this.viewportHeight > 0) mpv.resize(handle, this.viewportWidth, this.viewportHeight);
    const requestHeaders: Array<string> = [];
    const keys: Array<string> = Object.keys(headers);
    for (let i: number = 0; i < keys.length; i++) requestHeaders.push(keys[i] + ': ' + headers[keys[i]]);
    await mpv.open(handle, videoUrl, audioUrl, requestHeaders);
    if (generation !== this.generation) return;
    this.state = 'initialized';
    this.poll(generation);
  }

  private poll(generation: number): void {
    if (generation !== this.generation || this.handle === 0) return;
    try { this.consume(mpv.poll(this.handle)); }
    catch (e) { this.error('播放内核发生错误'); return; }
    if (generation === this.generation && this.handle !== 0 && this.state !== 'error') {
      const interval: number = DEBUG && Date.now() < this.rateDiagnosticsUntil ?
        RATE_DIAGNOSTICS_POLL_MS : STATE_POLL_MS;
      this.timer = setTimeout((): void => { this.timer = -1; this.poll(generation); }, interval);
    }
  }

  private consume(value: MpvState): void {
    if (Number.isFinite(value.position) && value.position >= 0) this.currentTime = value.position * 1000;
    for (let i: number = 0; i < value.events.length; i++) this.nativeEvent(value.events[i]);
    if (this.state === 'released' || this.state === 'error') return;
    if (!this.loaded && value.loaded) this.prepared();
    if (!this.loaded) return;
    const nextDuration: number = value.duration * 1000;
    if (Number.isFinite(nextDuration) && nextDuration >= 0 && Math.abs(nextDuration - this.duration) > 1) {
      this.duration = nextDuration; this.emit('duration', nextDuration);
    }
    if (value.width > 0 && value.height > 0 && (value.width !== this.width || value.height !== this.height)) {
      this.width = value.width; this.height = value.height; this.emit('size', this.width, this.height);
    }
    if (value.buffering !== this.buffering) {
      this.buffering = value.buffering;
      this.emit('buffer', value.buffering ? PlayerBuffering.START : PlayerBuffering.END);
    }
    if (!this.eof && value.eof) { this.eof = true; this.setState('completed'); }
    if (!value.eof) this.eof = false;
    if (Number.isFinite(value.speed) && value.speed > 0 && Math.abs(value.speed - this.rate) > 0.001) {
      this.rate = value.speed; this.emit('rate', value.speed);
    }
    const now: number = DEBUG ? Date.now() : 0;
    // Diagnostic sampling must not increase the UI playback-clock cadence.
    if (!DEBUG || now >= this.rateDiagnosticsUntil || now - this.timeEmittedAt >= STATE_POLL_MS) {
      this.timeEmittedAt = now;
      this.emit('time', this.currentTime);
    }
    if (DEBUG) {
      if (now - this.colorDiagnosticsAt >= DIAGNOSTICS_INTERVAL_MS) {
        this.colorDiagnosticsAt = now;
        hilog.info(0x0000, 'BiliPlayback',
          'mpv.color sourcePrimaries=%{public}s sourceTransfer=%{public}s sourceFormat=%{public}s targetPrimaries=%{public}s targetTransfer=%{public}s vo=%{public}s',
          value.sourcePrimaries, value.sourceTransfer, value.sourceFormat,
          value.targetPrimaries, value.targetTransfer, value.vo);
      }
      if (now < this.rateDiagnosticsUntil) {
        this.diagnosticsAt = now;
        hilog.info(0x0000, 'BiliPlayback',
          'mpv.rateSample elapsed=%{public}d speed=%{public}s clock=%{public}d audioPts=%{public}d avsync=%{public}s dropped=%{public}d decoderDropped=%{public}d',
          now - this.rateDiagnosticsRequestedAt, value.speed.toFixed(3), Math.round(this.currentTime),
          Number.isFinite(value.audioPts) && value.audioPts >= 0 ? Math.round(value.audioPts * 1000) : -1,
          value.avSync.toFixed(4), value.droppedFrames, value.decoderDroppedFrames);
      } else if (now - this.diagnosticsAt >= DIAGNOSTICS_INTERVAL_MS) {
        this.diagnosticsAt = now;
        hilog.info(0x0000, 'BiliPlayback',
          'mpv.clock=%{public}d hwdec=%{public}s avsync=%{public}s dropped=%{public}d decoderDropped=%{public}d',
          Math.round(this.currentTime), value.hwdec, value.avSync.toFixed(4), value.droppedFrames, value.decoderDroppedFrames);
      }
    }
  }

  private nativeEvent(event: MpvEvent): void {
    if (event.kind === 'audio-error' || event.kind === 'error' || (event.kind === 'end-file' && event.errorCode < 0)) {
      if (DEBUG) hilog.error(0x0000, 'BiliPlayback', 'mpv.error=%{public}d', event.errorCode);
      this.error(event.kind === 'audio-error' ? '音轨加载失败' : '播放内核无法读取当前线路', event.kind === 'audio-error');
    } else if (event.kind === 'file-loaded') this.prepared();
    else if (this.loaded && (event.kind === 'paused' || event.kind === 'playing')) this.setState(event.kind, true);
    else if (event.kind === 'playback-restart') {
      this.emit('frame');
      if (event.request >= 0) this.emit('seek', event.request, event.position * 1000);
    }
  }

  private prepared(): void {
    if (this.loaded) return;
    this.loaded = true; this.setState('prepared');
  }

  async play(): Promise<void> {
    const generation: number = this.generation;
    const request: number = ++this.playIntent;
    const handle: number = this.handle;
    if (handle === 0) return;
    try { await this.focus.activate(); }
    catch (e) {
      if (generation === this.generation && request === this.playIntent) this.emit('interruption');
      return;
    }
    if (generation !== this.generation || this.handle !== handle || request !== this.playIntent) return;
    mpv.play(handle);
  }

  async pause(): Promise<void> {
    ++this.playIntent;
    if (this.handle === 0) return;
    mpv.pause(this.handle);
  }

  seek(milliseconds: number, mode: PlayerSeekMode): void {
    if (this.handle === 0) return;
    mpv.seek(this.handle, milliseconds / 1000, milliseconds, mode === PlayerSeekMode.CLOSEST);
  }

  setPlaybackRate(rate: number): void {
    if (this.handle === 0) return;
    mpv.rate(this.handle, rate);
    if (DEBUG) {
      this.rateDiagnosticsRequestedAt = Date.now();
      this.rateDiagnosticsUntil = this.rateDiagnosticsRequestedAt + RATE_DIAGNOSTICS_DURATION_MS;
      hilog.info(0x0000, 'BiliPlayback', 'mpv.rateRequest at=%{public}s rate=%{public}s',
        this.rateDiagnosticsRequestedAt.toString(), rate.toFixed(3));
      if (this.timer >= 0) {
        clearTimeout(this.timer);
        const generation: number = this.generation;
        this.timer = setTimeout((): void => { this.timer = -1; this.poll(generation); }, RATE_DIAGNOSTICS_POLL_MS);
      }
    }
  }

  setVolume(volume: number): void {
    if (this.handle !== 0) mpv.volume(this.handle, volume);
  }

  resize(width: number, height: number): void {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return;
    this.viewportWidth = Math.round(width); this.viewportHeight = Math.round(height);
    if (this.handle !== 0) mpv.resize(this.handle, this.viewportWidth, this.viewportHeight);
  }

  release(): Promise<void> {
    if (this.closing !== null) return this.closing;
    ++this.generation;
    ++this.playIntent;
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
    const handle: number = this.handle;
    this.handle = 0; this.state = 'released'; this.loaded = false;
    // 若 create 尚未返回，由 open 的代际检查释放迟到 handle；此处也等待它完全退出。
    const opening: Promise<void> | null = this.opening;
    this.closing = Promise.all([
      handle !== 0 ? Promise.resolve().then((): Promise<void> => mpv.release(handle)) : Promise.resolve(),
      opening !== null ? opening.catch((): void => {}) : Promise.resolve(),
      this.focus.release(),
    ]).then((): void => {});
    return this.closing;
  }

  private setState(state: string, acknowledge: boolean = false): void {
    if ((!acknowledge && this.state === state) || this.state === 'released') return;
    this.state = state;
    const event: PlayerEngineEvent = new PlayerEngineEvent('state');
    event.state = state;
    this.notify(event);
  }

  private error(message: string, audio: boolean = false): void {
    if (this.state === 'released' || this.state === 'error') return;
    this.state = 'error';
    const event: PlayerEngineEvent = new PlayerEngineEvent(audio ? 'audio-error' : 'error'); event.message = message;
    this.notify(event);
  }

  private emit(kind: string, value: number = 0, second: number = 0): void {
    if (this.state === 'released' || this.state === 'error') return;
    const event: PlayerEngineEvent = new PlayerEngineEvent(kind); event.value = value; event.second = second;
    this.notify(event);
  }
}
