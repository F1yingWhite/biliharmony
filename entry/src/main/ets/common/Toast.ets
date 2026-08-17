/**
 * 统一 Toast：UIContext 版（官方推荐，无全局 deprecation），自带 try/catch。
 * 页面/组件里不再各自手写 private toast；组件销毁后调用抛异常会在这里被吞掉。
 */
import { UIContext } from '@kit.ArkUI';

/**
 * 弹一条 toast。组件可能已销毁时调用会抛异常，这里统一吞掉，不影响业务流程。
 * @param ctx this.getUIContext()；组件外无 UIContext 时不弹（静默失败，与旧行为一致）
 */
export function safeToast(ctx: UIContext | null | undefined, message: string): void {
  if (ctx === null || ctx === undefined) {
    return;
  }
  try {
    ctx.getPromptAction().showToast({ message: message });
  } catch (e) {
    // toast 失败（组件销毁/窗口异常）不影响业务流程。
  }
}