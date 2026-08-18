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

  /** 局部刷新某一项（点赞/点踩等原地修改后通知 LazyForEach 重绑） */
  public notifyItemChanged(index: number): void {
    if (index < 0 || index >= this.items.length) return;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    });
  }

  /**
   * 替换某一项并通知刷新。@Prop 对同引用对象不会重新同步，
   * 原地修改模型字段后必须换成新对象引用，子组件才能拿到新值。
   */
  public updateItem(index: number, item: T): void {
    if (index < 0 || index >= this.items.length) return;
    this.items[index] = item;
    this.notifyItemChanged(index);
  }

  /** 尾部追加（分页加载）：使用 push 原地追加，避免每页都复制整条大数组，降低长列表 O(n²) 开销。 */
  public append(items: Array<T>): void {
    if (items.length === 0) {
      return;
    }
    const start = this.items.length;
    for (let i = 0; i < items.length; i++) {
      this.items.push(items[i]);
    }
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
