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

/** 重叠档的绝对同屏上限：只在极端堆积（远超 QA 钉住的 180 条契约）时兜底帧预算。 */
const OVERLAP_HARD_CAP: number = 240;

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
/** 重复弹幕合并的聚类时间窗（秒）：与 pakku 默认量级一致。 */
const MERGE_WINDOW_SECONDS: number = 6;

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
  spacing: number = 1;
  density: number = 22;
  fullscreen: boolean = false;
  enabled: boolean = true;
  blockScrollDm: boolean = false;
  blockTopDm: boolean = false;
  blockBottomDm: boolean = false;
  blockColorDm: boolean = false;
  /** 相同文本 6 秒窗内合并为一簇（只喷最早一条）。 */
  mergeDuplicates: boolean = false;
  /** 合并簇在喷出时显示 ×N 计数后缀。 */
  showMergeCount: boolean = true;
  /** 智能云屏蔽等级 0-10：weight 低于该值的弹幕不喷出（B 站 app 同款，0 为关闭）。 */
  minWeight: number = 0;
  /** 有序弹幕列表消费游标。 */
  cursor: number = 0;
  /** 被点击"停住"的弹幕：绘制暂停（不前进、不过期），等待用户点赞/复制/举报后解冻。 */
  pinned: ActiveDm | null = null;

  private ctx: CanvasRenderingContext2D;
  /** 保留未合并的有序数据，设置变化可以原地重建，不依赖再次请求已缓存的分段。 */
  private sourceList: Array<DanmakuItem> | null = null;
  private localItems: Array<DanmakuItem> = [];
  private readonly localTokens: Set<number> = new Set<number>();
  private readonly localEchoConsumed: Set<DanmakuItem> = new Set<DanmakuItem>();
  private consumedBeforeMerge: Set<DanmakuItem> = new Set<DanmakuItem>();
  lastDrawMs: number = 0;
  private nextScrollLane: number = 0;
  private nextTopLane: number = 0;
  private nextBottomLane: number = 0;
  // drawFrame 双缓冲，避免每帧分配 keep 数组。
  private activeBack: Array<ActiveDm> = [];
  private textWidthCache: Map<string, number> = new Map<string, number>();
  private textBottomCache: Map<string, number> = new Map<string, number>();
  private colorCache: Map<number, string> = new Map<number, string>();
  /** 每次 spawn 只构建一次弹道桶，避免每个候选轨道都扫描完整 active 数组。 */
  private laneBuckets: Array<Array<ActiveDm>> = [];

  constructor(ctx: CanvasRenderingContext2D) {
    this.ctx = ctx;
  }

  setList(list: Array<DanmakuItem>): void {
    // seg.so 的条目按服务端选择顺序返回，不能直接交给二分游标和时间线消费。
    this.sourceList = this.remoteWithoutLocal(list).concat(this.localItems)
      .sort((a: DanmakuItem, b: DanmakuItem): number => a.time - b.time);
    this.list = this.applyMerge(this.sourceList);
    this.syncCursor(this.lastPlayerTime);
  }

  /** Source changes clear local confirmations; ordinary late server lists keep them. */
  resetList(): void {
    this.localItems = [];
    this.localTokens.clear();
    this.localEchoConsumed.clear();
    this.consumedBeforeMerge.clear();
    this.sourceList = [];
    this.list = [];
    this.cursor = 0;
    this.lastPlayerTime = 0;
    this.clearActive();
  }

  private remoteWithoutLocal(items: Array<DanmakuItem>): Array<DanmakuItem> {
    return items.filter((item: DanmakuItem): boolean => !this.localItems.some((local: DanmakuItem): boolean =>
      local === item || (local.idStr.length > 0 && local.idStr === item.idStr)));
  }

  setMergeDuplicates(enabled: boolean): void {
    const consumed: Set<DanmakuItem> = new Set<DanmakuItem>();
    for (const item of this.consumedBeforeMerge) consumed.add(item);
    for (let i: number = 0; i < this.cursor; i++) consumed.add(this.list[i]);
    this.mergeDuplicates = enabled;
    if (this.sourceList === null) this.sourceList = this.list.slice();
    this.list = this.applyMerge(this.sourceList);
    this.syncCursor(this.lastPlayerTime);
    this.consumedBeforeMerge = consumed;
  }

  /** 重复弹幕合并：相同文本在窗口内只保留最早一条，计数累加到簇头。 */
  private applyMerge(items: Array<DanmakuItem>): Array<DanmakuItem> {
    for (const item of items) item.mergeCount = 1;
    if (!this.mergeDuplicates || items.length === 0) return items.slice();
    const out: Array<DanmakuItem> = [];
    const heads: Map<string, DanmakuItem> = new Map();
    for (let i: number = 0; i < items.length; i++) {
      const item: DanmakuItem = items[i];
      // A confirmed sender preview stays independent of older identical remote comments.
      if (this.localItems.indexOf(item) >= 0) {
        out.push(item);
        continue;
      }
      const head: DanmakuItem | undefined = heads.get(item.text);
      if (head !== undefined && item.time - head.time <= MERGE_WINDOW_SECONDS) {
        head.mergeCount++;
        continue;
      }
      item.mergeCount = 1;
      heads.set(item.text, item);
      out.push(item);
    }
    return out;
  }

  /** 喷出文本：簇计数开启时为合并弹幕附加 ×N 后缀。 */
  private renderTextFor(item: DanmakuItem): string {
    const base: string = item.text.length > 80 ? item.text.substring(0, 79) + '…' : item.text;
    if (this.showMergeCount && item.mergeCount > 1) return base + ' ×' + String(item.mergeCount);
    return base;
  }

  /** 把分段弹幕合并进全局有序列表，并把游标推到播放头之后，避免重放已喷出的弹幕。 */
  appendSorted(segment: Array<DanmakuItem>): void {
    const items: Array<DanmakuItem> = this.remoteWithoutLocal(segment);
    if (items.length === 0) return;
    const pending: DanmakuItem | null = this.cursor < this.list.length ? this.list[this.cursor] : null;
    const previous: Array<DanmakuItem> = this.sourceList ?? this.list;
    // 服务端分段可能无序；排序新段，再与旧列表线性归并。
    let incoming: Array<DanmakuItem> = items;
    for (let i: number = 1; i < items.length; i++) {
      if (items[i - 1].time > items[i].time) {
        incoming = items.slice();
        incoming.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time);
        break;
      }
    }
    const merged: Array<DanmakuItem> = new Array<DanmakuItem>(previous.length + incoming.length);
    let oldIndex: number = 0;
    let newIndex: number = 0;
    let mergedIndex: number = 0;
    while (oldIndex < previous.length && newIndex < incoming.length) {
      if (previous[oldIndex].time <= incoming[newIndex].time) {
        merged[mergedIndex++] = previous[oldIndex++];
      } else {
        merged[mergedIndex++] = incoming[newIndex++];
      }
    }
    while (oldIndex < previous.length) merged[mergedIndex++] = previous[oldIndex++];
    while (newIndex < incoming.length) merged[mergedIndex++] = incoming[newIndex++];
    this.sourceList = merged;
    this.list = this.applyMerge(merged);
    const guard: number = this.lastPlayerTime + 0.1;
    let low: number = 0;
    let high: number = this.list.length;
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.list[middle].time <= guard) low = middle + 1;
      else high = middle;
    }
    this.cursor = low;
    // 预取不应消费旧列表里尚未调度的当前弹幕；它们仍受 spawn 的正常延迟窗口约束。
    if (pending !== null && pending.time >= this.lastPlayerTime - MAX_SPAWN_LATENCY_SECONDS) {
      const pendingIndex: number = this.list.indexOf(pending);
      if (pendingIndex >= 0) this.cursor = Math.min(this.cursor, pendingIndex);
    }
  }

  /** Store the submitted timestamp, but show its confirmation immediately at the current playhead. */
  insertLocal(item: DanmakuItem, now: number = this.lastPlayerTime, token: number = 0): boolean {
    if (!Number.isFinite(item.time) || item.time < 0 || !Number.isFinite(now) || now < 0 || item.text.length === 0) return false;
    if (token > 0 && this.localTokens.has(token)) return false;
    if (token > 0) this.localTokens.add(token);
    if (this.localItems.some((local: DanmakuItem): boolean => local === item ||
      (item.idStr.length > 0 && local.idStr === item.idStr))) return false;
    let prior: ActiveDm | undefined = undefined;
    if (item.idStr.length > 0) {
      // A segment response can precede the send acknowledgement; unify both directions by precise ID.
      prior = this.pinned !== null && this.pinned.item.idStr === item.idStr ? this.pinned :
        this.active.find((dm: ActiveDm): boolean => dm.item.idStr === item.idStr);
      let removedBeforeCursor: number = 0;
      this.list = this.list.filter((remote: DanmakuItem, index: number): boolean => {
        if (remote.idStr !== item.idStr) return true;
        if (index < this.cursor) removedBeforeCursor++;
        this.consumedBeforeMerge.delete(remote);
        return false;
      });
      this.cursor = Math.max(0, this.cursor - removedBeforeCursor);
      if (this.sourceList !== null) this.sourceList = this.sourceList.filter((remote: DanmakuItem): boolean => remote.idStr !== item.idStr);
    }
    this.localItems.push(item);
    if (this.sourceList === null) this.sourceList = this.list.slice();
    let rawIndex: number = this.sourceList.length;
    while (rawIndex > 0 && this.sourceList[rawIndex - 1].time > item.time) rawIndex--;
    this.sourceList.splice(rawIndex, 0, item);
    let low: number = 0;
    let high: number = this.list.length;
    while (low < high) {
      const middle: number = Math.floor((low + high) / 2);
      if (this.list[middle].time <= item.time) low = middle + 1;
      else high = middle;
    }
    this.list.splice(low, 0, item);
    if (low < this.cursor) this.cursor++;
    if (!this.enabled || item.mode !== 1 || this.blockScrollDm ||
      (this.blockColorDm && item.color !== 16777215) || item.weight < this.minWeight) return false;
    if (item.idStr.length > 0) this.active = this.active.filter((dm: ActiveDm): boolean => dm.item.idStr !== item.idStr);
    this.lastPlayerTime = now;
    this.localEchoConsumed.add(item);
    this.rebuildLaneBuckets();
    const size: number = this.sizeFor(item);
    const text: string = this.renderTextFor(item);
    const textWidth: number = this.measure(text, size);
    // Pause must show actual pixels now, rather than a comment waiting outside the right edge.
    const x: number = Math.max(4, this.width - textWidth - 12);
    const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
    const speed: number = (this.width + Math.max(10, size * 0.3) + textWidth) / travelSeconds;
    let lane: number = this.allocLane(x, speed, size, text);
    if (lane < 0) {
      // Sender confirmation gets one lane even when the incoming remote burst occupies every lane.
      const laneCount: number = this.laneCount(size, text);
      lane = this.nextScrollLane % laneCount;
      this.nextScrollLane = (lane + 1) % laneCount;
    }
    if (this.active.length >= this.maxActive()) {
      const oldest: number = this.active.findIndex((dm: ActiveDm): boolean => dm !== this.pinned);
      if (oldest >= 0) this.active.splice(oldest, 1);
    }
    const active: ActiveDm = prior ?? new ActiveDm(item, x, lane, speed, 0, false, now, textWidth, text, this.colorFor(item.color));
    active.item = item;
    if (active !== this.pinned) {
      active.x = x;
      active.lane = lane;
    }
    active.speed = speed;
    active.fixedUntil = 0;
    active.isFixed = false;
    active.born = now;
    active.textWidth = textWidth;
    active.renderText = text;
    active.renderColor = this.colorFor(item.color);
    active.reverse = false;
    active.special = null;
    active.fontSizeVp = size;
    this.active.push(active);
    this.drawFrame(false);
    return true;
  }

  /**
   * 视口尺寸变化。
   * 只更新宽高几何，不在此立即全量重绘：
   * - 滚动弹幕的 x 由渲染循环每帧推进没有缓存概念，宽度变化自然被下一帧吸收；
   * - 固定弹幕的横坐标在 drawFrame 中按当前 width 实时计算（width - textWidth）/2，同样无需重排；
   * - 默认轨道数量变化或高度缩小时，按每条文字的可见下沿 clamp，避免大字号末行截字；
   *   宽度变化无需重排，避免切换/缩放过程中
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
    const oldHeight: number = this.height;
    this.width = newW;
    this.height = newH;
    const newLanes: number = this.laneCount();
    if (newLanes !== oldLanes || newH < oldHeight) {
      this.clampDanmakuLanes();
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
    this.textBottomCache.clear();
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
      const itemFont: number = dm.fontSizeVp > 0 ? dm.fontSizeVp : this.fontSize();
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
    const fs: number = dm.fontSizeVp > 0 ? dm.fontSizeVp : this.fontSize();
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
      this.ctx.font = '600 ' + fs + 'vp sans-serif';
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

    // 密度由可用轨道和用户选择决定；重叠档不再套用固定的 96/64 条上限。
    const maxActive: number = this.maxActive();
    this.rebuildLaneBuckets();
    while (this.cursor < this.list.length && this.list[this.cursor].time <= now + 0.1) {
      // 当前屏已满时等待空位；下次调度会先丢弃届时已过期的项，不让它们积压到后续时间点。
      if (this.active.length >= maxActive) {
        break;
      }
      const item: DanmakuItem = this.list[this.cursor];
      this.cursor++;
      if (this.consumedBeforeMerge.has(item) || this.localEchoConsumed.has(item)) continue;
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
          dm.fontSizeVp = Math.max(8, Math.min(60, special.sizePct / 100 * this.height));
          dm.textWidth = this.measure(dm.renderText, dm.fontSizeVp);
          this.active.push(dm);
          continue;
        }
        // JSON 解析失败按普通滚动弹幕兜底（脏数据不丢弹幕）。
      }
      const sizeVp: number = this.sizeFor(item);
      const renderText: string = this.renderTextFor(item);
      const textW: number = this.measure(renderText, sizeVp);
      const renderColor: string = this.colorFor(item.color);
      if (item.mode === 4 || item.mode === 5) {
        // 固定弹幕：顶部/底部居中，停留 4 秒
        const fixedLane: number = this.allocFixedLane(item.mode, sizeVp, renderText);
        if (fixedLane < 0) continue;
        const dm: ActiveDm = new ActiveDm(item, -1, fixedLane, 0, now + 4, true, now, textW, renderText, renderColor);
        dm.fontSizeVp = sizeVp;
        this.active.push(dm);
        this.addToLaneBucket(dm);
      } else if (item.mode === 6) {
        // 逆向滚动弹幕（mode 6）：从左向右过屏，与正向分轨（避免对向相撞）。
        const textWm: number = textW;
        const spawnX: number = -textWm - Math.max(10, sizeVp * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
        const speed: number = (this.width - spawnX) / travelSeconds;
        const lane: number = this.allocReverseLane(spawnX + textWm, speed, sizeVp, renderText);
        if (lane < 0) continue;
        const dm: ActiveDm = new ActiveDm(item, spawnX, lane, speed, 0, false, now, textWm, renderText, renderColor);
        dm.reverse = true;
        dm.fontSizeVp = sizeVp;
        this.active.push(dm);
        this.addToLaneBucket(dm);
      } else {
        // 所有弹幕保持近似相同的过屏时间；长文本虽然速度更快，但分轨时会预判追尾。
        const spawnX: number = this.width + Math.max(10, sizeVp * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
        const speed: number = (spawnX + textW) / travelSeconds;
        const lane: number = this.allocLane(spawnX, speed, sizeVp, renderText);
        if (lane < 0) continue;
        const dm: ActiveDm = new ActiveDm(item, spawnX, lane, speed, 0, false, now, textW, renderText, renderColor);
        dm.fontSizeVp = sizeVp;
        this.active.push(dm);
        this.addToLaneBucket(dm);
      }
      if (this.localItems.indexOf(item) >= 0) this.localEchoConsumed.add(item);
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
    this.ctx.font = '600 ' + fontSize + 'vp sans-serif';
    this.ctx.strokeStyle = '#B3000000';
    this.ctx.lineWidth = this.fullscreen ? 0.8 : 0.7;
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
      const itemFont: number = dm.fontSizeVp > 0 ? dm.fontSizeVp : fontSize;
      // 同字号弹幕占绝大多数，避免每条都重复触发 Canvas 字体解析。
      if (Math.abs(itemFont - appliedFont) > 0.01) {
        this.ctx.font = '600 ' + itemFont + 'vp sans-serif';
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
    this.ctx.font = '600 ' + String(dm.fontSizeVp) + 'vp sans-serif';
    this.ctx.fillStyle = dm.renderColor;
    this.ctx.strokeText(dm.renderText, 0, 0);
    this.ctx.fillText(dm.renderText, 0, 0);
    this.ctx.restore();
    return true;
  }

  resetAt(time: number): void {
    this.localEchoConsumed.clear();
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
    this.textBottomCache.clear();
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (dm.special !== null) {
        const track: SpecialTrack = dm.special;
        dm.fontSizeVp = Math.max(8, Math.min(60, track.sizePct / 100 * this.height));
      } else {
        dm.fontSizeVp = this.sizeFor(dm.item);
      }
      dm.textWidth = this.measure(dm.renderText, dm.fontSizeVp);
      if (!dm.isFixed && dm.special === null) {
        const spawnInset: number = Math.max(10, this.fontSize() * 0.3);
        const travelSeconds: number = (this.fullscreen ? 10 : 8.5) / this.scrollSpeedFactor();
        dm.speed = (this.width + spawnInset + dm.textWidth) / travelSeconds;
      }
    }
    this.clampDanmakuLanes();
    this.drawFrame(false);
  }

  setSpacing(value: number): void {
    this.spacing = Math.max(0.5, Math.min(2, value));
    this.clampDanmakuLanes();
    this.drawFrame(false);
  }

  setDensity(value: number): void {
    this.density = Math.round(value);
    this.clampDanmakuLanes();
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
    this.consumedBeforeMerge.clear();
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

  /** 默认字号与 Canvas 坐标同为 vp；手机全屏约 47px，竖屏约 40px。 */
  private fontSize(): number {
    return (this.fullscreen ? 14 : 12) * this.fontScale;
  }

  private lineHeight(): number {
    // Canvas 坐标和字体统一为 vp，避免 px 字号被当成 vp 行距后在高密度屏上放大空隙。
    const factor: number = this.density >= 30 ? 0.95 : (this.density >= 27 ? 1.05 : 1.15);
    return this.fontSize() * (factor + (this.spacing - 1) * 0.4);
  }

  private laneCount(sizeVp: number = 0, text: string = ''): number {
    const size: number = sizeVp > 0 ? sizeVp : this.fontSize();
    const key: string = String(Math.round(size * 10)) + ':' + text;
    let measuredBottom: number | undefined = this.textBottomCache.get(key);
    if (measuredBottom === undefined && text.length > 0) {
      // 旋转重排时旧弹幕的测量缓存可能已被淘汰，重新测量后才能保护真实下伸部。
      this.measure(text, size);
      measuredBottom = this.textBottomCache.get(key);
    }
    // 覆盖完整画布；轨道步进之外只扣除文字从轨道顶到下沿的高度。
    // 每条使用自身字号/下伸部，额外 1vp 容纳描边和绘制坐标取整，防止末行截字。
    const bottom: number = (measuredBottom ?? size * 1.2) + 1;
    const steps: number = Math.max(0, this.height - bottom);
    return Math.max(1, Math.floor(steps / this.lineHeight()) + 1);
  }

  private maxActive(): number {
    // 所有当前时间的候选都可上屏，保留时间窗口和用户屏蔽规则。
    // 重叠档不设密度上限是产品契约（QA 钉住 180 条同屏全显），但为极端堆积兜底一个
    // 安全阀：240 条以上每帧描边+填充的绘制成本会把帧时间顶出预算，新弹幕从下一段再进。
    if (this.density >= 30) return Math.min(this.list.length + this.active.length, OVERLAP_HARD_CAP);
    return this.laneCount() * (this.density >= 27 ? 10 : 6);
  }

  private laneSafeForScroll(lane: number, spawnX: number, newSpeed: number): boolean {
    const minimumGap: number = Math.max(1, this.fontSize() * (this.density >= 27 ? 0.15 : 0.3) * this.spacing);
    const bucket: Array<ActiveDm> = this.laneBucket(lane);
    for (let i: number = 0; i < bucket.length; i++) {
      const current: ActiveDm = bucket[i];
      // 固定和滚动使用独立的分轨规则；固定字幕不应封锁整条滚动轨道。
      if (current.isFixed) continue;
      if (current.reverse) return false;
      const currentTail: number = current.x + current.textWidth;
      if (currentTail + minimumGap > spawnX) return false;
      if (this.density < 27 && newSpeed > current.speed + 0.01) {
        const catchSeconds: number = (spawnX - currentTail - minimumGap) / (newSpeed - current.speed);
        const currentExitSeconds: number = Math.max(0, (currentTail + minimumGap) / Math.max(1, current.speed));
        if (catchSeconds < currentExitSeconds) return false;
      }
    }
    return true;
  }

  /** 逆向弹幕（mode 6，从左向右）的镜像安全判断：tail 在左、head 在右。 */
  private laneSafeForReverse(lane: number, spawnTail: number, newSpeed: number): boolean {
    const minimumGap: number = Math.max(1, this.fontSize() * (this.density >= 27 ? 0.15 : 0.3) * this.spacing);
    const bucket: Array<ActiveDm> = this.laneBucket(lane);
    for (let i: number = 0; i < bucket.length; i++) {
      const current: ActiveDm = bucket[i];
      if (current.isFixed) continue;
      if (!current.reverse) return false;
      const currentHead: number = current.x;
      // 新弹幕 tail 已越过同轨前辈 head（镜像间距不足）。
      if (spawnTail + minimumGap > currentHead) return false;
      if (this.density < 27 && newSpeed > current.speed + 0.01) {
        const catchSeconds: number = (currentHead - spawnTail - minimumGap) / (newSpeed - current.speed);
        const currentExitSeconds: number = Math.max(0, (this.width - currentHead + minimumGap) / Math.max(1, current.speed));
        if (catchSeconds < currentExitSeconds) return false;
      }
    }
    return true;
  }

  private allocReverseLane(spawnTail: number, speed: number, sizeVp: number, text: string): number {
    const laneCount: number = this.laneCount(sizeVp, text);
    for (let offset: number = 0; offset < laneCount; offset++) {
      const lane: number = (this.nextScrollLane + offset) % laneCount;
      if (this.laneSafeForReverse(lane, spawnTail, speed)) {
        this.nextScrollLane = (lane + 1) % laneCount;
        return lane;
      }
    }
    // 重叠档在无空轨道时继续分配；正常/较多档仍保留入场间距。
    if (this.density >= 30) {
      const lane: number = this.nextScrollLane % laneCount;
      this.nextScrollLane = (lane + 1) % laneCount;
      return lane;
    }
    return -1;
  }

  private allocLane(spawnX: number, speed: number, sizeVp: number, text: string): number {
    const laneCount: number = this.laneCount(sizeVp, text);
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

  private allocFixedLane(mode: number, sizeVp: number, text: string): number {
    const laneCount: number = this.laneCount(sizeVp, text);
    const candidateCount: number = laneCount;
    const start: number = mode === 5 ? this.nextTopLane : this.nextBottomLane;
    for (let offset: number = 0; offset < candidateCount; offset++) {
      const relative: number = (start + offset) % candidateCount;
      const lane: number = mode === 5 ? relative : laneCount - 1 - relative;
      // 顶/底固定弹幕可铺开整个显示区域，不再限于三行；滚动弹幕不占固定槽位。
      const available: boolean = !this.laneBucket(lane).some((dm: ActiveDm) => dm.isFixed);
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

  private measure(text: string, sizeVp: number): number {
    const key: string = String(Math.round(sizeVp * 10)) + ':' + text;
    const cached: number | undefined = this.textWidthCache.get(key);
    if (cached !== undefined) return cached;
    this.ctx.font = '600 ' + sizeVp + 'vp sans-serif';
    const metrics: TextMetrics = this.ctx.measureText(text);
    const w: number = metrics.width;
    const descent: number = Number(metrics.actualBoundingBoxDescent);
    this.textBottomCache.set(key, sizeVp + (Number.isFinite(descent) && descent >= 0 ? descent : sizeVp * 0.2));
    const result: number = Math.max(20, w);
    if (this.textWidthCache.size > 512) {
      // 整体清空会造成短时间内大量重复测量；改为淘汰最早插入的一半（Map 迭代序即插入序）。
      let evict: number = 256;
      for (const oldest of this.textWidthCache.keys()) {
        if (evict <= 0) break;
        this.textWidthCache.delete(oldest);
        this.textBottomCache.delete(oldest);
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
  private clampDanmakuLanes(): void {
    const used: Set<number> = new Set<number>();
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (dm.special !== null) continue;
      const laneCount: number = this.laneCount(dm.fontSizeVp, dm.renderText);
      if (dm.lane < laneCount) used.add(dm.lane);
    }
    for (let i: number = 0; i < this.active.length; i++) {
      const dm: ActiveDm = this.active[i];
      if (dm.special !== null) continue;
      const laneCount: number = this.laneCount(dm.fontSizeVp, dm.renderText);
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
