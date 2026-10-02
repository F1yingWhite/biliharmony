import { PiPWindow as pictureInPicture } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

export interface PlayerVideoSize {
  width: number;
  height: number;
}

export interface PlayerPictureInPictureHost {
  isDestroyed: () => boolean;
  isReady: () => boolean;
  isInBackground: () => boolean;
  isPlaying: () => boolean;
  getContext: () => common.UIAbilityContext;
  getComponentController: () => XComponentController;
  getVideoSize: () => PlayerVideoSize;
  closePanels: () => void;
  togglePlay: () => void;
  onPlaybackPolicyChanged: () => void;
  toast: (message: string) => void;
}

/** Owns the native PiP window and all late-create/start cleanup. */
export class PlayerPictureInPicture {
  private controller: pictureInPicture.PiPController | null = null;
  private generation: number = 0;
  private active: boolean = false;
  private starting: boolean = false;
  private restoring: boolean = false;
  private host: PlayerPictureInPictureHost;

  constructor(host: PlayerPictureInPictureHost) {
    this.host = host;
  }

  keepsPlaybackAlive(): boolean {
    return this.active || this.starting || this.restoring;
  }

  isVisibleOrStarting(): boolean {
    return this.active || this.starting;
  }

  async start(): Promise<void> {
    if (this.starting || this.active || this.host.isDestroyed()) return;
    if (!this.host.isReady()) {
      this.host.toast('请等待视频加载后再开启小窗');
      return;
    }
    const generation: number = ++this.generation;
    this.starting = true;
    try {
      if (!pictureInPicture.isPiPEnabled()) {
        this.host.toast('当前设备不支持小窗播放');
        return;
      }
      this.host.closePanels();
      let controller: pictureInPicture.PiPController | null = this.controller;
      if (controller === null) {
        const size: PlayerVideoSize = this.host.getVideoSize();
        controller = await pictureInPicture.create({
          context: this.host.getContext(),
          componentController: this.host.getComponentController(),
          navigationId: 'bili_main_navigation',
          templateType: pictureInPicture.PiPTemplateType.VIDEO_PLAY,
          contentWidth: size.width > 0 ? size.width : 16,
          contentHeight: size.height > 0 ? size.height : 9,
        });
        if (!this.isCurrent(generation)) {
          this.stopDetached(controller);
          return;
        }
        this.controller = controller;
        controller.setAutoStartEnabled(false);
        this.bindEvents(controller);
      }
      await controller.startPiP();
      if (!this.isCurrent(generation)) {
        // Native start may finish after release stopped the pending window.
        this.stopDetached(controller);
        return;
      }
      this.sync();
    } catch (e) {
      if (this.isCurrent(generation)) {
        this.active = false;
        this.host.toast('小窗启动失败，请检查系统画中画权限后重试');
      }
    } finally {
      if (generation === this.generation) {
        this.starting = false;
        if (!this.host.isDestroyed() && this.host.isInBackground() && !this.active) {
          this.host.onPlaybackPolicyChanged();
        }
      }
    }
  }

  sync(): void {
    if (this.controller === null) return;
    try {
      this.controller.updatePiPControlStatus(pictureInPicture.PiPControlType.VIDEO_PLAY_PAUSE,
        this.host.isPlaying() ? pictureInPicture.PiPControlStatus.PLAY : pictureInPicture.PiPControlStatus.PAUSE);
      const size: PlayerVideoSize = this.host.getVideoSize();
      if (size.width > 0 && size.height > 0) this.controller.updateContentSize(size.width, size.height);
    } catch (_) {}
  }

  release(): void {
    ++this.generation;
    const controller: pictureInPicture.PiPController | null = this.controller;
    this.controller = null;
    this.active = false;
    this.starting = false;
    this.restoring = false;
    if (controller !== null) this.stopDetached(controller);
  }

  private isCurrent(generation: number): boolean {
    return generation === this.generation && !this.host.isDestroyed();
  }

  private bindEvents(controller: pictureInPicture.PiPController): void {
    controller.on('stateChange', (state: pictureInPicture.PiPState): void => {
      if (this.controller !== controller || this.host.isDestroyed()) return;
      if (state === pictureInPicture.PiPState.ABOUT_TO_START || state === pictureInPicture.PiPState.STARTED) {
        this.active = true;
        this.restoring = false;
        this.sync();
      } else if (state === pictureInPicture.PiPState.ABOUT_TO_RESTORE) {
        this.restoring = true;
      } else if (state === pictureInPicture.PiPState.STOPPED || state === pictureInPicture.PiPState.ERROR) {
        this.active = false;
        this.starting = false;
        if (!this.host.isInBackground()) this.restoring = false;
        if (!this.restoring) this.host.onPlaybackPolicyChanged();
      }
    });
    controller.on('controlEvent', (event: pictureInPicture.ControlEventParam): void => {
      if (this.controller !== controller || this.host.isDestroyed()) return;
      if (event.controlType === pictureInPicture.PiPControlType.VIDEO_PLAY_PAUSE && event.status !== undefined) {
        const play: boolean = event.status === pictureInPicture.PiPControlStatus.PLAY;
        if (play !== this.host.isPlaying()) this.host.togglePlay();
        this.sync();
      }
    });
  }

  private stopDetached(controller: pictureInPicture.PiPController): void {
    // A failing native cleanup step must not prevent the window from stopping.
    try { controller.off('stateChange'); } catch (_) {}
    try { controller.off('controlEvent'); } catch (_) {}
    try { controller.setAutoStartEnabled(false); } catch (_) {}
    try { controller.stopPiP().catch(() => {}); } catch (_) {}
  }
}
