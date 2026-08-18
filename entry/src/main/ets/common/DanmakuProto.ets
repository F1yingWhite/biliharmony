/**
 * 弹幕分段 protobuf 解码器：零依赖手写最小 wire-format 解析（varint / length-delimited / fixed 跳过）。
 * schema 对齐 PiliPlus lib/grpc/bilibili/community/service/dm/v1（bilibili-API-collect DanmakuElem）：
 * DmSegMobileReply { repeated DanmakuElem elems = 1; }
 * DanmakuElem { id=1, progress=2(毫秒), mode=3, fontsize=4, color=5, midHash=6, content=7, ctime=8, weight=9, ... }
 * 播放器只消费 time/mode/color/text，其余字段读进 ProtoDanmaku 供后续扩展。
 */
import { util } from '@kit.ArkTS';

/** 分段弹幕单条数据；time 已换算为秒，与 XML 解析结果（DanmakuItem）语义一致。 */
export class ProtoDanmaku {
  id: number = 0;       // int64，超过 2^53 会有精度损失；仅作是否存在判断，业务一律用 idStr
  idStr: string = '';   // dmid 十进制原串：点赞/举报必须用它，number 精度丢失会报“该弹幕已被删除”
  time: number = 0;     // 出现时间（秒）
  mode: number = 1;     // 1-3 滚动, 4 底部, 5 顶部
  fontsize: number = 25;
  color: number = 0xFFFFFF;
  midHash: string = '';
  text: string = '';
  ctime: number = 0;
  weight: number = 0;
}

/** 十进制串乘小整数（手算进位），供 varint 十进制展开用。 */
function decMulSmall(dec: string, m: number): string {
  if (m === 0 || dec === '0') {
    return '0';
  }
  let carry: number = 0;
  let out: string = '';
  for (let i: number = dec.length - 1; i >= 0; i--) {
    const v: number = (dec.charCodeAt(i) - 48) * m + carry;
    out = String.fromCharCode(48 + (v % 10)) + out;
    carry = Math.floor(v / 10);
  }
  while (carry > 0) {
    out = String.fromCharCode(48 + (carry % 10)) + out;
    carry = Math.floor(carry / 10);
  }
  return out;
}

/** 十进制串相加。 */
function decAdd(a: string, b: string): string {
  let i: number = a.length - 1;
  let j: number = b.length - 1;
  let carry: number = 0;
  let out: string = '';
  while (i >= 0 || j >= 0 || carry > 0) {
    const da: number = i >= 0 ? a.charCodeAt(i--) - 48 : 0;
    const db: number = j >= 0 ? b.charCodeAt(j--) - 48 : 0;
    const v: number = da + db + carry;
    out = String.fromCharCode(48 + (v % 10)) + out;
    carry = Math.floor(v / 10);
  }
  return out;
}

const WIRE_VARINT: number = 0;
const WIRE_FIXED64: number = 1;
const WIRE_LENGTH: number = 2;
const WIRE_FIXED32: number = 5;

/** 只读的 wire-format 游标；坏数据一律截断跳过，不抛异常。 */
class ProtoReader {
  private bytes: Uint8Array;
  private pos: number = 0;
  private limit: number = 0;

  constructor(bytes: Uint8Array, start: number, end: number) {
    this.bytes = bytes;
    this.pos = start;
    this.limit = Math.min(end, bytes.length);
  }

  eof(): boolean {
    return this.pos >= this.limit;
  }

  /** 读 varint；移位用乘法实现（位移运算只有 32 位），最多容纳 2^53 精度。 */
  /** 读 varint 并返回十进制原串：int64 dmid（约 3.5e16）超过 2^53，number 会丢尾数。 */
  readVarintString(): string {
    let decimal: string = '0';
    let power: string = '1'; // 128^i 的十进制串
    while (this.pos < this.limit) {
      const b: number = this.bytes[this.pos++];
      decimal = decAdd(decimal, decMulSmall(power, b & 0x7F));
      if ((b & 0x80) === 0) {
        return decimal;
      }
      power = decMulSmall(power, 128);
      if (power.length > 25) {
        break; // 坏数据保护：int64 varint 最多 10 字节
      }
    }
    return decimal;
  }
  readVarint(): number {
    let result: number = 0;
    let shift: number = 0;
    while (this.pos < this.limit) {
      const b: number = this.bytes[this.pos++];
      result += (b & 0x7F) * Math.pow(2, shift);
      if ((b & 0x80) === 0) {
        return result;
      }
      shift += 7;
      if (shift > 70) {
        break; // 坏数据保护：varint 不可能超过 10 字节
      }
    }
    return result;
  }

  /** 读 length-delimited 字段的字节区间；越界时截断到缓冲区末尾。 */
  readBytes(): Uint8Array {
    const length: number = this.readVarint();
    const end: number = Math.min(this.pos + length, this.limit);
    const out: Uint8Array = this.bytes.subarray(this.pos, end);
    this.pos = end;
    return out;
  }

  /** 跳过未知字段，保证 schema 演进兼容。 */
  skip(wire: number): void {
    if (wire === WIRE_VARINT) {
      this.readVarint();
    } else if (wire === WIRE_FIXED64) {
      this.pos = Math.min(this.pos + 8, this.limit);
    } else if (wire === WIRE_LENGTH) {
      this.pos = Math.min(this.pos + this.readVarint(), this.limit);
    } else if (wire === WIRE_FIXED32) {
      this.pos = Math.min(this.pos + 4, this.limit);
    } else {
      this.pos = this.limit; // 组类型等不再使用，直接终止该消息
    }
  }
}

function parseDanmakuElem(bytes: Uint8Array): ProtoDanmaku {
  const reader: ProtoReader = new ProtoReader(bytes, 0, bytes.length);
  const item: ProtoDanmaku = new ProtoDanmaku();
  let content: string = '';
  while (!reader.eof()) {
    const tag: number = reader.readVarint();
    const field: number = tag >> 3;
    const wire: number = tag & 7;
    if (field === 1 && wire === WIRE_VARINT) {
      item.idStr = reader.readVarintString();
      item.id = Number(item.idStr);
    } else if (field === 2 && wire === WIRE_VARINT) {
      item.time = reader.readVarint() / 1000;
    } else if (field === 3 && wire === WIRE_VARINT) {
      item.mode = reader.readVarint();
    } else if (field === 4 && wire === WIRE_VARINT) {
      item.fontsize = reader.readVarint();
    } else if (field === 5 && wire === WIRE_VARINT) {
      item.color = reader.readVarint();
    } else if (field === 6 && wire === WIRE_LENGTH) {
      item.midHash = util.TextDecoder.create('utf-8').decodeToString(reader.readBytes());
    } else if (field === 7 && wire === WIRE_LENGTH) {
      content = util.TextDecoder.create('utf-8').decodeToString(reader.readBytes());
    } else if (field === 8 && wire === WIRE_VARINT) {
      item.ctime = reader.readVarint();
    } else if (field === 9 && wire === WIRE_VARINT) {
      item.weight = reader.readVarint();
    } else {
      reader.skip(wire);
    }
  }
  item.text = content;
  return item;
}

/** 解析一段 DmSegMobileReply；空内容的脏条目直接丢弃。 */
export function parseDanmakuSegment(buffer: ArrayBuffer): Array<ProtoDanmaku> {
  const result: Array<ProtoDanmaku> = [];
  const bytes: Uint8Array = new Uint8Array(buffer);
  const reader: ProtoReader = new ProtoReader(bytes, 0, bytes.length);
  while (!reader.eof()) {
    const tag: number = reader.readVarint();
    const field: number = tag >> 3;
    const wire: number = tag & 7;
    if (field === 1 && wire === WIRE_LENGTH) {
      const body: Uint8Array = reader.readBytes();
      const item: ProtoDanmaku = parseDanmakuElem(body);
      if (item.text.length > 0) {
        result.push(item);
      }
    } else {
      reader.skip(wire);
    }
  }
  return result;
}
