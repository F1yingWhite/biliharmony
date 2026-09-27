/**
 * 开播系统提醒：基于 reminderAgentManager 的系统日历提醒（无需自建推送服务）。
 *
 * 用途：新番时间表「提醒」按钮——为某部番剧的开播时间登记一次系统提醒，
 * 应用不在前台也会由系统在到点时弹出。提醒 id 持久化，重启后仍可取消。
 * 失败安静降级：设备能力缺失/权限被拒时返回 false，UI 显示失败 toast。
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class AirReminderService {
  private static readonly PREFS_NAME: string = 'air_reminders';
  private static store: preferences.Preferences | null = null;
  private static ready: Promise<void> | null = null;

  private static ensureStore(context: common.UIAbilityContext): Promise<void> {
    if (AirReminderService.ready !== null) return AirReminderService.ready;
    AirReminderService.ready = preferences.getPreferences(context, { name: AirReminderService.PREFS_NAME })
      .then((store: preferences.Preferences) => {
        AirReminderService.store = store;
      }).catch(() => {
      });
    return AirReminderService.ready;
  }

  static async isScheduled(context: common.UIAbilityContext, key: string): Promise<boolean> {
    await AirReminderService.ensureStore(context);
    if (AirReminderService.store === null) return false;
    return (AirReminderService.store.getSync(key, 0) as number) > 0;
  }

  /** 登记一次系统提醒；同一 key 重复登记先取消旧的。 */
  static async schedule(context: common.UIAbilityContext, key: string, title: string, text: string,
    at: Date): Promise<boolean> {
    await AirReminderService.cancel(context, key);
    try {
      const info: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: at.getFullYear(),
          month: at.getMonth() + 1,
          day: at.getDate(),
          hour: at.getHours(),
          minute: at.getMinutes(),
          second: 0,
        },
        title: title,
        content: text,
        expiredContent: '该内容已开播',
        notificationId: Math.floor(Math.random() * 1000000) + 100,
        ringDuration: 0,
        snoozeTimes: 0,
        timeInterval: 0,
      };
      const id: number = await reminderAgentManager.publishReminder(info);
      await AirReminderService.ensureStore(context);
      if (AirReminderService.store !== null) {
        AirReminderService.store.putSync(key, id);
        await AirReminderService.store.flush();
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  static async cancel(context: common.UIAbilityContext, key: string): Promise<void> {
    await AirReminderService.ensureStore(context);
    if (AirReminderService.store === null) return;
    const id: number = AirReminderService.store.getSync(key, 0) as number;
    if (id <= 0) return;
    try {
      await reminderAgentManager.cancelReminder(id);
    } catch (e) {
      // 提醒可能已被系统移除；本地记录照常清理。
    }
    AirReminderService.store.putSync(key, 0);
    await AirReminderService.store.flush();
  }
}
