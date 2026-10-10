/**
 * 系统音频播放集成：AVSession 与后台长时任务。
 */
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';

export interface PlayerAvSessionCommands {
  skip?: (seconds: number) => void;
  next?: () => void;
  previous?: () => void;
  speed?: (rate: number) => void;
}

export class PlayerAvSessionHelper {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'BiliPlayback';
  private static readonly REQUEST_CODE: number = 26082001;
  private session: avSession.AVSession | null = null;
  private active: boolean = false;
  private busy: boolean = false;
  private released: boolean = false;
  private context: common.UIAbilityContext;
  private latestMetadata: avSession.AVMetadata | null = null;
  private latestState: avSession.AVPlaybackState | null = null;
  private clickAgent: WantAgent | null = null;
  private backgroundTaskId: number = -1;
  private backgroundRequested: boolean = false;
  private backgroundDesired: boolean = false;
  private backgroundBusy: boolean = false;
  private commands: PlayerAvSessionCommands = {};
  private nextRegistered: boolean = false;
  private previousRegistered: boolean = false;
  private forwardRegistered: boolean = false;
  private rewindRegistered: boolean = false;
  private speedRegistered: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async ensure(
    onPlay: () => void,
    onPause: () => void,
    onSeek: (timeMs: number) => void,
    metadata: avSession.AVMetadata,
    state: avSession.AVPlaybackState,
    commands: PlayerAvSessionCommands = {},
  ): Promise<void> {
    if (this.released) return;
    this.latestMetadata = metadata;
    this.latestState = state;
    this.setCommands(commands);
    if (this.active) {
      this.setMetadata(metadata);
      this.setPlaybackState(state);
      return;
    }
    if (this.busy) return;
    this.busy = true;
    let created: avSession.AVSession | null = null;
    try {
      // 后台只保留 DASH 音轨，向系统声明为音乐会话，由媒体中心/状态栏接管播控。
      const session: avSession.AVSession = await avSession.createAVSession(this.context, 'BiliHarmony', 'audio');
      created = session;
      if (this.released) return;
      session.on('play', () => { if (this.session === session && this.active) onPlay(); });
      session.on('pause', () => { if (this.session === session && this.active) onPause(); });
      session.on('seek', (time: number) => { if (this.session === session && this.active) onSeek(time); });
      await session.activate();
      if (this.released) return;
      await session.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY);
      if (this.released) return;
      this.session = session;
      this.active = true;
      this.nextRegistered = false;
      this.previousRegistered = false;
      this.forwardRegistered = false;
      this.rewindRegistered = false;
      this.speedRegistered = false;
      this.setCommands(this.commands);
      if (DEBUG) {
        hilog.info(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
          'avsession.active type=audio background=true');
      }
      if (this.latestMetadata !== null) this.setMetadata(this.latestMetadata);
      if (this.latestState !== null) this.setPlaybackState(this.latestState);
    } catch (e) {
      this.session = null;
      this.active = false;
      if (DEBUG) {
        hilog.error(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
          'avsession.ensure.error %{public}s', String(e));
      }
    } finally {
      if (created !== null && this.session !== created) await this.destroySession(created);
      this.busy = false;
    }
  }

  setMetadata(metadata: avSession.AVMetadata): void {
    this.latestMetadata = metadata;
    const session: avSession.AVSession | null = this.session;
    if (session !== null && this.active) {
      session.setAVMetadata(metadata).catch(() => {
      });
    }
  }

  /** Register only available queue commands, so single videos expose no fake next/previous action. */
  setCommands(commands: PlayerAvSessionCommands): void {
    this.commands = commands;
    const session: avSession.AVSession | null = this.session;
    if (session === null || !this.active) return;
    const current = (): boolean => this.session === session && this.active && !this.released;
    const next: boolean = commands.next !== undefined;
    if (next !== this.nextRegistered) {
      try {
        if (next) session.on('playNext', () => { if (current()) this.commands.next?.(); });
        else session.off('playNext');
        this.nextRegistered = next;
      } catch (e) { this.logCommandError('playNext', e); }
    }
    const previous: boolean = commands.previous !== undefined;
    if (previous !== this.previousRegistered) {
      try {
        if (previous) session.on('playPrevious', () => { if (current()) this.commands.previous?.(); });
        else session.off('playPrevious');
        this.previousRegistered = previous;
      } catch (e) { this.logCommandError('playPrevious', e); }
    }
    const skip: boolean = commands.skip !== undefined;
    if (skip !== this.forwardRegistered) {
      try {
        if (skip) session.on('fastForward', (milliseconds?: number) => {
          if (current()) this.commands.skip?.(PlayerAvSessionHelper.skipSeconds(milliseconds));
        });
        else session.off('fastForward');
        this.forwardRegistered = skip;
      } catch (e) { this.logCommandError('fastForward', e); }
    }
    if (skip !== this.rewindRegistered) {
      try {
        if (skip) session.on('rewind', (milliseconds?: number) => {
          if (current()) this.commands.skip?.(-PlayerAvSessionHelper.skipSeconds(milliseconds));
        });
        else session.off('rewind');
        this.rewindRegistered = skip;
      } catch (e) { this.logCommandError('rewind', e); }
    }
    const speed: boolean = commands.speed !== undefined;
    if (speed !== this.speedRegistered) {
      try {
        if (speed) session.on('setSpeed', (rate: number) => {
          if (current() && Number.isFinite(rate) && rate > 0) this.commands.speed?.(rate);
        });
        else session.off('setSpeed');
        this.speedRegistered = speed;
      } catch (e) { this.logCommandError('setSpeed', e); }
    }
  }

  private logCommandError(command: string, error: Object): void {
    if (DEBUG) hilog.warn(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
      'avsession.command.error %{public}s %{public}s', command, String(error));
  }

  private static skipSeconds(milliseconds: number | undefined): number {
    // API 26 AVSession command callbacks use milliseconds; the player uses seconds.
    return milliseconds !== undefined && Number.isFinite(milliseconds) && milliseconds > 0 ?
      Math.min(milliseconds / 1000, 3600) : 10;
  }

  setPlaybackState(state: avSession.AVPlaybackState): void {
    this.latestState = state;
    const session: avSession.AVSession | null = this.session;
    if (session !== null && this.active) {
      session.setAVPlaybackState(state).catch(() => {
      });
    }
    if (!this.active) return;
    const playing: boolean = state.state === avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    this.syncBackgroundTask(playing).catch(() => {
    });
  }

  release(): void {
    this.released = true;
    const session: avSession.AVSession | null = this.session;
    this.session = null;
    this.active = false;
    this.latestMetadata = null;
    this.latestState = null;
    this.commands = {};
    if (session !== null) this.destroySession(session).catch(() => {});
    this.backgroundDesired = false;
    this.stopBackgroundTask().catch(() => {
    });
  }

  private async destroySession(session: avSession.AVSession): Promise<void> {
    try { await session.deactivate(); } catch (e) {}
    try { await session.destroy(); } catch (e) {}
  }

  private async ensureClickAgent(): Promise<WantAgent> {
    if (this.clickAgent !== null) return this.clickAgent;
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.piliplus.harmony',
        abilityName: 'EntryAbility',
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: PlayerAvSessionHelper.REQUEST_CODE,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    };
    this.clickAgent = await wantAgent.getWantAgent(info);
    return this.clickAgent;
  }

  private async syncBackgroundTask(playing: boolean): Promise<void> {
    this.backgroundDesired = playing;
    if (this.backgroundBusy) return;
    this.backgroundBusy = true;
    let failed: boolean = false;
    try {
      if (this.backgroundDesired && !this.backgroundRequested) {
        const agent: WantAgent = await this.ensureClickAgent();
        if (this.released || !this.backgroundDesired) return;
        const request: backgroundTaskManager.ContinuousTaskRequest =
          new backgroundTaskManager.ContinuousTaskRequest();
        request.backgroundTaskModes =
          [backgroundTaskManager.BackgroundTaskMode.MODE_AV_PLAYBACK_AND_RECORD];
        request.backgroundTaskSubmodes =
          [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_AVSESSION_AUDIO_PLAYBACK];
        request.wantAgent = agent;
        const supported: boolean = request.isModeSupported();
        if (DEBUG) {
          hilog.info(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
            'background.mode.supported=%{public}s', String(supported));
        }
        if (!supported) throw new Error('AVSession audio playback background mode is unsupported');
        const result: backgroundTaskManager.ContinuousTaskNotification =
          await backgroundTaskManager.startBackgroundRunning(this.context, request);
        this.backgroundTaskId = result.continuousTaskId ?? -1;
        this.backgroundRequested = true;
        if (DEBUG) {
          hilog.info(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
            'background.start task=%{public}d', this.backgroundTaskId);
        }
      }
      if (!this.backgroundDesired && this.backgroundRequested) await this.stopBackgroundTask();
    } catch (e) {
      failed = true;
      if (DEBUG) {
        hilog.error(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
          'background.sync.error %{public}s', String(e));
      }
    } finally {
      this.backgroundBusy = false;
      if (!failed && this.backgroundDesired !== this.backgroundRequested) {
        this.syncBackgroundTask(this.backgroundDesired).catch(() => {
        });
      }
    }
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.backgroundRequested) return;
    const taskId: number = this.backgroundTaskId;
    this.backgroundRequested = false;
    this.backgroundTaskId = -1;
    try {
      if (taskId >= 0) await backgroundTaskManager.stopBackgroundRunning(this.context, taskId);
      else await backgroundTaskManager.stopBackgroundRunning(this.context);
      if (DEBUG) {
        hilog.info(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
          'background.stop task=%{public}d', taskId);
      }
    } catch (e) {
      if (DEBUG) {
        hilog.error(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
          'background.stop.error %{public}s', String(e));
      }
    }
  }

}
