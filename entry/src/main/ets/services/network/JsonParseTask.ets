/**
 * 大响应 JSON 的 taskpool 后台解析。
 * @Concurrent 函数只能引用「import 的或局部」的变量/类型，因此独立成模块
 * （与 DanmakuProto / YouTubeParseTasks 同款模式）。
 *
 * 返回 null 表示 taskpool 执行失败（线程池异常、跨线程序列化限制、body 非法 JSON）。
 * 调用方收到 null 后回退主线程同步解析——即使运行时不支持普通对象跨线程传输，
 * 行为也与不引入本模块时完全一致，失败对调用方零感知。
 */
import { taskpool } from '@kit.ArkTS';

@Concurrent
function parseJsonTask(body: string): Object {
  return JSON.parse(body) as Object;
}

/** 后台解析 JSON body；任何失败返回 null，由调用方回退同步解析。 */
export async function parseJsonAsync(body: string): Promise<Object | null> {
  try {
    return await taskpool.execute(parseJsonTask, body) as Object;
  } catch (e) {
    return null;
  }
}
