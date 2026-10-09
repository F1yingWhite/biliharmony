/** 播放业务仅依赖这些命令；解码、缓冲、音画时钟全部属于播放内核。 */
export interface PlayerEngine {
  readonly state: string;
  readonly currentTime: number;
  play(): Promise<void>;
  pause(): Promise<void>;
  seek(milliseconds: number, mode: PlayerSeekMode): void;
  setPlaybackRate(rate: number): void;
  setVolume(volume: number): void;
  resize(width: number, height: number): void;
  release(): Promise<void>;
}

export enum PlayerSeekMode { CLOSEST = 0, PREVIOUS_KEYFRAME = 1 }
export enum PlayerBuffering { START = 0, END = 1 }

export class PlayerEngineEvent {
  kind: string;
  value: number = 0;
  second: number = 0;
  state: string = '';
  message: string = '';
  constructor(kind: string) { this.kind = kind; }
}
