/**
 * B 站直播弹幕 WebSocket 客户端。只订阅消息，不发送弹幕、礼物或任何消费请求。
 * 使用 protover=2 接收 zlib 批量包，保证高流量房间的消息完整性。
 * 二进制包的切帧、zlib 解压与 JSON.parse 在长驻 Worker 线程执行
 * （workers/LiveDanmakuDecodeWorker.ets），主线程只做结构化事件的鉴权与消息分发；
 * Worker 不可用时回退主线程同步解码（功能完整，仅让出帧预算）。
 */
import { webSocket } from '@kit.NetworkKit';
import { util, worker } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BiliApi } from '../api/BiliApi';
import { HttpClient } from '../services/network/HttpClient';
import { LiveChatMessage, LiveDanmakuInfo, LiveDanmakuServer } from '../model/LiveModels';
import { asObject, asString, asNumber } from './Utils';
import { LiveApi } from '../api/LiveApi';
import { LiveDecodedEvent, decodeLivePacketsCore, inflateLiveZlib } from './LiveDanmakuDecode';

/** 主线程 ↔ 解码 Worker 的请求/回执结构（generation 回传用于丢弃过期连接的结果）。 */
interface WorkerDecodeRequest {
  seq: number;
  generation: number;
  buffer: ArrayBuffer;
}

interface WorkerDecodeResponse {
  seq: number;
  generation: number;
  events: Array<LiveDecodedEvent>;
}

export class LiveDanmakuClient {
  /** 重连退避基数 / 上限与连续失败上限：弱网下固定 2.5s 无限重试既耗电又易被服务端限流。 */
  private static readonly RETRY_BASE_DELAY_MS: number = 2500;
  private static readonly RETY_MAX_DELAY_MS: number = 60000;
  private static readonly MAX_RETRY_ATTEMPTS: number = 10;
  /** 心跳连续失败上限：达到即判定链路异常，主动放弃当前连接走重连。 */
  private static readonly MAX_HEARTBEAT_FAILURES: number = 2;
  /** 半开连接判定阈值：应为连接状态但超过该时长无任何入站消息（含 op=3 心跳回应）即主动重连。 */
  private static readonly INBOUND_STALE_MS: number = 90000;
  private roomId: number = 0;
  private generation: number = 0;
  private socket: webSocket.WebSocket | null = null;
  private heartbeatTimer: number = -1;
  private retryTimer: number = -1;
  private retryAttempts: number = 0;
  private closed: boolean = true;
  private messageSeq: number = 0;
  /** 最近一次收到任何入站消息的毫秒时间戳；半开连接看门狗据此判断链路是否名存实亡。 */
  private lastInboundAtMs: number = 0;
  /** 心跳连续失败次数；鉴权成功（op=8）或收到任何入站消息时清零。 */
  private heartbeatFailures: number = 0;
  onMessage: (message: LiveChatMessage) => void = () => {};
  onConnected: (connected: boolean) => void = () => {};
  /** 连续失败达到上限放弃自动重连时回调一次，UI 可据此展示"点击重连"。 */
  onGiveUp: () => void = () => {};
  /** 后台解码 Worker（长驻，随房间关闭销毁）：切帧/解压/JSON.parse 在此线程执行。 */
  private decodeWorker: worker.ThreadWorker | null = null;
  /** Worker 创建失败或运行中崩坏后粘性回退主线程同步解码，不再反复尝试。 */
  private decodeWorkerBroken: boolean = false;
  private decodeSeq: number = 0;
  private static workerActiveLogged: boolean = false;

  async connect(roomId: number): Promise<void> {
    this.close();
    this.roomId = roomId;
    this.closed = false;
    // 预热解码 Worker：首个鉴权回包不必支付线程冷启动。
    this.ensureDecodeWorker();
    const generation: number = this.generation;
    try {
      const info: LiveDanmakuInfo | null = await LiveApi.getLiveDanmakuInfo(roomId);
      if (this.closed || generation !== this.generation) return;
      if (info === null || info.servers.length === 0) {
        hilog.warn(0x0000, 'LiveDm', 'getDanmuInfo empty for room %{public}d', roomId);
        this.onConnected(false);
        this.scheduleReconnect();
        return;
      }
      const server: LiveDanmakuServer = info.servers[0];
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      this.socket = ws;
      ws.on('open', (err: BusinessError) => {
        if (err || this.socket !== ws || this.closed) return;
        const uid: number = Number(HttpClient.getCookie('DedeUserID')) || 0;
        const body: string = JSON.stringify({
          'uid': uid,
          'roomid': this.roomId,
          'protover': 2,
          'platform': 'web',
          'type': 2,
          'buvid': HttpClient.getCookie('buvid3'),
          'key': info.token,
        });
        ws.send(this.packet(7, body));
      });
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (err || this.socket !== ws || this.closed) return;
        // 任何入站消息都证明链路仍活跃：刷新活跃时间并清零心跳连续失败计数。
        // 必须在入队瞬间刷新（不等后台解码完成），否则解码延迟会被半开看门狗误判为链路失活。
        this.lastInboundAtMs = Date.now();
        this.heartbeatFailures = 0;
        if (typeof value === 'string') {
          this.parseJson(value as string);
        } else {
          const packet: ArrayBuffer = value as ArrayBuffer;
          // Worker 路径按消息到达顺序回传（单线程 FIFO）；同步回退路径在 decodeAndDispatch
          // 内部 await，同样保持顺序。单个损坏包不应中断后续消息解码。
          this.decodeAndDispatch(packet, generation).catch((): void => {
          });
        }
      });
      ws.on('close', () => {
        if (this.socket === ws) {
          this.stopHeartbeat();
          this.onConnected(false);
          this.scheduleReconnect();
        }
      });
      ws.on('error', () => {
        if (this.socket === ws) {
          this.stopHeartbeat();
          this.onConnected(false);
          this.scheduleReconnect();
        }
      });
      try {
        await ws.connect('wss://' + server.host + ':' + String(server.wssPort) + '/sub', {
          header: {
            'User-Agent': 'Mozilla/5.0',
            'Origin': 'https://live.bilibili.com',
          },
        });
      } catch (e) {
        if (this.socket === ws && generation === this.generation && !this.closed) {
          hilog.warn(0x0000, 'LiveDm', 'ws connect failed code %{public}d', (e as BusinessError).code ?? 0);
          this.onConnected(false);
          this.scheduleReconnect();
        }
      }
    } catch (e) {
      if (!this.closed && generation === this.generation) {
        this.onConnected(false);
        this.scheduleReconnect();
      }
    }
  }

  close(): void {
    this.generation++;
    this.closed = true;
    this.stopHeartbeat();
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const ws: webSocket.WebSocket | null = this.socket;
    this.socket = null;
    if (ws !== null) {
      try {
        ws.close();
      } catch (e) {
        // 已关闭的连接无需再次处理。
      }
    }
    // 房间关闭即销毁解码 Worker（线程随页面退出释放）；先摘引用，exit 事件不会误报崩坏。
    const w: worker.ThreadWorker | null = this.decodeWorker;
    this.decodeWorker = null;
    if (w !== null) {
      try {
        w.terminate();
      } catch (e) {
      }
    }
    this.onConnected(false);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.sendHeartbeat();
    this.heartbeatTimer = setInterval(() => this.sendHeartbeat(), 30000);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  /** 用户手动重连：清空失败计数后立即重试（自动重连已因连续失败放弃时使用）。 */
  manualReconnect(): void {
    this.retryAttempts = 0;
    if (this.roomId > 0) this.connect(this.roomId);
  }

  private scheduleReconnect(): void {
    if (this.closed || this.retryTimer >= 0 || this.roomId <= 0) return;
    if (this.retryAttempts >= LiveDanmakuClient.MAX_RETRY_ATTEMPTS) {
      hilog.error(0x0000, 'LiveDm', 'danmaku reconnect gave up after %{public}d attempts', this.retryAttempts);
      this.onGiveUp();
      return;
    }
    const delay: number = Math.min(
      LiveDanmakuClient.RETRY_BASE_DELAY_MS * Math.pow(2, this.retryAttempts),
      LiveDanmakuClient.RETY_MAX_DELAY_MS);
    this.retryAttempts++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      if (!this.closed) this.connect(this.roomId);
    }, delay);
  }

  private sendHeartbeat(): void {
    const ws: webSocket.WebSocket | null = this.socket;
    if (ws === null || this.closed) return;
    // 看门狗：服务端会回应每次心跳（op=3），若应为连接状态却超过 90s 无任何入站消息，
    // 说明链路大概率已半开（close/error 事件不会到来），主动走异常关闭路径借重连机制恢复。
    const now: number = Date.now();
    if (this.lastInboundAtMs > 0 && now - this.lastInboundAtMs > LiveDanmakuClient.INBOUND_STALE_MS) {
      this.abandonSocketForReconnect();
      return;
    }
    try {
      const result: Promise<boolean> = ws.send(this.packet(2, '[object Object]'));
      result.then((ok: boolean): void => {
        // 半开连接上 send 失败也可能仅以返回 false 呈现，与拒绝同样计入连续失败。
        if (!ok) this.onHeartbeatSendFailed(ws);
      }).catch((): void => {
        this.onHeartbeatSendFailed(ws);
      });
    } catch (e) {
      // 同步抛错与异步失败等价处理，不再静默吞掉。
      this.onHeartbeatSendFailed(ws);
    }
  }

  /** 心跳单次发送失败（同步抛错 / Promise 拒绝 / 返回 false）：连续达到上限即主动放弃半开连接。 */
  private onHeartbeatSendFailed(ws: webSocket.WebSocket): void {
    if (this.socket !== ws || this.closed) return;
    this.heartbeatFailures++;
    if (this.heartbeatFailures >= LiveDanmakuClient.MAX_HEARTBEAT_FAILURES) {
      this.abandonSocketForReconnect();
    }
  }

  /**
   * 主动健康关闭：TCP 半开（NAT 超时、弱网切基站）时 close/error 事件都不会到达，只能由本地发起断开。
   * 与 close()（用户退出直播间）的区别：不清 closed 标志、不清重连定时器，让 scheduleReconnect 照常调度。
   * 先把 socket 置空再 ws.close()，旧连接迟到的 close/error/message 回调会因 this.socket !== ws 全部失效，
   * 不会重复触发重连或污染新连接的活跃时间戳。
   */
  private abandonSocketForReconnect(): void {
    const ws: webSocket.WebSocket | null = this.socket;
    if (ws === null || this.closed) return;
    this.socket = null;
    this.stopHeartbeat();
    this.onConnected(false);
    try {
      ws.close();
    } catch (e) {
      // 半开连接上 close 同样可能失败，重连不依赖它成功，底层资源由系统回收。
    }
    this.scheduleReconnect();
  }

  private packet(operation: number, bodyText: string): ArrayBuffer {
    const body: Uint8Array = new util.TextEncoder().encodeInto(bodyText);
    const buffer: ArrayBuffer = new ArrayBuffer(16 + body.byteLength);
    const view: DataView = new DataView(buffer);
    view.setUint32(0, 16 + body.byteLength);
    view.setUint16(4, 16);
    view.setUint16(6, 1);
    view.setUint32(8, operation);
    view.setUint32(12, 1);
    new Uint8Array(buffer, 16).set(body);
    return buffer;
  }

  /** 确保后台解码 Worker 可用并返回它；创建失败或已崩坏时返回 null（粘性走同步解码）。 */
  private ensureDecodeWorker(): worker.ThreadWorker | null {
    if (this.decodeWorkerBroken) return null;
    if (this.decodeWorker !== null) return this.decodeWorker;
    try {
      const w: worker.ThreadWorker = new worker.ThreadWorker('entry/ets/workers/LiveDanmakuDecodeWorker.ets');
      w.on('message', (event: Object) => {
        const response: WorkerDecodeResponse = event as WorkerDecodeResponse;
        this.dispatchDecoded(response.events, response.generation);
      });
      w.on('messageerror', (): void => this.breakDecodeWorker('messageerror'));
      w.on('error', (): void => this.breakDecodeWorker('error'));
      w.on('exit', (): void => this.breakDecodeWorker('exit'));
      this.decodeWorker = w;
      if (!LiveDanmakuClient.workerActiveLogged) {
        LiveDanmakuClient.workerActiveLogged = true;
        hilog.info(0x0000, 'LiveDm', 'background decode worker active');
      }
      return w;
    } catch (e) {
      this.breakDecodeWorker('create');
      return null;
    }
  }

  /** Worker 崩坏：摘引用并销毁，粘性回退主线程同步解码（只报一次日志）。 */
  private breakDecodeWorker(reason: string): void {
    const w: worker.ThreadWorker | null = this.decodeWorker;
    if (w === null) return;
    this.decodeWorker = null;
    this.decodeWorkerBroken = true;
    hilog.warn(0x0000, 'LiveDm', 'decode worker unavailable (%{public}s), main-thread sync decode', reason);
    try {
      w.terminate();
    } catch (e) {
    }
  }

  /**
   * 一个二进制包的完整解码与分发。生产路径把切帧 + zlib 解压 + JSON.parse 发给
   * 长驻 Worker（workers/LiveDanmakuDecodeWorker.ets），主线程只做结构化事件的
   * 鉴权与消息分发；Worker 不可用/崩坏时回退主线程同步解码——鉴权与消息都不能丢，
   * 回退缺失曾导致「弹幕鉴权永不完成 → 无限重连 → 永远显示重连中」且错误被吞、
   * 聊天列表靠 HTTP 历史轮询兜底照常流动，完全无感知。
   * 顺序保证：Worker 单线程按到达顺序回传；同步路径在本调用内 await，同样有序。
   */
  private async decodeAndDispatch(buffer: ArrayBuffer, generation: number): Promise<void> {
    const w: worker.ThreadWorker | null = this.ensureDecodeWorker();
    if (w !== null) {
      this.decodeSeq++;
      const request: WorkerDecodeRequest = { seq: this.decodeSeq, generation: generation, buffer: buffer };
      try {
        w.postMessage(request);
        return;
      } catch (e) {
        // post 失败（线程刚崩坏等）：本包就地同步解码，后续包自动走同步路径。
        this.breakDecodeWorker('post');
      }
    }
    const events: Array<LiveDecodedEvent> = await decodeLivePacketsCore(buffer);
    this.dispatchDecoded(events, generation);
  }

  /** 解码结果的主线程分发：逐事件校验代际/关闭状态，事件顺序即包内字节顺序。 */
  private dispatchDecoded(events: Array<LiveDecodedEvent>, generation: number): void {
    for (let i: number = 0; i < events.length; i++) {
      if (this.closed || generation !== this.generation) return;
      const event: LiveDecodedEvent = events[i];
      if (event.operation === 8) {
        this.handleAuthResponse();
      } else if (event.operation === 5 && event.payload !== null) {
        this.emitParsedMessage(event.payload);
      }
    }
  }

  /** op=8 鉴权成功的全部主线程副作用：重置重连与心跳计数、记录活跃时间并开启心跳。 */
  private handleAuthResponse(): void {
    // WebSocket open 只代表 TCP/TLS 建立；收到 op=8 才是直播弹幕鉴权成功。
    this.retryAttempts = 0;
    this.heartbeatFailures = 0;
    this.lastInboundAtMs = Date.now();
    this.onConnected(true);
    this.startHeartbeat();
  }

  /** 从消息 JSON 构建 LiveChatMessage；DANMU_MSG 以外的命令返回 null（messageSeq 只在弹幕上消费）。 */
  private buildMessage(payload: Record<string, Object>): LiveChatMessage | null {
    const command: string = asString(payload['cmd'], '');
    if (command.startsWith('DANMU_MSG')) return LiveChatMessage.danmaku(payload, this.messageSeq++);
    if (command === 'SUPER_CHAT_MESSAGE') return LiveChatMessage.superChat(asObject(payload['data']));
    return null;
  }

  /** 单条消息分发：构建抛错按脏消息丢弃，不影响后续消息。 */
  private emitParsedMessage(payload: Object): void {
    try {
      const msg: LiveChatMessage | null = this.buildMessage(asObject(payload));
      if (msg !== null && msg.text.length > 0) this.onMessage(msg);
    } catch (e) {
      // 结构异常的消息直接丢弃，与旧 parseJson 的吞异常语义一致。
    }
  }

  /**
   * 同步回退解码路径：Worker 不可用（创建失败/崩坏）或 Node QA 沙箱时由 decodeAndDispatch 调用，
   * 分支行为与生产后台路径一致；parity 测试直接驱动本方法并注入 inflateZlib 延迟验证代际防护。
   */
  private async parsePackets(buffer: ArrayBuffer, generation: number): Promise<void> {
    const view: DataView = new DataView(buffer);
    let offset: number = 0;
    while (!this.closed && generation === this.generation && offset + 16 <= buffer.byteLength) {
      const packetLength: number = view.getUint32(offset);
      const headerLength: number = view.getUint16(offset + 4);
      const protocol: number = view.getUint16(offset + 6);
      const operation: number = view.getUint32(offset + 8);
      if (headerLength < 16 || packetLength < headerLength || packetLength <= 0 || offset + packetLength > buffer.byteLength) break;
      if (operation === 8) {
        this.handleAuthResponse();
      } else if (operation === 5 && (protocol === 0 || protocol === 1)) {
        const bytes: Uint8Array = new Uint8Array(buffer, offset + headerLength, packetLength - headerLength);
        const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
        this.parseJson(text);
      } else if (operation === 5 && protocol === 2) {
        // zlib 包的正文仍是若干个带 16 字节头的直播协议包，需要递归解包。
        const compressedView: Uint8Array = new Uint8Array(buffer, offset + headerLength,
          packetLength - headerLength);
        const compressed: ArrayBuffer = new ArrayBuffer(compressedView.byteLength);
        new Uint8Array(compressed).set(compressedView);
        const inflated: ArrayBuffer | null = await this.inflateZlib(compressed);
        if (inflated !== null) await this.parsePackets(inflated, generation);
      }
      offset += packetLength;
    }
  }

  /** 同步回退路径的 zlib 解压：复用 LiveDanmakuDecode 的共享实例与逐级扩容策略。 */
  private async inflateZlib(source: ArrayBuffer): Promise<ArrayBuffer | null> {
    return inflateLiveZlib(source);
  }

  private parseJson(text: string): void {
    try {
      this.emitParsedMessage(JSON.parse(text) as Object);
    } catch (e) {
      // 心跳/认证包并非 JSON 消息，忽略即可。
    }
  }
}
