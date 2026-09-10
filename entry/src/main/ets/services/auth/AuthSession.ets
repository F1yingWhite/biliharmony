/** 账号变更同步推进代际；网络响应和账号缓存均以此判断是否仍属于当前会话。 */
export class AuthSession {
  private static generation: number = 0;

  static get version(): number {
    return AuthSession.generation;
  }

  static advance(): void {
    AuthSession.generation++;
  }
}
