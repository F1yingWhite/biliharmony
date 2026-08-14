/** 页面、评论富文本和播放器之间的统一轻量命令通道。 */
export class PlayerCommandBus {
  private static bump(key: string): void {
    const token: number = AppStorage.get<number>(key) ?? 0;
    AppStorage.setOrCreate<number>(key, token + 1);
  }

  static seek(seconds: number): void {
    if (seconds < 0) return;
    AppStorage.setOrCreate<number>('videoSeekRequestSeconds', seconds);
    PlayerCommandBus.bump('videoSeekRequestToken');
  }

  static stop(): void {
    PlayerCommandBus.bump('videoPlaybackStopRequest');
  }

  static exitFullscreen(): void {
    PlayerCommandBus.bump('videoFullscreenExitRequest');
  }
}
