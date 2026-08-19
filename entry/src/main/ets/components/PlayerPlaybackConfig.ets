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

  static videoStrategy(showFirstFrame: boolean = true): media.PlaybackStrategy {
    return {
      // 播放中缓冲目标加大到 20s：网络抖动时更不容易二次卡顿。
      preferredBufferDuration: 20,
      preferredBufferDurationForPlaying: 0.8,
      // 起播/seek 后只要有 2s 缓冲就开播（原 3s；低于 2 会被系统判定非法参数）。
      thresholdForAutoQuickPlay: 2,
      // 续播场景关闭“先显示第 0 帧”：否则会闪一下片头再跳到续播点。
      showFirstFrameOnPrepare: showFirstFrame,
    };
  }

  static audioStrategy(): media.PlaybackStrategy {
    return {
      preferredBufferDuration: 20,
      preferredBufferDurationForPlaying: 0.5,
      thresholdForAutoQuickPlay: 2,
    };
  }

  static playbackHeaders(): Record<string, string> {
    return {
      'User-Agent': Constants.browserUa,
      'Referer': 'https://www.bilibili.com/',
    };
  }
}
