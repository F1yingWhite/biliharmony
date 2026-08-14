/** B 站私信会话列表与聊天详情。 */
import { promptAction } from '@kit.ArkUI';
import { Immersive } from '../common/Immersive';
import { AppNavStack, NAV_LOGIN } from '../common/AppRouter';
import { BiliApi, ActionResult } from '../api/BiliApi';
import { MessageSessionItem, MessageSessionPageData, PrivateMessageItem, PrivateMessagePageData } from '../model/Models';
import { UserStore } from '../common/UserStore';
import { colorWithAlpha, formatRelativeTime } from '../common/Utils';
import { LoadingView } from '../components/LoadingView';

@Component
export struct MessagesPage {
  @State sessions: Array<MessageSessionItem> = [];
  @State current: MessageSessionItem = new MessageSessionItem();
  @State messages: Array<PrivateMessageItem> = [];
  @State loading: boolean = false;
  @State hasMore: boolean = true;
  @State minSeqno: number = 0;
  @State draft: string = '';
  @State sending: boolean = false;
  @StorageProp('messageThreadOpen') @Watch('onThreadNavigationChanged') threadOpen: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;

  aboutToAppear(): void {
    AppStorage.setOrCreate<boolean>('messageThreadOpen', false);
    if (!UserStore.isLogin) {
      AppNavStack.replacePathByName(NAV_LOGIN, null);
      return;
    }
    this.loadSessions();
  }

  async loadSessions(): Promise<void> {
    if (this.loading) return;
    this.loading = true;
    const data: MessageSessionPageData = await BiliApi.getMessageSessions();
    this.sessions = data.sessions;
    this.hasMore = data.hasMore;
    this.loading = false;
  }

  async openSession(item: MessageSessionItem): Promise<void> {
    this.current = item;
    AppStorage.setOrCreate<boolean>('messageThreadOpen', true);
    this.messages = [];
    this.minSeqno = 0;
    this.hasMore = true;
    await this.loadMessages(true);
  }

  onThreadNavigationChanged(): void {
    if (!this.threadOpen && this.current.talkerId > 0) {
      this.current = new MessageSessionItem();
      this.messages = [];
      this.hasMore = true;
      this.minSeqno = 0;
    }
  }

  async loadMessages(reset: boolean): Promise<void> {
    if (this.loading || this.current.talkerId === 0 || (!reset && !this.hasMore)) return;
    this.loading = true;
    const data: PrivateMessagePageData = await BiliApi.getPrivateMessages(this.current.talkerId, reset ? 0 : this.minSeqno);
    this.messages = reset ? data.messages : this.mergeMessages(data.messages, this.messages);
    this.minSeqno = data.minSeqno > 0 ? data.minSeqno : this.minSeqno;
    this.hasMore = data.hasMore;
    this.loading = false;
    if (reset && this.messages.length > 0) {
      const ackSeqno: number = this.messages[this.messages.length - 1].seqno;
      // 打开会话即在本地消除红点，同时向 B 站回写最后已读 seqno。
      for (let i: number = 0; i < this.sessions.length; i++) {
        if (this.sessions[i].talkerId === this.current.talkerId) this.sessions[i].unread = 0;
      }
      this.sessions = this.sessions.slice();
      this.current.unread = 0;
      BiliApi.markPrivateMessagesRead(this.current.talkerId, ackSeqno);
    }
  }

  private mergeMessages(older: Array<PrivateMessageItem>, newer: Array<PrivateMessageItem>): Array<PrivateMessageItem> {
    const seen: Set<number> = new Set<number>();
    const all: Array<PrivateMessageItem> = [];
    for (let i: number = 0; i < older.length; i++) {
      if (!seen.has(older[i].seqno)) {
        seen.add(older[i].seqno);
        all.push(older[i]);
      }
    }
    for (let i: number = 0; i < newer.length; i++) {
      if (!seen.has(newer[i].seqno)) {
        seen.add(newer[i].seqno);
        all.push(newer[i]);
      }
    }
    return all;
  }

  async send(): Promise<void> {
    const content: string = this.draft.trim();
    const user = UserStore.current;
    if (content.length === 0 || user === null || this.sending) return;
    this.sending = true;
    const result: ActionResult = await BiliApi.sendPrivateMessage(user.mid, this.current.talkerId, content);
    this.sending = false;
    if (!result.ok) {
      promptAction.showToast({ message: result.message });
      return;
    }
    const local: PrivateMessageItem = new PrivateMessageItem();
    local.senderId = user.mid;
    local.receiverId = this.current.talkerId;
    local.text = content;
    local.timestamp = Math.floor(Date.now() / 1000);
    local.seqno = Date.now();
    this.messages = this.messages.concat([local]);
    this.draft = '';
  }

  goBack(): void {
    if (this.current.talkerId > 0) {
      AppStorage.setOrCreate<boolean>('messageThreadOpen', false);
    } else {
      AppNavStack.pop();
    }
  }

  @Builder
  Header() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        Text('‹')
          .fontSize(28)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      }
      .width(40)
      .height(46)
      .onClick(() => this.goBack())
      if (this.current.talkerId > 0 && this.current.avatar.length > 0) {
        Image(this.current.avatar).width(30).height(30).borderRadius(15).objectFit(ImageFit.Cover)
      }
      Text(this.current.talkerId > 0 ? this.current.name : '私信')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
      Blank()
    }
    .width('100%')
    .height(50)
    .padding({ left: 4, right: 14 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  @Builder
  SessionRow(item: MessageSessionItem) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        if (item.avatar.length > 0) {
          Image(item.avatar).width(48).height(48).borderRadius(24).objectFit(ImageFit.Cover)
        } else {
          Circle().width(48).height(48).fill(colorWithAlpha(this.accent, '33'))
          Text(item.name.length > 0 ? item.name.substring(0, 1) : 'B')
            .fontSize(18).fontColor(this.accent)
        }
        if (item.unread > 0) {
          Text(item.unread > 99 ? '99+' : String(item.unread))
            .fontSize(9).fontColor('#FFFFFF').backgroundColor('#FA4B4B')
            .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(9)
            .translate({ x: 5, y: -3 })
        }
      }
      .width(50).height(50)
      Column({ space: 6 }) {
        Row() {
          Text(item.name.length > 0 ? item.name : '用户 ' + String(item.talkerId))
            .fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C').layoutWeight(1).maxLines(1)
          Text(formatRelativeTime(item.timestamp))
            .fontSize(10).fontColor('#B0B3B8')
        }
        .width('100%')
        Text(item.preview.length > 0 ? item.preview : '暂无消息')
          .fontSize(12).fontColor('#9499A0').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .onClick(() => this.openSession(item))
  }

  @Builder
  MessageBubble(item: PrivateMessageItem) {
    Row() {
      if (item.senderId === (UserStore.current?.mid ?? 0)) Blank()
      Column({ space: 4 }) {
        Text(item.text)
          .fontSize(14)
          .fontColor(item.senderId === (UserStore.current?.mid ?? 0) ? '#FFFFFF' : (this.isDark ? '#FFFFFF' : '#18191C'))
          .lineHeight(20)
        Text(formatRelativeTime(item.timestamp))
          .fontSize(9)
          .fontColor(item.senderId === (UserStore.current?.mid ?? 0) ? '#CCFFFFFF' : '#9499A0')
      }
      .alignItems(item.senderId === (UserStore.current?.mid ?? 0) ? HorizontalAlign.End : HorizontalAlign.Start)
      .constraintSize({ maxWidth: '76%' })
      .padding({ left: 12, right: 12, top: 8, bottom: 7 })
      .borderRadius(14)
      .backgroundColor(item.senderId === (UserStore.current?.mid ?? 0) ? this.accent : (this.isDark ? '#303136' : '#F1F3F5'))
      if (item.senderId !== (UserStore.current?.mid ?? 0)) Blank()
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  @Builder
  Composer() {
    Row({ space: 8 }) {
      TextInput({ placeholder: '发一条友善的私信', text: this.draft })
        .height(38).layoutWeight(1).fontSize(14)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .placeholderColor('#9499A0')
        .backgroundColor(this.isDark ? '#292A2E' : '#F2F4F6')
        .borderRadius(19).padding({ left: 14, right: 14 })
        .onChange((value: string) => this.draft = value)
        .onSubmit(() => this.send())
      Button(this.sending ? '发送中' : '发送')
        .height(36).fontSize(13).fontColor('#FFFFFF')
        .backgroundColor(this.accent).borderRadius(18)
        .enabled(!this.sending && this.draft.trim().length > 0)
        .onClick(() => this.send())
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  build() {
    Column() {
      this.Header()
      if (this.current.talkerId === 0) {
        if (this.sessions.length === 0) {
          LoadingView({ loading: this.loading, empty: !this.loading, emptyText: '暂无私信会话', onRetry: () => this.loadSessions() })
        } else {
          List() {
            ForEach(this.sessions, (item: MessageSessionItem) => {
              ListItem() { this.SessionRow(item) }
            }, (item: MessageSessionItem) => String(item.talkerId))
          }
          .layoutWeight(1).padding({ left: 12, right: 12 }).scrollBar(BarState.Off)
        }
      } else {
        List() {
          ListItem() {
            Text(this.loading ? '加载中…' : (this.hasMore ? '加载更早消息' : '没有更早消息了'))
              .fontSize(11).fontColor(this.hasMore ? this.accent : '#9499A0')
              .width('100%').textAlign(TextAlign.Center).padding(12)
              .onClick(() => this.loadMessages(false))
          }
          ForEach(this.messages, (item: PrivateMessageItem) => {
            ListItem() { this.MessageBubble(item) }
          }, (item: PrivateMessageItem) => String(item.seqno))
        }
        .layoutWeight(1)
        .padding({ left: 10, right: 10 })
        .scrollBar(BarState.Off)
        this.Composer()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: Immersive.statusBarHeight() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
