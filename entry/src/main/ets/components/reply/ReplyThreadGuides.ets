/**
 * 楼中楼回复树缩进连接线。
 * 从 ReplyCard.ThreadTreeLines 拆出，让评论卡不再维护树线绘制细节。
 */
@Component
export struct ReplyThreadGuides {
  @Prop threadDepth: number = 0;
  @Prop threadGuides: Array<boolean> = [];
  @Prop measuredHeight: number = 72;
  @StorageProp('isDarkMode') isDark: boolean = false;

  private visualDepth(): number {
    return Math.min(3, Math.max(0, this.threadDepth - 1));
  }

  private threadIndent(): number {
    return this.visualDepth() * 14;
  }

  private treeJoinY(): number {
    return 20;
  }

  private treeGuideX(index: number): number {
    return index * 14 + 5;
  }

  private guideIndexes(): Array<number> {
    const indexes: Array<number> = [];
    for (let i: number = 0; i < this.visualDepth(); i++) indexes.push(i);
    return indexes;
  }

  private guideContinues(index: number): boolean {
    if (this.threadGuides.length === 0) return false;
    // 第 0 层是根评论的直接回复，视觉上已扁平化，因此树线索引从下一层开始。
    const sourceIndex: number = Math.min(this.threadGuides.length - 1, index + 1);
    return this.threadGuides[sourceIndex] ?? false;
  }

  private treeLineColor(): string {
    return this.isDark ? '#4D303239' : '#99D8DCE2';
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
            .width(Math.max(1, this.threadIndent() - this.treeGuideX(index) + 2))
            .height(this.treeJoinY() + 0.5)
            .border({
              width: { left: 1, bottom: 1 },
              color: this.treeLineColor(),
              radius: { bottomLeft: 6 },
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
        }
      }, (index: number) => 'tree-guide-' + String(this.threadDepth) + '-' + String(index))
    }
    .width(this.threadIndent() + 4)
    .height(this.measuredHeight)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
