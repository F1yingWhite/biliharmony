import { audio } from '@kit.AudioKit';

/** 原生播放器的应用音频焦点；仅显式播放时激活，不响应系统 RESUME 自动起播。 */
export class PlayerAudioFocus {
  private readonly onInterrupt: () => void;
  private session: audio.AudioSessionManager | null = null;
  private generation: number = 0;
  private released: boolean = false;
  private active: boolean = false;
  private ownsSession: boolean = false;
  private activation: Promise<void> | null = null;
  private releaseWork: Promise<void> | null = null;
  private readonly stateListener: (event: audio.AudioSessionStateChangedEvent) => void =
    (event: audio.AudioSessionStateChangedEvent): void => {
      if (this.released || !this.active) return;
      const hint: audio.AudioSessionStateChangeHint = event.stateChangeHint;
      if (hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_PAUSE ||
        hint === audio.AudioSessionStateChangeHint.AUDIO_SESSION_STATE_CHANGE_HINT_STOP) {
        this.onInterrupt();
      }
    };
  private readonly deactivatedListener: (event: audio.AudioSessionDeactivatedEvent) => void =
    (event: audio.AudioSessionDeactivatedEvent): void => {
      if (this.released || !this.active) return;
      this.active = false;
      this.ownsSession = false;
      if (event.reason === audio.AudioSessionDeactivatedReason.DEACTIVATED_LOWER_PRIORITY) this.onInterrupt();
    };

  constructor(onInterrupt: () => void) { this.onInterrupt = onInterrupt; }

  async activate(): Promise<void> {
    if (this.released) return;
    if (this.activation !== null) return this.activation;
    const generation: number = this.generation;
    const work: Promise<void> = this.activateCurrent(generation);
    this.activation = work;
    try {
      await work;
    } finally {
      // 拒绝的激活不留在缓存里；下一次用户播放仍可重新申请。
      if (this.activation === work) this.activation = null;
    }
  }

  private async activateCurrent(generation: number): Promise<void> {
    const session: audio.AudioSessionManager = this.getSession();
    if (this.released || generation !== this.generation) return;
    if (session.isAudioSessionActivated()) {
      // AudioSession 属于整个应用。其他播放已激活时借用，退出不撤销其焦点。
      this.active = true;
      return;
    }
    // 申请尚未返回时系统也可能发出中断；必须让调用方撤销这次播放意图。
    this.active = true;
    try {
      await session.activateAudioSession({ concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_DEFAULT });
      this.ownsSession = session.isAudioSessionActivated();
      if (!this.released && generation === this.generation) {
        this.active = this.ownsSession;
        // 焦点已被系统撤销而事件仍排队时，也不能让调用方继续这次起播。
        if (!this.ownsSession) this.onInterrupt();
      }
    } catch (e) {
      if (!this.released && generation === this.generation) this.active = false;
      throw new Error('音频焦点申请失败');
    }
    // 退出期间晚完成的激活由 release 屏障统一撤销，不能复活播放器或越过下一会话。
  }

  private getSession(): audio.AudioSessionManager {
    if (this.session !== null) return this.session;
    const session: audio.AudioSessionManager = audio.getAudioManager().getSessionManager();
    let stateBound: boolean = false;
    try {
      // 已激活的应用会话可能由别的播放持有，不能改变它的场景。
      if (!session.isAudioSessionActivated()) {
        session.setAudioSessionScene(audio.AudioSessionScene.AUDIO_SESSION_SCENE_MEDIA);
      }
      session.on('audioSessionStateChanged', this.stateListener);
      stateBound = true;
      session.on('audioSessionDeactivated', this.deactivatedListener);
      this.session = session;
      return session;
    } catch (e) {
      if (stateBound) { try { session.off('audioSessionStateChanged', this.stateListener); } catch (ignored) {} }
      throw new Error('音频焦点初始化失败');
    }
  }

  release(): Promise<void> {
    if (this.releaseWork !== null) return this.releaseWork;
    this.released = true;
    this.generation++;
    this.active = false;
    const session: audio.AudioSessionManager | null = this.session;
    if (session !== null) {
      try { session.off('audioSessionStateChanged', this.stateListener); } catch (e) {}
      try { session.off('audioSessionDeactivated', this.deactivatedListener); } catch (e) {}
    }
    const activation: Promise<void> | null = this.activation;
    this.releaseWork = Promise.resolve().then(async (): Promise<void> => {
      if (activation !== null) { try { await activation; } catch (e) {} }
      if (this.ownsSession && session !== null) {
        this.ownsSession = false;
        try { await session.deactivateAudioSession(); } catch (e) {}
      }
      this.session = null;
    });
    return this.releaseWork;
  }
}
