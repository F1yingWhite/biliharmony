/** All media positions are seconds; seek request identifies the caller's original request. */
export interface MpvEvent {
  kind: string;
  request: number;
  position: number;
  errorCode: number;
}

/** Values observed from libmpv, with no application-side clock extrapolation. */
export interface MpvState {
  position: number;
  /** Observed audio-pts in seconds; -1 means currently unavailable. */
  audioPts: number;
  duration: number;
  width: number;
  height: number;
  paused: boolean;
  buffering: boolean;
  eof: boolean;
  loaded: boolean;
  speed: number;
  volume: number;
  hwdec: string;
  /** Source and renderer-target color observations; unknown means unavailable. */
  sourcePrimaries: string;
  sourceTransfer: string;
  sourceFormat: string;
  targetPrimaries: string;
  targetTransfer: string;
  vo: string;
  avSync: number;
  droppedFrames: number;
  decoderDroppedFrames: number;
  events: Array<MpvEvent>;
}

/** caFilePath is the app-private path of the pinned Mozilla CA bundle. TLS verification is always enabled. */
export const create: (surfaceId: string, caFilePath: string) => Promise<number>;
/** Header lines, such as `Referer: https://www.bilibili.com/`, remain exact strings. */
export const open: (id: number, videoUrl: string, audioUrl: string, headers: Array<string>) => Promise<void>;
export const poll: (id: number) => MpvState;
export const play: (id: number) => void;
export const pause: (id: number) => void;
export const seek: (id: number, seconds: number, request: number, precise: boolean) => void;
export const rate: (id: number, value: number) => void;
export const volume: (id: number, value: number) => void;
export const resize: (id: number, width: number, height: number) => void;
/** Cancels ownership immediately; waits for native shutdown away from the UI thread. */
export const release: (id: number) => Promise<void>;
