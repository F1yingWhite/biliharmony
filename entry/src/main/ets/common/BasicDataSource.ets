/**
 * 通用 LazyForEach 数据源。列表页持有一个实例，数据变化时调用
 * reset()/append()/prepend() 等方法，由数据源负责通知懒加载组件刷新。
 */
export class BasicDataSource<T> implements IDataSource {
  private listeners: Array<DataChangeListener> = [];
  protected items: Array<T> = [];

  public totalCount(): number {
    return this.items.length;
  }

  public getData(index: number): T {
    return this.items[index];
  }

  public getAll(): Array<T> {
    return this.items;
  }

  public isEmpty(): boolean {
    return this.items.length === 0;
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** 全量替换（下拉刷新/切换数据源） */
  public reset(items: Array<T>): void {
    this.items = items.slice();
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  /** 尾部追加（分页加载） */
  public append(items: Array<T>): void {
    if (items.length === 0) {
      return;
    }
    const start = this.items.length;
    this.items = this.items.concat(items);
    for (let i = 0; i < items.length; i++) {
      this.listeners.forEach((listener: DataChangeListener) => {
        listener.onDataAdd(start + i);
      });
    }
  }

  /** 头部插入（新消息/最新动态） */
  public prepend(items: Array<T>): void {
    if (items.length === 0) {
      return;
    }
    this.items = items.concat(this.items);
    for (let i = items.length - 1; i >= 0; i--) {
      this.listeners.forEach((listener: DataChangeListener) => {
        listener.onDataAdd(i);
      });
    }
  }

  public clear(): void {
    this.reset([]);
  }
}
