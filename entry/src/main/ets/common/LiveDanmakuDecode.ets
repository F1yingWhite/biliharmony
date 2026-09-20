/**
 * 直播弹幕解码核心（纯函数，无 UI 依赖）：供 LiveDanmakuClient.ets 的 @Concurrent 任务调用。
 * 一个 WebSocket 二进制包的完整解码——按 16 字节头切帧、zlib 解压（含嵌套压缩包递归）、
 * 逐条 JSON.parse——全部在 taskpool 后台线程执行，与 VOD 侧 DanmakuProtoCore 同款模式。
 * 注意：@Concurrent 函数只能引用「import 的或函数内局部」的变量/类型，
 * 因此本模块只提供纯核心与数据结构，taskpool 封装放在 LiveDanmakuClient.ets。
 */
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';

/** 单条解码结果（跨线程传递的纯数据）：operation=8 表示鉴权回应，operation=5 时 payload 为消息 JSON。 */
export interface LiveDecodedEvent {
  operation: number;
  /** op=5 的消息 JSON 对象；非 JSON 的心跳/脏包为 null，由主线程跳过（与旧 parseJson 吞异常语义一致）。 */
  payload: Object | null;
}

/** 每个 taskpool 工作线程复用一个解压实例：zlib.createZip 有原生开销，旧实现每包新建只增不减。 */
let sharedZip: zlib.Zip | null = null;
/** 串行化共享实例上的解压调用：同一工作线程内并发任务的异步解压不得交叉使用同一实例。 */
let inflateChain: Promise<void> = Promise.resolve();

/**
 * 解压直播 zlib 消息（经队列串行化）；输出未知时逐级扩容，最高 8 MiB，防止异常包无限占用内存。
 * 同时供 LiveDanmakuClient 的同步回退路径（Node QA 沙箱没有 taskpool）复用。
 */
export function inflateLiveZlib(source: ArrayBuffer): Promise<ArrayBuffer | null> {
  const task: Promise<ArrayBuffer | null> = inflateChain.then((): Promise<ArrayBuffer | null> =>
    inflateWithSharedZip(source));
  inflateChain = task.then((): void => {}, (): void => {});
  return task;
}

async function inflateWithSharedZip(source: ArrayBuffer): Promise<ArrayBuffer | null> {
  if (sharedZip === null) {
    sharedZip = await zlib.createZip();
  }
  const zip: zlib.Zip = sharedZip;
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

/** 非 JSON 正文（心跳/脏包）返回 null，与旧 parseJson 的吞异常语义一致。 */
function parseLooseJson(text: string): Object | null {
  try {
    return JSON.parse(text) as Object;
  } catch (e) {
    return null;
  }
}

/**
 * 解码一个 WebSocket 二进制包：按到达顺序展开为扁平事件序列（鉴权 + 消息）。
 * zlib 压缩包的正文仍是若干个带 16 字节头的直播协议包，就地递归解包；
 * 未支持的分支（op=3 心跳回应、protover=3 Brotli）与旧主线程实现一致，整包跳过。
 */
export async function decodeLivePacketsCore(buffer: ArrayBuffer): Promise<Array<LiveDecodedEvent>> {
  const events: Array<LiveDecodedEvent> = [];
  await collectLiveEvents(buffer, events);
  return events;
}

async function collectLiveEvents(buffer: ArrayBuffer, events: Array<LiveDecodedEvent>): Promise<void> {
  const view: DataView = new DataView(buffer);
  let offset: number = 0;
  while (offset + 16 <= buffer.byteLength) {
    const packetLength: number = view.getUint32(offset);
    const headerLength: number = view.getUint16(offset + 4);
    const protocol: number = view.getUint16(offset + 6);
    const operation: number = view.getUint32(offset + 8);
    if (headerLength < 16 || packetLength < headerLength || packetLength <= 0 || offset + packetLength > buffer.byteLength) break;
    if (operation === 8) {
      const auth: LiveDecodedEvent = { operation: 8, payload: null };
      events.push(auth);
    } else if (operation === 5 && (protocol === 0 || protocol === 1)) {
      const bytes: Uint8Array = new Uint8Array(buffer, offset + headerLength, packetLength - headerLength);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      const message: LiveDecodedEvent = { operation: 5, payload: parseLooseJson(text) };
      events.push(message);
    } else if (operation === 5 && protocol === 2) {
      // zlib 接口没有偏移参数，压缩正文必须先拷贝成独立缓冲再解压。
      const compressedView: Uint8Array = new Uint8Array(buffer, offset + headerLength, packetLength - headerLength);
      const compressed: ArrayBuffer = new ArrayBuffer(compressedView.byteLength);
      new Uint8Array(compressed).set(compressedView);
      const inflated: ArrayBuffer | null = await inflateLiveZlib(compressed);
      if (inflated !== null) await collectLiveEvents(inflated, events);
    }
    offset += packetLength;
  }
}
