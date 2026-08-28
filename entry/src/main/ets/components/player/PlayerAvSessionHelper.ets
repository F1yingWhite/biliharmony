/**
 * 系统音频播放集成：AVSession 与后台长时任务。
 */
import { common, WantAgent, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';

export class PlayerAvSessionHelper {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'BiliPlayback';
  private static readonly REQUEST_CODE: number = 26082001;
  private session: avSession.AVSession | null = null;
  private active: boolean = false;
  private busy: boolean = false;
  private context: common.UIAbilityContext;
  private latestMetadata: avSession.AVMetadata | null = null;
  private latestState: avSession.AVPlaybackState | null = null;
  private clickAgent: WantAgent | null = null;
  private backgroundTaskId: number = -1;
  private backgroundRequested: boolean = false;
  private backgroundDesired: boolean = false;
  private backgroundBusy: boolean = false;

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
    this.latestMetadata = metadata;
    this.latestState = state;
    if (this.active) {
      this.setMetadata(metadata);
      this.setPlaybackState(state);
      return;
    }
    if (this.busy) return;
    this.busy = true;
    try {
      // 后台只保留 DASH 音轨，向系统声明为音乐会话，由媒体中心/状态栏接管播控。
      const session: avSession.AVSession = await avSession.createAVSession(this.context, 'BiliHarmony', 'audio');
      session.on('play', () => onPlay());
      session.on('pause', () => onPause());
      session.on('seek', (time: number) => onSeek(time));
      await session.activate();
      await session.setBackgroundPlayMode(avSession.BackgroundPlayMode.ENABLE_BACKGROUND_PLAY);
      this.session = session;
      this.active = true;
      if (DEBUG) {
        hilog.info(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
          'avsession.active type=audio background=true');
      }
      if (this.latestMetadata !== null) this.setMetadata(this.latestMetadata);
      if (this.latestState !== null) this.setPlaybackState(this.latestState);
    } catch (e) {
      this.session = null;
      if (DEBUG) {
        hilog.error(PlayerAvSessionHelper.DOMAIN, PlayerAvSessionHelper.TAG,
          'avsession.ensure.error %{public}s', String(e));
      }
    } finally {
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
    this.backgroundDesired = false;
    this.stopBackgroundTask().catch(() => {
    });
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
