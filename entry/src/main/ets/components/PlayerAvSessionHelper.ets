/**
 * AVSession 封装：创建/更新/释放系统媒体会话。
 * 从 PlayerView 的 ensureAVSession/updateAVSessionMetadata/updateAVSessionPlaybackState/deactivate 抽离。
 */
import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';

export class PlayerAvSessionHelper {
  private session: avSession.AVSession | null = null;
  private active: boolean = false;
  private busy: boolean = false;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async ensure(
    onPlay: () => void,
    onPause: () => void,
    onSeek: (timeMs: number) => void,
    metadata: avSession.AVMetadata,
    state: avSession.AVPlaybackState,
  ): Promise<void> {
    if (this.active || this.busy) return;
    this.busy = true;
    try {
      const session: avSession.AVSession = await avSession.createAVSession(this.context, 'BiliHaromny', 'video');
      session.on('play', () => onPlay());
      session.on('pause', () => onPause());
      session.on('seek', (time: number) => onSeek(time));
      await session.activate();
      this.session = session;
      this.active = true;
      this.setMetadata(metadata);
      this.setPlaybackState(state);
    } catch (e) {
      this.session = null;
    } finally {
      this.busy = false;
    }
  }

  setMetadata(metadata: avSession.AVMetadata): void {
    const session: avSession.AVSession | null = this.session;
    if (session === null || !this.active) return;
    session.setAVMetadata(metadata).catch(() => {
    });
  }

  setPlaybackState(state: avSession.AVPlaybackState): void {
    const session: avSession.AVSession | null = this.session;
    if (session === null || !this.active) return;
    session.setAVPlaybackState(state).catch(() => {
    });
  }

  release(): void {
    const session: avSession.AVSession | null = this.session;
    if (session !== null && this.active) {
      try {
        session.deactivate().catch(() => {
        });
      } catch (e) {
      }
    }
    this.session = null;
    this.active = false;
  }
}
