/**
 * B 站分区图标映射：SVG 素材取自 BewlyBewly（MIT License）官方分区图标集，
 * 位于 resources/rawfile/icons/channels/，按分区名解析 rawfile 路径；无映射返回空串。
 */
export class ChannelIcons {
  private static readonly MAP: Record<string, string> = {
    '动画': 'channel-douga',
    '音乐': 'channel-music',
    '游戏': 'channel-game',
    '知识': 'channel-knowledge',
    '科技': 'channel-tech',
    '生活': 'channel-life',
    '舞蹈': 'channel-dance',
    '鬼畜': 'channel-kichiku',
    '影视': 'channel-cinema',
    '美食': 'channel-food',
    '运动': 'channel-sports',
    '娱乐': 'channel-ent',
    '电影': 'channel-movie',
    '电视剧': 'channel-teleplay',
    '纪录片': 'channel-documentary',
    '资讯': 'channel-information',
    '时尚': 'channel-fashion',
    '动物圈': 'channel-animal',
    '漫画': 'channel-comic',
    '直播': 'channel-live',
  };

  /** 分区名 → rawfile 路径；无匹配图标返回空串（调用方回退到首字占位）。 */
  static rawfileFor(label: string): string {
    const id: string | undefined = ChannelIcons.MAP[label];
    return id === undefined ? '' : 'icons/channels/' + id + '.svg';
  }
}
