/**
 * B 站直播弹幕 WebSocket 客户端。只订阅消息，不发送弹幕、礼物或任何消费请求。
 * 使用 protover=2 接收 zlib 批量包，保证高流量房间的消息完整性。
 */
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { BiliApi } from '../api/BiliApi';
import { HttpClient } from './HttpClient';
import { LiveChatMessage, LiveDanmakuInfo, LiveDanmakuServer } from '../model/LiveModels';
import { asObject, asString, asNumber } from './Utils';
import { LiveApi } from '../api/LiveApi';

export class LiveDanmakuClient {
  private roomId: number = 0;
  private socket: webSocket.WebSocket | null = null;
  private heartbeatTimer: number = -1;
  private retryTimer: number = -1;
  private closed: boolean = true;
  private messageSeq: number = 0;
  /** 压缩包必须按 WebSocket 到达顺序解码，避免异步解压导致消息乱序。 */
  private decodeQueue: Promise<void> = Promise.resolve();
  onMessage: (message: LiveChatMessage) => void = () => {};
  onConnected: (connected: boolean) => void = () => {};

  async connect(roomId: number): Promise<void> {
    this.close();
    this.roomId = roomId;
    this.closed = false;
    try {
      const info: LiveDanmakuInfo | null = await LiveApi.getLiveDanmakuInfo(roomId);
      if (this.closed || info === null || info.servers.length === 0) {
        this.onConnected(false);
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
        if (typeof value === 'string') {
          this.parseJson(value as string);
        } else {
          const packet: ArrayBuffer = value as ArrayBuffer;
          this.decodeQueue = this.decodeQueue.then(async (): Promise<void> => {
            if (this.socket === ws && !this.closed) await this.parsePackets(packet);
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
        if (this.socket === ws) this.onConnected(false);
      }
    } catch (e) {
      // 弹幕信息拉取或 WebSocket 创建失败：按连接失败处理，重试语义不变。
      this.onConnected(false);
    }
  }

  close(): void {
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

  private scheduleReconnect(): void {
    if (this.closed || this.retryTimer >= 0 || this.roomId <= 0) return;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      if (!this.closed) this.connect(this.roomId);
    }, 2500);
  }

  private sendHeartbeat(): void {
    const ws: webSocket.WebSocket | null = this.socket;
    if (ws !== null && !this.closed) {
      try {
        ws.send(this.packet(2, '[object Object]'));
      } catch (e) {
        // 下一次网络状态回调会更新连接状态。
      }
    }
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

  private async parsePackets(buffer: ArrayBuffer): Promise<void> {
    const view: DataView = new DataView(buffer);
    let offset: number = 0;
    while (offset + 16 <= buffer.byteLength) {
      const packetLength: number = view.getUint32(offset);
      const headerLength: number = view.getUint16(offset + 4);
      const protocol: number = view.getUint16(offset + 6);
      const operation: number = view.getUint32(offset + 8);
      if (packetLength < headerLength || packetLength <= 0 || offset + packetLength > buffer.byteLength) break;
      if (operation === 8) {
        // WebSocket open 只代表 TCP/TLS 建立；收到 op=8 才是直播弹幕鉴权成功。
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
        if (inflated !== null) await this.parsePackets(inflated);
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
