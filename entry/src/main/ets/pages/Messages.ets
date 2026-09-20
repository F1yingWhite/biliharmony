import { MotionTokens } from '../common/MotionTokens';
/** B 站消息中心：私信会话/聊天 + 回复我的/@我/收到的赞/系统通知 五个分类 Tab。 */
import { AppTheme } from '../common/AppTheme';
import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { Immersive } from '../common/Immersive';
import { AppNavStack, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  ImageViewerParam, ImageViewerSrcRect, NAV_IMAGE_VIEWER, NAV_LOGIN, NAV_VIDEO_DETAIL,
  VideoDetailParam, setHeroBgSnapshot } from '../common/AppRouter';
import { BiliApi, ActionResult } from '../api/BiliApi';
import { MessageSessionItem, MessageSessionPageData, PrivateMessageItem, PrivateMessagePageData } from '../model/Models';
import { UserStore } from '../services/auth/UserStore';
import { MsgUnreadStore } from '../services/message/MsgUnreadStore';
import { colorWithAlpha, formatRelativeTime } from '../common/Utils';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { MsgNotifyList } from '../components/MsgNotifyList';
import { PageHeader } from '../components/PageHeader';
import { BasicDataSource } from '../common/BasicDataSource';
import { MessageApi } from '../api/MessageApi';
import { biliImageOriginal, biliImageThumbnail } from '../common/ImageUrl';

@Component
export struct MessagesPage {
  @State current: MessageSessionItem = new MessageSessionItem();
  @State messages: Array<PrivateMessageItem> = [];
  @State sessionLoading: boolean = false;
  @State messageLoading: boolean = false;
  @State sessionError: string = '';
  @State messageError: string = '';
  @State hasMore: boolean = true;
  @State sessionHasMore: boolean = true;
  @State sessionCount: number = 0;
  @State minSeqno: number = 0;
  @State draft: string = '';
  @State sending: boolean = false;
  @State readAllLoading: boolean = false;
  @State viewportWidth: number = 400;
  private messageScroller: Scroller = new Scroller();
  private firstVisibleMessage: number = 0;
  private pendingScrollIndex: number | null = null;
  private scrollTimer: number = -1;
  /** 顶部分类 Tab：0 私信 1 回复 2 @我 3 赞 4 系统 */
  @State activeTab: number = 0;
  @StorageProp('messageThreadOpen') threadOpen: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private sessionsSource: BasicDataSource<MessageSessionItem> = new BasicDataSource<MessageSessionItem>();
  private tabs: Array<string> = ['私信', '回复', '@我', '赞', '系统'];
  /** 通知列表惰性挂载：首次切到对应 Tab 才创建，避免一进页面就并发五个请求。 */
  private tabMounted: Array<boolean> = [true, false, false, false, false];
  /** 会话请求代际：切换会话后丢弃旧会话返回的数据。 */
  private messageGeneration: number = 0;

  aboutToAppear(): void {
    AppStorage.setOrCreate<boolean>('messageThreadOpen', false);
    if (!UserStore.isLogin) {
      AppNavStack.replacePathByName(NAV_LOGIN, null);
      return;
    }
    this.loadSessions(true).catch(() => {
    });
  }

  async loadSessions(reset: boolean): Promise<void> {
    if (this.sessionLoading || (!reset && !this.sessionHasMore)) return;
    this.sessionLoading = true;
    try {
      const all: Array<MessageSessionItem> = this.sessionsSource.getAll();
      const beginTs: number = reset || all.length === 0 ? 0 : all[all.length - 1].sessionTs;
      const data: MessageSessionPageData = await MessageApi.getMessageSessions(beginTs);
      if (data.error.length > 0) {
        // 失败不清空已有列表；首次加载失败时由 LoadingView 展示原因与重试。
        if (reset) this.sessionError = data.error;
        return;
      }
      this.sessionError = '';
      if (reset) {
        this.sessionsSource.reset(data.sessions);
      } else {
        this.sessionsSource.append(this.dedupSessions(data.sessions));
      }
      // BasicDataSource 只会刷新已挂载的 LazyForEach；首屏列表尚未挂载时，
      // 必须用 @State 切换“加载态 / 列表”外层分支。
      this.sessionCount = this.sessionsSource.totalCount();
      this.sessionHasMore = data.hasMore;
    } finally {
      this.sessionLoading = false;
    }
  }

  /** 分页去重：B 站会话接口按 session_ts 翻页，边界处可能重复返回同一会话。 */
  private dedupSessions(incoming: Array<MessageSessionItem>): Array<MessageSessionItem> {
    const seen: Set<number> = new Set<number>();
    const all: Array<MessageSessionItem> = this.sessionsSource.getAll();
    for (let i: number = 0; i < all.length; i++) {
      seen.add(all[i].talkerId);
    }
    const out: Array<MessageSessionItem> = [];
    for (let i: number = 0; i < incoming.length; i++) {
      if (!seen.has(incoming[i].talkerId)) {
        seen.add(incoming[i].talkerId);
        out.push(incoming[i]);
      }
    }
    return out;
  }

  async openSession(item: MessageSessionItem): Promise<void> {
    this.messageGeneration++;
    this.current = item;
    this.draft = '';
    this.pendingScrollIndex = null;
    AppStorage.setOrCreate<boolean>('messageThreadOpen', true);
    this.messages = [];
    this.messageError = '';
    this.minSeqno = 0;
    this.hasMore = true;
    await this.loadMessages(true);
  }

  async loadMessages(reset: boolean): Promise<void> {
    if (this.current.talkerId === 0 || (!reset && (this.messageLoading || !this.hasMore))) return;
    const generation: number = this.messageGeneration;
    this.messageLoading = true;
    const talkerId: number = this.current.talkerId;
    try {
      const data: PrivateMessagePageData = await MessageApi.getPrivateMessages(talkerId, reset ? 0 : this.minSeqno);
      if (generation !== this.messageGeneration || this.current.talkerId !== talkerId) return;
      if (data.error.length > 0) {
        this.messageError = data.error;
        return;
      }
      this.messageError = '';
      const previousCount: number = this.messages.length;
      const firstVisible: number = this.firstVisibleMessage;
      this.messages = reset ? data.messages : this.mergeMessages(data.messages, this.messages);
      // 首次进入看最新消息；向前翻页保留原来的阅读位置。
      this.pendingScrollIndex = reset ? -1 : firstVisible + this.messages.length - previousCount;
      this.scheduleMessageScroll();
      this.minSeqno = data.minSeqno > 0 ? data.minSeqno : this.minSeqno;
      this.hasMore = data.hasMore;
      if (reset && this.messages.length > 0) {
        const ackSeqno: number = this.messages[this.messages.length - 1].seqno;
        // 服务端确认成功后再清本地红点，避免请求失败时退出会话又恢复成未读。
        MessageApi.markPrivateMessagesRead(talkerId, ackSeqno).then((result: ActionResult) => {
          if (result.ok) this.clearSessionUnread(talkerId);
        }).catch(() => {
        });
      }
    } catch (e) {
      if (generation === this.messageGeneration) this.messageError = '消息加载失败，请重试';
    } finally {
      if (generation === this.messageGeneration) this.messageLoading = false;
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
    const talkerId: number = this.current.talkerId;
    const generation: number = this.messageGeneration;
    if (content.length === 0 || user === null || talkerId === 0 || this.sending) return;
    this.sending = true;
    try {
      const result: ActionResult = await MessageApi.sendPrivateMessage(user.mid, talkerId, content);
      if (generation !== this.messageGeneration || this.current.talkerId !== talkerId) return;
      if (!result.ok) {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
        return;
      }
      const local: PrivateMessageItem = new PrivateMessageItem();
      local.senderId = user.mid;
      local.receiverId = talkerId;
      local.text = content;
      local.timestamp = Math.floor(Date.now() / 1000);
      local.seqno = Date.now();
      this.messages = this.messages.concat([local]);
      this.pendingScrollIndex = -1;
      this.scheduleMessageScroll();
      if (this.draft.trim() === content) this.draft = '';
    } catch (e) {
      if (generation === this.messageGeneration && this.current.talkerId === talkerId) {
        this.getUIContext().getPromptAction().showToast({ message: '发送失败，请检查网络' });
      }
    } finally {
      this.sending = false;
    }
  }

  goBack(): void {
    if (this.threadOpen) {
      this.messageGeneration++;
      this.messageLoading = false;
      AppStorage.setOrCreate<boolean>('messageThreadOpen', false);
    } else {
      AppNavStack.pop();
    }
  }

  aboutToDisappear(): void {
    this.messageGeneration++;
    if (this.scrollTimer >= 0) clearTimeout(this.scrollTimer);
    // 离开消息中心回到首页时重新拉一次未读数，让头栏角标与服务端已读状态对齐。
    MsgUnreadStore.refresh().catch(() => {
    });
  }

  private scheduleMessageScroll(): void {
    const index: number | null = this.pendingScrollIndex;
    if (index === null || !this.threadOpen) return;
    this.pendingScrollIndex = null;
    const generation: number = this.messageGeneration;
    if (this.scrollTimer >= 0) clearTimeout(this.scrollTimer);
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      if (!this.threadOpen || generation !== this.messageGeneration) return;
      if (index < 0) this.messageScroller.scrollToIndex(this.messages.length, false, ScrollAlign.END);
      else this.messageScroller.scrollToIndex(index, false, ScrollAlign.START);
    }, 120);
  }

  private bubbleWidth(): number {
    return Math.max(120, Math.min(280, this.viewportWidth - 96));
  }

  @Builder
  SessionAvatar() {
    if (this.current.talkerId > 0 && this.current.avatar.length > 0) {
      Image(this.current.avatar).width(30).height(30).borderRadius(15).objectFit(ImageFit.Cover)
    }
  }

  @Builder
  SessionRow(item: MessageSessionItem) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        if (item.avatar.length > 0) {
          Image(item.avatar).width(48).height(48).borderRadius(24).objectFit(ImageFit.Cover)
        } else {
          Circle().width(48).height(48).fill(colorWithAlpha(this.accent, '33'))
          Text(item.name.length > 0 ? item.name.substring(0, 1) : 'B')
            .fontSize(18).fontColor(this.accent)
        }
        if (item.unread > 0) {
          Text(item.unread > 99 ? '99+' : String(item.unread))
            .fontSize(9).fontColor('#FFFFFF').backgroundColor(AppTheme.DANGER)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(9)
            .position({ right: -3, top: -3 })
        }
      }
      .width(50).height(50)
      Column({ space: 6 }) {
        Row() {
          Text(item.name.length > 0 ? item.name : '用户 ' + String(item.talkerId))
            .fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#FFFFFF' : '#18191C').layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(formatRelativeTime(item.timestamp))
            .fontSize(10).fontColor('#B0B3B8')
          Text('⋯')
            .fontSize(12).fontColor('#9499A0')
            .padding({ left: 8, right: 4, top: 2, bottom: 2 })
            .priorityGesture(TapGesture().onAction(() => this.confirmRemoveSession(item)))
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
    // 长按删除会话（对齐 PiliPlus 私信会话删除）
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => this.confirmRemoveSession(item))
    )
  }

  /** 长按删除私信会话：确认后调服务端删除，成功后本地移除该会话行。 */
  private confirmRemoveSession(item: MessageSessionItem): void {
    if (item.talkerId <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: '该会话不支持删除' });
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除会话',
        message: '删除后聊天记录不再显示（对方记录不受影响）。确定删除吗？',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '删除', color: AppTheme.DANGER },
        ],
      }).then((dialogResult) => {
        if (Number(dialogResult.index) !== 1) return;
        MessageApi.removeSession(item.talkerId)
          .then((r: ActionResult) => {
            if (r.ok) {
              this.sessionsSource.reset(
                this.sessionsSource.getAll().filter((x: MessageSessionItem) => x.talkerId !== item.talkerId));
              this.sessionCount = this.sessionsSource.totalCount();
              this.getUIContext().getPromptAction().showToast({ message: '会话已删除' });
            } else {
              this.getUIContext().getPromptAction().showToast({ message: r.message });
            }
          })
          .catch(() => {
            this.getUIContext().getPromptAction().showToast({ message: '删除失败，请稍后重试' });
          });
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  private clearSessionUnread(talkerId: number): void {
    const all: Array<MessageSessionItem> = this.sessionsSource.getAll();
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].talkerId !== talkerId || all[i].unread === 0) continue;
      const updated: MessageSessionItem = all[i].clone();
      updated.unread = 0;
      all[i] = updated;
      this.sessionsSource.updateItem(i, updated);
    }
    this.sessionsSource.reset(all);
    if (this.current.talkerId === talkerId) this.current.unread = 0;
  }

  private async markAllRead(): Promise<void> {
    if (this.readAllLoading) return;
    this.readAllLoading = true;
    let failed: number = 0;
    try {
      const notifyResult: ActionResult = await MessageApi.markAllNotificationsRead();
      if (notifyResult.ok) MsgUnreadStore.clearAll();
      else failed++;

      const sessions: Array<MessageSessionItem> = this.sessionsSource.getAll();
      for (let i: number = 0; i < sessions.length; i++) {
        if (sessions[i].unread <= 0) continue;
        const result: ActionResult = await MessageApi.markPrivateMessagesRead(sessions[i].talkerId);
        if (result.ok) this.clearSessionUnread(sessions[i].talkerId);
        else failed++;
      }
      this.getUIContext().getPromptAction().showToast({
        message: failed === 0 ? '已标记全部已读' : '部分消息标记失败，请稍后重试',
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '标记已读失败，请稍后重试' });
    } finally {
      this.readAllLoading = false;
    }
  }

  private richMediaId(item: PrivateMessageItem): string {
    return 'private-message-media-' + String(item.seqno);
  }

  private richCardId(item: PrivateMessageItem): string {
    return 'private-message-card-' + String(item.seqno);
  }

  private imageMessageHeight(item: PrivateMessageItem): number {
    if (item.imageWidth <= 0 || item.imageHeight <= 0) return 180;
    return Math.max(80, Math.min(300, Math.min(240, this.bubbleWidth()) * item.imageHeight / item.imageWidth));
  }

  private componentRect(id: string): ImageViewerSrcRect | undefined {
    try {
      const area = this.getUIContext().getComponentUtils().getRectangleById(id);
      if (area.size.width <= 0 || area.size.height <= 0 || area.windowOffset.x < 0 || area.windowOffset.y < 0) {
        return undefined;
      }
      const x: number = this.getUIContext().px2vp(area.windowOffset.x);
      const screenWidth: number = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
      if (x >= screenWidth) return undefined;
      return {
        x: x,
        y: this.getUIContext().px2vp(area.windowOffset.y),
        w: this.getUIContext().px2vp(area.size.width),
        h: this.getUIContext().px2vp(area.size.height),
      };
    } catch (e) {
      return undefined;
    }
  }

  private openRichMessage(item: PrivateMessageItem): void {
    if (item.imageUrl.length > 0) {
      const rect: ImageViewerSrcRect | undefined = this.componentRect(this.richMediaId(item));
      const preview: string = biliImageThumbnail(item.imageUrl, 640);
      const viewer: ImageViewerParam = {
        images: [biliImageOriginal(item.imageUrl)],
        initialIndex: 0,
        srcIds: [this.richMediaId(item)],
        srcPreviews: [preview],
      };
      if (rect !== undefined) {
        viewer.srcRect = rect;
        viewer.srcRects = [rect];
        AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
        AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
      }
      AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer);
      return;
    }
    if (item.richBvid.length === 0 && item.richAid <= 0) return;
    const param: VideoDetailParam = {
      bvid: item.richBvid,
      aid: item.richAid,
      title: item.richTitle.length > 0 ? item.richTitle : item.text,
      cover: item.richCover,
    };
    try {
      const cardRect: ImageViewerSrcRect | undefined = this.componentRect(this.richCardId(item));
      if (cardRect !== undefined) {
        const snapshot: image.PixelMap = this.getUIContext().getComponentSnapshot().getSync(this.richCardId(item), {
          waitUntilRenderFinished: true,
        });
        param.cardRect = cardRect;
        setHeroBgSnapshot(snapshot);
        AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
        AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
        AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
        return;
      }
    } catch (e) {
      // 快照或测量失败时回退到封面 hero，不能阻断视频打开。
    }
    const coverRect: ImageViewerSrcRect | undefined = this.componentRect(this.richMediaId(item));
    if (coverRect !== undefined && item.richCover.length > 0) {
      param.srcRect = coverRect;
      AppStorage.setOrCreate<boolean>(HERO_NAV_TRANSITION_ACTIVE_KEY, true);
      AppStorage.setOrCreate<number>(HERO_NAV_TRANSITION_DURATION_KEY, 360);
    }
    AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param);
  }

  @Builder
  RichMessageCard(item: PrivateMessageItem) {
    Row({ space: 8 }) {
      if (item.richCover.length > 0) {
        Image(item.richCover)
          .id(this.richMediaId(item))
          .width(64)
          .height(64)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
      }
      Column({ space: 3 }) {
        Text(item.richTitle.length > 0 ? item.richTitle : item.text)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
          .lineHeight(19)
        if (item.richDesc.length > 0) {
          Text(item.richDesc)
            .fontSize(14)
            .fontColor(this.isDark ? '#C5CAD3' : '#5C626E')
            .lineHeight(21)
            .copyOption(CopyOptions.LocalDevice)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width(this.bubbleWidth())
    .padding(8)
    .borderRadius(10)
    .backgroundColor(this.isDark ? '#292C33' : '#FFFFFF')
    .id(this.richCardId(item))
    .onClick(() => this.openRichMessage(item))
  }

  @Builder
  ImageMessageCard(item: PrivateMessageItem) {
    Image(biliImageThumbnail(item.imageUrl, 640))
      .id(this.richMediaId(item))
      .width(Math.min(240, this.bubbleWidth()))
      .height(this.imageMessageHeight(item))
      .objectFit(ImageFit.Contain)
      .borderRadius(10)
      .clip(true)
      .onClick(() => this.openRichMessage(item))
  }

  @Builder
  MessageAvatar(mine: boolean) {
    Image(mine ? (UserStore.current?.face || $r('app.media.placeholder_avatar_noface')) :
      (this.current.avatar || $r('app.media.placeholder_avatar_noface')))
      .width(34).height(34).borderRadius(17).objectFit(ImageFit.Cover)
  }

  @Builder
  MessageBubble(item: PrivateMessageItem) {
    Row({ space: 8 }) {
      if (item.senderId === (UserStore.current?.mid ?? 0)) Blank()
      else this.MessageAvatar(false)
      Column({ space: 5 }) {
        if (item.imageUrl.length > 0) {
          this.ImageMessageCard(item)
        } else if (item.richTitle.length > 0 || item.richCover.length > 0 || item.richUrl.length > 0) {
          this.RichMessageCard(item)
        } else {
          Text(item.text)
            .fontSize(14)
            .fontColor(this.isDark ? '#F1F2F5' : '#242833')
            .lineHeight(21)
            .copyOption(CopyOptions.LocalDevice)
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .borderRadius(14)
            .backgroundColor(item.senderId === (UserStore.current?.mid ?? 0) ?
              colorWithAlpha(this.accent, this.isDark ? '55' : '26') : (this.isDark ? '#292C33' : '#FFFFFF'))
        }
        Text(formatRelativeTime(item.timestamp))
          .fontSize(10)
          .fontColor(this.isDark ? '#A5AAB5' : '#808792')
          .padding({ left: 4, right: 4 })
      }
      .alignItems(item.senderId === (UserStore.current?.mid ?? 0) ? HorizontalAlign.End : HorizontalAlign.Start)
      .constraintSize({ maxWidth: this.bubbleWidth() })
      if (item.senderId === (UserStore.current?.mid ?? 0)) this.MessageAvatar(true)
      else Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 8, bottom: 8 })
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
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }

  @Builder
  MsgTabBar() {
    Row() {
      ForEach(this.tabs, (label: string, index: number) => {
        Column({ space: 4 }) {
          Text(label)
            .fontSize(15)
            .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.activeTab === index ? this.accent : (this.isDark ? '#C8C8CC' : '#61666D'))
          Column()
            .width(20)
            .height(3)
            .borderRadius(2)
            .backgroundColor(this.activeTab === index ? this.accent : '#00000000')
        }
        .layoutWeight(1)
        .padding({ top: 10, bottom: 6 })
        .animation({ duration: 180, curve: Curve.EaseOut })
        .onClick(() => {
          // 首次切到该 Tab 才挂载对应列表组件（aboutToAppear 里发起首屏请求并清零角标）。
          this.tabMounted[index] = true;
          this.activeTab = index;
        })
      }, (label: string) => label)
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333333' : '#EEEEEE' })
  }

  @Builder
  SessionListContent() {
    if (this.sessionCount === 0) {
      LoadingView({ skeleton: 'sessions', loading: this.sessionLoading, empty: !this.sessionLoading && this.sessionError.length === 0,
        emptyText: '暂无私信会话', errorText: this.sessionError,
        onRetry: () => this.loadSessions(true).catch(() => {
        }) })
    } else {
      List() {
        LazyForEach(this.sessionsSource, (item: MessageSessionItem) => {
          ListItem() { this.SessionRow(item) }
        }, (item: MessageSessionItem) => String(item.talkerId))
        ListItem() {
          LoadMoreFooter({
            loading: this.sessionLoading,
            hasMore: this.sessionHasMore,
            moreText: '',
            endText: '',
            fixedHeight: this.sessionLoading ? 48 : 1,
          })
        }
      }
      .layoutWeight(1)
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.Off)
      .cachedCount(5)
      .onReachEnd(() => {
        this.loadSessions(false).catch(() => {
        });
      })
    }
  }

  @Builder
  MessageHomePage() {
    Column() {
      PageHeader({
        title: '消息中心',
        headerHeight: 50,
        padLeft: 4,
        backWidth: 40,
        onBack: () => AppNavStack.pop(),
        trailing: (): void => {
          this.ReadAllButton()
        },
      })
      this.MsgTabBar()
      // 已挂载的 Tab 保持存活（visibility 切换），保住列表数据与滚动位置。
      Stack() {
        Column() {
          this.SessionListContent()
        }
        .width('100%')
        .height('100%')
        .visibility(this.activeTab === 0 ? Visibility.Visible : Visibility.Hidden)
        if (this.tabMounted[1]) {
          MsgNotifyList({ tab: 'reply' })
            .visibility(this.activeTab === 1 ? Visibility.Visible : Visibility.Hidden)
        }
        if (this.tabMounted[2]) {
          MsgNotifyList({ tab: 'at' })
            .visibility(this.activeTab === 2 ? Visibility.Visible : Visibility.Hidden)
        }
        if (this.tabMounted[3]) {
          MsgNotifyList({ tab: 'like' })
            .visibility(this.activeTab === 3 ? Visibility.Visible : Visibility.Hidden)
        }
        if (this.tabMounted[4]) {
          MsgNotifyList({ tab: 'sys' })
            .visibility(this.activeTab === 4 ? Visibility.Visible : Visibility.Hidden)
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }

  /** 消息首页头栏「全部已读」：服务端确认通知分类和当前已加载的私信会话。 */
  @Builder
  ReadAllButton() {
    Text(this.readAllLoading ? '处理中…' : '全部已读')
      .fontSize(12)
      .fontColor(this.readAllLoading ? '#73767A' : '#B0B3B8')
      .padding({ left: 18, right: 2, top: 8, bottom: 8 })
      .onClick(() => {
        this.markAllRead().catch(() => {
        });
      })
  }

  /** 私信聊天页右上「举报」入口（对方用户）。 */
  @Builder
  ReportUserButton() {
    Text('举报')
      .fontSize(12)
      .fontColor('#B0B3B8')
      .padding({ left: 18, right: 2, top: 8, bottom: 8 })
      .priorityGesture(TapGesture().onAction(() => this.reportCurrentUser()))
  }

  /** 举报当前私信对象：原因选择 → 提交。 */
  private reportCurrentUser(): void {
    if (this.current.talkerId <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: '会话信息不完整' });
      return;
    }
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '举报用户',
        message: '举报 ' + this.current.name + ' 后由 B 站人工审核，请如实选择原因。',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '垃圾广告', color: '#18191C' },
          { text: '人身攻击', color: '#18191C' },
          { text: '骚扰', color: '#18191C' },
          { text: '其他', color: '#18191C' },
        ],
      }).then((dialogResult) => {
        const pick: number = Number(dialogResult.index);
        const reasons: Array<Array<string>> = [['', ''], ['6', '垃圾广告'], ['8', '人身攻击'], ['7', '骚扰'], ['9', '其他']];
        if (pick <= 0 || pick >= reasons.length) return;
        MessageApi.reportImMessage(this.current.talkerId,
          Number(reasons[pick][0]), reasons[pick][1])
          .then((r: ActionResult) => {
            this.getUIContext().getPromptAction().showToast({ message: r.ok ? '已提交举报，感谢反馈' : r.message });
          })
          .catch(() => {
            this.getUIContext().getPromptAction().showToast({ message: '举报失败，请稍后重试' });
          });
      });
    } catch (e) {
      // 弹窗失败不阻塞。
    }
  }

  @Builder
  MessageThreadPage() {
    Column() {
      PageHeader({
        title: this.current.name,
        headerHeight: 50,
        padLeft: 4,
        backWidth: 40,
        onBack: () => this.goBack(),
        // PageHeader 现有两个 @BuilderParam（middle/trailing），尾随闭包不再可用，需显式传 middle。
        middle: (): void => {
          this.SessionAvatar()
        },
        trailing: (): void => {
          this.ReportUserButton()
        },
      })
      List({ scroller: this.messageScroller }) {
        ListItem() {
          Text(this.messageLoading ? '加载中…' : (this.messageError.length > 0 ? this.messageError + ' · 点此重试' :
            (this.hasMore ? '加载更早消息' : '没有更早消息了')))
            .fontSize(11).fontColor(this.messageError.length > 0 || this.hasMore ? this.accent : '#9499A0')
            .width('100%').textAlign(TextAlign.Center).padding(12)
            .onClick(() => {
              if (!this.messageLoading && (this.messageError.length > 0 || this.hasMore)) {
                this.loadMessages(this.messages.length === 0).catch(() => {
                });
              }
            })
        }
        ForEach(this.messages, (item: PrivateMessageItem) => {
          ListItem() { this.MessageBubble(item) }
        }, (item: PrivateMessageItem) => String(item.seqno))
      }
      .layoutWeight(1)
      .padding({ left: 10, right: 10 })
      .scrollBar(BarState.Off)
      .onScrollIndex((start: number) => this.firstVisibleMessage = start)
      .contentEndOffset(12)
      .clip(true)
      this.Composer()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#18191C' : '#F4F5F7')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        this.MessageHomePage()
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.threadOpen ? '-24%' : '0%' })
      .opacity(this.threadOpen ? 0.88 : 1)
      .hitTestBehavior(this.threadOpen ? HitTestMode.None : HitTestMode.Default)
      .animation({ duration: MotionTokens.navigation, curve: Curve.EaseOut })

      Stack({ alignContent: Alignment.TopStart }) {
        this.MessageThreadPage()
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.threadOpen ? '0%' : '100%' })
      .zIndex(1)
      .hitTestBehavior(this.threadOpen ? HitTestMode.Default : HitTestMode.None)
      .shadow({ radius: 12, color: '#26000000', offsetX: -5, offsetY: 0 })
      .animation({ duration: MotionTokens.navigation, curve: Curve.EaseOut })
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .padding({ top: Immersive.statusBarHeight(), bottom: Immersive.bottomInset() })
    .onAreaChange((previous: Area, current: Area) => {
      const width: number = Number(current.width);
      if (width > 0) this.viewportWidth = width;
    })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }
}
