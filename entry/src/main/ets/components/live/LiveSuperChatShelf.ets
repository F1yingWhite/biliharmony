/** 参考官方 SC 标签栏：头像金额横排，点击标签展开对应卡片；播放画面持续可见。 */
import { LiveChatMessage } from '../../model/LiveModels';

@Component
export struct LiveSuperChatShelf {
  @Prop @Watch('refreshActive') messages: Array<LiveChatMessage> = [];
  @Prop floating: boolean = false;
  @Prop panelHeight: number = 220;
  @State activeMessages: Array<LiveChatMessage> = [];
  @State @Watch('onSelectionChanged') selectedId: string = '';
  onExpandedChange: (expanded: boolean) => void = () => {};
  @State nowSeconds: number = Math.floor(Date.now() / 1000);
  private timer: number = -1;

  aboutToAppear(): void {
    this.refreshActive();
    this.timer = setInterval(() => this.refreshActive(), 1000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    this.onExpandedChange(false);
  }

  private refreshActive(): void {
    this.nowSeconds = Math.floor(Date.now() / 1000);
    this.activeMessages = this.messages.filter((message: LiveChatMessage) =>
      message.endTime <= 0 || message.endTime > this.nowSeconds);
    if (!this.activeMessages.some((message: LiveChatMessage) => message.id === this.selectedId)) {
      this.selectedId = '';
    }
  }

  private onSelectionChanged(): void {
    this.onExpandedChange(this.selectedId.length > 0);
  }

  private selected(): LiveChatMessage {
    return this.activeMessages.find((message: LiveChatMessage) => message.id === this.selectedId) ??
      new LiveChatMessage();
  }

  private remaining(message: LiveChatMessage): string {
    if (message.endTime <= 0) return '';
    const seconds: number = Math.max(0, message.endTime - this.nowSeconds);
    const hours: number = Math.floor(seconds / 3600);
    const minutes: number = Math.floor(seconds / 60) % 60;
    return (hours > 0 ? String(hours).padStart(2, '0') + ':' : '') +
      String(minutes).padStart(2, '0') + ':' + String(seconds % 60).padStart(2, '0');
  }

  @Builder
  MessageCard(message: LiveChatMessage) {
    Column() {
      Row({ space: 7 }) {
        Image(message.face || $r('app.media.placeholder_avatar_noface'))
          .width(28).height(28).borderRadius(14).objectFit(ImageFit.Cover)
        Column({ space: 3 }) {
          Text(message.uname).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor('#343740').maxLines(1)
          Text('¥' + String(message.price)).fontSize(11).fontColor('#686D76')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.remaining(message)).fontSize(10).fontColor('#777D87')
        Text('×').fontSize(21).fontColor('#686D76')
          .width(28).height(32).textAlign(TextAlign.Center)
          .accessibilityText('收起醒目留言')
          .onClick(() => this.selectedId = '')
      }.width('100%').padding({ left: 9, right: 4, top: 8, bottom: 8 }).backgroundColor('#F2F6F8')
      Scroll() {
        Text(message.text).width('100%').fontSize(13).fontColor('#FFFFFF').padding(10)
      }
      .width('100%').constraintSize({ maxHeight: this.panelHeight })
      .scrollBar(BarState.Auto)
    }
    .width('100%').borderRadius(8).backgroundColor(message.backgroundColor).clip(true)
  }

  build() {
    Column({ space: 6 }) {
      if (this.activeMessages.length > 0) {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.activeMessages, (message: LiveChatMessage) => {
              Row({ space: 5 }) {
                Image(message.face || $r('app.media.placeholder_avatar_noface'))
                  .width(24).height(24).borderRadius(12).objectFit(ImageFit.Cover)
                Text('¥' + String(message.price)).fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              }
              .height(30).padding({ left: 3, right: 10 }).borderRadius(15)
              .backgroundColor(message.backgroundColor)
              .border({ width: this.selectedId === message.id ? 1.5 : 0, color: '#FFFFFF' })
              .accessibilityText(message.uname + '，醒目留言，' + message.price + '元')
              .id((this.floating ? 'live-sc-landscape-' : 'live-sc-portrait-') + message.id)
              .onClick(() => this.selectedId = this.selectedId === message.id ? '' : message.id)
            }, (message: LiveChatMessage) => message.id)
          }
        }
        .width('100%').align(Alignment.Start).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        if (this.selectedId.length > 0) this.MessageCard(this.selected())
      }
    }
    .width('100%')
    .padding(this.activeMessages.length > 0 && !this.floating ?
      { left: 12, right: 12, top: 4, bottom: 8 } : 0)
  }
}
