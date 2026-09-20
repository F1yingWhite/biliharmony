/**
 * B 站直播弹幕 WebSocket 客户端。只订阅消息，不发送弹幕、礼物或任何消费请求。
 * 使用 protover=2 接收 zlib 批量包，保证高流量房间的消息完整性。
 */
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { BiliApi } from '../api/BiliApi';
import { HttpClient } from '../services/network/HttpClient';
import { LiveChatMessage, LiveDanmakuInfo, LiveDanmakuServer } from '../model/LiveModels';
import { asObject, asString, asNumber } from './Utils';
import { LiveApi } from '../api/LiveApi';

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
  /** 压缩包必须按 WebSocket 到达顺序解码，避免异步解压导致消息乱序。 */
  private decodeQueue: Promise<void> = Promise.resolve();
  onMessage: (message: LiveChatMessage) => void = () => {};
  onConnected: (connected: boolean) => void = () => {};
  /** 连续失败达到上限放弃自动重连时回调一次，UI 可据此展示"点击重连"。 */
  onGiveUp: () => void = () => {};

  async connect(roomId: number): Promise<void> {
    this.close();
    this.roomId = roomId;
    this.closed = false;
    const generation: number = this.generation;
    try {
      const info: LiveDanmakuInfo | null = await LiveApi.getLiveDanmakuInfo(roomId);
      if (this.closed || generation !== this.generation) return;
      if (info === null || info.servers.length === 0) {
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
        this.lastInboundAtMs = Date.now();
        this.heartbeatFailures = 0;
        if (typeof value === 'string') {
          this.parseJson(value as string);
        } else {
          const packet: ArrayBuffer = value as ArrayBuffer;
          this.decodeQueue = this.decodeQueue.then(async (): Promise<void> => {
            if (this.socket === ws && !this.closed && generation === this.generation) await this.parsePackets(packet, generation);
          }).catch((): void => {
            // 单个损坏包不应中断后续消息解码。
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
    this.decodeQueue = Promise.resolve();
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
        // WebSocket open 只代表 TCP/TLS 建立；收到 op=8 才是直播弹幕鉴权成功。
        this.retryAttempts = 0;
        this.heartbeatFailures = 0;
        this.lastInboundAtMs = Date.now();
        this.onConnected(true);
        this.startHeartbeat();
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

  /** 解压直播 zlib 消息；输出未知时逐级扩容，最高 8 MiB，防止异常包无限占用内存。 */
  private async inflateZlib(source: ArrayBuffer): Promise<ArrayBuffer | null> {
    const zip: zlib.Zip = await zlib.createZip();
    let capacity: number = Math.max(64 * 1024, source.byteLength * 8);
    const maxCapacity: number = 8 * 1024 * 1024;
    while (capacity <= maxCapacity) {
      const output: ArrayBuffer = new ArrayBuffer(capacity);
      try {
        const result: zlib.ZipOutputInfo = await zip.uncompress(output, source, source.byteLength);
        if (result.status === zlib.ReturnStatus.OK || result.status === zlib.ReturnStatus.STREAM_END) {
          return output.slice(0, result.destLen);
        }
      } catch (e) {
        // 输出空间不足也可能以 BusinessError 返回，扩容后重试。
      }
      capacity *= 2;
    }
    return null;
  }

  private parseJson(text: string): void {
    try {
      const payload: Record<string, Object> = asObject(JSON.parse(text) as Object);
      const command: string = asString(payload['cmd'], '');
      let msg: LiveChatMessage | null = null;
      if (command.startsWith('DANMU_MSG')) {
        msg = LiveChatMessage.danmaku(payload, this.messageSeq++);
      } else if (command === 'SUPER_CHAT_MESSAGE') {
        msg = LiveChatMessage.superChat(asObject(payload['data']));
      }
      if (msg !== null && msg.text.length > 0) this.onMessage(msg);
    } catch (e) {
      // 心跳/认证包并非 JSON 消息，忽略即可。
    }
  }
}
