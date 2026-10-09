import { UserSpaceParam } from './AppRouter';

/** 按页面参数对象记录系统栏背景，嵌套打开同一用户的空间也保持独立。 */
export class UserSpaceChrome {
  private static readonly coveredPages: WeakMap<UserSpaceParam, boolean> =
    new WeakMap<UserSpaceParam, boolean>();

  static setCovered(param: UserSpaceParam, covered: boolean): void {
    UserSpaceChrome.coveredPages.set(param, covered);
  }

  /** 头图始终使用浅色图标；纯色遮罩仅在浅色模式下使用深色图标。 */
  static statusIconLight(param: UserSpaceParam, isDark: boolean): boolean {
    return isDark || UserSpaceChrome.coveredPages.get(param) !== true;
  }
}
