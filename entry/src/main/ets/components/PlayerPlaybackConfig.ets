/**
 * 播放器底层播放策略配置：URL 选择/播放策略/请求头。
 * 与解耦 AVPlayer 初始化的纯函数集合。
 */
import { media } from '@kit.MediaKit';
import { Constants } from '../common/Constants';

export class PlayerPlaybackConfig {
  static sourceUrl(sources: Array<string>, index: number): string {
    return sources[Math.min(index, Math.max(0, sources.length - 1))] ?? '';
  }

  static videoStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: 15,
      preferredBufferDurationForPlaying: 1,
      thresholdForAutoQuickPlay: 3,
      showFirstFrameOnPrepare: true,
    };
  }

  static audioStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: 20,
      preferredBufferDurationForPlaying: 0.6,
      thresholdForAutoQuickPlay: 2.6,
    };
  }

  static playbackHeaders(): Record<string, string> {
    return {
      'User-Agent': Constants.browserUa,
      'Referer': 'https://www.bilibili.com/',
    };
  }
}
