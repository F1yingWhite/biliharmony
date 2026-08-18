/**
 * 楼中楼回复树缩进连接线与折叠圆点。
 * 从 ReplyCard.ThreadTreeLines 拆出，让评论卡不再维护树线绘制细节。
 */
@Component
export struct ReplyThreadGuides {
  @Prop threadDepth: number = 0;
  @Prop threadGuides: Array<boolean> = [];
  @Prop threadHasChildren: boolean = false;
  @Prop @Watch('onThreadCollapsedChanged') threadCollapsed: boolean = false;
  @Prop measuredHeight: number = 72;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  onToggle: () => void = () => {};
  /** 子组件本地镜像折叠态，让 +/ - 图标变化在 ReplyThreadGuides 内部用 animateTo 驱动，
   * 不再依赖父 List/ForEach 是否保留原组件实例。 */
  @State visualCollapsed: boolean = false;

  aboutToAppear(): void {
    this.visualCollapsed = this.threadCollapsed;
  }

  onThreadCollapsedChanged(): void {
    this.getUIContext().animateTo({ duration: 160, curve: Curve.EaseInOut }, () => {
      this.visualCollapsed = this.threadCollapsed;
    });
  }

  private visualDepth(): number {
    return Math.min(3, Math.max(0, this.threadDepth));
  }

  private threadIndent(): number {
    return this.visualDepth() * 18;
  }

  private treeJoinY(): number {
    return 24;
  }

  private treeGuideX(index: number): number {
    return index * 18 + 9;
  }

  private guideIndexes(): Array<number> {
    const indexes: Array<number> = [];
    for (let i: number = 0; i < this.visualDepth(); i++) indexes.push(i);
    return indexes;
  }

  private guideContinues(index: number): boolean {
    if (this.threadGuides.length === 0) return false;
    if (index === this.visualDepth() - 1) return this.threadGuides[this.threadGuides.length - 1] ?? false;
    return this.threadGuides[index] ?? false;
  }

  private treeLineColor(): string {
    return this.isDark ? '#4A4D54' : '#D3D7DD';
  }

  private treeNodeFillColor(): string {
    return this.isDark ? '#26272B' : '#FFFFFF';
  }

  build() {
    ForEach(this.guideIndexes(), (index: number) => {
      if (index < this.visualDepth() - 1 && this.guideContinues(index)) {
        Column()
          .width(1.5)
          .height(this.measuredHeight)
          .borderRadius(0.75)
          .backgroundColor(this.treeLineColor())
          .position({ x: this.treeGuideX(index) - 0.75, y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }
      if (index === this.visualDepth() - 1) {
        Row()
          .width(Math.max(1, this.threadIndent() - this.treeGuideX(index) + 0.75))
          .height(this.treeJoinY() + 0.75)
          .border({
            width: { left: 1.5, bottom: 1.5 },
            color: this.treeLineColor(),
            radius: { bottomLeft: 7 },
          })
          .position({ x: this.treeGuideX(index) - 0.75, y: 0 })
          .hitTestBehavior(HitTestMode.None)
        if (this.guideContinues(index)) {
          Column()
            .width(1.5)
            .height(Math.max(0, this.measuredHeight - this.treeJoinY() + 16))
            .borderRadius(0.75)
            .backgroundColor(this.treeLineColor())
            .position({ x: this.treeGuideX(index) - 0.75, y: this.treeJoinY() })
            .hitTestBehavior(HitTestMode.None)
        }
        if (this.threadHasChildren) {
          Stack({ alignContent: Alignment.Center }) {
            Circle()
              .width(12)
              .height(12)
              .fill(this.treeNodeFillColor())
              .stroke(this.visualCollapsed ? this.accent : this.treeLineColor())
              .strokeWidth(1.2)
            Row()
              .width(6)
              .height(1.4)
              .backgroundColor(this.visualCollapsed ? this.accent : '#9BA0A8')
            Column()
              .width(1.4)
              .height(6)
              .backgroundColor(this.accent)
              .opacity(this.visualCollapsed ? 1 : 0)
              .scale({ x: 1, y: this.visualCollapsed ? 1 : 0.1 })
              .animation({ duration: 130, curve: Curve.EaseInOut })
          }
          .width(28)
          .height(28)
          .position({ x: this.treeGuideX(index) - 14, y: this.treeJoinY() - 14 })
          .hitTestBehavior(HitTestMode.Block)
          .priorityGesture(TapGesture().onAction(() => this.onToggle()))
        }
      }
    }, (index: number) => 'tree-guide-' + String(this.threadDepth) + '-' + String(index))
  }
}
