import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEBUG } from 'BuildProfile';

/** 评论链路诊断日志。只记录标识、计数和状态，不记录正文、Cookie 或请求签名。 */
export class CommentLog {
  private static readonly DOMAIN: number = 0x0000;
  static readonly TAG: string = 'BiliComment';
  private static sequence: number = 0;

  static nextRequestId(): number {
    CommentLog.sequence++;
    return CommentLog.sequence;
  }

  static elapsed(startedAt: number): number {
    return Math.max(0, Date.now() - startedAt);
  }

  static errorText(error: Object): string {
    const value: string = String(error);
    return value.substring(0, Math.min(160, value.length));
  }

  static info(event: string, details: string = ''): void {
    if (!DEBUG) return;
    hilog.info(CommentLog.DOMAIN, CommentLog.TAG, '%{public}s %{public}s', event, details);
  }

  static warn(event: string, details: string = ''): void {
    if (!DEBUG) return;
    hilog.warn(CommentLog.DOMAIN, CommentLog.TAG, '%{public}s %{public}s', event, details);
  }

  static error(event: string, details: string = ''): void {
    if (!DEBUG) return;
    hilog.error(CommentLog.DOMAIN, CommentLog.TAG, '%{public}s %{public}s', event, details);
  }
}
