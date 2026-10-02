import { MessageSessionItem, PrivateMessageItem } from '../../model/message/MessageModels';

export function privateMessageIdentity(item: PrivateMessageItem): string {
  return item.seqnoText.length > 0 ? item.seqnoText : 'local-' + String(item.seqno);
}

/** LazyForEach 同 key 缓存行：显示字段变化必须生成新 key。 */
export function sessionRowIdentity(item: MessageSessionItem): string {
  return JSON.stringify([String(item.talkerId), String(item.unread), item.maxSeqno, item.name,
    item.avatar, item.preview, String(item.timestamp), String(item.pinned)]);
}
