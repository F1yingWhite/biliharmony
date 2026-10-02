import { MotionTokens } from '../common/MotionTokens';
/** B 站消息中心：私信会话/聊天 + 回复我的/@我/收到的赞/系统通知 五个分类 Tab。 */
import { AppTheme } from '../common/AppTheme';
import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { Immersive } from '../common/Immersive';
import { AppNavStack, HERO_NAV_TRANSITION_ACTIVE_KEY, HERO_NAV_TRANSITION_DURATION_KEY,
  ImageViewerParam, ImageViewerSrcRect, NAV_IMAGE_VIEWER, NAV_LOGIN, NAV_VIDEO_DETAIL,
  VideoDetailParam, setHeroBgSnapshot } from '../common/AppRouter';
import { MessageSessionItem, PrivateMessageItem } from '../model/Models';
import { UserStore } from '../services/auth/UserStore';
import { MsgUnreadStore } from '../services/message/MsgUnreadStore';
import { colorWithAlpha, formatRelativeTime } from '../common/Utils';
import { LoadingView } from '../components/LoadingView';
import { LoadMoreFooter } from '../components/LoadMoreFooter';
import { MsgNotifyList } from '../components/MsgNotifyList';
import { PageHeader } from '../components/PageHeader';
import { biliImageOriginal, biliImageThumbnail } from '../common/ImageUrl';

import { SessionListController } from '../components/message/SessionListController';
import { PrivateChatSession } from '../components/message/PrivateChatSession';
import { SessionListState, PrivateChatState, SessionActionSnapshot, ChatActionSnapshot,
  ChatScrollRequest } from '../components/message/MessageState';
import { privateMessageIdentity, sessionRowIdentity } from '../components/message/MessageIdentity';

@Component
export struct MessagesPage {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  @State sessions: SessionListState = new SessionListState();
  @State chat: PrivateChatState = new PrivateChatState();
  private listController: SessionListController = new SessionListController(
    (state: SessionListState) => this.sessions = state,
    (message: string) => this.showToast(message),
    (talkerId: number, cursor: string) => this.chatController.confirmRead(talkerId, cursor));
  private chatController: PrivateChatSession = new PrivateChatSession(
    (state: PrivateChatState) => this.chat = state,
    (message: string) => this.showToast(message),
    (request: ChatScrollRequest) => this.scheduleMessageScroll(request),
    (talkerId: number, cursor: string) => this.listController.acknowledge(talkerId, cursor));
  @State viewportWidth: number = 400;
  private messageScroller: Scroller = new Scroller();
  private firstVisibleMessage: number = 0;
  private scrollTimer: number = -1;
  private active: boolean = false;
  @State activeTab: number = 0;
  @StorageProp('messageThreadOpen') @Watch('onThreadOpenChanged') threadOpen: boolean = false;
  @StorageProp('loginVersion') @Watch('onLoginChanged') loginVersion: number = 0;
  @StorageProp('accentColor') accent: string = '#FB7299';
  @StorageProp('isDarkMode') isDark: boolean = false;
  private tabs: Array<string> = ['私信', '回复', '@我', '赞', '系统'];
  @State tabMounted: Array<boolean> = [true, false, false, false, false];

  aboutToAppear(): void {
    this.active = true;
    this.activateAccount();
  }

  private activateAccount(): void {
    this.closeThread();
    this.listController.activate();
    if (!UserStore.isLogin) {
      AppNavStack.replacePathByName(NAV_LOGIN, null);
      return;
    }
    this.listController.load(true).catch(() => {});
  }

  private onLoginChanged(): void {
    if (!this.active) return;
    this.activeTab = 0;
    this.tabMounted = [true, false, false, false, false];
    this.activateAccount();
  }

  private onThreadOpenChanged(): void {
    // 系统返回键由 Index 关闭 storage；同样要使进行中的聊天请求失效。
    if (!this.threadOpen && this.chat.open) this.closeThread();
  }

  async openSession(item: MessageSessionItem): Promise<void> {
    this.cancelMessageScroll();
    this.firstVisibleMessage = 0;
    AppStorage.setOrCreate<boolean>('messageThreadOpen', true);
    await this.chatController.open(item);
    if (!this.chat.open) AppStorage.setOrCreate<boolean>('messageThreadOpen', false);
  }

  private closeThread(): void {
    this.cancelMessageScroll();
    this.chatController.close();
    AppStorage.setOrCreate<boolean>('messageThreadOpen', false);
  }

  goBack(): void {
    if (this.threadOpen) this.closeThread();
    else AppNavStack.pop();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.closeThread();
    this.listController.dispose();
    MsgUnreadStore.refresh().catch(() => {});
  }

  private cancelMessageScroll(): void {
    if (this.scrollTimer >= 0) clearTimeout(this.scrollTimer);
    this.scrollTimer = -1;
  }

  private scheduleMessageScroll(request: ChatScrollRequest): void {
    const index: number = request.latest ? -1 : this.firstVisibleMessage + request.added;
    this.cancelMessageScroll();
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      if (!this.threadOpen || !this.chatController.isCurrent(request.session)) return;
      if (index < 0) this.messageScroller.scrollToIndex(this.chatController.source.totalCount(), false, ScrollAlign.END);
      else this.messageScroller.scrollToIndex(index, false, ScrollAlign.START);
    }, 120);
  }

  private showToast(message: string): void {
    if (this.active) this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private bubbleWidth(): number {
    return Math.max(120, Math.min(280, this.viewportWidth - 96));
  }

  @Builder
  SessionAvatar() {
    if (this.chat.current.talkerId > 0 && this.chat.current.avatar.length > 0) {
      Image(this.chat.current.avatar).width(30).height(30).borderRadius(15).objectFit(ImageFit.Cover)
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
    // 长按会话：置顶/取消置顶、删除（对齐官方会话管理）
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => this.promptSessionActions(item))
    )
  }

  private promptSessionActions(item: MessageSessionItem): void {
    const action: SessionActionSnapshot | null = this.listController.captureAction(item);
    if (action === null) return;
    try {
      this.getUIContext().getPromptAction().showActionMenu({
        title: action.item.name.length > 0 ? action.item.name : '会话操作',
        buttons: [
          { text: action.item.pinned ? '取消置顶' : '置顶', color: this.isDark ? '#E6E6E6' : '#18191C' },
          { text: '删除会话', color: AppTheme.DANGER },
        ],
      }).then((result) => {
        if (!this.listController.actionCurrent(action)) return;
        const index: number = Number(result.index);
        if (index === 0) this.listController.togglePin(action).catch(() => {});
        else if (index === 1) this.showRemoveDialog(action);
      }).catch(() => {});
    } catch (error) {
      // 原生菜单不可用时保留会话。
    }
  }

  private confirmRemoveSession(item: MessageSessionItem): void {
    const action: SessionActionSnapshot | null = this.listController.captureAction(item);
    if (action !== null) this.showRemoveDialog(action);
  }

  private showRemoveDialog(action: SessionActionSnapshot): void {
    if (!this.listController.actionCurrent(action)) return;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除会话',
        message: '删除后聊天记录不再显示（对方记录不受影响）。确定删除吗？',
        buttons: [{ text: '取消', color: '#9499A0' }, { text: '删除', color: AppTheme.DANGER }],
      }).then((result) => {
        if (Number(result.index) === 1) this.listController.remove(action).catch(() => {});
      }).catch(() => {});
    } catch (error) {
      // 未确认的操作不会提交。
    }
  }

  private messageIdentity(item: PrivateMessageItem): string {
    return privateMessageIdentity(item);
  }

  private sessionRowKey(item: MessageSessionItem): string {
    return sessionRowIdentity(item);
  }

  private richMediaId(item: PrivateMessageItem): string {
    return 'private-message-media-' + this.messageIdentity(item);
  }

  private richCardId(item: PrivateMessageItem): string {
    return 'private-message-card-' + this.messageIdentity(item);
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
      if (MotionTokens.isReduced()) {
        const viewer: ImageViewerParam = { images: [biliImageOriginal(item.imageUrl)], initialIndex: 0 };
        AppNavStack.pushPathByName(NAV_IMAGE_VIEWER, viewer, false);
        return;
      }
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
    if (MotionTokens.isReduced()) {
      AppNavStack.pushPathByName(NAV_VIDEO_DETAIL, param, false);
      return;
    }
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
      (this.chat.current.avatar || $r('app.media.placeholder_avatar_noface')))
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
      TextInput({ placeholder: '发一条友善的私信', text: this.chat.draft })
        .height(38).layoutWeight(1).fontSize(14)
        .fontColor(this.isDark ? '#FFFFFF' : '#18191C')
        .placeholderColor('#9499A0')
        .backgroundColor(this.isDark ? '#292A2E' : '#F2F4F6')
        .borderRadius(19).padding({ left: 14, right: 14 })
        .onChange((value: string) => this.chatController.setDraft(value))
        .onSubmit(() => this.chatController.send())
      Button(this.chat.sending ? '发送中' : '发送')
        .height(36).fontSize(13).fontColor('#FFFFFF')
        .backgroundColor(this.accent).borderRadius(18)
        .enabled(!this.chat.sending && this.chat.draft.trim().length > 0)
        .onClick(() => this.chatController.send())
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
    if (this.sessions.count === 0) {
      LoadingView({ skeleton: 'sessions', loading: this.sessions.loading, empty: !this.sessions.loading && this.sessions.error.length === 0,
        emptyText: '暂无私信会话', errorText: this.sessions.error,
        onRetry: () => this.listController.load(true).catch(() => {
        }) })
    } else {
      List() {
        LazyForEach(this.listController.source, (item: MessageSessionItem) => {
          ListItem() { this.SessionRow(item) }
        }, (item: MessageSessionItem) => this.sessionRowKey(item))
        ListItem() {
          if (this.sessions.error.length > 0) {
            Text(this.sessions.error + ' · 点此重试')
              .fontSize(12).fontColor(this.accent).width('100%').textAlign(TextAlign.Center).padding(12)
              .onClick(() => this.listController.retry())
          } else {
            LoadMoreFooter({
              loading: this.sessions.loading,
              hasMore: this.sessions.hasMore,
              moreText: '',
              endText: '',
              fixedHeight: this.sessions.loading ? 48 : 1,
            })
          }
        }
      }
      .layoutWeight(1)
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.Off)
      .cachedCount(5)
      .onReachEnd(() => {
        if (this.sessions.error.length === 0) this.listController.load(false).catch(() => {});
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
          MsgNotifyList({ tab: 'reply', active: this.activeTab === 1 })
            .visibility(this.activeTab === 1 ? Visibility.Visible : Visibility.Hidden)
        }
        if (this.tabMounted[2]) {
          MsgNotifyList({ tab: 'at', active: this.activeTab === 2 })
            .visibility(this.activeTab === 2 ? Visibility.Visible : Visibility.Hidden)
        }
        if (this.tabMounted[3]) {
          MsgNotifyList({ tab: 'like', active: this.activeTab === 3 })
            .visibility(this.activeTab === 3 ? Visibility.Visible : Visibility.Hidden)
        }
        if (this.tabMounted[4]) {
          MsgNotifyList({ tab: 'sys', active: this.activeTab === 4 })
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
    Text(this.sessions.readAllLoading ? '处理中…' : '全部已读')
      .fontSize(12)
      .fontColor(this.sessions.readAllLoading ? '#73767A' : '#B0B3B8')
      .padding({ left: 18, right: 2, top: 8, bottom: 8 })
      .onClick(() => {
        this.listController.markAllRead().catch(() => {
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

  /** 原生对话框只收集原因；目标与账号在打开时固定。 */
  private reportCurrentUser(): void {
    const action: ChatActionSnapshot | null = this.chatController.captureAction();
    if (action === null) return;
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '举报用户',
        message: '举报 ' + action.name + ' 后由 B 站人工审核，请如实选择原因。',
        buttons: [
          { text: '取消', color: '#9499A0' },
          { text: '垃圾广告', color: '#18191C' },
          { text: '人身攻击', color: '#18191C' },
          { text: '骚扰', color: '#18191C' },
          { text: '其他', color: '#18191C' },
        ],
      }).then((result) => {
        const pick: number = Number(result.index);
        const reasons: Array<Array<string>> = [['', ''], ['6', '垃圾广告'], ['8', '人身攻击'], ['7', '骚扰'], ['9', '其他']];
        if (pick > 0 && pick < reasons.length) {
          this.chatController.report(action, Number(reasons[pick][0]), reasons[pick][1]).catch(() => {});
        }
      }).catch(() => {});
    } catch (error) {
      // 未确认的举报不会提交。
    }
  }

  @Builder
  MessageThreadPage() {
    Column() {
      PageHeader({
        title: this.chat.current.name,
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
          Text(this.chat.loading ? '加载中…' : (this.chat.error.length > 0 ? this.chat.error + ' · 点此重试' :
            (this.chat.hasMore ? '加载更早消息' : '没有更早消息了')))
            .fontSize(11).fontColor(this.chat.error.length > 0 || this.chat.hasMore ? this.accent : '#9499A0')
            .width('100%').textAlign(TextAlign.Center).padding(12)
            .onClick(() => {
              if (!this.chat.loading && (this.chat.error.length > 0 || this.chat.hasMore)) {
                this.chatController.load(this.chatController.source.totalCount() === 0).catch(() => {
                });
              }
            })
        }
        LazyForEach(this.chatController.source, (item: PrivateMessageItem) => {
          ListItem() { this.MessageBubble(item) }
        }, (item: PrivateMessageItem) => this.messageIdentity(item))
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
      .animation({ duration: MotionTokens.duration(MotionTokens.navigation, this.reduceMotion), curve: Curve.EaseOut })

      Stack({ alignContent: Alignment.TopStart }) {
        this.MessageThreadPage()
      }
      .width('100%')
      .height('100%')
      .translate({ x: this.threadOpen ? '0%' : '100%' })
      .zIndex(1)
      .hitTestBehavior(this.threadOpen ? HitTestMode.Default : HitTestMode.None)
      .shadow({ radius: 12, color: '#26000000', offsetX: -5, offsetY: 0 })
      .animation({ duration: MotionTokens.duration(MotionTokens.navigation, this.reduceMotion), curve: Curve.EaseOut })
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
