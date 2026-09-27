/**
 * 直播弹幕后台解码 Worker（长驻线程）。
 * 主线程把原始二进制包 postMessage 过来（含 seq/generation 回执字段），
 * 这里切帧 + zlib 解压 + JSON.parse，把已解码的事件数组按到达顺序发回。
 *
 * 不用 taskpool 的原因：解压 API 只有 Promise 版本，而 @Concurrent 任务不允许
 * 返回未决 Promise（真机报 Can't return Promise in pending state，鉴权回包被
 * 静默丢弃导致直播间永远「重连中」）；Worker 的消息模型没有这个限制——异步解压
 * 完成后再 postMessage 已解码的普通结果即可。
 */
import { worker, ThreadWorkerGlobalScope, MessageEvent } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LiveDecodedEvent, decodeLivePacketsCore } from '../common/LiveDanmakuDecode';

interface DecodeRequest {
  seq: number;
  generation: number;
  buffer: ArrayBuffer;
}

interface DecodeResponse {
  seq: number;
  generation: number;
  events: Array<LiveDecodedEvent>;
}

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

workerPort.onmessage = (e: MessageEvent<Object>) => {
  const request: DecodeRequest = e.data as DecodeRequest;
  decodeLivePacketsCore(request.buffer).then((events: Array<LiveDecodedEvent>) => {
    const response: DecodeResponse = { seq: request.seq, generation: request.generation, events: events };
    workerPort.postMessage(response);
  }).catch((err: Object) => {
    // 单个损坏包不中断后续解码；但失败必须回传让主线程可见（静默吞掉曾让
    // 「鉴权成功而弹幕全无」无从诊断）。同因只回传一次细节，避免刷屏。
    const detail: string = String(err);
    const response: DecodeResponse = { seq: request.seq, generation: request.generation, events: [] };
    workerPort.postMessage(response);
    if (detail !== lastFailure) {
      lastFailure = detail;
      hilog.error(0x0000, 'LiveDmW', 'decode failed: %{public}s', detail);
    }
  });
};

let lastFailure: string = '';
