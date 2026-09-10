/** 用户手选画质优先于自动策略；单个视频的权限/片源回退不能覆盖偏好。 */
export class PlayerQualityPreference {
  static requested(): number {
    const manual: number = AppStorage.get<number>('videoManualQuality') ?? 0;
    if (manual > 0) return manual;
    const mode: number = AppStorage.get<number>('videoQualityPref') ?? 0;
    return mode === 3 ? 64 : (mode === 0 ? 80 : 127);
  }

  static remember(qn: number): void {
    if (qn > 0) AppStorage.setOrCreate<number>('videoManualQuality', qn);
  }

  static useMode(mode: number): void {
    AppStorage.setOrCreate<number>('videoManualQuality', 0);
    AppStorage.setOrCreate<number>('videoQualityPref', mode);
  }
}
