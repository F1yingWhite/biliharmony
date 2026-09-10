/**
 * 直播弹幕 Canvas 渲染器：把 LivePlayerView 里内联的滚动弹幕引擎抽成独立类。
 * 职责与 PlayerDanmakuEngine 对齐：车道分配、双缓冲推进、定时器与绘制；组件层只保留视图/开关同步。
 * socket 批量到达的弹幕先入短时待喷队列，拥挤时优先保证新消息的实时性。
 */
import { LiveChatMessage, LiveEmoteItem } from '../../model/LiveModels';
import { colorHex } from '../player/PlayerDanmakuSupport';
import { image } from '@kit.ImageKit';
import { HttpClient } from '../../services/network/HttpClient';
import { Constants } from '../../common/Constants';

class ActiveLiveDanmaku {
  message: LiveChatMessage;
  x: number;
  lane: number;
  speed: number;
  width: number;
  text: string;
  textWidth: number = 0;
  emote: image.PixelMap | null = null;
  emoteWidth: number = 0;
  emoteHeight: number = 0;

  constructor(message: LiveChatMessage, x: number, lane: number, speed: number, width: number, text: string) {
    this.message = message;
    this.x = x;
    this.lane = lane;
    this.speed = speed;
    this.width = width;
    this.text = text;
  }
}
export class LiveDanmakuRenderer {
  /** 组件开关：false 时不再喷出新弹幕并停止绘制。 */
  enabled: boolean = true;
  fullscreen: boolean = false;
  playing: boolean = false;
  width: number = 1;
  height: number = 1;
  /** 弹幕设置（对齐视频播放页）：透明度 0.2-1 / 速度 0.5-2 / 字号 0.7-1.8 / 密度档位（按轨道容量计算同屏数量）。 */
  opacity: number = 0.88;
  speedScale: number = 1;
  fontScale: number = 1;
  spacing: number = 1;
  density: number = 28;

  private ctx: CanvasRenderingContext2D;
  private active: Array<ActiveLiveDanmaku> = [];
  /** 待喷出队列：只保留短时间内的新消息，避免高流量房间持续补播旧弹幕。 */
  private pending: Array<LiveChatMessage> = [];
  private readonly pendingTtlMs: number = 3000;
  private lastReleaseMs: number = 0;
  private tick: number = -1;
  private lastDrawMs: number = 0;
  private nextLane: number = 0;
  private seenMessageIds: Set<string> = new Set<string>();
  private messageBaselineReady: boolean = false;
  private emoteCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private emoteLoading: Set<string> = new Set<string>();
  private emoteFailed: Set<string> = new Set<string>();
  private resourceGeneration: number = 0;

  constructor(ctx: CanvasRenderingContext2D) {
    this.ctx = ctx;
  }

  /** 进入播放器时用已有消息建立基线，避免启动瞬间把历史消息全部重喷一遍。 */
  setBaseline(messages: Array<LiveChatMessage>): void {
    this.seenMessageIds.clear();
    for (let i: number = 0; i < messages.length; i++) this.seenMessageIds.add(messages[i].id);
    this.messageBaselineReady = true;
  }

  /** 手动同步直播时清空旧画面与待喷队列，再以最新历史快照建立增量基线。 */
  resetBaseline(messages: Array<LiveChatMessage>): void {
    this.pending = [];
    this.stopLoop(true);
    this.lastReleaseMs = 0;
    this.setBaseline(messages);
  }

  /** 新消息增量进入：基线之后新增的弹幕先入待喷队列，由渲染循环按节奏逐条释放。 */
  onMessagesChanged(messages: Array<LiveChatMessage>): void {
    if (!this.messageBaselineReady) return;
    const fresh: Array<LiveChatMessage> = [];
    for (let i: number = 0; i < messages.length; i++) {
      const message: LiveChatMessage = messages[i];
      if (this.seenMessageIds.has(message.id)) continue;
      this.seenMessageIds.add(message.id);
      fresh.push(message);
      if (this.fullscreen) this.prefetchEmote(message);
    }
    if (this.seenMessageIds.size > 600) {
      this.seenMessageIds.clear();
      for (let i = 0; i < messages.length; i++) this.seenMessageIds.add(messages[i].id);
    }
    // 竖屏只保留下方聊天列表，画面弹幕引擎不排队、不下载表情。
    if (!this.fullscreen) return;
    for (let i = 0; i < fresh.length; i++) {
      this.pending.push(fresh[i]);
    }
    this.trimPending(Date.now());
    if (fresh.length > 0 && this.playing && this.enabled) this.startLoop();
  }

  private trimPending(now: number): void {
    while (this.pending.length > 0 && now - this.pending[0].timestamp * 1000 > this.pendingTtlMs) {
      this.pending.shift();
    }
    const capacity: number = Math.max(100, this.laneCount() * 10);
    if (this.pending.length > capacity) {
      this.pending.splice(0, this.pending.length - capacity);
    }
  }

  /**
   * 按绘制帧从队列释放弹幕。一次最多填满现有空轨道；轨道不足时保留队首，
   * 避免高流量房间因为批量到达或短暂拥堵直接少掉大部分弹幕。
   */
  private drainQueue(): void {
    if (this.pending.length === 0) return;
    const now: number = Date.now();
    this.trimPending(now);
    if (this.pending.length === 0) return;
    if (now - this.lastReleaseMs < 32) return;
    const burst: number = this.pending.length;
    let released: boolean = false;
    let attempts: number = 0;
    for (let i: number = 0; i < burst && this.pending.length > 0 && attempts < this.pending.length; i++) {
      if (this.density < 30 && this.active.length >= this.laneCount() * (this.density >= 27 ? 10 : 6)) break;
      const message: LiveChatMessage = this.pending[0];
      if (!this.emoteReady(message)) {
        this.pending.push(this.pending.shift() as LiveChatMessage);
        attempts++;
        i--;
        continue;
      }
      if (!this.spawnMessage(message)) break;
      this.pending.shift();
      released = true;
    }
    if (released) this.lastReleaseMs = now;
  }

  /** 清空所有活动弹幕和消息基线（组件销毁/生命周期重入时用）。 */
  release(): void {
    this.resourceGeneration++;
    this.playing = false;
    this.pending = [];
    this.stopLoop(true);
    this.seenMessageIds.clear();
    this.messageBaselineReady = false;
    this.emoteCache.forEach((pixelMap: image.PixelMap) => {
      try { pixelMap.release(); } catch (e) {}
    });
    this.emoteCache.clear();
    this.emoteLoading.clear();
    this.emoteFailed.clear();
  }

  toggle(on: boolean): void {
    this.enabled = on;
    if (!this.enabled) {
      this.pending = [];
      this.stopLoop(true);
    }
  }

  /** 同步播放/全屏状态；从暂停恢复或进入全屏时若有存量弹幕则立即续画。 */
  setPlayback(playing: boolean, fullscreen: boolean): void {
    this.playing = playing;
    this.fullscreen = fullscreen;
    if (!fullscreen) {
      this.pending = [];
      this.stopLoop(true);
      return;
    }
    if (playing && this.enabled && (this.active.length > 0 || this.pending.length > 0)) this.startLoop();
  }

  setSpacing(value: number): void {
    this.spacing = Math.max(0.5, Math.min(2, value));
    const lanes: number = this.laneCount();
    this.active.forEach((item: ActiveLiveDanmaku) => item.lane = Math.min(item.lane, lanes - 1));
  }

  private fontSize(): number {
    // 与视频播放器使用同一默认视觉字号，避免直播弹幕只有视频弹幕约一半大小。
    return (this.fullscreen ? 14 : 12) * this.fontScale;
  }

  private lineHeight(): number {
    // Canvas 坐标和字体统一为 vp，避免 px 字号被当成 vp 行距后在高密度屏上放大空隙。
    const factor: number = this.density >= 30 ? 0.95 : (this.density >= 27 ? 1.05 : 1.15);
    return this.fontSize() * (factor + (this.spacing - 1) * 0.4);
  }

  private laneCount(): number {
    const topInset: number = 6;
    const bottomInset: number = 8;
    const usableForLaneSteps: number = Math.max(0, this.height - topInset - bottomInset - this.fontSize());
    return Math.max(1, Math.floor(usableForLaneSteps / this.lineHeight()) + 1);
  }

  private laneAvailable(lane: number, spawnX: number): boolean {
    const gap: number = Math.max(1, this.fontSize() * (this.density >= 27 ? 0.15 : 0.3) * this.spacing);
    for (let i: number = 0; i < this.active.length; i++) {
      const current: ActiveLiveDanmaku = this.active[i];
      if (current.lane === lane && current.x + current.width + gap > spawnX) return false;
    }
    return true;
  }

  private allocateLane(spawnX: number): number {
    const count: number = this.laneCount();
    for (let offset: number = 0; offset < count; offset++) {
      const lane: number = (this.nextLane + offset) % count;
      if (this.laneAvailable(lane, spawnX)) {
        this.nextLane = (lane + 1) % count;
        return lane;
      }
    }
    if (this.density >= 30) {
      const lane: number = this.nextLane % count;
      this.nextLane = (lane + 1) % count;
      return lane;
    }
    return -1;
  }

  private firstEmoteUrl(message: LiveChatMessage): string {
    return message.emotes.length > 0 ? message.emotes[0].url : '';
  }

  private emoteReady(message: LiveChatMessage): boolean {
    const url: string = this.firstEmoteUrl(message);
    return url.length === 0 || this.emoteCache.has(url) || this.emoteFailed.has(url);
  }

  private prefetchEmote(message: LiveChatMessage): void {
    const url: string = this.firstEmoteUrl(message);
    if (url.length === 0 || this.emoteCache.has(url) || this.emoteLoading.has(url) || this.emoteFailed.has(url)) return;
    this.emoteLoading.add(url);
    const generation: number = this.resourceGeneration;
    this.loadEmote(url).then((pixelMap: image.PixelMap | null): void => {
      if (generation !== this.resourceGeneration) {
        if (pixelMap !== null) pixelMap.release().catch(() => {});
        return;
      }
      this.emoteLoading.delete(url);
      if (pixelMap === null) this.emoteFailed.add(url);
      else this.emoteCache.set(url, pixelMap);
      if (this.playing && this.enabled && this.pending.length > 0) this.startLoop();
    }).catch((): void => {
      if (generation !== this.resourceGeneration) return;
      this.emoteLoading.delete(url);
      this.emoteFailed.add(url);
    });
  }

  private async loadEmote(url: string): Promise<image.PixelMap | null> {
    let source: image.ImageSource | null = null;
    try {
      const bytes: ArrayBuffer = await HttpClient.getBytes(url, {
        'User-Agent': Constants.browserUa,
        'Referer': 'https://live.bilibili.com/',
      });
      if (bytes.byteLength === 0) return null;
      source = image.createImageSource(bytes);
      return await source.createPixelMap({ desiredSize: { width: 96, height: 96 } });
    } catch (e) {
      return null;
    } finally {
      if (source !== null) {
        try { source.release(); } catch (e) {}
      }
    }
  }

  private cleanEmoteText(message: LiveChatMessage): string {
    return LiveChatMessage.textWithoutEmotes(message);
  }

  private isBulgedEmote(item: LiveEmoteItem | null): boolean {
    if (item === null) return false;
    // bulge_display 表示“可突出显示”。只有播放器内的房间大表情才按膨胀尺寸绘制；
    // emoji_/official_ 及 20px 内联表情仍是普通的一行内表情。
    return item.bulgeDisplay > 0 && item.inPlayerArea > 0 && item.unique.startsWith('room_') &&
      item.width >= 100 && item.height >= 100;
  }

  private spawnMessage(message: LiveChatMessage): boolean {
    if (!this.enabled || this.width <= 1 || message.text.length === 0) return false;
    // 视频画面浮层只显示正文；用户名属于右侧/下方聊天列表，不参与滚动弹幕。
    const emoteUrl: string = this.firstEmoteUrl(message);
    const emote: image.PixelMap | null = emoteUrl.length > 0 ? (this.emoteCache.get(emoteUrl) ?? null) : null;
    let body: string = message.emotes.length > 0 ? this.cleanEmoteText(message) : message.text;
    if (message.type === 'sc') body = 'SC ¥' + String(message.price) + '  ' + body;
    if (body.length === 0 && emote === null) {
      body = message.emotes.length > 0 && message.emotes[0].emoji.length > 0 ? message.emotes[0].emoji : '[表情]';
    }
    const text: string = body;
    this.ctx.font = '600 ' + String(this.fontSize()) + 'vp sans-serif';
    const textWidth: number = text.length > 0 ? this.ctx.measureText(text).width : 0;
    const emoteItem = message.emotes.length > 0 ? message.emotes[0] : null;
    // 普通表情为 0.8 行高，只有协议明确的房间大表情使用 1.2 行高。
    const emoteHeight: number = emote !== null ? this.lineHeight() *
      (this.isBulgedEmote(emoteItem) ? 1.2 : 0.8) : 0;
    const rawRatio: number = emoteItem !== null && emoteItem.width > 0 && emoteItem.height > 0 ?
      emoteItem.width / emoteItem.height : 1;
    const emoteRatio: number = Math.max(0.5, Math.min(2.5, rawRatio));
    const emoteWidth: number = emoteHeight * emoteRatio;
    const width: number = Math.max(24, textWidth + (textWidth > 0 && emoteWidth > 0 ? 6 : 0) + emoteWidth);
    const spawnX: number = this.width + 10;
    const lane: number = this.allocateLane(spawnX);
    if (lane < 0) return false;
    // 相同设置下所有正文保持一致的像素速度；不再让长文本为了固定穿屏时长而异常加速。
    const baseSpeed: number = Math.max(this.fullscreen ? 105 : 90, this.width / 8);
    const active: ActiveLiveDanmaku = new ActiveLiveDanmaku(message, spawnX, lane, baseSpeed *
      Math.max(0.5, this.speedScale), width, text);
    active.textWidth = textWidth;
    active.emote = emote;
    active.emoteWidth = emoteWidth;
    active.emoteHeight = emoteHeight;
    this.active.push(active);
    if (this.playing) this.startLoop();
    return true;
  }

  private drawFrame(): void {
    this.ctx.clearRect(0, 0, this.width, this.height);
    const now: number = Date.now();
    const delta: number = this.lastDrawMs > 0 ? Math.min(0.12, Math.max(0.012, (now - this.lastDrawMs) / 1000)) : 0.033;
    this.lastDrawMs = now;
    const fontSize: number = this.fontSize();
    const topInset: number = 6;
    this.ctx.font = '600 ' + String(fontSize) + 'vp sans-serif';
    this.ctx.lineWidth = this.fullscreen ? 0.8 : 0.7;
    this.ctx.strokeStyle = '#B3000000';
    this.ctx.globalAlpha = Math.min(1, Math.max(0.2, this.opacity));
    const keep: Array<ActiveLiveDanmaku> = [];
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveLiveDanmaku = this.active[i];
      dm.x -= dm.speed * delta;
      if (dm.x + dm.width < -10) continue;
      this.ctx.fillStyle = dm.message.type === 'sc' ? '#FFD45A' : colorHex(dm.message.color);
      const y: number = topInset + dm.lane * this.lineHeight() + fontSize;
      if (dm.text.length > 0) {
        this.ctx.strokeText(dm.text, dm.x, y);
        this.ctx.fillText(dm.text, dm.x, y);
      }
      if (dm.emote !== null && dm.emoteWidth > 0 && dm.emoteHeight > 0) {
        const imageX: number = dm.x + dm.textWidth + (dm.textWidth > 0 ? 6 : 0);
        this.ctx.drawImage(dm.emote, imageX, y - dm.emoteHeight * 0.82, dm.emoteWidth, dm.emoteHeight);
      }
      keep.push(dm);
    }
    this.ctx.globalAlpha = 1;
    this.active = keep;
    // 队列里还有待喷弹幕时循环保持运转，彻底清空后才停表。
    if (keep.length === 0 && this.pending.length === 0) this.stopLoop(false);
  }

  private startLoop(): void {
    if (this.tick >= 0 || !this.enabled || (this.active.length === 0 && this.pending.length === 0)) return;
    this.lastDrawMs = Date.now();
    this.tick = setInterval(() => {
      if (this.playing && this.enabled) {
        this.drainQueue();
        this.drawFrame();
      }
    }, Math.max(8, Math.round(1000 / Math.max(24, Math.min(120, this.frameRate)))));
  }

  frameRate: number = 60;

  setFrameRate(value: number): void {
    this.frameRate = Math.max(24, Math.min(120, Math.round(value)));
    if (this.tick >= 0) {
      clearInterval(this.tick);
      this.tick = -1;
      this.startLoop();
    }
  }

  private stopLoop(clear: boolean): void {
    if (this.tick >= 0) clearInterval(this.tick);
    this.tick = -1;
    this.lastDrawMs = 0;
    if (clear) {
      this.active = [];
      this.pending = [];
      this.nextLane = 0;
    }
    this.ctx.clearRect(0, 0, this.width, this.height);
  }
}
