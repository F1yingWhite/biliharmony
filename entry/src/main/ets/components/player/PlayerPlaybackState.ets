import { VideoQualityOption } from '../../model/Models';

/** 输入是一个视频的资源快照，不引用页面或可变 @Prop 数组。 */
export class PlayerPlaybackSource {
  aid: number = 0;
  bvid: string = '';
  cid: number = 0;
  epId: number = 0;
  version: number = 0;
  urls: Array<string> = [];
  audioUrls: Array<string> = [];
  qualities: Array<VideoQualityOption> = [];
  quality: number = 0;
  initialSeek: number = 0;
  preview: boolean = false;
}

/** 起播前实时读取系统策略；Watch 与原生事件的到达顺序不能决定是否允许出声。 */
export interface PlayerPlaybackPolicy {
  background: boolean;
  allowBackground: boolean;
  pipKeepsAlive: boolean;
  muted: boolean;
}

export class PlayerPlaybackState {
  prepared: boolean = false;
  playing: boolean = false;
  firstFrameShown: boolean = false;
  errorText: string = '';
  position: number = 0;
  duration: number = 0;
  buffering: boolean = false;
  seekLocked: boolean = false;
  seekRecoveryCoverVisible: boolean = false;
  qualityLoading: boolean = false;
  activeQuality: number = 0;
  qualities: Array<VideoQualityOption> = [];
  preview: boolean = false;
  playbackRate: number = 1;
  holdSpeedActive: boolean = false;
  backgroundAudioOnly: boolean = false;

  copy(): PlayerPlaybackState {
    const value: PlayerPlaybackState = new PlayerPlaybackState();
    value.prepared = this.prepared;
    value.playing = this.playing;
    value.firstFrameShown = this.firstFrameShown;
    value.errorText = this.errorText;
    value.position = this.position;
    value.duration = this.duration;
    value.buffering = this.buffering;
    value.seekLocked = this.seekLocked;
    value.seekRecoveryCoverVisible = this.seekRecoveryCoverVisible;
    value.qualityLoading = this.qualityLoading;
    value.activeQuality = this.activeQuality;
    value.qualities = this.qualities.slice();
    value.preview = this.preview;
    value.playbackRate = this.playbackRate;
    value.holdSpeedActive = this.holdSpeedActive;
    value.backgroundAudioOnly = this.backgroundAudioOnly;
    return value;
  }
}

/** 语义事件供 UI / 弹幕 / AVSession 适配，不把原生播放器交给页面。 */
export class PlayerPlaybackEvent {
  kind: string;
  value: number;
  second: number;
  constructor(kind: string, value: number = 0, second: number = 0) {
    this.kind = kind;
    this.value = value;
    this.second = second;
  }
}

export interface PlayerPlaybackObserver {
  policy: () => PlayerPlaybackPolicy;
  state: (state: PlayerPlaybackState) => void;
  event: (event: PlayerPlaybackEvent) => void;
  progress: (seconds: number, background: boolean) => void;
}
