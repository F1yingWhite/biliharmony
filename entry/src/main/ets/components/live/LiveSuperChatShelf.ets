/** 参考官方 SC 标签栏：头像金额横排，点击标签展开对应卡片；播放画面持续可见。 */
import { LiveChatMessage } from '../../model/LiveModels';

/**
 * 父页面持有的 SC 数据通道：合并进 @State 后 publish 直呼订阅者，
 * 替代 @Prop messages 在每次 SC 合并时的整组深拷贝。订阅时立即补发当前快照，
 * 晚创建的浮层（全屏时才挂载）不会错过已到达的 SC。
 */
export class LiveSuperChatFeed {
  private latest: Array<LiveChatMessage> = [];
  private sinks: Array<(list: Array<LiveChatMessage>) => void> = [];

  count(): number {
    return this.latest.length;
  }

  publish(list: Array<LiveChatMessage>): void {
    this.latest = list;
    for (let i: number = 0; i < this.sinks.length; i++) this.sinks[i](list);
  }

  subscribe(sink: (list: Array<LiveChatMessage>) => void): void {
    this.sinks.push(sink);
    sink(this.latest);
  }

  unsubscribe(sink: (list: Array<LiveChatMessage>) => void): void {
    const at: number = this.sinks.indexOf(sink);
    if (at >= 0) this.sinks.splice(at, 1);
  }
}

@Component
export struct LiveSuperChatShelf {
  feed: LiveSuperChatFeed = new LiveSuperChatFeed();
  @Prop floating: boolean = false;
  @Prop panelHeight: number = 220;
  @State activeMessages: Array<LiveChatMessage> = [];
  @State @Watch('onSelectionChanged') selectedId: string = '';
  onExpandedChange: (expanded: boolean) => void = () => {};
  /** 唯一的每秒变化量：倒计时文本由它驱动，activeMessages 只在到期边界真正改变集合时才换引用。 */
  @State nowSeconds: number = Math.floor(Date.now() / 1000);
  private messages: Array<LiveChatMessage> = [];
  private receive: ((list: Array<LiveChatMessage>) => void) | null = null;
  private timer: number = -1;

  aboutToAppear(): void {
    this.receive = (list: Array<LiveChatMessage>): void => {
      this.messages = list;
      this.refreshActive();
    };
    this.feed.subscribe(this.receive);
    this.timer = setInterval(() => this.refreshActive(), 1000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) clearInterval(this.timer);
    this.timer = -1;
    if (this.receive !== null) this.feed.unsubscribe(this.receive);
    this.receive = null;
    this.onExpandedChange(false);
  }

  private refreshActive(): void {
    this.nowSeconds = Math.floor(Date.now() / 1000);
    const next: Array<LiveChatMessage> = [];
    const nextIds: Set<string> = new Set<string>();
    for (let i: number = 0; i < this.messages.length; i++) {
      const message: LiveChatMessage = this.messages[i];
      if (message.endTime > 0 && message.endTime <= this.nowSeconds) continue;
      next.push(message);
      nextIds.add(message.id);
    }
    const previous: Array<LiveChatMessage> = this.activeMessages;
    const previousCount: number = previous ? previous.length : -1;
    const selectionValid: boolean = this.selectedId.length === 0 || nextIds.has(this.selectedId);
    if (this.sameActiveIds(previous, previousCount, nextIds)) {
      // 每秒 tick 集合未变：只推进 nowSeconds 驱动倒计时，不换 activeMessages 引用、整列不重 diff。
      if (!selectionValid) this.selectedId = '';
      return;
    }
    this.activeMessages = next;
    if (!selectionValid) this.selectedId = '';
  }

  private sameActiveIds(previous: Array<LiveChatMessage>, previousCount: number, nextIds: Set<string>): boolean {
    if (previousCount !== nextIds.size) return false;
    for (let i: number = 0; i < previous.length; i++) {
      if (!nextIds.has(previous[i].id)) return false;
    }
    return true;
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
