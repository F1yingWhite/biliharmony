/**
 * 全局响应式布局 token。
 * 页面只表达“信息流 / 阅读 / 普通页面”语义，不再各自散落屏宽断点和最大宽度。
 */
export class LayoutTokens {
  static readonly phonePadding: number = 10;
  static readonly widePadding: number = 18;
  static readonly readingMaxWidth: number = 760;
  static readonly pageMaxWidth: number = 960;
  static readonly feedMaxWidth: number = 1180;

  static horizontalPadding(width: number): number {
    return width >= 600 ? LayoutTokens.widePadding : LayoutTokens.phonePadding;
  }

  /** 手机保持双列；折叠屏、平板逐级增加列数，单卡不会被横向拉得过宽。 */
  static feedColumns(width: number): number {
    if (width >= 1040) return 5;
    if (width >= 820) return 4;
    if (width >= 560) return 3;
    return 2;
  }

  /** 表情键盘网格：给图片和两行短名称留足空间，手机 5 列、宽屏 7/9 列。 */
  static emoteColumnsTemplate(width: number): string {
    if (width >= 720) return '1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr';
    if (width >= 600) return '1fr 1fr 1fr 1fr 1fr 1fr 1fr';
    return '1fr 1fr 1fr 1fr 1fr';
  }
}
