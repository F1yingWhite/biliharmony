/**
 * 播放器 Canvas 弹幕渲染引擎。
 *
 * 从 PlayerView 中拆出的纯逻辑/绘制类：负责弹幕有序列表游标、滚动/固定轨道分配、
 * 双缓冲推进、文本测量缓存与 Canvas 绘制。组件层只保留定时器、生命周期和设置项同步。
 */
import { DanmakuItem } from '../../api/BiliApi';
import { ActiveDm, colorHex, parseSpecialDanmaku, SpecialTrack } from './PlayerDanmakuSupport';

/** 未及时上屏的弹幕最多容忍一次播放器时间回调的抖动，避免繁忙片段形成延迟队列。 */
const MAX_SPAWN_LATENCY_SECONDS: number = 0.75;

/** 弹幕视口矩形（Canvas 像素坐标），供点击气泡定位。 */
export class DmViewportRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
  /** 文字可见顶（baseline - actualAscent）。 */
  visualTop: number = 0;
  /** 文字可见底（baseline + actualDescent）。 */
  visualBottom: number = 0;
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
  /** 视频播放倍速，仅参与滚动位移；固定/高级弹幕直接使用播放头时间。 */
  playbackRate: number = 1.0;
  speed: number = 1.0;
  fontScale: number = 1.0;
  density: number = 22;
  fullscreen: boolean = false;
  enabled: boolean = true;
  blockScrollDm: boolean = false;
  blockTopDm: boolean = false;
  blockBottomDm: boolean = false;
  blockColorDm: boolean = false;
  /** 智能云屏蔽等级 0-10：weight 低于该值的弹幕不喷出（B 站 app 同款，0 为关闭）。 */
  minWeight: number = 0;
  /** 有序弹幕列表消费游标。 */
  cursor: number = 0;
  /** 被点击"停住"的弹幕：绘制暂停（不前进、不过期），等待用户点赞/复制/举报后解冻。 */
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
  /** 每次 spawn 只构建一次弹道桶，避免每个候选轨道都扫描完整 active 数组。 */
  private laneBuckets: Array<Array<ActiveDm>> = [];

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
    // protobuf 分段通常已经有序；仅在脏响应无序时排序新段，再与旧列表线性归并。
    let incoming: Array<DanmakuItem> = items;
    for (let i: number = 1; i < items.length; i++) {
      if (items[i - 1].time > items[i].time) {
        incoming = items.slice();
        incoming.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time);
        break;
      }
    }
    const merged: Array<DanmakuItem> = new Array<DanmakuItem>(this.list.length + incoming.length);
    let oldIndex: number = 0;
    let newIndex: number = 0;
    let mergedIndex: number = 0;
    while (oldIndex < this.list.length && newIndex < incoming.length) {
      if (this.list[oldIndex].time <= incoming[newIndex].time) {
        merged[mergedIndex++] = this.list[oldIndex++];
      } else {
        merged[mergedIndex++] = incoming[newIndex++];
      }
    }
    while (oldIndex < this.list.length) merged[mergedIndex++] = this.list[oldIndex++];
    while (newIndex < incoming.length) merged[mergedIndex++] = incoming[newIndex++];
    this.list = merged;
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
    this.laneBuckets.length = 0;
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

  /** 命中测试（返回运行态实例）：点击弹幕时先冻结该条，供弹幕操作条点赞/复制/举报。 */
  hitTestActive(x: number, y: number): ActiveDm | null {
    if (x < 0 || y < 0 || x > this.width || y > this.height) {
      return null;
    }
    const laneH: number = this.lineHeight();
    let hit: ActiveDm | null = null;
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      // 高级弹幕自由定位且通常转瞬即逝，不参与点按冻结。
      if (dm.special !== null) continue;
      const itemFont: number = dm.fontSizePx > 0 ? dm.fontSizePx : this.fontSize();
      const top: number = dm.lane * laneH;
      if (y < top || y > top + itemFont) continue;
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

  /** 停住某条被点中的弹幕（B 站交互：点一下弹幕冻结，上方显示点赞/复制/举报）。 */
  pin(dm: ActiveDm | null): void {
    this.pinned = dm;
    this.drawFrame(false);
  }

  /** 弹幕视口矩形（px/pv 统一）：x/w 是水平范围，y 为轨道顶（≈文字顶），h 为字号。 */
  dmViewportOf(dm: ActiveDm): DmViewportRect {
    const fs: number = dm.fontSizePx > 0 ? dm.fontSizePx : this.fontSize();
    const top: number = dm.lane * this.lineHeight();
    const w: number = dm.textWidth;
    const rect: DmViewportRect = new DmViewportRect();
    rect.x = dm.isFixed ? (this.width - w) / 2 : dm.x;
    rect.y = top;
    rect.w = w;
    rect.h = fs;
    // 文字实际以 baseline（lane*lineHeight+fontSize）绘制；用真实 ascent/descent
    // 精确给出可见文字范围，供气泡定位避免与文字重叠。
    try {
      this.ctx.font = '600 ' + fs + 'px sans-serif';
      const tm: TextMetrics = this.ctx.measureText(dm.renderText);
      const ascent: number = Number(tm.actualBoundingBoxAscent);
      const descent: number = Number(tm.actualBoundingBoxDescent);
      const baseline: number = top + fs;
      rect.visualTop = baseline - (ascent > 0 ? ascent : fs * 0.82);
      rect.visualBottom = baseline + (descent > 0 ? descent : fs * 0.18);
    } catch (e) {
      rect.visualTop = top + fs * 0.18;
      rect.visualBottom = top + fs * 1.15;
    }
    return rect;
  }

  spawn(now: number): void {
    if (this.enabled === false || this.list.length === 0) {
      return;
    }
    // 弹幕是和播放时间绑定的即时内容，不是必须逐条消费的消息队列。画面繁忙时若停住游标，
    // 旧弹幕会在数秒甚至数十秒后才出现。每次调度先跳过已经错过展示窗口的项目，始终追上播放头。
    const earliestTime: number = Math.max(0, now - MAX_SPAWN_LATENCY_SECONDS);
    let low: number = this.cursor;
    let high: number = this.list.length;
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.list[middle].time < earliestTime) low = middle + 1;
      else high = middle;
    }
    this.cursor = low;

    // 数量同时受用户密度、实际轨道数和 Canvas 性能上限约束。
    const maxActive: number = this.maxActive();
    const spawnBudget: number = this.fullscreen ? 24 : 16;
    this.rebuildLaneBuckets();
    let spawned: number = 0;
    while (this.cursor < this.list.length && this.list[this.cursor].time <= now + 0.1 && spawned < spawnBudget) {
      // 当前屏已满时等待空位；下次调度会先丢弃届时已过期的项，不让它们积压到后续时间点。
      if (this.active.length >= maxActive) {
        break;
      }
      const item: DanmakuItem = this.list[this.cursor];
      this.cursor++;
      spawned++;
      // mode 8 代码弹幕 / 9 BAS 弹幕 / 0 等非法类型不按文本渲染（B 站客户端同样不显示原始内容）。
      if (item.mode < 1 || item.mode > 7) {
        continue;
      }
      const isTop: boolean = item.mode === 5;
      const isBottom: boolean = item.mode === 4;
      const isScroll: boolean = isTop === false && isBottom === false;
      if ((isScroll && this.blockScrollDm) || (isTop && this.blockTopDm) ||
        (isBottom && this.blockBottomDm) || (this.blockColorDm && item.color !== 16777215) ||
        item.weight < this.minWeight) {
        continue;
      }
      // mode 7 高级弹幕：自由定位 + 运动轨道，不占滚动/固定弹道，不做碰撞管理（与 B 站一致）。
      if (item.mode === 7) {
        const parsed: [string, SpecialTrack] | null = parseSpecialDanmaku(item.text);
        if (parsed !== null) {
          const special: SpecialTrack = parsed[1];
          const dm: ActiveDm = new ActiveDm(item, 0, 0, 0, 0, false, now, 0, parsed[0],
            this.colorFor(item.color));
          dm.special = special;
          dm.fontSizePx = Math.max(14, Math.min(90, special.sizePct / 100 * this.height));
          dm.textWidth = this.measure(dm.renderText, dm.fontSizePx);
          this.active.push(dm);
          continue;
        }
        // JSON 解析失败按普通滚动弹幕兜底（脏数据不丢弹幕）。
      }
      const sizePx: number = this.sizeFor(item);
      const renderText: string = item.text.length > 80 ? item.text.substring(0, 79) + '…' : item.text;
      const textW: number = this.measure(renderText, sizePx);
      const renderColor: string = this.colorFor(item.color);
      if (item.mode === 4 || item.mode === 5) {
        // 固定弹幕：顶部/底部居中，停留 4 秒
        const fixedLane: number = this.allocFixedLane(item.mode);
        if (fixedLane < 0) continue;
        const dm: ActiveDm = new ActiveDm(item, -1, fixedLane, 0, now + 4, true, now, textW, renderText, renderColor);
        dm.fontSizePx = sizePx;
        this.active.push(dm);
        this.addToLaneBucket(dm);
      } else if (item.mode === 6) {
        // 逆向滚动弹幕（mode 6）：从左向右过屏，与正向分轨（避免对向相撞）。
        const textWm: number = textW;
        const spawnX: number = -textWm - Math.max(10, sizePx * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
        const speed: number = (this.width - spawnX) / travelSeconds;
        const lane: number = this.allocReverseLane(spawnX + textWm, speed);
        if (lane < 0) continue;
        const dm: ActiveDm = new ActiveDm(item, spawnX, lane, speed, 0, false, now, textWm, renderText, renderColor);
        dm.reverse = true;
        dm.fontSizePx = sizePx;
        this.active.push(dm);
        this.addToLaneBucket(dm);
      } else {
        // 所有弹幕保持近似相同的过屏时间；长文本虽然速度更快，但分轨时会预判追尾。
        const spawnX: number = this.width + Math.max(10, sizePx * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
        const speed: number = (spawnX + textW) / travelSeconds;
        const lane: number = this.allocLane(spawnX, speed);
        if (lane < 0) continue;
        const dm: ActiveDm = new ActiveDm(item, spawnX, lane, speed, 0, false, now, textW, renderText, renderColor);
        dm.fontSizePx = sizePx;
        this.active.push(dm);
        this.addToLaneBucket(dm);
      }
    }
  }

  drawFrame(advance: boolean = true, frameTimeMs: number = Date.now()): void {
    this.ctx.clearRect(0, 0, this.width, this.height);
    const now: number = this.lastPlayerTime;
    const fontSize: number = this.fontSize();
    const laneH: number = this.lineHeight();
    // 双缓冲原地复用，避免每帧分配 keep 数组带来的 GC 压力。
    const keep: Array<ActiveDm> = this.activeBack;
    keep.length = 0;
    // DisplaySync 给出的帧时间同源、无 setInterval 抖动。卡住后按真实间隔追上播放画面，
    // 不再把 >120ms 的时间永久丢掉；2.5s 以上的播放头跳变会由上层 resetDanmakuAt 处理。
    const deltaSec: number = advance && this.lastDrawMs > 0 ?
      Math.min(2.5, Math.max(0, (frameTimeMs - this.lastDrawMs) / 1000)) : 0;
    if (advance) this.lastDrawMs = frameTimeMs;
    this.ctx.globalAlpha = this.opacity;
    this.ctx.font = '600 ' + fontSize + 'px sans-serif';
    this.ctx.strokeStyle = '#B3000000';
    this.ctx.lineWidth = this.fullscreen ? 2.5 : 2;
    let appliedFont: number = fontSize;
    let appliedColor: string = '';
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      const frozen: boolean = dm === this.pinned;
      // 高级弹幕：自由定位 + 运动轨道，独立绘制路径（不占弹道、不参与命中）。
      if (dm.special !== null) {
        if (this.drawSpecial(dm, now)) {
          keep.push(dm);
        }
        continue;
      }
      const itemFont: number = dm.fontSizePx > 0 ? dm.fontSizePx : fontSize;
      // 同字号弹幕占绝大多数，避免每条都重复触发 Canvas 字体解析。
      if (Math.abs(itemFont - appliedFont) > 0.01) {
        this.ctx.font = '600 ' + itemFont + 'px sans-serif';
        appliedFont = itemFont;
      }
      if (dm.isFixed) {
        // 固定弹幕：被点击冻结时不过期（保持停住），否则按 fixedUntil 过期。
        if (!frozen && now > dm.fixedUntil) {
          continue;
        }
        // 整数坐标：位置锁死后浮点亚像素每帧取齐会原地抖动，取整避免文字闪烁。
        const x: number = Math.round((this.width - dm.textWidth) / 2);
        const y: number = Math.round(dm.lane * laneH + itemFont);
        if (appliedColor !== dm.renderColor) {
          this.ctx.fillStyle = dm.renderColor;
          appliedColor = dm.renderColor;
        }
        this.ctx.strokeText(dm.renderText, x, y);
        this.ctx.fillText(dm.renderText, x, y);
        keep.push(dm);
      } else if (dm.reverse) {
        // 逆向滚动（mode 6）：从左向右推进。
        if (!frozen) dm.x += dm.speed * deltaSec;
        if (!frozen && dm.x - dm.textWidth > this.width + 10) {
          continue;
        }
        const x: number = Math.round(dm.x);
        const y: number = Math.round(dm.lane * laneH + itemFont);
        if (appliedColor !== dm.renderColor) {
          this.ctx.fillStyle = dm.renderColor;
          appliedColor = dm.renderColor;
        }
        this.ctx.strokeText(dm.renderText, x, y);
        this.ctx.fillText(dm.renderText, x, y);
        keep.push(dm);
      } else {
        // 滚动弹幕：被冻结时停在当前位置不再前进。
        if (!frozen) dm.x -= dm.speed * deltaSec;
        if (!frozen && dm.x + dm.textWidth < -10) {
          continue;
        }
        const x: number = Math.round(dm.x);
        const y: number = Math.round(dm.lane * laneH + itemFont);
        if (appliedColor !== dm.renderColor) {
          this.ctx.fillStyle = dm.renderColor;
          appliedColor = dm.renderColor;
        }
        this.ctx.strokeText(dm.renderText, x, y);
        this.ctx.fillText(dm.renderText, x, y);
        keep.push(dm);
      }
    }
    this.ctx.globalAlpha = 1;
    this.activeBack = this.active;
    this.active = keep;
  }

  /**
   * mode 7 高级弹幕：按运动轨道插值定位绘制。
   * 返回 false 表示已过期（超过 delay+duration），调用方丢弃。
   * 缓动采用 DFM 同款 quadratic easeOut（-t*(t-2)）。
   */
  private drawSpecial(dm: ActiveDm, now: number): boolean {
    const track: SpecialTrack = dm.special as SpecialTrack;
    const elapsedMs: number = (now - dm.born) * 1000;
    if (elapsedMs < track.delayMs) {
      return true; // 延迟中，未到出场时间
    }
    const t0: number = elapsedMs - track.delayMs;
    if (t0 > track.durationMs) {
      return false;
    }
    let progress: number = t0 / track.durationMs;
    if (track.easeOut) {
      progress = -progress * (progress - 2);
    }
    progress = Math.max(0, Math.min(1, progress));
    const x: number = Math.round((track.fromX + (track.toX - track.fromX) * progress) * this.width);
    const y: number = Math.round((track.fromY + (track.toY - track.fromY) * progress) * this.height);
    this.ctx.save();
    this.ctx.translate(x, y);
    if (track.rotateZ !== 0) {
      this.ctx.rotate(track.rotateZ * Math.PI / 180);
    }
    this.ctx.font = '600 ' + String(dm.fontSizePx) + 'px sans-serif';
    this.ctx.fillStyle = dm.renderColor;
    this.ctx.strokeText(dm.renderText, 0, 0);
    this.ctx.fillText(dm.renderText, 0, 0);
    this.ctx.restore();
    return true;
  }

  resetAt(time: number): void {
    this.lastPlayerTime = time;
    this.clearActive();
    this.syncCursor(time);
  }

  setSpeed(value: number): void {
    this.speed = value;
    this.refreshScrollSpeeds();
  }

  setPlaybackRate(value: number): void {
    this.playbackRate = value;
    this.refreshScrollSpeeds();
  }

  private scrollSpeedFactor(): number {
    return Math.max(0.5, this.speed) * Math.max(0.1, this.playbackRate);
  }

  private refreshScrollSpeeds(): void {
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (!dm.isFixed && dm.special === null) {
        const spawnInset: number = Math.max(10, this.fontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
        dm.speed = (this.width + spawnInset + dm.textWidth) / travelSeconds;
      }
    }
  }

  setFontScale(value: number): void {
    this.fontScale = value;
    this.textWidthCache.clear();
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (dm.special !== null) {
        const track: SpecialTrack = dm.special;
        dm.fontSizePx = Math.max(14, Math.min(90, track.sizePct / 100 * this.height));
      } else {
        dm.fontSizePx = this.sizeFor(dm.item);
      }
      dm.textWidth = this.measure(dm.renderText, dm.fontSizePx);
      if (!dm.isFixed && dm.special === null) {
        const spawnInset: number = Math.max(10, this.fontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
        dm.speed = (this.width + spawnInset + dm.textWidth) / travelSeconds;
      }
    }
    const laneCount: number = this.laneCount();
    this.clampDanmakuLanes(laneCount);
    this.drawFrame(false);
  }

  setDensity(value: number): void {
    const oldLaneCount: number = this.laneCount();
    this.density = Math.round(value);
    const newLaneCount: number = this.laneCount();
    if (newLaneCount !== oldLaneCount) this.clampDanmakuLanes(newLaneCount);
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
        (isBottom && this.blockBottomDm) || (this.blockColorDm && dm.item.color !== 16777215) ||
        dm.item.weight < this.minWeight) continue;
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

  /** 默认字号（竖屏 38 / 全屏 48）；行高单独由 lineHeight 控制，不再用大间距假装字号。 */
  private fontSize(): number {
    return (this.fullscreen ? 48 : 38) * this.fontScale;
  }

  private lineHeight(): number {
    // 以旧默认字号作为行高基准；超出部分只按 50% 计入行高（次线性），
    // 让新默认字号更大而轨道仍紧凑，用户继续放大时轨道数也不会骤减。
    const base: number = this.fullscreen ? 44 : 34;
    const extra: number = this.fontSize() - base;
    const normalHeight: number = base + 2 + (extra > 0 ? extra * 0.5 : extra);
    // 高密度优先增加纵向轨道，而不是把大量弹幕重复塞进少数基线。
    // 普通档也收紧约 10%，配合更大的默认字号消除“字小但轨道很空”的观感；
    // 高密度档继续保持原有轨道数量，不因字号增大重新变回少轨道。
    const densityFactor: number = this.density >= 30 ? 0.68 : (this.density >= 27 ? 0.82 : 0.90);
    return Math.max(this.fontSize() * 0.68, normalHeight * densityFactor);
  }

  private laneCount(): number {
    // 弹幕覆盖画面约 94%（对齐 B 站密度观感），只给进度条/字幕留一条窄安全区。
    const usableHeight: number = Math.max(this.lineHeight(), this.height * 0.94);
    return Math.max(1, Math.floor(usableHeight / this.lineHeight()));
  }

  private maxActive(): number {
    const byDensity: number = this.fullscreen ? this.density * 4 : this.density * 3;
    const byLane: number = this.laneCount() * (this.fullscreen ? 8 : 6);
    return Math.max(5, Math.min(this.fullscreen ? 96 : 64, byDensity, byLane));
  }

  private laneSafeForScroll(lane: number, spawnX: number, newSpeed: number): boolean {
    const minimumGap: number = Math.max(18, this.fontSize() * 0.62);
    const bucket: Array<ActiveDm> = this.laneBucket(lane);
    for (let i: number = 0; i < bucket.length; i++) {
      const current: ActiveDm = bucket[i];
      // 固定弹幕仍占据同一条视觉轨道，滚动弹幕不能从它下面穿过；
      // 逆向弹幕与正向同轨会对向相撞，同样拒绝。
      if (current.isFixed || current.reverse) return false;
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

  /** 逆向弹幕（mode 6，从左向右）的镜像安全判断：tail 在左、head 在右。 */
  private laneSafeForReverse(lane: number, spawnTail: number, newSpeed: number): boolean {
    const minimumGap: number = Math.max(18, this.fontSize() * 0.62);
    const bucket: Array<ActiveDm> = this.laneBucket(lane);
    for (let i: number = 0; i < bucket.length; i++) {
      const current: ActiveDm = bucket[i];
      // 固定弹幕与正向弹幕都不能与逆向弹幕同轨。
      if (current.isFixed || !current.reverse) return false;
      const currentHead: number = current.x;
      // 新弹幕 tail 已越过同轨前辈 head（镜像间距不足）。
      if (spawnTail + minimumGap > currentHead) return false;
      if (newSpeed > current.speed + 0.01) {
        const catchSeconds: number = (currentHead - spawnTail - minimumGap) / (newSpeed - current.speed);
        const currentExitSeconds: number = Math.max(0, (this.width - currentHead + minimumGap) / Math.max(1, current.speed));
        if (catchSeconds < currentExitSeconds) return false;
      }
    }
    return true;
  }

  private allocReverseLane(spawnTail: number, speed: number): number {
    const laneCount: number = this.laneCount();
    for (let offset: number = 0; offset < laneCount; offset++) {
      const lane: number = (this.nextScrollLane + offset) % laneCount;
      if (this.laneSafeForReverse(lane, spawnTail, speed)) {
        this.nextScrollLane = (lane + 1) % laneCount;
        return lane;
      }
    }
    // “重叠”档的语义是宁可复用弹道也不丢掉当前弹幕；正常/较多档仍坚持防碰撞。
    if (this.density >= 30) {
      const lane: number = this.nextScrollLane % laneCount;
      this.nextScrollLane = (lane + 1) % laneCount;
      return lane;
    }
    return -1;
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
    if (this.density >= 30) {
      const lane: number = this.nextScrollLane % laneCount;
      this.nextScrollLane = (lane + 1) % laneCount;
      return lane;
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
      // 顶部、底部和滚动弹幕共用视觉轨道，彻底避免模式间互相覆盖。
      const available: boolean = this.laneBucket(lane).length === 0;
      if (available) {
        if (mode === 5) this.nextTopLane = (relative + 1) % candidateCount;
        else this.nextBottomLane = (relative + 1) % candidateCount;
        return lane;
      }
    }
    if (this.density >= 30) {
      const relative: number = start % candidateCount;
      const lane: number = mode === 5 ? relative : laneCount - 1 - relative;
      if (mode === 5) this.nextTopLane = (relative + 1) % candidateCount;
      else this.nextBottomLane = (relative + 1) % candidateCount;
      return lane;
    }
    return -1;
  }

  /** 逐条字号：B 站 18/25/36 档按 25 为基准缩放，再叠用户字号缩放。 */
  private sizeFor(item: DanmakuItem): number {
    const factor: number = item.fontsize > 0 ? item.fontsize / 25 : 1;
    return this.fontSize() * Math.max(0.6, Math.min(1.8, factor));
  }

  private measure(text: string, sizePx: number): number {
    const key: string = String(Math.round(sizePx * 10)) + ':' + text;
    const cached: number | undefined = this.textWidthCache.get(key);
    if (cached !== undefined) return cached;
    this.ctx.font = '600 ' + sizePx + 'px sans-serif';
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

  private rebuildLaneBuckets(): void {
    const count: number = this.laneCount();
    while (this.laneBuckets.length < count) this.laneBuckets.push([]);
    for (let i: number = 0; i < this.laneBuckets.length; i++) this.laneBuckets[i].length = 0;
    for (let i: number = 0; i < this.active.length; i++) this.addToLaneBucket(this.active[i]);
  }

  private laneBucket(lane: number): Array<ActiveDm> {
    while (this.laneBuckets.length <= lane) this.laneBuckets.push([]);
    return this.laneBuckets[lane];
  }

  private addToLaneBucket(dm: ActiveDm): void {
    if (dm.special !== null || dm.lane < 0) return;
    this.laneBucket(dm.lane).push(dm);
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
