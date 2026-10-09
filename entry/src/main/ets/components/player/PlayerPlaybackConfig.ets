/**
 * 播放来源配置：CDN 选择和 B 站请求头。
 * 播放内核内部管理解码与缓冲。
 */
import { Constants } from '../../common/Constants';

export class PlayerPlaybackConfig {
  static sourceUrl(sources: Array<string>, index: number): string {
    return sources[Math.min(index, Math.max(0, sources.length - 1))] ?? '';
  }

  static playbackHeaders(): Record<string, string> {
    return {
      'User-Agent': Constants.browserUa,
      'Referer': 'https://www.bilibili.com/',
    };
  }
}
