/**
 * 封面取色：下载图片 → 解码缩略 PixelMap → 采样量化提取主色/鲜艳色
 * 用于"沉浸光感"动态主题（视频详情、播放页背景氛围色）
 */
import { image } from '@kit.ImageKit';
import { HttpClient } from './HttpClient';
import { RGB, rgbToHex, withSaturation } from './ColorUtil';

export class ImagePalette {
  dominant: string = '#FB7299';   // 主色（出现频率最高）
  vibrant: string = '#FB7299';    // 鲜艳色（高饱和高频色）

  constructor(dominant: string, vibrant: string) {
    this.dominant = dominant;
    this.vibrant = vibrant;
  }
}

// 量化桶
class Bucket {
  count: number = 0;
  rSum: number = 0;
  gSum: number = 0;
  bSum: number = 0;

  get avg(): RGB {
    if (this.count === 0) {
      return new RGB(0, 0, 0);
    }
    return new RGB(this.rSum / this.count, this.gSum / this.count, this.bSum / this.count);
  }

  add(r: number, g: number, b: number): void {
    this.count++;
    this.rSum += r;
    this.gSum += g;
    this.bSum += b;
  }

  /** 桶内颜色饱和度（简化：max-min 归一化） */
  get saturation(): number {
    const avg: RGB = this.avg;
    const maxC: number = Math.max(avg.r, avg.g, avg.b);
    const minC: number = Math.min(avg.r, avg.g, avg.b);
    return (maxC - minC) / 255;
  }
}

export class ImageColor {
  /**
   * 从图片 URL 提取调色板
   * @param url 图片地址
   * @param sampleSize 缩略采样尺寸
   */
  static async extract(url: string, sampleSize: number = 40): Promise<ImagePalette> {
    const fallback: ImagePalette = new ImagePalette('#FB7299', '#FB7299');
    if (url.length === 0) {
      return fallback;
    }
    try {
      const bytes: ArrayBuffer = await HttpClient.getBytes(url, {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
        'Referer': 'https://www.bilibili.com/',
      });
      if (bytes.byteLength === 0) {
        return fallback;
      }
      const source: image.ImageSource = image.createImageSource(bytes);
      const pixelMap: image.PixelMap = await source.createPixelMap({
        desiredSize: { width: sampleSize, height: sampleSize },
      });
      const buffer: ArrayBuffer = new ArrayBuffer(sampleSize * sampleSize * 4);
      await pixelMap.readPixelsToBuffer(buffer);
      const pixels: Uint8Array = new Uint8Array(buffer);
      pixelMap.release();
      source.release();

      // 4bit 量化分桶（每通道 4bit → 共 4096 桶）
      const bucketMap: Map<number, Bucket> = new Map<number, Bucket>();
      const total: number = sampleSize * sampleSize;
      for (let i: number = 0; i < total; i++) {
        const idx: number = i * 4;
        const r: number = pixels[idx];
        const g: number = pixels[idx + 1];
        const b: number = pixels[idx + 2];
        const key: number = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
        let bucket: Bucket | undefined = bucketMap.get(key);
        if (bucket === undefined) {
          bucket = new Bucket();
          bucketMap.set(key, bucket);
        }
        bucket.add(r, g, b);
      }

      // 主色：数量最多
      let dominant: RGB = new RGB(251, 114, 153);
      let maxCount: number = -1;
      bucketMap.forEach((bucket: Bucket) => {
        if (bucket.count > maxCount) {
          maxCount = bucket.count;
          dominant = bucket.avg;
        }
      });

      // 鲜艳色：饱和度最高的高频桶
      let vibrant: RGB = dominant;
      let bestScore: number = -1;
      bucketMap.forEach((bucket: Bucket) => {
        if (bucket.count < total * 0.02) {
          return;
        }
        const score: number = bucket.saturation * 2 + bucket.count / total;
        if (score > bestScore) {
          bestScore = score;
          vibrant = bucket.avg;
        }
      });

      let vibrantHex: string = rgbToHex(vibrant);
      vibrantHex = withSaturation(vibrantHex, 0.75);
      return new ImagePalette(rgbToHex(dominant), vibrantHex);
    } catch (e) {
      return fallback;
    }
  }
}
