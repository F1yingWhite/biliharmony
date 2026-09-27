/** 用户手选画质优先于自动策略；单个视频的权限/片源回退不能覆盖偏好。 */
export class PlayerQualityPreference {
  private static save: ((manual: number, mode: number) => void) | null = null;

  static restore(manual: number, mode: number, save: (manual: number, mode: number) => void): void {
    AppStorage.setOrCreate<number>('videoManualQuality', Math.max(0, manual));
    AppStorage.setOrCreate<number>('videoQualityPref', mode);
    PlayerQualityPreference.save = save;
  }

  private static persist(): void {
    if (PlayerQualityPreference.save !== null) {
      PlayerQualityPreference.save(AppStorage.get<number>('videoManualQuality') ?? 0,
        AppStorage.get<number>('videoQualityPref') ?? 0);
    }
  }

  static label(qn: number): string {
    const labels: Record<string, string> = { '127': '8K', '126': '杜比视界', '125': 'HDR',
      '120': '4K', '116': '1080P60', '112': '1080P+', '100': '智能修复',
      '80': '1080P', '74': '720P60', '64': '720P', '32': '480P', '16': '360P' };
    return labels[String(qn)] ?? String(qn);
  }

  static requested(): number {
    const manual: number = AppStorage.get<number>('videoManualQuality') ?? 0;
    if (manual > 0) return manual;
    const mode: number = AppStorage.get<number>('videoQualityPref') ?? 0;
    return mode === 3 ? 64 : (mode === 0 ? 80 : 127);
  }

  static remember(qn: number): void {
    if (qn <= 0) return;
    AppStorage.setOrCreate<number>('videoManualQuality', qn);
    PlayerQualityPreference.persist();
  }

  static useMode(mode: number): void {
    AppStorage.setOrCreate<number>('videoManualQuality', 0);
    AppStorage.setOrCreate<number>('videoQualityPref', mode);
    PlayerQualityPreference.persist();
  }
}
