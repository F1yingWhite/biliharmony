/**
 * 播放器更多菜单/弹层面板的语义色。
 * 从 PlayerView 的 sheetTitle/sheetSub/sheetRowBg 抽为公共函数，供菜单、弹幕面板、屏蔽面板复用。
 */
export function playerPanelTitle(isDark: boolean): string {
  return isDark ? '#FFFFFF' : '#18191C';
}

export function playerPanelSub(isDark: boolean): string {
  return isDark ? '#B3FFFFFF' : '#5A5F66';
}

export function playerPanelRowBg(isDark: boolean): string {
  return isDark ? '#26272B' : '#F5F7F9';
}
