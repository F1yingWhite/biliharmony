/** 高频交互用短反馈，内容切换留出辨认时间；不改播放器与图片 hero 的时序。 */
export class MotionTokens {
  static readonly feedback: number = 120;
  static readonly content: number = 180;
  static readonly navigation: number = 260;

  static appear(): TransitionEffect {
    return TransitionEffect.OPACITY.animation({ duration: MotionTokens.content, curve: Curve.EaseOut });
  }
}
