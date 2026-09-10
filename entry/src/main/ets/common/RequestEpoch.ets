/** 一组相互替代的异步操作：只有最新请求可以提交结果或复位 loading。 */
export class RequestEpoch {
  private version: number = 0;

  next(): number {
    return ++this.version;
  }

  isCurrent(version: number): boolean {
    return version === this.version;
  }

  invalidate(): void {
    this.version++;
  }
}
