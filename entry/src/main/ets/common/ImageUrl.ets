/** 去除哔哩哔哩图片 CDN 的 @缩放/格式后缀，恢复原图地址。 */
export function biliImageOriginal(url: string): string {
  if (url.indexOf('hdslb.com') < 0) return url;
  const queryAt: number = url.indexOf('?');
  const query: string = queryAt >= 0 ? url.substring(queryAt) : '';
  let path: string = queryAt >= 0 ? url.substring(0, queryAt) : url;
  const transformAt: number = path.lastIndexOf('@');
  if (transformAt > path.lastIndexOf('/')) path = path.substring(0, transformAt);
  return path + query;
}

/** 评论流等列表场景只请求按展示宽度缩放的 WebP，点击查看器后再加载原图。 */
export function biliImageThumbnail(url: string, width: number): string {
  if (url.indexOf('hdslb.com') < 0) return url;
  const original: string = biliImageOriginal(url).split('?')[0];
  return original + '@' + String(Math.max(120, Math.round(width))) + 'w.webp';
}
