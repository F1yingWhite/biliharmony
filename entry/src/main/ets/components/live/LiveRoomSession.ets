import { LiveApi } from '../../api/LiveApi';
import { LiveRoomParam } from '../../common/AppRouter';
import { LiveDanmakuClient } from '../../common/LiveDanmakuClient';
import { LiveChatMessage, LivePlayInfo, LiveRoomInfo } from '../../model/LiveModels';
import { AuthSession } from '../../services/auth/AuthSession';
import { LiveChatBuffer } from './LiveChatBuffer';

export class LiveRoomState {
  info: LiveRoomInfo = new LiveRoomInfo();
  play: LivePlayInfo = new LivePlayInfo();
  loading: boolean = true;
  qualityLoading: boolean = false;
  refreshing: boolean = false;
  connected: boolean = false;
  gaveUp: boolean = false;
  error: string = '';
}

/** 一个房间的一次账号会话：请求、实时连接和补拉定时器一起失效。 */
export class LiveRoomSession {
  private readonly chat: LiveChatBuffer;
  private readonly publish: (state: LiveRoomState) => void;
  private readonly toast: (message: string) => void;
  private state: LiveRoomState = new LiveRoomState();
  private roomId: number = 0;
  private uid: number = 0;
  private account: number = -1;
  private generation: number = 0;
  private active: boolean = false;
  private client: LiveDanmakuClient | null = null;
  private historyTimer: number = -1;
  private historyRequest: number = -1;

  constructor(chat: LiveChatBuffer, publish: (state: LiveRoomState) => void, toast: (message: string) => void) {
    this.chat = chat;
    this.publish = publish;
    this.toast = toast;
  }

  activate(param: LiveRoomParam): void {
    this.dispose();
    this.active = true;
    this.account = AuthSession.version;
    this.roomId = param.roomId;
    this.uid = param.uid;
    this.state = new LiveRoomState();
    this.state.info.roomId = param.roomId;
    this.state.info.uid = param.uid;
    this.state.info.title = param.title;
    this.state.info.uname = param.uname;
    this.state.info.face = param.face;
    this.state.info.cover = param.cover;
    this.chat.activate(() => this.current(this.generation));
    this.chat.establishBaseline([], true);
    this.emit();
  }

  dispose(): void {
    this.active = false;
    this.generation++;
    this.disconnect();
    this.chat.dispose();
  }

  async load(): Promise<void> {
    if (!this.current(this.generation)) return;
    const generation: number = this.begin();
    this.state.loading = true;
    this.state.error = '';
    this.emit();
    try {
      const info: LiveRoomInfo | null = await LiveApi.getLiveRoomInfo(this.roomId, this.uid);
      if (!this.current(generation)) return;
      if (info !== null) { this.state.info = info; this.emit(); }
      const play: LivePlayInfo | null = await LiveApi.getLivePlayInfo(this.roomId, 10000);
      if (!this.current(generation)) return;
      if (play === null || play.url.length === 0) {
        this.state.error = info !== null && info.liveStatus !== 1 ? '主播当前未开播' : '直播播放地址获取失败';
        return;
      }
      const history: Array<LiveChatMessage> = await LiveApi.getLiveDanmakuHistory(this.roomId);
      if (!this.current(generation)) return;
      // 历史只建立基线；发布播放地址之后播放器才能挂载，不能回放快照。
      this.chat.establishBaseline(history, true);
      this.state.play = play;
      this.connect(generation);
      this.refreshSuperChats(generation);
    } catch (e) {
      if (this.current(generation)) this.state.error = '直播间加载失败，请检查网络后重试';
    } finally {
      if (this.current(generation)) { this.state.loading = false; this.emit(); }
    }
  }

  async changeQuality(qn: number): Promise<void> {
    if (!this.current(this.generation) || this.state.qualityLoading || this.state.refreshing || this.state.loading) return;
    const generation: number = this.generation;
    this.state.qualityLoading = true;
    this.emit();
    try {
      const play: LivePlayInfo | null = await LiveApi.getLivePlayInfo(this.roomId, qn);
      if (!this.current(generation)) return;
      if (play === null || play.url.length === 0) throw new Error('empty quality url');
      this.state.play = play;
    } catch (e) {
      if (this.current(generation)) this.toast('画质切换失败，已保留当前画质，请稍后重试');
    } finally {
      if (this.current(generation)) { this.state.qualityLoading = false; this.emit(); }
    }
  }

  async sync(): Promise<void> {
    if (!this.current(this.generation) || this.state.refreshing || this.state.loading) return;
    const generation: number = this.begin();
    this.state.refreshing = true;
    const qn: number = this.state.play.currentQn > 0 ? this.state.play.currentQn : 10000;
    this.emit();
    try {
      // 同步等待两条请求，任一失败均已由 Promise.all 接住，避免另一条迟到 rejection 无人处理。
      const results: [LivePlayInfo | null, Array<LiveChatMessage>] = await Promise.all([
        LiveApi.getLivePlayInfo(this.roomId, qn), LiveApi.getLiveDanmakuHistory(this.roomId),
      ]);
      if (!this.current(generation)) return;
      const play: LivePlayInfo | null = results[0];
      if (play === null || play.url.length === 0) throw new Error('empty live url');
      this.chat.establishBaseline(results[1]);
      this.state.play = play;
      this.state.error = '';
      this.toast('已同步到直播最新状态');
    } catch (e) {
      if (this.current(generation)) this.toast('同步失败，请检查网络后重试');
    } finally {
      if (this.current(generation)) {
        // 失败也恢复旧播放源的连接；新会话的回调不能再接收已关闭连接的消息。
        this.connect(generation);
        this.state.refreshing = false;
        this.emit();
      }
    }
  }

  manualReconnect(): void {
    if (!this.current(this.generation) || this.state.connected || !this.state.gaveUp) return;
    this.state.gaveUp = false;
    this.emit();
    this.client?.manualReconnect();
  }

  private begin(): number {
    this.generation++;
    this.disconnect();
    this.chat.clearPending();
    this.state.connected = false;
    this.state.gaveUp = false;
    this.state.qualityLoading = false;
    return this.generation;
  }

  private current(generation: number): boolean {
    return this.active && this.generation === generation && this.account === AuthSession.version;
  }

  private connect(generation: number): void {
    if (!this.current(generation)) return;
    const client: LiveDanmakuClient = new LiveDanmakuClient();
    this.client = client;
    client.onMessage = (message: LiveChatMessage) => {
      if (this.acceptConnection(generation, client)) this.chat.append(message);
    };
    client.onConnected = (connected: boolean) => {
      if (!this.acceptConnection(generation, client)) return;
      this.state.connected = connected;
      if (connected) this.state.gaveUp = false;
      this.emit();
    };
    client.onGiveUp = () => {
      if (!this.acceptConnection(generation, client)) return;
      this.state.gaveUp = true;
      this.emit();
    };
    client.connect(this.roomId).catch(() => {});
    this.chat.markConnected();
    this.historyTimer = setInterval(() => {
      if (this.acceptConnection(generation, client) && Date.now() - this.chat.lastReceivedAt >= 8000) {
        this.pollHistory(generation);
      }
    }, 5000);
  }

  private acceptConnection(generation: number, client: LiveDanmakuClient): boolean {
    if (this.client !== client) return false;
    if (this.current(generation)) return true;
    // 登录广播未送达页面时仍停止旧账号的重连、心跳和补拉。
    if (this.account !== AuthSession.version) this.dispose();
    return false;
  }

  private disconnect(): void {
    if (this.historyTimer >= 0) clearInterval(this.historyTimer);
    this.historyTimer = -1;
    this.historyRequest = -1;
    const client: LiveDanmakuClient | null = this.client;
    this.client = null;
    client?.close();
  }

  private async refreshSuperChats(generation: number): Promise<void> {
    try {
      const snapshot: Array<LiveChatMessage> = await LiveApi.getLiveSuperChats(this.roomId);
      if (this.current(generation)) this.chat.mergeSnapshot(snapshot);
    } catch (e) {
      // SC 快照不影响视频与实时连接。
    }
  }

  private async pollHistory(generation: number): Promise<void> {
    if (this.historyRequest === generation) return;
    this.historyRequest = generation;
    try {
      const results: Array<Array<LiveChatMessage>> = await Promise.all([
        LiveApi.getLiveDanmakuHistory(this.roomId).catch(() => new Array<LiveChatMessage>()),
        LiveApi.getLiveSuperChats(this.roomId).catch(() => new Array<LiveChatMessage>()),
      ]);
      if (!this.current(generation)) return;
      results[0].forEach((message: LiveChatMessage) => this.chat.append(message));
      this.chat.mergeSnapshot(results[1]);
    } finally {
      if (this.historyRequest === generation) this.historyRequest = -1;
    }
  }

  private emit(): void {
    if (!this.current(this.generation)) return;
    const state: LiveRoomState = new LiveRoomState();
    state.info = this.state.info;
    state.play = this.state.play;
    state.loading = this.state.loading;
    state.refreshing = this.state.refreshing;
    state.qualityLoading = this.state.qualityLoading;
    state.connected = this.state.connected;
    state.gaveUp = this.state.gaveUp;
    state.error = this.state.error;
    this.publish(state);
  }
}
