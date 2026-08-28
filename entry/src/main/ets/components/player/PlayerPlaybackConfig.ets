/**
 * 播放器底层播放策略配置：URL 选择/播放策略/请求头。
 * 与解耦 AVPlayer 初始化的纯函数集合。
 */
import { media } from '@kit.MediaKit';
import { Constants } from '../../common/Constants';

export class PlayerPlaybackConfig {
  static sourceUrl(sources: Array<string>, index: number): string {
    return sources[Math.min(index, Math.max(0, sources.length - 1))] ?? '';
  }

  static videoStrategy(showFirstFrame: boolean = true): media.PlaybackStrategy {
    return {
      // 只使用 AVPlayer 内存缓冲。12s 足以覆盖常见网络抖动，也避免高码率片源抢跑过多数据。
      preferredBufferDuration: 12,
      preferredBufferDurationForPlaying: 1,
      // API 26 建议最大水线至少比起播水线高 2s。
      thresholdForAutoQuickPlay: 3,
      // 续播场景关闭“先显示第 0 帧”：否则会闪一下片头再跳到续播点。
      showFirstFrameOnPrepare: showFirstFrame,
    };
  }

  static audioStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: 12,
      preferredBufferDurationForPlaying: 1,
      thresholdForAutoQuickPlay: 3,
    };
  }

  static playbackHeaders(): Record<string, string> {
    return {
      'User-Agent': Constants.browserUa,
      'Referer': 'https://www.bilibili.com/',
    };
  }
}
