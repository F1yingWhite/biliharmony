/** 直播间：仅观看直播、切换画质、查看实时弹幕与 SC。 */
import { BiliApi } from '../api/BiliApi';
import { AppNavStack, LiveRoomParam } from '../common/AppRouter';
import { Immersive } from '../common/Immersive';
import { LiveDanmakuClient } from '../common/LiveDanmakuClient';
import { LivePlayerView } from '../components/LivePlayerView';
import { LiveChatMessage, LivePlayInfo, LiveRoomInfo } from '../model/LiveModels';

@Component
export struct LiveRoomPage {
  param: LiveRoomParam = { roomId: 0, uid: 0, title: '', uname: '', face: '', cover: '' };
  @State roomInfo: LiveRoomInfo = new LiveRoomInfo();
  @State playInfo: LivePlayInfo = new LivePlayInfo();
  @State messages: Array<LiveChatMessage> = [];
  @State superChats: Array<LiveChatMessage> = [];
  @State loading: boolean = true;
  @State qualityLoading: boolean = false;
  @State connected: boolean = false;
  @State fullscreen: boolean = false;
  @State chatTab: number = 0;
  @State errorText: string = '';
  @State playerHeight: number = 247.5;
  @StorageProp('isDarkMode') isDark: boolean = false;
  @StorageProp('accentColor') accent: string = '#FB7299';
  private client: LiveDanmakuClient = new LiveDanmakuClient();

  aboutToAppear(): void {
    this.roomInfo.roomId = this.param.roomId;
    this.roomInfo.uid = this.param.uid;
    this.roomInfo.title = this.param.title;
    this.roomInfo.uname = this.param.uname;
    this.roomInfo.face = this.param.face;
    this.roomInfo.cover = this.param.cover;
    this.client.onMessage = (message: LiveChatMessage) => this.appendMessage(message);
    this.client.onConnected = (value: boolean) => this.connected = value;
    this.loadRoom();
  }

  aboutToDisappear(): void {
    this.client.close();
  }

  async loadRoom(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    const info: LiveRoomInfo | null = await BiliApi.getLiveRoomInfo(this.param.roomId, this.param.uid);
    if (info !== null) this.roomInfo = info;
    const play: LivePlayInfo | null = await BiliApi.getLivePlayInfo(this.param.roomId, 10000);
    if (play === null || play.url.length === 0) {
      this.errorText = info !== null && info.liveStatus !== 1 ? '主播当前未开播' : '直播播放地址获取失败';
      this.loading = false;
      return;
    }
    this.playInfo = play;
    const history: Array<LiveChatMessage> = await BiliApi.getLiveDanmakuHistory(this.param.roomId);
    this.messages = history;
    this.superChats = await BiliApi.getLiveSuperChats(this.param.roomId);
    this.loading = false;
    this.client.connect(this.param.roomId);
  }

  async changeQuality(qn: number): Promise<void> {
    if (this.qualityLoading) return;
    this.qualityLoading = true;
    const next: LivePlayInfo | null = await BiliApi.getLivePlayInfo(this.param.roomId, qn);
    if (next !== null && next.url.length > 0) this.playInfo = next;
    this.qualityLoading = false;
  }

  appendMessage(message: LiveChatMessage): void {
    if (message.type === 'sc') {
      const nextSc: Array<LiveChatMessage> = [message].concat(this.superChats);
      this.superChats = nextSc.slice(0, 50);
    }
    const next: Array<LiveChatMessage> = this.messages.concat([message]);
    this.messages = next.length > 240 ? next.slice(next.length - 200) : next;
  }

  @Builder
  BackButton() {
    Stack({ alignContent: Alignment.Center }) {
      Image($r('app.media.ic_back')).width(20).height(20).fillColor('#FFFFFF')
    }
    .width(36).height(36).borderRadius(18).backgroundColor('#73000000')
    .margin({ left: 10, top: Immersive.statusBarHeight() + 8 })
    .onClick(() => AppNavStack.pop())
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
      Text('仅观看')
        .fontSize(10).fontColor(this.isDark ? '#77777C' : '#A0A3A8')
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .borderRadius(9).backgroundColor(this.isDark ? '#26272C' : '#EEF0F2')
    }
    .width('100%').height(42).padding({ left: 14, right: 14 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DanmakuList() {
    List({ space: 8 }) {
      ForEach(this.messages.slice().reverse(), (msg: LiveChatMessage) => {
        ListItem() {
          Row({ space: 7 }) {
            Text(msg.uname.length > 0 ? msg.uname : '观众')
              .fontSize(11).fontColor(this.accent).maxLines(1)
              .constraintSize({ maxWidth: 110 })
            Text(msg.text)
              .fontSize(13).fontColor(this.isDark ? '#E1E2E3' : '#303236')
              .layoutWeight(1).maxLines(3)
          }
          .width('100%').padding({ left: 14, right: 14 })
          .alignItems(VerticalAlign.Top)
        }
      }, (msg: LiveChatMessage) => msg.id)
    }
    .width('100%').layoutWeight(1).scrollBar(BarState.Off)
    .contentEndOffset(Immersive.bottomInset() + 18)
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
          const height: number = newValue.height as number;
          if (height > 0) this.playerHeight = height;
        })
        this.RoomHeader()
        Divider().strokeWidth(0.5).color(this.isDark ? '#24252A' : '#ECEEF0')
        this.ChatTabs()
        if (this.chatTab === 0) {
          this.DanmakuList()
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
        this.BackButton()
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
