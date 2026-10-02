import { webview } from '@kit.ArkWeb';
import { youtubeFullscreenProbeHtml, youtubePlayerHtml, youtubePlaybackError,
  YOUTUBE_PLAYER_ORIGIN } from '../../common/YouTubePlayerHtml';

export interface YouTubeWebPlaybackState {
  loading: boolean;
  error: string;
}

/** Owns navigation, readiness timeout and disposal of one Web playback surface. */
export class YouTubeWebPlayback {
  readonly controller: webview.WebviewController = new webview.WebviewController();
  private active: boolean = false;
  private attached: boolean = false;
  private loaded: boolean = false;
  private initialPageLoaded: boolean = false;
  private timer: number = -1;
  private generation: number = 0;
  private id: string = '';
  private probe: boolean = false;
  private readonly publish: (state: YouTubeWebPlaybackState) => void;
  private readonly keepScreenOn: (value: boolean) => void;
  private readonly inBackground: () => boolean;

  constructor(publish: (state: YouTubeWebPlaybackState) => void, keepScreenOn: (value: boolean) => void,
    inBackground: () => boolean) {
    this.publish = publish;
    this.keepScreenOn = keepScreenOn;
    this.inBackground = inBackground;
  }

  activate(id: string, probe: boolean = false): void {
    ++this.generation;
    this.clearTimer();
    this.id = id;
    this.probe = probe;
    this.active = true;
    this.loaded = false;
    this.initialPageLoaded = false;
    this.load();
  }

  attach(): void { this.attached = true; this.load(); }

  pageEnded(url: string): void {
    if (!this.active || url !== 'about:blank' || this.initialPageLoaded) return;
    this.initialPageLoaded = true;
    this.loaded = false;
    this.load();
  }

  retry(): void {
    this.loaded = false;
    this.initialPageLoaded = false;
    this.load();
  }

  title(title: string): void {
    if (!this.active) return;
    if (title === 'YT_READY' || title.startsWith('YT_STATE_')) {
      this.clearTimer();
      this.publish({ loading: false, error: '' });
      this.keepScreenOn(title === 'YT_STATE_1' && !this.inBackground());
      if (this.inBackground()) this.pause();
    }
    const error: string = youtubePlaybackError(title);
    if (error.length > 0) {
      this.clearTimer();
      this.publish({ loading: false, error: error });
      this.keepScreenOn(false);
    }
  }

  pause(): void {
    if (this.attached) {
      try { this.controller.runJavaScript('pauseVideo()').catch(() => {}); } catch (_) {}
    }
    this.keepScreenOn(false);
  }

  dispose(): void {
    this.active = false;
    ++this.generation;
    this.clearTimer();
    this.pause();
    this.loaded = false;
    try { this.controller.loadUrl('about:blank'); } catch (_) {}
  }

  private load(): void {
    if (!this.active || !this.attached || this.loaded) return;
    this.loaded = true;
    this.clearTimer();
    this.publish({ loading: true, error: '' });
    try {
      this.controller.loadData(this.probe ? youtubeFullscreenProbeHtml() : youtubePlayerHtml(this.id),
        'text/html', 'UTF-8', YOUTUBE_PLAYER_ORIGIN + '/');
    } catch (_) {
      this.loaded = false;
      this.title('YT_NETWORK_ERROR');
      return;
    }
    const generation: number = this.generation;
    this.timer = setTimeout((): void => {
      if (!this.active || generation !== this.generation) return;
      this.timer = -1;
      this.publish({ loading: false, error: '播放器加载较慢，请检查网络后重试' });
    }, 25000);
  }

  private clearTimer(): void {
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
  }
}
