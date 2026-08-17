/** 直播间：观看直播、切换画质、实时弹幕/表情与 SC。 */

import { ActionResult, BiliApi } from '../api/BiliApi';
import { AppNavStack, LiveRoomParam, NAV_LOGIN } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { LiveDanmakuClient } from '../common/LiveDanmakuClient';
import { LivePlayerView } from '../components/LivePlayerView';
import { BackButton, BackButtonVariant } from '../components/BackButton';
import { LiveChatMessage, LiveEmoteItem, LiveEmotePackage, LivePlayInfo, LiveRoomInfo } from '../model/LiveModels';
import { UserStore } from '../common/UserStore';
import { LiveApi } from '../api/LiveApi';

@Component
export struct LiveRoomPage {
  param: LiveRoomParam = { roomId: 0, uid: 0, title: '', uname: '', face: '', cover: '' };
  @State roomInfo: LiveRoomInfo = new LiveRoomInfo();
  @State playInfo: LivePlayInfo = new LivePlayInfo();
  // messages 保持时间正序（LivePlayerView 弹幕浮层取尾部 N 条）；chatList 为渲染用倒序（新消息在前）
  @State messages: Array<LiveChatMessage> = [];
  @State chatList: Array<LiveChatMessage> = [];
  @State superChats: Array<LiveChatMessage> = [];
  @State loading: boolean = true;
  @State qualityLoading: boolean = false;
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
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  private client: LiveDanmakuClient = new LiveDanmakuClient();
  // 弹幕合帧缓冲：高频消息攒 220ms 批量写入 @State，避免每条消息驱动整页重渲染
  private pendingMsgs: Array<LiveChatMessage> = [];
  private flushTimer: number = -1;
  private destroyed: boolean = false;
  private lifecycleGeneration: number = 0;
  private historyPollTimer: number = -1;
  private lastLiveMessageAt: number = 0;
  private knownMessageIds: Set<string> = new Set<string>();

  aboutToAppear(): void {
    this.destroyed = false;
    this.lifecycleGeneration++;
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
      this.chatList = history.slice().reverse().slice(0, 200);
      this.lastLiveMessageAt = Date.now();
      // 先建立首屏历史基线再挂播放器，避免把历史消息一次性灌入画面轨道。
      this.playInfo = play;
      this.superChats = await LiveApi.getLiveSuperChats(this.param.roomId);
      if (this.destroyed || generation !== this.lifecycleGeneration) return;
      this.client.connect(this.param.roomId).catch(() => {
      });
      this.startHistoryFallback();
    } catch (e) {
      if (!this.destroyed && generation === this.lifecycleGeneration) {
        this.errorText = '直播间加载失败，请检查网络后重试';
      }
    } finally {
      if (!this.destroyed && generation === this.lifecycleGeneration) this.loading = false;
    }
  }

  async changeQuality(qn: number): Promise<void> {
    if (this.qualityLoading) return;
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
      this.chatList = [local].concat(this.chatList).slice(0, 200);
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
      const nextSc: Array<LiveChatMessage> = [message].concat(this.superChats);
      this.superChats = nextSc.slice(0, 50);
    }
    this.pendingMsgs.push(message);
    if (this.flushTimer < 0) {
      this.flushTimer = setTimeout(() => {
        this.flushTimer = -1;
        this.flushMessages();
      }, 220);
    }
  }

  private startHistoryFallback(): void {
    if (this.historyPollTimer >= 0) clearInterval(this.historyPollTimer);
    this.historyPollTimer = setInterval(() => {
      if (this.destroyed || Date.now() - this.lastLiveMessageAt < 8000) return;
      this.pollRecentHistory().catch(() => {
      });
    }, 5000);
  }

  /** WebSocket 安静超过 8 秒时低频补拉，只追加未见 ID，不重放进房快照。 */
  private async pollRecentHistory(): Promise<void> {
    const history: Array<LiveChatMessage> = await LiveApi.getLiveDanmakuHistory(this.param.roomId);
    if (this.destroyed) return;
    for (let i: number = 0; i < history.length; i++) {
      if (!this.knownMessageIds.has(history[i].id)) this.appendMessage(history[i]);
    }
  }

  /** 合帧落盘：正序 messages 供播放器浮层，倒序 chatList 供弹幕列表直接渲染（不再 slice().reverse()）。 */
  private flushMessages(): void {
    if (this.destroyed || this.pendingMsgs.length === 0) {
      return;
    }
    const batch: Array<LiveChatMessage> = this.pendingMsgs;
    this.pendingMsgs = [];
    const next: Array<LiveChatMessage> = this.messages.concat(batch);
    this.messages = next.length > 240 ? next.slice(next.length - 200) : next;
    this.chatList = batch.slice().reverse().concat(this.chatList).slice(0, 200);
  }

  @Builder
  RoomHeader() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Image(this.roomInfo.face.length > 0 ? this.roomInfo.face : $r('app.media.placeholder_avatar_noface'))
          .width(42).height(42).borderRadius(21).objectFit(ImageFit.Cover)
        Column({ space: 3 }) {
          Text(this.roomInfo.uname.length > 0 ? this.roomInfo.uname : this.param.uname)
            .fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.isDark ? '#E6E6E6' : '#18191C').maxLines(1)
          Row({ space: 6 }) {
            Circle().width(7).height(7).fill(this.connected ? '#45D483' : '#9499A0')
            Text(this.connected ? '弹幕已连接' : '弹幕连接中')
              .fontSize(10).fontColor(this.isDark ? '#8A8A8E' : '#9499A0')
            if (this.roomInfo.areaName.length > 0) {
              Text(this.roomInfo.areaName).fontSize(10).fontColor(this.accent)
            }
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.roomInfo.watched)
          .fontSize(11).fontColor(this.isDark ? '#8A8A8E' : '#9499A0')
      }
      .width('100%').alignItems(VerticalAlign.Center)
      Text(this.roomInfo.title.length > 0 ? this.roomInfo.title : this.param.title)
        .width('100%').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.isDark ? '#F1F2F3' : '#18191C').maxLines(2)
    }
    .width('100%').padding({ left: 14, right: 14, top: 13, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
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
    let text: string = msg.text;
    for (let i: number = 0; i < msg.emotes.length; i++) {
      const emote: LiveEmoteItem = msg.emotes[i];
      if (emote.unique.length > 0) text = text.split(emote.unique).join('');
      if (emote.emoji.length > 0 && emote.emoji !== emote.unique) text = text.split(emote.emoji).join('');
    }
    return text.trim();
  }

  @Builder
  ChatMessageContent(msg: LiveChatMessage) {
    if (msg.emotes.length > 0) {
      Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, alignItems: ItemAlign.Center }) {
        if (this.cleanEmoteText(msg).length > 0) {
          Text(this.cleanEmoteText(msg))
            .fontSize(13).fontColor(this.isDark ? '#E1E2E3' : '#303236').maxLines(3)
        }
        ForEach(msg.emotes, (emote: LiveEmoteItem) => {
          Image(emote.url)
            .width(emote.unique.startsWith('official_') ? 18 : 22)
            .height(emote.unique.startsWith('official_') ? 18 : 22)
            .objectFit(ImageFit.Contain)
        }, (emote: LiveEmoteItem) => emote.unique + emote.url)
      }
      .layoutWeight(1)
    } else {
      Text(msg.text)
        .fontSize(13).fontColor(this.isDark ? '#E1E2E3' : '#303236')
        .layoutWeight(1).maxLines(3)
    }
  }

  @Builder
  DanmakuList() {
    List({ space: 8 }) {
      ForEach(this.chatList, (msg: LiveChatMessage) => {
        ListItem() {
          Row({ space: 7 }) {
            Text(msg.uname.length > 0 ? msg.uname : '观众')
              .fontSize(11).fontColor(this.accent).maxLines(1)
              .constraintSize({ maxWidth: 110 })
            this.ChatMessageContent(msg)
          }
          .width('100%').padding({ left: 14, right: 14 })
          .alignItems(VerticalAlign.Center)
        }
      }, (msg: LiveChatMessage) => msg.id)
    }
    .width('100%').layoutWeight(1).scrollBar(BarState.Off)
    .contentEndOffset(Immersive.bottomInset() + 18)
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
                Image(emote.url).width(42).height(42).objectFit(ImageFit.Contain)
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
                if (pkg.icon.length > 0) Image(pkg.icon).width(28).height(28).objectFit(ImageFit.Contain)
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
        TextInput({ placeholder: this.sending ? '发送中…' : '发一条直播弹幕', text: this.draft })
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
              Text(msg.text).width('100%').fontSize(14).fontColor('#FFFFFF').maxLines(5)
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
        this.RoomHeader()
        Divider().strokeWidth(0.5).color(this.isDark ? '#24252A' : '#ECEEF0')
        this.ChatTabs()
        if (this.chatTab === 0) {
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
          playInfo: this.playInfo, messages: this.messages,
          title: this.roomInfo.title, uname: this.roomInfo.uname,
          onQualityChange: (qn: number) => this.changeQuality(qn),
          onFullscreenChange: (value: boolean) => this.fullscreen = value,
        })
        .width('100%')
        .height(this.fullscreen ? '100%' : this.playerHeight)
        .margin({ top: this.fullscreen ? 0 : Immersive.statusBarHeight() })
        .zIndex(this.fullscreen ? 10 : 2)
      }
      if (!this.fullscreen) {
        BackButton({ variant: BackButtonVariant.DARK })
          .margin({ left: 10, top: Immersive.statusBarHeight() + 8 })
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
