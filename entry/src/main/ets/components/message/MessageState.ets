import { MessageSessionItem } from '../../model/message/MessageModels';
import { MessageSessionToken } from './MessageSessionScope';

export class SessionListState {
  loading: boolean = false;
  error: string = '';
  hasMore: boolean = true;
  count: number = 0;
  readAllLoading: boolean = false;
}

export class PrivateChatState {
  current: MessageSessionItem = new MessageSessionItem();
  open: boolean = false;
  loading: boolean = false;
  error: string = '';
  hasMore: boolean = true;
  draft: string = '';
  sending: boolean = false;
}

/** 原生菜单/确认框打开时冻结操作对象，不从随后变化的页面读取目标。 */
export interface SessionActionSnapshot {
  session: MessageSessionToken;
  menu: number;
  item: MessageSessionItem;
}

export interface ChatActionSnapshot {
  session: MessageSessionToken;
  talkerId: number;
  name: string;
}

export interface ChatScrollRequest {
  session: MessageSessionToken;
  latest: boolean;
  added: number;
}
