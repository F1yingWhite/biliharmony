/** 直播间：观看直播、切换画质、实时弹幕/表情与 SC。 */

import { ActionResult, BiliApi } from '../api/BiliApi';
import { AppNavStack, LiveRoomParam, NAV_LOGIN } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { LiveDanmakuClient } from '../common/LiveDanmakuClient';
import { LiveSuperChatShelf } from '../components/live/LiveSuperChatShelf';
import { LivePlayerView } from '../components/live/LivePlayerView';
import { StaticLiveImage } from '../components/live/StaticLiveImage';
import { BackButton, BackButtonVariant } from '../components/BackButton';
import { LiveChatMessage, LiveEmoteItem, LiveEmotePackage, LivePlayInfo, LiveRoomInfo } from '../model/LiveModels';
import { UserStore } from '../services/auth/UserStore';
import { LiveApi } from '../api/LiveApi';
import { colorHex } from '../components/player/PlayerDanmakuSupport';

@Component
export struct LiveRoomPage {
  param: LiveRoomParam = { roomId: 0, uid: 0, title: '', uname: '', face: '', cover: '' };
  @State roomInfo: LiveRoomInfo = new LiveRoomInfo();
  @State playInfo: LivePlayInfo = new LivePlayInfo();
  // messages 保持时间正序（LivePlayerView 弹幕浮层取尾部 N 条）；chatList 同为正序（新消息在底部，自动贴底）
  @State messages: Array<LiveChatMessage> = [];
  @State chatList: Array<LiveChatMessage> = [];
  private chatScroller: Scroller = new Scroller();
  /** 用户是否停留在弹幕列表底部附近（在底部新消息才自动跟滚）。 */
  private chatAtBottom: boolean = true;
  @State superChats: Array<LiveChatMessage> = [];
  @State loading: boolean = true;
  @State qualityLoading: boolean = false;
  @State refreshing: boolean = false;
  @State liveSyncVersion: number = 0;
  @State draft: string = '';
  @State sending: boolean = false;
  @State emotePanelOpen: boolean = false;
  @State emoteLoading: boolean = false;
  @State emotePackages: Array<LiveEmotePackage> = [];
  @State emotePackageIndex: number = 0;
  @State connected: boolean = false;
  @State fullscreen: boolean = false;
  @State chatTab: number = 0;
  @State errorText: string = '';
  @State playerHeight: number = 247.5;
  @State roomHeaderHeight: number = 69;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  private client: LiveDanmakuClient = new LiveDanmakuClient();
  // 弹幕合帧缓冲：高频消息攒 220ms 批量写入 @State，避免每条消息驱动整页重渲染
  private pendingMsgs: Array<LiveChatMessage> = [];
  private flushTimer: number = -1;
  private destroyed: boolean = false;
  private lifecycleGeneration: number = 0;
  private historyPollTimer: number = -1;
  private historyPollGeneration: number = -1;
  private lastLiveMessageAt: number = 0;
  private knownMessageIds: Set<string> = new Set<string>();

  aboutToAppear(): void {
    this.destroyed = false;
    this.lifecycleGeneration++;
    Immersive.setKeepScreenOn(true);
    this.roomInfo.roomId = this.param.roomId;
    this.roomInfo.uid = this.param.uid;
    this.roomInfo.title = this.param.title;
    this.roomInfo.uname = this.param.uname;
    this.roomInfo.face = this.param.face;
    this.roomInfo.cover = this.param.cover;
    this.client.onMessage = (message: LiveChatMessage) => this.appendMessage(message);
    this.client.onConnected = (value: boolean) => this.connected = value;
    this.loadRoom().catch(() => {
    });
    this.loadEmoticons().catch(() => {
    });
  }

  aboutToDisappear(): void {
    this.destroyed = true;
    this.lifecycleGeneration++;
    Immersive.setKeepScreenOn(false);
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.pendingMsgs = [];
    if (this.historyPollTimer >= 0) {
      clearInterval(this.historyPollTimer);
      this.historyPollTimer = -1;
    }
    this.client.close();
  }

  async loadRoom(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    this.loading = true;
    this.errorText = '';
    try {
      const info: LiveRoomInfo | null = await LiveApi.getLiveRoomInfo(this.param.roomId, this.param.uid);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      if (info !== null) this.roomInfo = info;
      const play: LivePlayInfo | null = await LiveApi.getLivePlayInfo(this.param.roomId, 10000);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      if (play === null || play.url.length === 0) {
        this.errorText = info !== null && info.liveStatus !== 1 ? '主播当前未开播' : '直播播放地址获取失败';
        return;
      }
      const history: Array<LiveChatMessage> = await LiveApi.getLiveDanmakuHistory(this.param.roomId);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      this.knownMessageIds.clear();
      for (let i: number = 0; i < history.length; i++) this.knownMessageIds.add(history[i].id);
      this.messages = history;
      this.chatList = history.slice(-200);
      this.chatAtBottom = true;
      this.scrollChatToEnd(true);
      this.lastLiveMessageAt = Date.now();
      // 先建立首屏历史基线再挂播放器，避免把历史消息一次性灌入画面轨道。
      this.playInfo = play;
      // SC 快照是独立补充，不能阻塞实时弹幕连接或把视频判定为加载失败。
      this.client.connect(this.param.roomId).catch(() => {});
      this.startHistoryFallback();
      this.refreshSuperChats(generation).catch(() => {});
    } catch (e) {
      if (!this.destroyed && generation === this.lifecycleGeneration) {
        this.errorText = '直播间加载失败，请检查网络后重试';
      }
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) this.loading = false;
    }
  }

  private async refreshSuperChats(generation: number): Promise<void> {
    const snapshot: Array<LiveChatMessage> = await LiveApi.getLiveSuperChats(this.param.roomId);
    if (this.destroyed || generation !== this.lifecycleGeneration) return;
    this.superChats = this.mergeSuperChats(this.superChats, snapshot);
  }

  async changeQuality(qn: number): Promise<void> {
    if (this.qualityLoading || this.refreshing) return;
    this.qualityLoading = true;
    const generation: number = this.lifecycleGeneration;
    try {
      const next: LivePlayInfo | null = await LiveApi.getLivePlayInfo(this.param.roomId, qn);
      if (!this.destroyed && generation === this.lifecycleGeneration && next !== null && next.url.length > 0) {
        this.playInfo = next;
      }
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) this.qualityLoading = false;
    }
  }

  /** 同步到直播最新状态：播放源、历史弹幕基线和实时连接从同一刷新边界重新建立。 */
  async syncLive(): Promise<void> {
    if (this.refreshing || this.loading || this.destroyed) return;
    this.refreshing = true;
    this.qualityLoading = false;
    const generation: number = ++this.lifecycleGeneration;
    const qn: number = this.playInfo.currentQn > 0 ? this.playInfo.currentQn : 10000;
    let synced: boolean = false;

    this.client.close();
    this.connected = false;
    this.stopHistoryFallback();
    this.clearPendingMessages();

    try {
      // 两个请求同时发出，尽量缩小播放源与弹幕快照之间的时间差。
      const playTask: Promise<LivePlayInfo | null> = LiveApi.getLivePlayInfo(this.param.roomId, qn);
      const historyTask: Promise<Array<LiveChatMessage>> = LiveApi.getLiveDanmakuHistory(this.param.roomId);
      const play: LivePlayInfo | null = await playTask;
      const history: Array<LiveChatMessage> = await historyTask;
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      if (play === null || play.url.length === 0) throw new Error('empty live url');

      this.knownMessageIds.clear();
      for (let i: number = 0; i < history.length; i++) this.knownMessageIds.add(history[i].id);
      this.messages = history;
      this.chatList = history.slice(-200);
      this.chatAtBottom = true;
      this.lastLiveMessageAt = Date.now();
      this.playInfo = play;
      this.liveSyncVersion++;
      this.errorText = '';
      this.scrollChatToEnd(true);
      synced = true;
      this.getUIContext().getPromptAction().showToast({ message: '已同步到直播最新状态' });
    } catch (e) {
      if (!this.destroyed && generation === this.lifecycleGeneration) {
        this.getUIContext().getPromptAction().showToast({ message: '同步失败，请检查网络后重试' });
      }
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) {
        // 即使刷新失败，也恢复旧播放源对应的实时弹幕连接，避免房间停在离线状态。
        this.client.connect(this.param.roomId).catch(() => {
        });
        this.lastLiveMessageAt = Date.now();
        this.startHistoryFallback();
        this.refreshing = false;
        if (!synced) this.connected = false;
      }
    }
  }

  async loadEmoticons(): Promise<void> {
    if (this.emoteLoading || this.emotePackages.length > 0) return;
    this.emoteLoading = true;
    try {
      const packages: Array<LiveEmotePackage> = await LiveApi.getLiveEmoticons(this.param.roomId);
      if (!this.destroyed) this.emotePackages = packages;
    } finally {
      if (!this.destroyed) this.emoteLoading = false;
    }
  }

  private ensureLogin(): boolean {
    if (UserStore.isLogin) return true;
    this.getUIContext().getPromptAction().showToast({ message: '请先登录后发送直播弹幕' });
    AppNavStack.pushPathByName(NAV_LOGIN, null);
    return false;
  }

  async sendDanmaku(emote: LiveEmoteItem | null = null): Promise<void> {
    const content: string = this.draft.trim();
    if (this.sending || !this.ensureLogin() || (emote === null && content.length === 0)) return;
    this.sending = true;
    try {
      const result: ActionResult = await LiveApi.sendLiveDanmaku(this.param.roomId, content, emote);
      if (!result.ok) {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
        return;
      }
      const local: LiveChatMessage = new LiveChatMessage();
      local.id = 'local_' + String(Date.now());
      local.uname = UserStore.current?.uname ?? '我';
      local.text = emote === null ? content : (emote.emoji.length > 0 ? emote.emoji : emote.unique);
      if (emote !== null) local.emotes.push(emote);
      this.knownMessageIds.add(local.id);
      this.messages = this.messages.concat([local]);
      this.chatList = this.chatList.concat([local]).slice(-200);
      this.chatAtBottom = true;
      this.scrollChatToEnd();
      this.draft = '';
      this.emotePanelOpen = false;
      this.getUIContext().getPromptAction().showToast({ message: '弹幕发送成功' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '弹幕发送失败，请检查网络' });
    } finally {
      if (!this.destroyed) this.sending = false;
    }
  }

  appendMessage(message: LiveChatMessage): void {
    if (this.destroyed) return;
    if (this.knownMessageIds.has(message.id)) return;
    this.knownMessageIds.add(message.id);
    this.lastLiveMessageAt = Date.now();
    if (message.type === 'sc') {
      this.superChats = this.mergeSuperChats([message], this.superChats);
    }
    this.pendingMsgs.push(message);
    if (this.flushTimer < 0) {
      this.flushTimer = setTimeout(() => {
        this.flushTimer = -1;
        this.flushMessages();
      }, 220);
    }
  }

  private mergeSuperChats(first: Array<LiveChatMessage>, second: Array<LiveChatMessage>): Array<LiveChatMessage> {
    const seen: Set<string> = new Set<string>();
    return first.concat(second).filter((message: LiveChatMessage): boolean => {
      if (seen.has(message.id)) return false;
      seen.add(message.id);
      return true;
    }).sort((a: LiveChatMessage, b: LiveChatMessage): number => b.timestamp - a.timestamp).slice(0, 50);
  }

  private startHistoryFallback(): void {
    this.stopHistoryFallback();
    this.historyPollTimer = setInterval(() => {
      if (this.destroyed || Date.now() - this.lastLiveMessageAt < 8000) return;
      this.pollRecentHistory().catch(() => {
      });
    }, 5000);
  }

  private stopHistoryFallback(): void {
    if (this.historyPollTimer >= 0) {
      clearInterval(this.historyPollTimer);
      this.historyPollTimer = -1;
    }
  }

  private clearPendingMessages(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.pendingMsgs = [];
  }

  /** WebSocket 安静超过 8 秒时低频补拉，只追加未见 ID，不重放进房快照。 */
  private async pollRecentHistory(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    if (this.historyPollGeneration === generation) return;
    this.historyPollGeneration = generation;
    try {
      const results: Array<Array<LiveChatMessage>> = await Promise.all([
        LiveApi.getLiveDanmakuHistory(this.param.roomId).catch(() => new Array<LiveChatMessage>()),
        LiveApi.getLiveSuperChats(this.param.roomId).catch(() => new Array<LiveChatMessage>()),
      ]);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      for (let i: number = 0; i < results[0].length; i++) {
        if (!this.knownMessageIds.has(results[0][i].id)) this.appendMessage(results[0][i]);
      }
      this.superChats = this.mergeSuperChats(this.superChats, results[1]);
    } finally {
      if (this.historyPollGeneration === generation) this.historyPollGeneration = -1;
    }
  }

  /** 合帧落盘：正序 messages 供播放器浮层；chatList 同为正序，新消息追加在底部。 */
  private flushMessages(): void {
    if (this.destroyed || this.pendingMsgs.length === 0) {
      return;
    }
    const batch: Array<LiveChatMessage> = this.pendingMsgs;
    this.pendingMsgs = [];
    const next: Array<LiveChatMessage> = this.messages.concat(batch);
    this.messages = next.length > 240 ? next.slice(next.length - 200) : next;
    this.chatList = this.chatList.concat(batch).slice(-200);
    // 用户本就在底部时才跟滚；翻上去读历史不打断。
    if (this.chatAtBottom) this.scrollChatToEnd();
  }

  /** 列表贴底；首屏需跨过视频/顶栏和历史消息的多轮布局。 */
  private scrollChatToEnd(settleLayout: boolean = false): void {
    const delays: Array<number> = settleLayout ? [80, 220, 500] : [40, 140];
    for (let i: number = 0; i < delays.length; i++) {
      setTimeout(() => {
        if (this.destroyed || this.chatList.length === 0) return;
        this.chatAtBottom = true;
        this.chatScroller.scrollToIndex(this.chatList.length - 1, false, ScrollAlign.END);
        this.chatScroller.scrollEdge(Edge.End);
      }, delays[i]);
    }
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
      Text(this.connected ? '实时' : '重连中')
        .fontSize(10).fontColor(this.connected ? '#45D483' : (this.isDark ? '#77777C' : '#A0A3A8'))
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .borderRadius(9).backgroundColor(this.isDark ? '#26272C' : '#EEF0F2')
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
      ForEach(this.chatList, (msg: LiveChatMessage) => {
        ListItem() {
          this.ChatBadgeRow(msg)
        }
      }, (msg: LiveChatMessage) => msg.id)
    }
    .width('100%').layoutWeight(1).scrollBar(BarState.Off)
    .contentEndOffset(Immersive.bottomInset() + 18)
    .onScrollIndex((first: number, last: number) => {
      this.chatAtBottom = last >= this.chatList.length - 2;
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
              Image(this.roomInfo.cover).width('100%').height('100%').objectFit(ImageFit.Cover).opacity(0.45)
            }
            if (this.loading) {
              LoadingProgress().width(38).height(38).color('#FFFFFF')
            } else {
              Text(this.errorText).fontSize(14).fontColor('#FFFFFF')
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
            LiveSuperChatShelf({ messages: this.superChats })
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
          playInfo: this.playInfo, messages: this.messages, superChats: this.superChats,
          syncVersion: this.liveSyncVersion,
          title: this.roomInfo.title, uname: this.roomInfo.uname,
          onQualityChange: (qn: number) => this.changeQuality(qn),
          onFullscreenChange: (value: boolean) => this.fullscreen = value,
        })
        .width('100%')
        .height(this.fullscreen ? '100%' : this.playerHeight)
        .margin({ top: this.fullscreen ? 0 : Immersive.statusBarHeight() + this.roomHeaderHeight + 0.5 })
        .zIndex(this.fullscreen ? 10 : 2)
      }
      if (!this.fullscreen) {
        BackButton({ variant: BackButtonVariant.DARK })
          .margin({ left: 10, top: Immersive.statusBarHeight() + this.roomHeaderHeight + 8 })
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
