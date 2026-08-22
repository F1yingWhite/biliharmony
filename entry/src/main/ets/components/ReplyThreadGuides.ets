/**
 * 楼中楼回复树缩进连接线与轻量折叠节点。
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
    return this.visualDepth() * 16;
  }

  private treeJoinY(): number {
    return 24;
  }

  private treeGuideX(index: number): number {
    return index * 16 + 8;
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
    return this.isDark ? '#34373D' : '#E1E4E8';
  }

  build() {
    // 明确限制覆盖层只占左侧树线区域。过去裸 ForEach 作为 Stack 的最后一个
    // 子组件时，宿主命中区域可能扩展到整张回复卡，挡住其下方点赞/点踩按钮。
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.guideIndexes(), (index: number) => {
        if (index < this.visualDepth() - 1 && this.guideContinues(index)) {
          Column()
            .width(1)
            .height(this.measuredHeight)
            .borderRadius(0.5)
            .backgroundColor(this.treeLineColor())
            .position({ x: this.treeGuideX(index) - 0.5, y: 0 })
            .hitTestBehavior(HitTestMode.None)
        }
        if (index === this.visualDepth() - 1) {
          Row()
            .width(Math.max(1, this.threadIndent() - this.treeGuideX(index) + 3))
            .height(this.treeJoinY() + 0.5)
            .border({
              width: { left: 1, bottom: 1 },
              color: this.treeLineColor(),
              radius: { bottomLeft: 5 },
            })
            .position({ x: this.treeGuideX(index) - 0.5, y: 0 })
            .hitTestBehavior(HitTestMode.None)
          if (this.guideContinues(index)) {
            Column()
              .width(1)
              .height(Math.max(0, this.measuredHeight - this.treeJoinY()))
              .borderRadius(0.5)
              .backgroundColor(this.treeLineColor())
              .position({ x: this.treeGuideX(index) - 0.5, y: this.treeJoinY() })
              .hitTestBehavior(HitTestMode.None)
          }
          if (this.threadHasChildren) {
            Stack({ alignContent: Alignment.Center }) {
              Circle()
                .width(this.visualCollapsed ? 7 : 5)
                .height(this.visualCollapsed ? 7 : 5)
                .fill(this.visualCollapsed ? this.accent : this.treeLineColor())
                .animation({ duration: 130, curve: Curve.EaseInOut })
              Column()
                .width(1)
                .height(4)
                .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
                .opacity(this.visualCollapsed ? 1 : 0)
              Row()
                .width(4)
                .height(1)
                .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
                .opacity(this.visualCollapsed ? 1 : 0)
            }
            .width(24)
            .height(24)
            .position({ x: this.treeGuideX(index) - 12, y: this.treeJoinY() - 12 })
            .hitTestBehavior(HitTestMode.Block)
            .priorityGesture(TapGesture().onAction(() => this.onToggle()))
          }
        }
      }, (index: number) => 'tree-guide-' + String(this.threadDepth) + '-' + String(index))
    }
    .width(this.threadIndent() + 4)
    .height(this.measuredHeight)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
