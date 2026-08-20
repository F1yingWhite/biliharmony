import { VideoDetail } from '../model/Models';

interface ResolvedVideoSize {
  width: number;
  height: number;
}

/** 视频详情页的纯尺寸计算，避免页面状态类重复解析分 P、旋转与真实解码尺寸。 */
export class VideoDetailGeometry {
  private static resolveSize(detail: VideoDetail, cid: number, realWidth: number,
    realHeight: number): ResolvedVideoSize {
    let width: number = realWidth > 0 ? realWidth : detail.width;
    let height: number = realHeight > 0 ? realHeight : detail.height;
    let rotate: number = detail.rotate;
    for (let i: number = 0; i < detail.pages.length; i++) {
      const page = detail.pages[i];
      if (page.cid !== cid || page.width <= 0 || page.height <= 0) continue;
      if (realWidth <= 0 || realHeight <= 0) {
        width = page.width;
        height = page.height;
      }
      rotate = page.rotate;
      break;
    }
    if ((realWidth <= 0 || realHeight <= 0) && Math.abs(rotate) % 180 !== 0) {
      const rotatedWidth: number = height;
      height = width;
      width = rotatedWidth;
    }
    return { width: width, height: height };
  }

  static playerHeight(detail: VideoDetail, cid: number, screenWidth: number, screenHeight: number,
    statusBarHeight: number, bottomInset: number, realWidth: number, realHeight: number): number {
    if (screenWidth <= 0 || screenHeight <= 0) return 220;
    const usableHeight: number = Math.max(480, screenHeight - statusBarHeight - bottomInset);
    const regularHeight: number = screenWidth * 9 / 16;
    const maximumHeight: number = Math.max(regularHeight, Math.floor(usableHeight * 0.6));
    const size: ResolvedVideoSize = VideoDetailGeometry.resolveSize(detail, cid, realWidth, realHeight);
    if (size.width <= 0 || size.height <= 0) return regularHeight;
    const naturalHeight: number = screenWidth * size.height / size.width;
    return Math.max(regularHeight, Math.min(maximumHeight, naturalHeight));
  }

  static shouldCollapse(playing: boolean, detail: VideoDetail, cid: number, realWidth: number,
    realHeight: number): boolean {
    if (!playing) return true;
    const size: ResolvedVideoSize = VideoDetailGeometry.resolveSize(detail, cid, realWidth, realHeight);
    return size.width > 0 && size.height > size.width;
  }

  static pageDuration(detail: VideoDetail, cid: number): number {
    for (let i: number = 0; i < detail.pages.length; i++) {
      if (detail.pages[i].cid === cid && detail.pages[i].duration > 0) return detail.pages[i].duration;
    }
    return detail.duration;
  }
}
