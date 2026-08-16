import { BiliApi } from '../api/BiliApi';
import { MsgFeedUnread } from '../model/Models';
import { UserStore } from './UserStore';

/**
 * 首页消息入口未读角标：与 HotSearchStore 同款“共享请求去重”，
 * 四个通知分类（回复/@/赞/系统）的未读合计发布到 AppStorage('msgUnreadTotal') 供头栏角标使用。
 */
export class MsgUnreadStore {
  private static pending: Promise<void> | null = null;
  private static unread: MsgFeedUnread = new MsgFeedUnread();

  static async refresh(): Promise<void> {
    if (!UserStore.isLogin) {
      MsgUnreadStore.publish();
      return;
    }
    if (MsgUnreadStore.pending !== null) return MsgUnreadStore.pending;
    const request: Promise<void> = BiliApi.getMsgFeedUnread().then((data: MsgFeedUnread) => {
      MsgUnreadStore.unread = data;
      MsgUnreadStore.publish();
    });
    MsgUnreadStore.pending = request;
    try {
      await request;
    } finally {
      // 并发调用共享同一请求；旧请求完成时不能把新请求的标记清掉。
      if (MsgUnreadStore.pending === request) MsgUnreadStore.pending = null;
    }
  }

  /** 进入对应分类后本地清零（系统通知另有服务端已读游标上报，由列表页负责）。 */
  static clearCategory(category: string): void {
    if (category === 'reply') {
      MsgUnreadStore.unread.reply = 0;
    } else if (category === 'at') {
      MsgUnreadStore.unread.at = 0;
    } else if (category === 'like') {
      MsgUnreadStore.unread.like = 0;
    } else if (category === 'sys') {
      MsgUnreadStore.unread.sysMsg = 0;
    } else {
      return;
    }
    MsgUnreadStore.publish();
  }

  private static publish(): void {
    AppStorage.setOrCreate<number>('msgUnreadTotal', MsgUnreadStore.unread.total());
  }
}
