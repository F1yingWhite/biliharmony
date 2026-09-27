/** 按压、内容切换与页面导航共用节奏；减少动效只影响装饰动画，不改变手势或媒体时钟。 */
export class MotionTokens {
  static readonly KEY_REDUCE_MOTION: string = 'reduceMotionEnabled';
  static readonly feedback: number = 120;
  static readonly content: number = 180;
  static readonly navigation: number = 260;

  static isReduced(): boolean {
    return AppStorage.get<boolean>(MotionTokens.KEY_REDUCE_MOTION) === true;
  }

  static duration(normal: number, reduced: boolean = MotionTokens.isReduced()): number {
    return reduced ? 0 : normal;
  }

  static appear(reduced: boolean = MotionTokens.isReduced()): TransitionEffect {
    return TransitionEffect.OPACITY.animation({ duration: reduced ? 80 : MotionTokens.content, curve: Curve.EaseOut });
  }
}
