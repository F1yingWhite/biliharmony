@Component
export struct SponsorBlockNotice {
  @Prop title: string = '';
  @Prop detail: string = '';
  @Prop color: string = '#00D400';
  @Prop manual: boolean = false;
  @Prop canUndo: boolean = false;
  @Prop canVote: boolean = false;
  onPrimary: () => void = () => {};
  onVote: (type: number) => void = () => {};
  onClose: () => void = () => {};

  @Builder
  IconAction(icon: Resource, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Image(icon)
        .width(18)
        .height(18)
        .renderMode(ImageRenderMode.Template)
        .fillColor('#FFFFFF')
    }
    .width(34)
    .height(34)
    .borderRadius(4)
    .backgroundColor('#24FFFFFF')
    .onClick(() => onTap())
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Column()
          .width(4)
          .height(34)
          .borderRadius(2)
          .backgroundColor(this.color)
        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.detail.length > 0) {
            Text(this.detail)
              .fontSize(11)
              .fontColor('#BFFFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        this.IconAction($r('app.media.ic_close'), () => this.onClose())
      }
      .width('100%')

      Row({ space: 6 }) {
        if (this.canVote) {
          this.IconAction($r('app.media.ic_like'), () => this.onVote(1))
          this.IconAction($r('app.media.ic_dislike'), () => this.onVote(0))
        }
        Blank()
        if (this.manual || this.canUndo) {
          Text(this.canUndo ? '撤销' : '立即处理')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(4)
            .backgroundColor(this.color)
            .onClick(() => this.onPrimary())
        }
      }
      .width('100%')
    }
    .width(280)
    .padding(10)
    .borderRadius(6)
    .backgroundColor('#E6111216')
    .border({ width: 0.5, color: '#35FFFFFF' })
    .shadow({ radius: 10, color: '#44000000', offsetY: 3 })
  }
}
