import { DanmakuItem } from '../api/BiliApi';

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
