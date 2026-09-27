/**
 * 弹幕解码核心（纯函数，无 UI 依赖）：供 DanmakuProto.ets 的 @Concurrent 任务调用。
 * 注意：@Concurrent 函数只能引用「import 的或函数内局部」的变量/类型，
 * 因此 ProtoReader 等必须放在独立模块中导入使用。
 */
import { util } from '@kit.ArkTS';

/** 解码结果（跨线程共享）。主线程侧再映射为 DanmakuItem，字段语义与旧 ProtoDanmaku/XML 解析一致。 */
@Sendable
export class SendableDanmaku {
  time: number = 0;          // 出现时间（秒）
  mode: number = 1;          // 1-3 滚动, 4 底部, 5 顶部
  color: number = 0xFFFFFF;
  text: string = '';
  id: number = 0;            // int64 超过 2^53 有精度损失，仅作存在判断
  idStr: string = '';        // dmid 十进制原串：点赞/举报必须用它
  fontsize: number = 25;
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

/** 只读的 wire-format 游标；坏数据一律截断跳过，不抛异常。 */
class ProtoReader {
  private static readonly WIRE_VARINT: number = 0;
  private static readonly WIRE_FIXED64: number = 1;
  private static readonly WIRE_LENGTH: number = 2;
  private static readonly WIRE_FIXED32: number = 5;
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

  /** 读 varint；移位用乘法实现（位移运算只有 32 位），最多容纳 2^53 精度。 */
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
    if (wire === ProtoReader.WIRE_VARINT) {
      this.readVarint();
    } else if (wire === ProtoReader.WIRE_FIXED64) {
      this.pos = Math.min(this.pos + 8, this.limit);
    } else if (wire === ProtoReader.WIRE_LENGTH) {
      const length: number = this.readVarint();
      this.pos = Math.min(this.pos + length, this.limit);
    } else if (wire === ProtoReader.WIRE_FIXED32) {
      this.pos = Math.min(this.pos + 4, this.limit);
    } else {
      this.pos = this.limit; // 组类型等不再使用，直接终止该消息
    }
  }
}

function parseDanmakuElem(bytes: Uint8Array): SendableDanmaku {
  const reader: ProtoReader = new ProtoReader(bytes, 0, bytes.length);
  const item: SendableDanmaku = new SendableDanmaku();
  let content: string = '';
  while (!reader.eof()) {
    const tag: number = reader.readVarint();
    const field: number = tag >> 3;
    const wire: number = tag & 7;
    if (field === 1 && wire === 0) {
      item.idStr = reader.readVarintString();
      item.id = Number(item.idStr);
    } else if (field === 2 && wire === 0) {
      item.time = reader.readVarint() / 1000;
    } else if (field === 3 && wire === 0) {
      item.mode = reader.readVarint();
    } else if (field === 4 && wire === 0) {
      item.fontsize = reader.readVarint();
    } else if (field === 5 && wire === 0) {
      item.color = reader.readVarint();
    } else if (field === 6 && wire === 2) {
      util.TextDecoder.create('utf-8').decodeToString(reader.readBytes()); // midHash：业务未消费
    } else if (field === 7 && wire === 2) {
      content = util.TextDecoder.create('utf-8').decodeToString(reader.readBytes());
    } else if (field === 8 && wire === 0) {
      reader.readVarint(); // ctime：业务未消费
    } else if (field === 9 && wire === 0) {
      item.weight = reader.readVarint();
    } else {
      reader.skip(wire);
    }
  }
  item.text = content;
  return item;
}

/** 解析一段 DmSegMobileReply；空内容的脏条目直接丢弃。 */
export function decodeDanmakuSegBuffer(buffer: ArrayBuffer): Array<SendableDanmaku> {
  const result: Array<SendableDanmaku> = [];
  const bytes: Uint8Array = new Uint8Array(buffer);
  const reader: ProtoReader = new ProtoReader(bytes, 0, bytes.length);
  while (!reader.eof()) {
    const tag: number = reader.readVarint();
    const field: number = tag >> 3;
    const wire: number = tag & 7;
    if (field === 1 && wire === 2) {
      const body: Uint8Array = reader.readBytes();
      const item: SendableDanmaku = parseDanmakuElem(body);
      if (item.text.length > 0) {
        result.push(item);
      }
    } else {
      reader.skip(wire);
    }
  }
  return result;
}

/** XML 实体解码 + 内嵌标签剥离（与旧 BiliApi.decodeXmlEntities 语义一致）。 */
function decodeXmlEntities(s: string): string {
  let out: string = s;
  out = out.replace(/&amp;/g, '&');
  out = out.replace(/&lt;/g, '<');
  out = out.replace(/&gt;/g, '>');
  out = out.replace(/&quot;/g, '"');
  out = out.replace(/&#39;/g, "'");
  out = out.replace(/&apos;/g, "'");
  out = out.replace(/<[^>]*>/g, '');
  return out;
}

/** 解析整份弹幕 XML（<d p="...">text</d>）；脏 mode/color 回退默认值。 */
export function decodeDanmakuXmlBuffer(xml: string): Array<SendableDanmaku> {
  const result: Array<SendableDanmaku> = [];
  const re: RegExp = /<d p="([^"]*)">([^<]*)<\/d>/g;
  let m: RegExpExecArray | null = re.exec(xml);
  while (m !== null) {
    const parts: Array<string> = m[1].split(',');
    if (parts.length >= 4) {
      const time: number = Number(parts[0]);
      const mode: number = Number(parts[1]);
      const color: number = Number(parts[3]);
      if (!Number.isNaN(time)) {
        const item: SendableDanmaku = new SendableDanmaku();
        item.time = time;
        item.mode = Number.isNaN(mode) ? 1 : mode;
        item.color = Number.isNaN(color) ? 0xFFFFFF : color;
        item.text = decodeXmlEntities(m[2]);
        item.weight = 10; // XML 协议无权重字段，与 DanmakuItem 默认值对齐
        result.push(item);
      }
    }
    m = re.exec(xml);
  }
  return result;
}
