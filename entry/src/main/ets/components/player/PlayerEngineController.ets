import { PlayerEngine, PlayerEngineEvent } from './PlayerEngine';
import { PlayerMpvEngine } from './PlayerMpvEngine';
import { PlayerPlaybackConfig } from './PlayerPlaybackConfig';

/** 一段播放只创建一个 libmpv；替换资源前等待旧实例释放其 Surface。 */
export class PlayerEngineController {
  engine: PlayerEngine | null = null;
  prepared: boolean = false;
  firstRenderReady: boolean = false;
  private generation: number = 0;
  private creating: boolean = false;
  private releases: Array<Promise<void>> = [];
  private readonly notify: (event: PlayerEngineEvent) => void;

  constructor(notify: (event: PlayerEngineEvent) => void) { this.notify = notify; }
  get exists(): boolean { return this.engine !== null || this.creating; }

  async open(videoUrl: string, audioUrl: string, surfaceId: string): Promise<void> {
    if (this.exists || surfaceId.length === 0) return;
    const generation: number = ++this.generation;
    this.creating = true;
    try {
      await Promise.all(this.releases.slice());
      if (generation !== this.generation) return;
      if (videoUrl.length === 0) throw new Error('播放地址为空');
      const engine: PlayerMpvEngine = new PlayerMpvEngine((event: PlayerEngineEvent): void => {
        if (generation !== this.generation || this.engine !== engine) return;
        if (event.kind === 'state' && event.state === 'prepared') this.prepared = true;
        if (event.kind === 'frame') this.firstRenderReady = true;
        this.notify(event);
      });
      this.engine = engine;
      await engine.open(surfaceId, videoUrl, audioUrl, PlayerPlaybackConfig.playbackHeaders());
    } catch (e) {
      if (generation === this.generation) {
        const event: PlayerEngineEvent = new PlayerEngineEvent('error');
        event.message = '播放内核资源加载失败，请重试或切换清晰度';
        this.notify(event);
      }
    } finally {
      if (generation === this.generation) this.creating = false;
    }
  }

  release(): Promise<void> {
    ++this.generation;
    this.creating = false;
    const engine: PlayerEngine | null = this.engine;
    this.engine = null;
    this.prepared = false; this.firstRenderReady = false;
    if (engine !== null) {
      let pending: Promise<void>;
      try { pending = engine.release(); } catch (e) { pending = Promise.reject(new Error('播放内核释放失败')); }
      this.releases.push(pending);
      pending.then(() => {
        const index: number = this.releases.indexOf(pending);
        if (index >= 0) this.releases.splice(index, 1);
      }, (): void => {});
    }
    return Promise.all(this.releases.slice()).then(() => {});
  }
}
