/** 直播间：观看直播、切换画质、实时弹幕/表情与 SC。 */

import { ActionResult } from '../api/BiliApi';
import { AppNavStack, LiveRoomParam, NAV_LOGIN } from '../common/AppRouter';
import { BasicDataSource } from '../common/BasicDataSource';
import { Immersive } from '../common/Immersive';
import { LiveChatBuffer, LiveChatOutput } from '../components/live/LiveChatBuffer';
import { LiveRoomSession, LiveRoomState } from '../components/live/LiveRoomSession';
import { AuthSession } from '../services/auth/AuthSession';
import { MotionTokens } from '../common/MotionTokens';
import { biliImageThumbnail } from '../common/ImageUrl';
import { LiveSuperChatShelf } from '../components/live/LiveSuperChatShelf';
import { LivePlayerFeed, LivePlayerView } from '../components/live/LivePlayerView';
import { StaticLiveImage } from '../components/live/StaticLiveImage';
import { BackButton, BackButtonVariant } from '../components/BackButton';
import { LiveChatMessage, LiveEmoteItem, LiveEmotePackage, LivePlayInfo, LiveRoomInfo } from '../model/LiveModels';
import { UserStore } from '../services/auth/UserStore';
import { LiveApi } from '../api/LiveApi';
import { colorHex } from '../components/player/PlayerDanmakuSupport';

/** 播放器占位封面：满屏宽单元格（~360vp）按 VideoCard 同款 ~5 倍密度出图，避免整图解码。 */
const PLAYER_COVER_RENDER_WIDTH: number = 1800;

@Component
export struct LiveRoomPage {
  @StorageProp(MotionTokens.KEY_REDUCE_MOTION) reduceMotion: boolean = false;
  param: LiveRoomParam = { roomId: 0, uid: 0, title: '', uname: '', face: '', cover: '' };
  @State roomInfo: LiveRoomInfo = new LiveRoomInfo();
  @State playInfo: LivePlayInfo = new LivePlayInfo();
  // 播放器消息走 liveFeed 直通道（保持时间正序，挂载时建立增量基线）；不再用 @State 驱动播放器 @Prop 深拷贝。
  private chatScroller: Scroller = new Scroller();
  /** 用户是否停留在弹幕列表底部附近（在底部新消息才自动跟滚）。 */
  private chatAtBottom: boolean = true;
  @State superChats: Array<LiveChatMessage> = [];
  @State loading: boolean = true;
  @State qualityLoading: boolean = false;
  @State refreshing: boolean = false;
  @State draft: string = '';
  @State sending: boolean = false;
  @State emotePanelOpen: boolean = false;
  @State emoteLoading: boolean = false;
  @State emotePackages: Array<LiveEmotePackage> = [];
  @State emotePackageIndex: number = 0;
  @State connected: boolean = false;
  /** 弹幕连接自动重连放弃后为 true：徽标改为「点击重连」，恢复由用户触发。 */
  @State danmakuGaveUp: boolean = false;
  @State fullscreen: boolean = false;
  @State chatTab: number = 0;
  @State errorText: string = '';
  @State playerHeight: number = 247.5;
  @State roomHeaderHeight: number = 69;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  /** 播放器数据直通道：聊天合帧批次/SC 合并结果直呼播放器与 SC 浮层，替代 @Prop 数组深拷贝。 */
  private liveFeed: LivePlayerFeed = new LivePlayerFeed();
  private chatOutput: LiveChatOutput = {
    resetMessages: (messages: Array<LiveChatMessage>) => { this.liveFeed.resetMessages(messages); },
    publishMessages: (messages: Array<LiveChatMessage>) => { this.liveFeed.publishMessages(messages); },
    publishSuperChats: (messages: Array<LiveChatMessage>) => { this.liveFeed.publishSuperChats(messages); },
  };
  private chat: LiveChatBuffer = new LiveChatBuffer(this.chatOutput, (baseline: boolean) => {
    if (baseline) this.chatAtBottom = true;
    if (this.chatAtBottom) this.scrollChatToEnd(baseline);
  }, (messages: Array<LiveChatMessage>) => { this.superChats = messages; });
  private chatSource: BasicDataSource<LiveChatMessage> = this.chat.source;
  private session: LiveRoomSession = new LiveRoomSession(this.chat, (state: LiveRoomState) => {
    this.roomInfo = state.info;
    this.playInfo = state.play;
    this.loading = state.loading;
    this.refreshing = state.refreshing;
    this.qualityLoading = state.qualityLoading;
    this.connected = state.connected;
    this.danmakuGaveUp = state.gaveUp;
    this.errorText = state.error;
  }, (message: string) => {
    if (!this.destroyed) this.getUIContext().getPromptAction().showToast({ message: message });
  });
  private destroyed: boolean = false;
  private lifecycleGeneration: number = 0;
  private sendRequestId: number = 0;
  private emoteRequestId: number = 0;
  @StorageProp('loginVersion') @Watch('onAccountChanged') loginVersion: number = 0;

  aboutToAppear(): void {
    this.destroyed = false;
    Immersive.setKeepScreenOn(true);
    this.openSession();
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.lifecycleGeneration++;
    this.sendRequestId++;
    this.emoteRequestId++;
    Immersive.setKeepScreenOn(false);
    this.session.dispose();
  }

  onAccountChanged(): void {
    if (!this.destroyed) this.openSession();
  }

  private openSession(): void {
    this.lifecycleGeneration++;
    this.sendRequestId++;
    this.emoteRequestId++;
    this.sending = false;
    this.emoteLoading = false;
    this.emotePackages = [];
    this.emotePackageIndex = 0;
    this.session.activate(this.param);
    this.loadRoom().catch(() => {});
    this.loadEmoticons().catch(() => {});
  }

  async loadRoom(): Promise<void> { await this.session.load(); }

  async changeQuality(qn: number): Promise<void> { await this.session.changeQuality(qn); }

  /** 同步到直播最新状态：同时失效表单与旧列表的延迟 UI 回调。 */
  async syncLive(): Promise<void> {
    if (this.refreshing || this.loading || this.destroyed) return;
    this.lifecycleGeneration++;
    await this.session.sync();
  }

  async loadEmoticons(): Promise<void> {
    if (this.destroyed || this.emoteLoading || this.emotePackages.length > 0) return;
    const generation: number = this.lifecycleGeneration;
    const account: number = AuthSession.version;
    const roomId: number = this.param.roomId;
    const request: number = ++this.emoteRequestId;
    this.emoteLoading = true;
    try {
      const packages: Array<LiveEmotePackage> = await LiveApi.getLiveEmoticons(roomId);
      if (!this.destroyed && generation === this.lifecycleGeneration && account === AuthSession.version &&
        roomId === this.param.roomId && request === this.emoteRequestId) this.emotePackages = packages;
    } finally {
      if (!this.destroyed && request === this.emoteRequestId) this.emoteLoading = false;
    }
  }

  private ensureLogin(): boolean {
    if (UserStore.isLogin) return true;
    this.getUIContext().getPromptAction().showToast({ message: '请先登录后发送直播弹幕' });
    AppNavStack.pushPathByName(NAV_LOGIN, null);
    return false;
  }

  async sendDanmaku(emote: LiveEmoteItem | null = null): Promise<void> {
    const submittedDraft: string = this.draft;
    const content: string = submittedDraft.trim();
    if (this.destroyed || this.sending || !this.ensureLogin() || (emote === null && content.length === 0)) return;
    const generation: number = this.lifecycleGeneration;
    const roomId: number = this.param.roomId;
    const account: number = AuthSession.version;
    const requestId: number = ++this.sendRequestId;
    this.sending = true;
    try {
      const result: ActionResult = await LiveApi.sendLiveDanmaku(roomId, content, emote);
      if (this.destroyed || generation !== this.lifecycleGeneration ||
        roomId !== this.param.roomId || requestId !== this.sendRequestId || account !== AuthSession.version) return;
      if (!result.ok) {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
        return;
      }
      const local: LiveChatMessage = new LiveChatMessage();
      local.id = 'local_' + String(Date.now()) + '_' + String(requestId);
      local.uname = UserStore.current?.uname ?? '我';
      local.text = emote === null ? content : (emote.emoji.length > 0 ? emote.emoji : emote.unique);
      if (emote !== null) local.emotes.push(emote);
      this.chatAtBottom = true;
      this.chat.appendLocal(local);
      if (this.draft === submittedDraft) {
        this.draft = '';
        this.emotePanelOpen = false;
      }
      this.getUIContext().getPromptAction().showToast({ message: '弹幕发送成功' });
    } catch (e) {
      if (this.destroyed || generation !== this.lifecycleGeneration ||
        roomId !== this.param.roomId || requestId !== this.sendRequestId || account !== AuthSession.version) return;
      this.getUIContext().getPromptAction().showToast({ message: '弹幕发送失败，请检查网络' });
    } finally {
      if (!this.destroyed && requestId === this.sendRequestId) this.sending = false;
    }
  }

  /** 列表贴底；首屏需跨过视频/顶栏和历史消息的多轮布局。 */
  private scrollChatToEnd(settleLayout: boolean = false): void {
    const generation: number = this.lifecycleGeneration;
    const delays: Array<number> = settleLayout ? [80, 220, 500] : [40, 140];
    for (let i: number = 0; i < delays.length; i++) {
      setTimeout(() => {
        // 布局等待期间可能上滑、离开或同步直播；只跟随当前页面仍贴底的用户。
        if (this.destroyed || generation !== this.lifecycleGeneration ||
          !this.chatAtBottom || this.chatSource.totalCount() === 0) return;
        this.chatScroller.scrollToIndex(this.chatSource.totalCount() - 1, false, ScrollAlign.END);
        this.chatScroller.scrollEdge(Edge.End);
      }, delays[i]);
    }
  }

  /** 全屏切换：播放器节点的尺寸/边距在同一动画上下文过渡，绑定 fullscreen 的布局一起平滑回流。 */
  private animateFullscreenChange(value: boolean): void {
    if (this.fullscreen === value || this.destroyed) return;
    this.getUIContext().animateTo({
      duration: MotionTokens.duration(MotionTokens.navigation, this.reduceMotion),
      curve: Curve.EaseOut,
    }, () => {
      this.fullscreen = value;
    });
  }

  @Builder
  RoomHeader() {
    // 对齐官方直播间顶栏：头像 + 名字/直播状态，右侧人气；标题交由全屏页头呈现。
    Row({ space: 10 }) {
      Image(this.roomInfo.face.length > 0 ? this.roomInfo.face : $r('app.media.placeholder_avatar_noface'))
        .width(46).height(46).borderRadius(23).objectFit(ImageFit.Cover)
      Column({ space: 4 }) {
        Text(this.roomInfo.uname.length > 0 ? this.roomInfo.uname : this.param.uname)
          .fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.isDark ? '#F1F2F3' : '#18191C').maxLines(1)
        Row({ space: 6 }) {
          Circle().width(6).height(6).fill(this.connected ? '#45D483' : '#9499A0')
          Text(this.connected ? '直播中' : '连接中')
            .fontSize(10).fontColor(this.isDark ? '#8A8A8E' : '#9499A0')
          if (this.roomInfo.areaName.length > 0) {
            Text(this.roomInfo.areaName).fontSize(10).fontColor(this.accent)
          }
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Row({ space: 8 }) {
        Text(this.roomInfo.watched)
          .fontSize(11).fontColor(this.isDark ? '#8A8A8E' : '#9499A0')
        Stack({ alignContent: Alignment.Center }) {
          if (this.refreshing) {
            LoadingProgress().width(17).height(17).color(this.accent)
          } else {
            Image($r('app.media.ic_refresh'))
              .width(18).height(18).fillColor(this.isDark ? '#D5D7DB' : '#61666D')
              .renderMode(ImageRenderMode.Template)
          }
        }
        .width(34).height(34).borderRadius(17)
        .backgroundColor(this.isDark ? '#25262B' : '#EEF0F2')
        .enabled(!this.refreshing && !this.loading)
        .onClick(() => this.syncLive().catch(() => {
        }))
      }.alignItems(VerticalAlign.Center)
    }
    .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 11 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ChatTabs() {
    Row({ space: 18 }) {
      Text('弹幕')
        .fontSize(14).fontWeight(this.chatTab === 0 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.chatTab === 0 ? this.accent : (this.isDark ? '#9A9A9E' : '#777B82'))
        .onClick(() => this.chatTab = 0)
      Text('醒目留言' + (this.superChats.length > 0 ? ' ' + String(this.superChats.length) : ''))
        .fontSize(14).fontWeight(this.chatTab === 1 ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.chatTab === 1 ? this.accent : (this.isDark ? '#9A9A9E' : '#777B82'))
        .onClick(() => this.chatTab = 1)
      Blank()
      Text(this.connected ? '实时' : (this.danmakuGaveUp ? '点击重连' : '重连中'))
        .fontSize(10).fontColor(this.connected ? '#45D483' : (this.isDark ? '#77777C' : '#A0A3A8'))
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .borderRadius(9).backgroundColor(this.isDark ? '#26272C' : '#EEF0F2')
        .onClick(() => {
          if (this.danmakuGaveUp && !this.connected) {
            this.session.manualReconnect();
          }
        })
    }
    .width('100%').height(42).padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
  }

  /** 去掉消息文本里的表情占位符，避免图片和 [xx表情] 文本同时显示。 */
  private cleanEmoteText(msg: LiveChatMessage): string {
    return LiveChatMessage.textWithoutEmotes(msg);
  }

  /** 官方样式弹幕行：粉丝团牌子 + 蓝色「名字:」+ 白色内容（表情消息内联图片）。 */
  @Builder
  ChatBadgeRow(msg: LiveChatMessage) {
    Row({ space: 6 }) {
      if (msg.medalName.length > 0) {
        Text(msg.medalName + ' ' + String(msg.medalLevel))
          .fontSize(9).fontColor('#FFFFFF')
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .backgroundColor(msg.medalColor > 0 ? colorHex(msg.medalColor) : '#5B7EA6')
          .borderRadius(4)
      }
      if (msg.emotes.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, alignItems: ItemAlign.Center }) {
          Text((msg.uname.length > 0 ? msg.uname : '观众') + ': ')
            .fontSize(13).fontColor('#7EB6E8')
          if (this.cleanEmoteText(msg).length > 0) {
            Text(this.cleanEmoteText(msg))
              .fontSize(13).fontColor(this.isDark ? '#F1F2F3' : '#303236').maxLines(3)
          }
          ForEach(msg.emotes, (emote: LiveEmoteItem) => {
            StaticLiveImage({
              url: emote.url,
              imageWidth: emote.unique.startsWith('official_') ? 18 : 22,
              imageHeight: emote.unique.startsWith('official_') ? 18 : 22,
            })
          }, (emote: LiveEmoteItem) => emote.unique + emote.url)
        }
        .layoutWeight(1)
      } else {
        Text() {
          Span((msg.uname.length > 0 ? msg.uname : '观众') + ': ')
            .fontSize(13).fontColor('#7EB6E8')
          Span(msg.text)
            .fontSize(13).fontColor(this.isDark ? '#F1F2F3' : '#303236')
        }
        .layoutWeight(1).maxLines(3)
      }
    }
    .width('100%').padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DanmakuList() {
    List({ space: 8, scroller: this.chatScroller }) {
      LazyForEach(this.chatSource, (msg: LiveChatMessage) => {
        ListItem() {
          this.ChatBadgeRow(msg)
        }
      }, (msg: LiveChatMessage) => msg.id)
    }
    .width('100%').layoutWeight(1).scrollBar(BarState.Off)
    .cachedCount(4)
    .contentEndOffset(Immersive.bottomInset() + 18)
    .onScrollIndex((first: number, last: number) => {
      this.chatAtBottom = last >= this.chatSource.totalCount() - 2;
    })
  }

  @Builder
  LiveEmotePanel() {
    Column() {
      if (this.emoteLoading) {
        Row() { LoadingProgress().width(24).height(24).color(this.accent) }
          .width('100%').height(170).justifyContent(FlexAlign.Center)
      } else if (this.emotePackages.length === 0) {
        Text('暂无可发送的直播表情').fontSize(12).fontColor('#9499A0')
          .width('100%').height(170).textAlign(TextAlign.Center)
      } else {
        Grid() {
          ForEach(this.emotePackages[this.emotePackageIndex].emotes, (emote: LiveEmoteItem) => {
            GridItem() {
              Column({ space: 2 }) {
                StaticLiveImage({ url: emote.url, imageWidth: 42, imageHeight: 42 })
                if (emote.emoji.length > 0) {
                  Text(emote.emoji.replace(/^\[|\]$/g, '')).fontSize(9).fontColor('#9499A0').maxLines(1)
                }
              }
              .width('100%').height('100%').justifyContent(FlexAlign.Center)
              .onClick(() => this.sendDanmaku(emote))
            }
          }, (emote: LiveEmoteItem) => emote.unique)
        }
        .width('100%').height(170).columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
        .rowsGap(4).columnsGap(2).padding({ left: 8, right: 8, top: 6 })
        .scrollBar(BarState.Off)
        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.emotePackages, (pkg: LiveEmotePackage, index: number) => {
              Row() {
                if (pkg.icon.length > 0) {
                  StaticLiveImage({ url: pkg.icon, imageWidth: 28, imageHeight: 28 })
                }
                else Text(String(index + 1)).fontSize(11).fontColor('#9499A0')
              }
              .height(36).padding({ left: 9, right: 9 }).borderRadius(8)
              .backgroundColor(index === this.emotePackageIndex ? '#22FB7299' : '#00000000')
              .onClick(() => this.emotePackageIndex = index)
            }, (pkg: LiveEmotePackage, index: number) => String(pkg.packageType) + String(index))
          }
          .padding({ left: 8, right: 8 })
        }
        .width('100%').height(42).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      }
    }
    .width('100%').height(212)
    .backgroundColor(this.isDark ? '#232428' : '#F5F6F8')
    .border({ width: { top: 0.5 }, color: this.isDark ? '#333333' : '#E7E9EC' })
  }

  @Builder
  DanmakuComposer() {
    Column() {
      Row({ space: 7 }) {
        TextInput({ placeholder: this.sending ? '发送中…' : '发个弹幕呗~', text: this.draft })
          .height(38).layoutWeight(1).fontSize(13)
          .fontColor(this.isDark ? '#FFFFFF' : '#18191C').placeholderColor('#9499A0')
          .backgroundColor(this.isDark ? '#292A2E' : '#EEF0F2').borderRadius(19)
          .padding({ left: 14, right: 10 }).enterKeyType(EnterKeyType.Send)
          .onChange((value: string) => this.draft = value)
          .onSubmit(() => this.sendDanmaku())
        Stack({ alignContent: Alignment.Center }) {
          Image(this.emotePanelOpen ? $r('app.media.ic_keyboard') : $r('app.media.ic_emoji'))
            .width(23).height(23).renderMode(ImageRenderMode.Template)
            .fillColor(this.emotePanelOpen ? this.accent : '#9499A0')
        }
        .width(38).height(38).borderRadius(19)
        .onClick(() => {
          if (!this.ensureLogin()) return;
          this.emotePanelOpen = !this.emotePanelOpen;
          if (this.emotePanelOpen) this.loadEmoticons().catch(() => {});
        })
        Button('发送').height(36).fontSize(12).fontColor('#FFFFFF')
          .backgroundColor(this.accent).borderRadius(18)
          .enabled(!this.sending && this.draft.trim().length > 0)
          .opacity(!this.sending && this.draft.trim().length > 0 ? 1 : 0.45)
          .onClick(() => this.sendDanmaku())
      }
      .width('100%').padding({ left: 10, right: 10, top: 7, bottom: 7 })
      if (this.emotePanelOpen) this.LiveEmotePanel()
    }
    .width('100%').padding({ bottom: Immersive.bottomInset() })
    .backgroundColor(this.isDark ? '#18191C' : '#FFFFFF')
  }

  @Builder
  SuperChatList() {
    if (this.superChats.length === 0) {
      Column({ space: 8 }) {
        Text('暂时没有醒目留言').fontSize(14).fontColor(this.isDark ? '#AAAAB0' : '#777B82')
        Text('这里会显示直播间当前有效的 SC').fontSize(11).fontColor(this.isDark ? '#77777C' : '#A0A3A8')
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else {
      List({ space: 10 }) {
        ForEach(this.superChats, (msg: LiveChatMessage) => {
          ListItem() {
            Column({ space: 7 }) {
              Row({ space: 8 }) {
                if (msg.face.length > 0) {
                  Image(msg.face).width(28).height(28).borderRadius(14).objectFit(ImageFit.Cover)
                }
                Text(msg.uname).fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').layoutWeight(1)
                Text('¥' + String(msg.price)).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              }.width('100%')
              Text(msg.text).width('100%').fontSize(14).fontColor('#FFFFFF')
            }
            .width('100%').padding(12).borderRadius(12)
            .backgroundColor(msg.backgroundColor)
          }
        }, (msg: LiveChatMessage) => msg.id)
      }
      .width('100%').layoutWeight(1).padding({ left: 12, right: 12 })
      .scrollBar(BarState.Off).contentEndOffset(Immersive.bottomInset() + 18)
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 页面内容常驻；全屏只改变同一个播放器节点的尺寸和层级，避免重建 AVPlayer/弹幕连接。
      Column() {
        Column()
          .width('100%').height(Immersive.statusBarHeight()).backgroundColor('#000000')
        this.RoomHeader()
        Divider().strokeWidth(0.5).color(this.isDark ? '#24252A' : '#ECEEF0')
        Stack({ alignContent: Alignment.Center }) {
          if (this.playInfo.url.length === 0) {
            if (this.roomInfo.cover.length > 0) {
              Image(biliImageThumbnail(this.roomInfo.cover, PLAYER_COVER_RENDER_WIDTH))
                .width('100%').height('100%').objectFit(ImageFit.Cover).opacity(0.45)
                .alt($r('app.media.placeholder_cover'))
            }
            if (this.loading) {
              LoadingProgress().width(38).height(38).color('#FFFFFF')
            } else {
              Column({ space: 12 }) {
                Text(this.errorText).fontSize(14).fontColor('#FFFFFF').textAlign(TextAlign.Center)
                Button('重新加载').height(36).fontSize(12).fontColor('#FFFFFF')
                  .backgroundColor('#553D424A').borderRadius(18)
                  .onClick(() => this.loadRoom())
              }.padding(20)
            }
          }
        }
        .width('100%').aspectRatio(16 / 9).backgroundColor('#000000')
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const height: number = Number(newValue.height);
          if (height > 0) this.playerHeight = height;
        })
        this.ChatTabs()
        if (this.chatTab === 0) {
          if (this.superChats.length > 0) {
            LiveSuperChatShelf({ feed: this.liveFeed.superChatFeed })
          }
          this.DanmakuList()
          this.DanmakuComposer()
        } else {
          this.SuperChatList()
        }
      }
      .width('100%').height('100%')
      .backgroundColor(this.isDark ? '#18191C' : '#F7F8FA')

      if (this.playInfo.url.length > 0) {
        LivePlayerView({
          playInfo: this.playInfo, feed: this.liveFeed,
          retrying: this.refreshing,
          onRetry: () => this.syncLive(),
          title: this.roomInfo.title, uname: this.roomInfo.uname,
          cover: biliImageThumbnail(this.roomInfo.cover, PLAYER_COVER_RENDER_WIDTH),
          onQualityChange: (qn: number) => this.changeQuality(qn),
          onFullscreenChange: (value: boolean) => this.animateFullscreenChange(value),
        })
        .width('100%')
        .height(this.fullscreen ? '100%' : this.playerHeight)
        .margin({ top: this.fullscreen ? 0 : Immersive.statusBarHeight() + this.roomHeaderHeight + 0.5 })
        .zIndex(this.fullscreen ? 10 : 2)
      }
      if (!this.fullscreen) {
        BackButton({ variant: BackButtonVariant.DARK })
          .margin({ left: 10, top: Immersive.statusBarHeight() + this.roomHeaderHeight + 8 })
          .zIndex(3)
      }
      if (this.qualityLoading) {
        Row({ space: 7 }) {
          LoadingProgress().width(16).height(16).color('#FFFFFF')
          Text('正在切换画质').fontSize(12).fontColor('#FFFFFF')
        }
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(18).backgroundColor('#CC202124').align(Alignment.Center).zIndex(12)
      }
    }
    .width('100%').height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
