import { DanmakuItem } from '../../api/BiliApi';

/** mode 7 高级弹幕的运动轨道（B 站实样格式：[fromX,fromY,"1-1",size,text,rz,ry,toX,toY,duration,delay,ease,font,?]）。 */
export class SpecialTrack {
  fromX: number = 0;   // 起点 x（0-1 视口比例）
  fromY: number = 0;
  toX: number = 0;     // 终点 x
  toY: number = 0;
  sizePct: number = 4; // 字号（视口高度百分比，实样 3~6）
  rotateZ: number = 0; // 2D 旋转角（度）
  durationMs: number = 3000;
  delayMs: number = 0;
  easeOut: boolean = true;
}
/** 单条已进入画布的弹幕运行态。 */
export class ActiveDm {
  item: DanmakuItem;
  x: number;
  lane: number;
  speed: number;
  fixedUntil: number;
  isFixed: boolean;
  born: number;
  textWidth: number;
  renderText: string;
  renderColor: string;
  /** 逆向滚动（mode 6）：x 从左向右推进。 */
  reverse: boolean = false;
  /** 高级弹幕（mode 7）运动轨道；非 null 时 x/lane/speed 不参与绘制。 */
  special: SpecialTrack | null = null;
  /** 本条实际绘制字号（逐条字号：18/25/36 档 × 用户缩放）。 */
  fontSizePx: number = 0;

  constructor(item: DanmakuItem, x: number, lane: number, speed: number, fixedUntil: number, isFixed: boolean,
    born: number, textWidth: number, renderText: string, renderColor: string) {
    this.item = item;
    this.x = x;
    this.lane = lane;
    this.speed = speed;
    this.fixedUntil = fixedUntil;
    this.isFixed = isFixed;
    this.born = born;
    this.textWidth = textWidth;
    this.renderText = renderText;
    this.renderColor = renderColor;
  }
}

/**
 * 解析 mode 7 高级弹幕内容 JSON。成功返回 [显示文本, 轨道]，失败返回 null（按普通滚动兜底）。
 * 实样：[0.99,0.35,"1-1",3,"内容",0,0,0,0.35,3000,0,true,"幼圆",1]
 */
export function parseSpecialDanmaku(content: string): [string, SpecialTrack] | null {
  const trimmed: string = content.trim();
  if (!trimmed.startsWith('[')) return null;
  try {
    const arr: Array<Object> = JSON.parse(trimmed) as Array<Object>;
    if (arr.length < 11) return null;
    const track: SpecialTrack = new SpecialTrack();
    track.fromX = clamp01(toNum(arr[0], 0));
    track.fromY = clamp01(toNum(arr[1], 0));
    track.sizePct = Math.max(1, Math.min(12, toNum(arr[3], 4)));
    const text: string = String(arr[4] ?? '');
    if (text.length === 0) return null;
    track.rotateZ = toNum(arr[5], 0);
    track.toX = clamp01(toNum(arr[7], track.fromX));
    track.toY = clamp01(toNum(arr[8], track.fromY));
    track.durationMs = Math.max(500, Math.min(30000, toNum(arr[9], 3000)));
    track.delayMs = Math.max(0, Math.min(10000, toNum(arr[10], 0)));
    track.easeOut = arr.length > 11 ? Boolean(arr[11]) : true;
    return [text, track];
  } catch (e) {
    return null;
  }
}

function toNum(v: Object, fallback: number): number {
  const n: number = Number(v);
  return Number.isNaN(n) ? fallback : n;
}

function clamp01(v: number): number {
  // 高级弹幕坐标常见略超 0-1（贴边飞出），允许 ±0.2 余量。
  return Math.max(-0.2, Math.min(1.2, v));
}

export const CONTROLS_GRADIENT_COLORS: Array<[ResourceColor, number]> =
  [['#99000000', 0.0], ['#00000000', 0.35], ['#99000000', 1.0]];

/** protobuf 分段弹幕的段长（秒）：与 B 站网页端一致，每 6 分钟一段。 */
export const DM_SEGMENT_SECONDS: number = 360;

/** 弹幕整数颜色转 ArkUI #RRGGBB。 */
export function colorHex(color: number): string {
  const r: number = (color >> 16) & 0xff;
  const g: number = (color >> 8) & 0xff;
  const b: number = color & 0xff;
  const to2 = (n: number): string => {
    const s: string = n.toString(16);
    return s.length === 1 ? '0' + s : s;
  };
  return '#' + to2(r) + to2(g) + to2(b);
}
