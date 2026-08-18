/**
 * 直播弹幕 Canvas 渲染器：把 LivePlayerView 里内联的滚动弹幕引擎抽成独立类。
 * 职责与 PlayerDanmakuEngine 对齐：车道分配、双缓冲推进、定时器与绘制；组件层只保留视图/开关同步。
 * socket 批量到达的弹幕先入待喷队列，按固定节奏逐条释放，避免一批一批同时上屏。
 */
import { LiveChatMessage } from '../model/LiveModels';
import { colorHex } from './PlayerDanmakuSupport';

class ActiveLiveDanmaku {
  message: LiveChatMessage;
  x: number;
  lane: number;
  speed: number;
  width: number;
  text: string;

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
  /** 弹幕设置（对齐视频播放页）：透明度 0.2-1 / 速度 0.5-2 / 字号 0.7-1.8 / 密度（同屏上限）。 */
  opacity: number = 0.88;
  speedScale: number = 1;
  fontScale: number = 1;
  maxActive: number = 28;

  private ctx: CanvasRenderingContext2D;
  private active: Array<ActiveLiveDanmaku> = [];
  /** 待喷出队列：socket 批量到达的弹幕先入队，按固定节奏逐条释放，避免一批一批同时上屏。 */
  private pending: Array<LiveChatMessage> = [];
  private lastReleaseMs: number = 0;
  private tick: number = -1;
  private lastDrawMs: number = 0;
  private nextLane: number = 0;
  private seenMessageIds: Set<string> = new Set<string>();
  private messageBaselineReady: boolean = false;

  constructor(ctx: CanvasRenderingContext2D) {
    this.ctx = ctx;
  }

  /** 进入播放器时用已有消息建立基线，避免启动瞬间把历史消息全部重喷一遍。 */
  setBaseline(messages: Array<LiveChatMessage>): void {
    this.seenMessageIds.clear();
    for (let i: number = 0; i < messages.length; i++) this.seenMessageIds.add(messages[i].id);
    this.messageBaselineReady = true;
  }

  /** 新消息增量进入：基线之后新增的弹幕先入待喷队列，由渲染循环按节奏逐条释放。 */
  onMessagesChanged(messages: Array<LiveChatMessage>): void {
    if (!this.messageBaselineReady) return;
    let added: boolean = false;
    for (let i: number = 0; i < messages.length; i++) {
      const message: LiveChatMessage = messages[i];
      if (this.seenMessageIds.has(message.id)) continue;
      this.seenMessageIds.add(message.id);
      this.pending.push(message);
      added = true;
    }
    if (this.seenMessageIds.size > 600) {
      this.seenMessageIds.clear();
      for (let i = 0; i < messages.length; i++) this.seenMessageIds.add(messages[i].id);
    }
    if (added && this.playing && this.enabled) this.startLoop();
  }

  /**
   * 按节奏从队列释放弹幕：每 ~130ms 放一条（积压 >8 时放两条）；
   * 积压超过 30 条丢弃最旧，保证直播弹幕的时效性（与 B 站客户端丢弃策略一致）。
   */
  private drainQueue(): void {
    if (this.pending.length === 0) return;
    const now: number = Date.now();
    if (now - this.lastReleaseMs < 130) return;
    if (this.pending.length > 30) {
      this.pending.splice(0, this.pending.length - 30);
    }
    const burst: number = this.pending.length > 8 ? 2 : 1;
    let released: boolean = false;
    for (let i: number = 0; i < burst && this.pending.length > 0; i++) {
      if (this.active.length >= this.maxActive) break;
      const message: LiveChatMessage = this.pending.shift() as LiveChatMessage;
      this.spawnMessage(message);
      released = true;
    }
    if (released) this.lastReleaseMs = now;
  }

  /** 清空所有活动弹幕和消息基线（组件销毁/生命周期重入时用）。 */
  release(): void {
    this.pending = [];
    this.stopLoop(true);
    this.seenMessageIds.clear();
    this.messageBaselineReady = false;
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
    if (playing && this.enabled && (this.active.length > 0 || this.pending.length > 0)) this.startLoop();
  }

  private fontSize(): number {
    return (this.fullscreen ? 28 : 18) * this.fontScale;
  }

  private lineHeight(): number {
    return this.fontSize() + 5;
  }

  private laneCount(): number {
    const topInset: number = this.fullscreen ? 54 : 6;
    const usable: number = Math.max(this.lineHeight(), this.height * 0.78 - topInset);
    return Math.max(1, Math.floor(usable / this.lineHeight()));
  }

  private laneAvailable(lane: number, spawnX: number): boolean {
    const gap: number = Math.max(20, this.fontSize());
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
    return -1;
  }

  private spawnMessage(message: LiveChatMessage): void {
    if (!this.enabled || this.width <= 1 || message.text.length === 0 || this.active.length >= this.maxActive) return;
    const text: string = message.type === 'sc' ? 'SC ¥' + String(message.price) + '  ' + message.text :
      (message.emotes.length > 0 && message.text === message.emotes[0].unique ? '[直播表情]' : message.text);
    this.ctx.font = '600 ' + String(this.fontSize()) + 'px sans-serif';
    const width: number = Math.max(24, this.ctx.measureText(text).width);
    const spawnX: number = this.width + 10;
    const lane: number = this.allocateLane(spawnX);
    if (lane < 0) return;
    const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / Math.max(0.5, this.speedScale);
    this.active.push(new ActiveLiveDanmaku(message, spawnX, lane,
      (spawnX + width) / travelSeconds, width, text));
    if (this.playing) this.startLoop();
  }

  private drawFrame(): void {
    this.ctx.clearRect(0, 0, this.width, this.height);
    const now: number = Date.now();
    const delta: number = this.lastDrawMs > 0 ? Math.min(0.12, Math.max(0.012, (now - this.lastDrawMs) / 1000)) : 0.033;
    this.lastDrawMs = now;
    const fontSize: number = this.fontSize();
    const topInset: number = this.fullscreen ? 54 : 6;
    this.ctx.font = '600 ' + String(fontSize) + 'px sans-serif';
    this.ctx.lineWidth = this.fullscreen ? 2.5 : 2;
    this.ctx.strokeStyle = '#B3000000';
    this.ctx.globalAlpha = Math.min(1, Math.max(0.2, this.opacity));
    const keep: Array<ActiveLiveDanmaku> = [];
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveLiveDanmaku = this.active[i];
      dm.x -= dm.speed * delta;
      if (dm.x + dm.width < -10) continue;
      this.ctx.fillStyle = dm.message.type === 'sc' ? '#FFD45A' : colorHex(dm.message.color);
      const y: number = topInset + dm.lane * this.lineHeight() + fontSize;
      this.ctx.strokeText(dm.text, dm.x, y);
      this.ctx.fillText(dm.text, dm.x, y);
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
    }, this.fullscreen ? 25 : 33);
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
