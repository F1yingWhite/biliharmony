/**
 * 轻量触觉反馈工具：所有按钮级交互统一走这里，取代各处重复的 vibrator 调用。
 *
 * 用法：交互回调第一行调用 Haptic.tap()，失败/未授权静默忽略，不影响业务。
 * 参考 B 站手机端：点赞/投币/关注等主互动按钮用短促轻震（15ms），
 * 次级操作（打开面板/切页）用更短更轻的 8ms。
 */
import { vibrator } from '@kit.SensorServiceKit';

export class Haptic {
  /** 主互动按钮（点赞/投币/收藏/关注/发送）：15ms 短震 */
  static tap(): void {
    Haptic.vibrate(15);
  }

  /** 次级操作（打开面板/关闭面板/切 tab/普通点击）：8ms 极轻震动 */
  static light(): void {
    Haptic.vibrate(8);
  }

  /** 强调反馈（取消点赞/取关等"解除"类操作）：12ms。 */
  static release(): void {
    Haptic.vibrate(12);
  }

  private static vibrate(duration: number): void {
    try {
      vibrator.startVibration({ type: 'time', duration: duration }, { usage: 'physicalFeedback' }).catch(() => {
        // 模拟器/无权限时静默降级
      });
    } catch (e) {
      // 不支持震动时静默忽略
    }
  }
}