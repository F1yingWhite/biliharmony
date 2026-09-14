/** 握持手决定搜索位置；无法判断握持方向时，操作手事件作为补充。 */
import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError, Callback } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class Handedness {
  static readonly LEFT: string = 'left';
  static readonly RIGHT: string = 'right';
  static readonly KEY_SIDE: string = 'dockSearchSide';
  static readonly KEY_PINNED: string = 'dockSearchSidePinned';
  private static readonly TAG: string = 'BiliHandedness';
  private static initialized: boolean = false;
  private static active: boolean = true;
  private static generation: number = 0;
  private static holdingSide: string = '';
  private static holdingListener: Callback<motion.HoldingHandStatus> | null = null;
  private static operatingListener: Callback<motion.OperatingHandStatus> | null = null;

  static init(): void {
    if (!Handedness.initialized) {
      PersistentStorage.persistProp<string>(Handedness.KEY_SIDE, Handedness.RIGHT);
      PersistentStorage.persistProp<boolean>(Handedness.KEY_PINNED, false);
      Handedness.initialized = true;
    }
    Handedness.subscribe();
  }

  static side(): string {
    return AppStorage.get<string>(Handedness.KEY_SIDE) === Handedness.LEFT ? Handedness.LEFT : Handedness.RIGHT;
  }

  static isLeft(): boolean {
    return Handedness.side() === Handedness.LEFT;
  }

  static pinned(): boolean {
    return AppStorage.get<boolean>(Handedness.KEY_PINNED) ?? false;
  }

  static pin(side: string): void {
    AppStorage.setOrCreate<boolean>(Handedness.KEY_PINNED, true);
    Handedness.unsubscribe();
    Handedness.publish(side === Handedness.LEFT ? Handedness.LEFT : Handedness.RIGHT, 'manual');
  }

  static useAutomatic(): void {
    AppStorage.setOrCreate<boolean>(Handedness.KEY_PINNED, false);
    Handedness.subscribe();
  }

  /** 后台释放传感器，回前台重新订阅；过期回调不能再改写新一轮状态。 */
  static setActive(active: boolean): void {
    Handedness.active = active;
    if (active) {
      Handedness.subscribe();
    } else {
      Handedness.unsubscribe();
    }
  }

  private static accepts(generation: number): boolean {
    return generation === Handedness.generation && Handedness.active && !Handedness.pinned();
  }

  private static subscribe(): void {
    if (!Handedness.initialized || !Handedness.active || Handedness.pinned()) {
      return;
    }
    if (canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      const generation: number = Handedness.generation;
      // 两路分别订阅：其中一种能力不可用，不影响另一种。
      if (Handedness.holdingListener === null) {
        const listener: Callback<motion.HoldingHandStatus> = (status: motion.HoldingHandStatus): void => {
          if (!Handedness.accepts(generation)) return;
          hilog.info(0x0000, Handedness.TAG, 'holding event=%{public}d', status);
          Handedness.holdingSide = '';
          if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
            Handedness.holdingSide = Handedness.LEFT;
          } else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
            Handedness.holdingSide = Handedness.RIGHT;
          }
          if (Handedness.holdingSide.length > 0) {
            Handedness.publish(Handedness.holdingSide, 'holding');
          }
        };
        try {
          motion.on('holdingHandChanged', listener);
          Handedness.holdingListener = listener;
          hilog.info(0x0000, Handedness.TAG, 'holding subscribed');
        } catch (e) {
          Handedness.logError('holding subscribe', e as BusinessError);
        }
      }
      if (Handedness.operatingListener === null) {
        const listener: Callback<motion.OperatingHandStatus> = (status: motion.OperatingHandStatus): void => {
          if (!Handedness.accepts(generation)) return;
          hilog.info(0x0000, Handedness.TAG, 'operating event=%{public}d holding=%{public}s', status,
            Handedness.holdingSide);
          // 单手握持时以握持手为准，另一只手偶尔点屏不会把按钮挪走。
          if (Handedness.holdingSide.length > 0) return;
          if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
            Handedness.publish(Handedness.LEFT, 'operating');
          } else if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
            Handedness.publish(Handedness.RIGHT, 'operating');
          }
        };
        try {
          motion.on('operatingHandChanged', listener);
          Handedness.operatingListener = listener;
          hilog.info(0x0000, Handedness.TAG, 'operating subscribed');
        } catch (e) {
          Handedness.logError('operating subscribe', e as BusinessError);
        }
      }
      // 不用 getRecentOperatingHandStatus 的历史结果覆盖刚刚的握持方向。
      // 初始保留上次位置，等系统给出本轮真实事件再换边。
    }
  }

  private static unsubscribe(): void {
    Handedness.generation++;
    Handedness.holdingSide = '';
    if (canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      if (Handedness.holdingListener !== null) {
        try {
          motion.off('holdingHandChanged', Handedness.holdingListener);
        } catch (e) {
          Handedness.logError('holding unsubscribe', e as BusinessError);
        }
      }
      if (Handedness.operatingListener !== null) {
        try {
          motion.off('operatingHandChanged', Handedness.operatingListener);
        } catch (e) {
          Handedness.logError('operating unsubscribe', e as BusinessError);
        }
      }
    }
    Handedness.holdingListener = null;
    Handedness.operatingListener = null;
  }

  private static logError(action: string, err: BusinessError): void {
    hilog.info(0x0000, Handedness.TAG, '%{public}s unavailable code=%{public}d', action, err.code);
  }

  private static publish(side: string, source: string): void {
    if (Handedness.side() === side) return;
    AppStorage.setOrCreate<string>(Handedness.KEY_SIDE, side);
    hilog.info(0x0000, Handedness.TAG, 'side=%{public}s source=%{public}s', side, source);
  }
}
