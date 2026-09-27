/**
 * 弹幕解码（taskpool 后台线程）：protobuf 分段 + XML 兜底两种协议。
 * 弹幕段可达数百 KB～MB 级、数千条消息，varint/正则全量扫描必须离开主线程，
 * 否则加载/预取分段时直接掉帧。核心解析在 DanmakuProtoCore.ets
 * （@Concurrent 函数只能引用「import 的或局部」的变量/类型，解析器必须独立成模块）。
 */
import { taskpool } from '@kit.ArkTS';
import { decodeDanmakuSegBuffer, decodeDanmakuXmlBuffer, SendableDanmaku } from './DanmakuProtoCore';

export { SendableDanmaku } from './DanmakuProtoCore';

@Concurrent
function decodeDanmakuSegTask(buffer: ArrayBuffer): Array<SendableDanmaku> {
  return decodeDanmakuSegBuffer(buffer);
}

@Concurrent
function decodeDanmakuXmlTask(xml: string): Array<SendableDanmaku> {
  return decodeDanmakuXmlBuffer(xml);
}

/** 主线程入口：protobuf 分段解码。ArrayBuffer 参数默认转移所有权（零拷贝），调用后不可再读。 */
export async function decodeDanmakuSeg(buffer: ArrayBuffer): Promise<Array<SendableDanmaku>> {
  return await taskpool.execute(decodeDanmakuSegTask, buffer) as Array<SendableDanmaku>;
}

/** 主线程入口：XML 弹幕解码。 */
export async function decodeDanmakuXml(xml: string): Promise<Array<SendableDanmaku>> {
  return await taskpool.execute(decodeDanmakuXmlTask, xml) as Array<SendableDanmaku>;
}
