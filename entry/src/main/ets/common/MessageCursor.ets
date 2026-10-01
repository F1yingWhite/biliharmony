import { asObject } from './Utils';

/** 消息序号和通知游标为 int64，解析之前保留原始十进制值。 */
export function parseMessageJson(body: string): Record<string, Object> {
  try {
    const exact: string = body.replace(/"(max_seqno|msg_seqno|cursor)"\s*:\s*(\d+)(?=\s*[,}])/g,
      '"$1":"$2"');
    return asObject(JSON.parse(exact) as Object);
  } catch (e) {
    return {};
  }
}

/** 按十进制字符串比较，避免相邻 int64 在 number 中合并。 */
export function compareMessageCursor(first: string, second: string): number {
  const a: string = first.replace(/^0+(?=\d)/, '');
  const b: string = second.replace(/^0+(?=\d)/, '');
  if (a.length !== b.length) return a.length > b.length ? 1 : -1;
  return a === b ? 0 : (a > b ? 1 : -1);
}
