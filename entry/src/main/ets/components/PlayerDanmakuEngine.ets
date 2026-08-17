/**
 * 播放器 Canvas 弹幕渲染引擎。
 *
 * 从 PlayerView 中拆出的纯逻辑/绘制类：负责弹幕有序列表游标、滚动/固定轨道分配、
 * 双缓冲推进、文本测量缓存与 Canvas 绘制。组件层只保留定时器、生命周期和设置项同步。
 */
import { DanmakuItem } from '../api/BiliApi';
import { ActiveDm, colorHex } from './PlayerDanmakuSupport';

/** 弹幕视口矩形（Canvas 像素坐标），供点击气泡定位。 */
export class DmViewportRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
}

export class PlayerDanmakuEngine {
  /** 已按 time 升序排列的全量弹幕。 */
  list: Array<DanmakuItem> = [];
  /** 当前画布上的活动弹幕。 */
  active: Array<ActiveDm> = [];
  width: number = 1;
  height: number = 1;
  /** 最近一次播放头时间（秒），用于识别跳变/回退。 */
  lastPlayerTime: number = 0;
  opacity: number = 0.85;
  speed: number = 1.0;
  fontScale: number = 1.3;
  density: number = 18;
  fullscreen: boolean = false;
  enabled: boolean = true;
  blockScrollDm: boolean = false;
  blockTopDm: boolean = false;
  blockBottomDm: boolean = false;
  blockColorDm: boolean = false;
  /** 有序弹幕列表消费游标。 */
  cursor: number = 0;
  /** 被点击"停住"的弹幕：绘制暂停（不前进、不过期），等待用户点赞/点踩/举报后解冻。 */
  pinned: ActiveDm | null = null;

  private ctx: CanvasRenderingContext2D;
  lastDrawMs: number = 0;
  private nextScrollLane: number = 0;
  private nextTopLane: number = 0;
  private nextBottomLane: number = 0;
  // drawFrame 双缓冲，避免每帧分配 keep 数组。
  private activeBack: Array<ActiveDm> = [];
  private textWidthCache: Map<string, number> = new Map<string, number>();
  private colorCache: Map<number, string> = new Map<number, string>();

  constructor(ctx: CanvasRenderingContext2D) {
    this.ctx = ctx;
  }

  setList(list: Array<DanmakuItem>): void {
    this.list = list;
    this.syncCursor(this.lastPlayerTime);
  }

  /** 把分段弹幕合并进全局有序列表，并把游标推到播放头之后，避免重放已喷出的弹幕。 */
  appendSorted(items: Array<DanmakuItem>): void {
    if (items.length === 0) return;
    this.list = this.list.concat(items);
    this.list.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time);
    const guard: number = this.lastPlayerTime + 0.1;
    let low: number = 0;
    let high: number = this.list.length;
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.list[middle].time <= guard) low = middle + 1;
      else high = middle;
    }
    this.cursor = low;
  }

  /** 本地发送弹幕按时间插入有序列表；若插入在游标前，游标同步后移。 */
  insertLocal(item: DanmakuItem): void {
    let low: number = 0;
    let high: number = this.list.length;
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.list[middle].time <= item.time) low = middle + 1;
      else high = middle;
    }
    this.list.splice(low, 0, item);
    if (low < this.cursor) this.cursor++;
  }

  /**
   * 视口尺寸变化。
   * 只更新宽高几何，不在此立即全量重绘：
   * - 滚动弹幕的 x 由渲染循环每帧推进没有缓存概念，宽度变化自然被下一帧吸收；
   * - 固定弹幕的横坐标在 drawFrame 中按当前 width 实时计算（width - textWidth）/2，同样无需重排；
   * - 仅当轨道数量（由行高与可用高度决定）真正变化时才需要 clamp，避免切换/缩放过程中
   *   onAreaChange 高频回调引发「每条弹幕重新分轨 + 整卡重绘」的 CPU 与帧率开销。
   * 调用方负责：渲染循环运行中放任下一帧；暂停态补一次 drawFrame 避免 Canvas 清空白屏。
   */
  setViewport(width: number, height: number): void {
    const newW: number = Math.max(1, width);
    const newH: number = Math.max(1, height);
    if (Math.abs(newW - this.width) < 0.5 && Math.abs(newH - this.height) < 0.5) {
      return;
    }
    const oldLanes: number = this.laneCount();
    this.width = newW;
    this.height = newH;
    const newLanes: number = this.laneCount();
    if (newLanes !== oldLanes) {
      this.clampDanmakuLanes(newLanes);
    }
  }

  clearActive(): void {
    this.active = [];
    this.pinned = null;
    this.nextScrollLane = 0;
    this.nextTopLane = 0;
    this.nextBottomLane = 0;
    this.ctx.clearRect(0, 0, this.width, this.height);
  }

  clearCaches(): void {
    this.textWidthCache.clear();
    this.colorCache.clear();
  }

  clearCanvas(): void {
    this.ctx.clearRect(0, 0, this.width, this.height);
  }

  /** 命中测试：返回包含点 (x, y) 的最后绘制的弹幕（视觉最上层优先），用于点击弹幕触发举报。 */
  hitTest(x: number, y: number): DanmakuItem | null {
    const hit: ActiveDm | null = this.hitTestActive(x, y);
    return hit !== null ? hit.item : null;
  }

  /** 命中测试（返回运行态实例）：点击弹幕时先冻结该条，供弹幕操作条点赞/点踩/举报。 */
  hitTestActive(x: number, y: number): ActiveDm | null {
    if (x < 0 || y < 0 || x > this.width || y > this.height) {
      return null;
    }
    const fontSize: number = this.fontSize();
    const laneH: number = this.lineHeight();
    let hit: ActiveDm | null = null;
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      const top: number = dm.lane * laneH;
      if (y < top || y > top + fontSize) continue;
      let left: number = dm.x;
      if (dm.isFixed) {
        left = (this.width - dm.textWidth) / 2;
      }
      if (x >= left - 4 && x <= left + dm.textWidth + 4) {
        hit = dm; // 越靠后的越新，走在最上层
      }
    }
    return hit;
  }

  /** 停住某条被点中的弹幕（B 站交互：点一下弹幕冻结，上方显示点赞/点踩/举报）。 */
  pin(dm: ActiveDm | null): void {
    this.pinned = dm;
    this.drawFrame(false);
  }

  /** 弹幕视口矩形（px）：供点击气泡在弹幕上方/下方定位。 */
  dmViewportOf(dm: ActiveDm): DmViewportRect {
    const fs: number = this.fontSize();
    const top: number = dm.lane * this.lineHeight();
    const w: number = dm.textWidth;
    const rect: DmViewportRect = new DmViewportRect();
    rect.x = dm.isFixed ? (this.width - w) / 2 : dm.x;
    rect.y = top;
    rect.w = w;
    rect.h = fs;
    return rect;
  }

  spawn(now: number): void {
    if (this.enabled === false || this.list.length === 0) {
      return;
    }
    // 数量同时受用户密度、实际轨道数和 Canvas 性能上限约束。
    const maxActive: number = this.maxActive();
    const spawnBudget: number = this.fullscreen ? 12 : 8;
    let spawned: number = 0;
    while (this.cursor < this.list.length && this.list[this.cursor].time <= now + 0.1 && spawned < spawnBudget) {
      // 当前屏已满时暂停消费游标，待滚动弹幕出屏后再继续，避免把繁忙时段弹幕永久丢掉。
      if (this.active.length >= maxActive) {
        break;
      }
      const item: DanmakuItem = this.list[this.cursor];
      this.cursor++;
      spawned++;
      const isTop: boolean = item.mode === 5;
      const isBottom: boolean = item.mode === 4;
      const isScroll: boolean = isTop === false && isBottom === false;
      if ((isScroll && this.blockScrollDm) || (isTop && this.blockTopDm) ||
        (isBottom && this.blockBottomDm) || (this.blockColorDm && item.color !== 16777215)) {
        continue;
      }
      const renderText: string = item.text.length > 80 ? item.text.substring(0, 79) + '…' : item.text;
      const textW: number = this.measureText(renderText);
      const renderColor: string = this.colorFor(item.color);
      if (item.mode === 4 || item.mode === 5) {
        // 固定弹幕：顶部/底部居中，停留 4 秒
        const fixedLane: number = this.allocFixedLane(item.mode);
        if (fixedLane < 0) continue;
        this.active.push(new ActiveDm(item, -1, fixedLane, 0, now + 4, true, now, textW, renderText, renderColor));
      } else {
        // 所有弹幕保持近似相同的过屏时间；长文本虽然速度更快，但分轨时会预判追尾。
        const spawnX: number = this.width + Math.max(10, this.fontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / Math.max(0.5, this.speed);
        const speed: number = (spawnX + textW) / travelSeconds;
        const lane: number = this.allocLane(spawnX, speed);
        if (lane < 0) continue;
        this.active.push(new ActiveDm(item, spawnX, lane, speed, 0, false, now, textW, renderText, renderColor));
      }
    }
  }

  drawFrame(advance: boolean = true): void {
    this.ctx.clearRect(0, 0, this.width, this.height);
    const now: number = this.lastPlayerTime;
    const fontSize: number = this.fontSize();
    const laneH: number = this.lineHeight();
    // 双缓冲原地复用，避免每帧分配 keep 数组带来的 GC 压力。
    const keep: Array<ActiveDm> = this.activeBack;
    keep.length = 0;
    const drawMs: number = Date.now();
    const deltaSec: number = advance ?
      (this.lastDrawMs > 0 ? Math.min(0.12, Math.max(0.012, (drawMs - this.lastDrawMs) / 1000)) : 0.033) : 0;
    if (advance) this.lastDrawMs = drawMs;
    this.ctx.globalAlpha = this.opacity;
    this.ctx.font = '600 ' + fontSize + 'px sans-serif';
    this.ctx.strokeStyle = '#B3000000';
    this.ctx.lineWidth = this.fullscreen ? 2.5 : 2;
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      const frozen: boolean = dm === this.pinned;
      if (dm.isFixed) {
        // 固定弹幕：被点击冻结时不过期（保持停住），否则按 fixedUntil 过期。
        if (!frozen && now > dm.fixedUntil) {
          continue;
        }
        this.ctx.fillStyle = dm.renderColor;
        const x: number = (this.width - dm.textWidth) / 2;
        const y: number = dm.lane * laneH + fontSize;
        this.ctx.strokeText(dm.renderText, x, y);
        this.ctx.fillText(dm.renderText, x, y);
        keep.push(dm);
      } else {
        // 滚动弹幕：被冻结时停在当前位置不再前进。
        if (!frozen) dm.x -= dm.speed * deltaSec;
        if (!frozen && dm.x + dm.textWidth < -10) {
          continue;
        }
        this.ctx.fillStyle = dm.renderColor;
        const y: number = dm.lane * laneH + fontSize;
        this.ctx.strokeText(dm.renderText, dm.x, y);
        this.ctx.fillText(dm.renderText, dm.x, y);
        keep.push(dm);
      }
    }
    this.ctx.globalAlpha = 1;
    this.activeBack = this.active;
    this.active = keep;
  }

  resetAt(time: number): void {
    this.lastPlayerTime = time;
    this.clearActive();
    this.syncCursor(time);
  }

  setSpeed(value: number): void {
    this.speed = value;
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (!dm.isFixed) {
        const spawnInset: number = Math.max(10, this.fontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / Math.max(0.5, value);
        dm.speed = (this.width + spawnInset + dm.textWidth) / travelSeconds;
      }
    }
  }

  setFontScale(value: number): void {
    this.fontScale = value;
    this.textWidthCache.clear();
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      dm.textWidth = this.measureText(dm.renderText);
      if (!dm.isFixed) {
        const spawnInset: number = Math.max(10, this.fontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / Math.max(0.5, this.speed);
        dm.speed = (this.width + spawnInset + dm.textWidth) / travelSeconds;
      }
    }
    const laneCount: number = this.laneCount();
    this.clampDanmakuLanes(laneCount);
    this.drawFrame(false);
  }

  setDensity(value: number): void {
    this.density = Math.round(value);
    const maxActive: number = this.maxActive();
    if (this.active.length > maxActive) this.active = this.active.slice(0, maxActive);
  }

  applyFilters(): void {
    const keep: Array<ActiveDm> = [];
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      const isTop: boolean = dm.item.mode === 5;
      const isBottom: boolean = dm.item.mode === 4;
      const isScroll: boolean = !isTop && !isBottom;
      if ((isScroll && this.blockScrollDm) || (isTop && this.blockTopDm) ||
        (isBottom && this.blockBottomDm) || (this.blockColorDm && dm.item.color !== 16777215)) continue;
      keep.push(dm);
    }
    this.active = keep;
  }

  syncCursor(time: number): void {
    let low: number = 0;
    let high: number = this.list.length;
    const threshold: number = Math.max(0, time - 0.12);
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.list[middle].time < threshold) low = middle + 1;
      else high = middle;
    }
    this.cursor = low;
  }

  /** 默认字号进一步增大；行高单独由 lineHeight 控制，不再用大间距假装字号。 */
  private fontSize(): number {
    return (this.fullscreen ? 40 : 30) * this.fontScale;
  }

  private lineHeight(): number {
    // 旧实现固定加 10，字号越大空隙越夸张；现在只保留 3vp 防描边相碰。
    return this.fontSize() + 3;
  }

  private laneCount(): number {
    // 弹幕只覆盖画面上方约 86%，给进度条/字幕留出底部安全区。
    const usableHeight: number = Math.max(this.lineHeight(), this.height * 0.86);
    return Math.max(1, Math.floor(usableHeight / this.lineHeight()));
  }

  private maxActive(): number {
    const byDensity: number = this.fullscreen ? this.density * 3 : this.density * 2;
    const byLane: number = this.laneCount() * 5;
    return Math.max(5, Math.min(this.fullscreen ? 60 : 40, byDensity, byLane));
  }

  private laneSafeForScroll(lane: number, spawnX: number, newSpeed: number): boolean {
    const minimumGap: number = Math.max(18, this.fontSize() * 0.62);
    for (let i: number = 0; i < this.active.length; i++) {
      const current: ActiveDm = this.active[i];
      if (current.lane !== lane) continue;
      // 固定弹幕仍占据同一条视觉轨道，滚动弹幕不能从它下面穿过。
      if (current.isFixed) return false;
      const currentTail: number = current.x + current.textWidth;
      if (currentTail + minimumGap > spawnX) return false;
      if (newSpeed > current.speed + 0.01) {
        const catchSeconds: number = (spawnX - currentTail - minimumGap) / (newSpeed - current.speed);
        const currentExitSeconds: number = Math.max(0, (currentTail + minimumGap) / Math.max(1, current.speed));
        if (catchSeconds < currentExitSeconds) return false;
      }
    }
    return true;
  }

  private allocLane(spawnX: number, speed: number): number {
    const laneCount: number = this.laneCount();
    for (let offset: number = 0; offset < laneCount; offset++) {
      const lane: number = (this.nextScrollLane + offset) % laneCount;
      if (this.laneSafeForScroll(lane, spawnX, speed)) {
        this.nextScrollLane = (lane + 1) % laneCount;
        return lane;
      }
    }
    return -1;
  }

  private allocFixedLane(mode: number): number {
    const laneCount: number = this.laneCount();
    const candidateCount: number = Math.max(1, Math.min(3, laneCount));
    const start: number = mode === 5 ? this.nextTopLane : this.nextBottomLane;
    for (let offset: number = 0; offset < candidateCount; offset++) {
      const relative: number = (start + offset) % candidateCount;
      const lane: number = mode === 5 ? relative : laneCount - 1 - relative;
      let available: boolean = true;
      for (let i: number = 0; i < this.active.length; i++) {
        // 顶部、底部和滚动弹幕共用视觉轨道，彻底避免模式间互相覆盖。
        if (this.active[i].lane === lane) {
          available = false;
          break;
        }
      }
      if (available) {
        if (mode === 5) this.nextTopLane = (relative + 1) % candidateCount;
        else this.nextBottomLane = (relative + 1) % candidateCount;
        return lane;
      }
    }
    return -1;
  }

  private measureText(text: string): number {
    const size: number = this.fontSize();
    const key: string = String(Math.round(size * 10)) + ':' + text;
    const cached: number | undefined = this.textWidthCache.get(key);
    if (cached !== undefined) return cached;
    this.ctx.font = '600 ' + size + 'px sans-serif';
    const w: number = this.ctx.measureText(text).width;
    const result: number = Math.max(20, w);
    if (this.textWidthCache.size > 512) {
      // 整体清空会造成短时间内大量重复测量；改为淘汰最早插入的一半（Map 迭代序即插入序）。
      let evict: number = 256;
      for (const oldest of this.textWidthCache.keys()) {
        if (evict <= 0) break;
        this.textWidthCache.delete(oldest);
        evict--;
      }
    }
    this.textWidthCache.set(key, result);
    return result;
  }

  private colorFor(color: number): string {
    const cached: string | undefined = this.colorCache.get(color);
    if (cached !== undefined) return cached;
    const result: string = colorHex(color);
    this.colorCache.set(color, result);
    return result;
  }

  /** 字号/轨道数变化后，保留已上屏弹幕并就近夹到新轨道，避免“行数变少弹幕直接消失”。 */
  private clampDanmakuLanes(laneCount: number): void {
    const used: Set<number> = new Set<number>();
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (dm.lane < laneCount) used.add(dm.lane);
    }
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (dm.lane < laneCount) continue;
      let lane: number = dm.isFixed && dm.item.mode === 4 ? laneCount - 1 : dm.lane % laneCount;
      if (used.has(lane)) {
        let free: number = -1;
        for (let l: number = 0; l < laneCount; l++) {
          if (used.has(l) === false) {
            free = l;
            break;
          }
        }
        if (free >= 0) lane = free;
      }
      dm.lane = lane;
      used.add(lane);
    }
  }
}
