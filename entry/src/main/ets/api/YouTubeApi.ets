import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { asObject, asString, formatDuration } from '../common/Utils';

/** YouTube 身份独立于 B 站的 aid / bvid / cid。只读取公开元数据，不提取媒体地址。 */
export class YouTubeVideo {
  id: string = '';
  title: string = '';
  channel: string = '';
  thumbnail: string = '';
  duration: string = '';
  views: string = '';
  published: string = '';
  description: string = '';
  notice: string = '';
}

function textValue(value: Object | undefined): string {
  const node: Record<string, Object> = asObject(value);
  if (typeof node['simpleText'] === 'string') return asString(node['simpleText']);
  if (!Array.isArray(node['runs'])) return '';
  return (node['runs'] as Array<Object>).map((run: Object) => asString(asObject(run)['text'])).join('');
}

export class YouTubeApi {
  /**
   * 请求公开页面时声明桌面版 UA。不带 UA 会被 YouTube 判为不可信客户端并返回
   * 验证页/移动版页面：ytInitialData 里没有 videoRenderer，搜索解析会失败。
   * 这是服务端兼容性所需，不涉及伪装登录态，也不改变任何账号语义。
   */
  private static readonly DESKTOP_UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static validId(id: string): boolean { return /^[a-zA-Z0-9_-]{11}$/.test(id); }

  /** 只接受 YouTube 自己的链接，避免把任意 URL 交给网络层或播放器。 */
  static videoId(input: string): string {
    const value: string = input.trim();
    if (YouTubeApi.validId(value)) return value;
    const short: RegExpMatchArray | null = value.match(/^https?:\/\/youtu\.be\/([a-zA-Z0-9_-]{11})(?:[?&#/]|$)/i);
    if (short !== null) return short[1];
    if (!/^https?:\/\/(?:www\.|m\.|music\.)?youtube\.com\//i.test(value)) return '';
    const path: RegExpMatchArray | null = value.match(/youtube\.com\/(?:shorts|embed|live)\/([a-zA-Z0-9_-]{11})(?:[?&#/]|$)/i);
    if (path !== null) return path[1];
    if (!/youtube\.com\/watch\?/i.test(value)) return '';
    const query: RegExpMatchArray | null = value.match(/[?&]v=([a-zA-Z0-9_-]{11})(?:[&#]|$)/);
    return query !== null ? query[1] : '';
  }

  /** 扫描 JSON 的字符串/括号边界；标题中的分号、花括号不会截断数据。绝不执行远端脚本。 */
  static initialObject(html: string, variable: string): Record<string, Object> | null {
    const pattern: RegExp = new RegExp('(?:var\\s+' + variable + '|window\\["' + variable + '"\\])\\s*=\\s*');
    const match: RegExpMatchArray | null = html.match(pattern);
    if (match === null || match.index === undefined) return null;
    const start: number = match.index + match[0].length;
    if (html[start] !== '{') return null;
    let depth: number = 0;
    let quoted: boolean = false;
    let escaped: boolean = false;
    for (let i: number = start; i < html.length; i++) {
      const c: string = html[i];
      if (quoted) {
        if (escaped) escaped = false;
        else if (c === '\\') escaped = true;
        else if (c === '"') quoted = false;
      } else if (c === '"') quoted = true;
      else if (c === '{') depth++;
      else if (c === '}' && --depth === 0) {
        try { return asObject(JSON.parse(html.substring(start, i + 1)) as Object); }
        catch (_) { return null; }
      }
    }
    return null;
  }

  private static collect(node: Object, videos: Array<YouTubeVideo>, seen: Set<string>, depth: number): void {
    if (depth > 40 || node === null || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      for (const item of node as Array<Object>) YouTubeApi.collect(item, videos, seen, depth + 1);
      return;
    }
    const record: Record<string, Object> = asObject(node);
    // 广告位、推荐搜索词和频道卡片不冒充视频结果。
    if (record['adSlotRenderer'] !== undefined || record['promotedSparklesWebRenderer'] !== undefined) return;
    if (record['videoRenderer'] !== undefined) {
      const data: Record<string, Object> = asObject(record['videoRenderer']);
      const id: string = asString(data['videoId']);
      if (!YouTubeApi.validId(id) || seen.has(id)) return;
      const video: YouTubeVideo = new YouTubeVideo();
      video.id = id;
      video.title = textValue(data['title']);
      if (video.title.length === 0) return;
      video.channel = textValue(data['ownerText']) || textValue(data['longBylineText']);
      video.thumbnail = 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg';
      video.duration = textValue(data['lengthText']);
      video.views = textValue(data['viewCountText']);
      video.published = textValue(data['publishedTimeText']);
      const snippets: Object = data['detailedMetadataSnippets'];
      if (Array.isArray(snippets) && (snippets as Array<Object>).length > 0) {
        video.description = textValue(asObject((snippets as Array<Object>)[0])['snippetText']);
      }
      seen.add(id);
      videos.push(video);
      return;
    }
    for (const key of Object.keys(record)) YouTubeApi.collect(record[key], videos, seen, depth + 1);
  }

  static parseSearch(html: string): Array<YouTubeVideo> {
    const initial: Record<string, Object> | null = YouTubeApi.initialObject(html, 'ytInitialData');
    if (initial === null || initial['contents'] === undefined) {
      throw new Error('YouTube 返回了验证页或页面格式已变化，请稍后重试');
    }
    const videos: Array<YouTubeVideo> = [];
    YouTubeApi.collect(initial['contents'], videos, new Set<string>(), 0);
    return videos;
  }

  private static async page(url: string): Promise<string> {
    const response: HttpResponse = await HttpClient.get(url, {
      'Accept': 'text/html',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      // 必须声明桌面版 UA：不带 UA 时 YouTube 返回验证页/移动版页面，
      // ytInitialData 里没有 videoRenderer，解析会直接抛"页面格式已变化"。
      // 实测同一 URL：桌面 UA → 22 条结果可解析；移动 UA → 解析失败。
      'User-Agent': YouTubeApi.DESKTOP_UA,
    });
    if (!response.ok) throw new Error(response.status < 0 ?
      'YouTube 连接失败，请确认当前网络能访问 YouTube。' + response.transportMessage :
      'YouTube 暂时无法访问（HTTP ' + String(response.status) + '）');
    return response.body;
  }

  static async search(query: string): Promise<Array<YouTubeVideo>> {
    const term: string = query.trim().substring(0, 200);
    if (term.length === 0) return [];
    return YouTubeApi.parseSearch(await YouTubeApi.page(
      'https://www.youtube.com/results?search_query=' + encodeURIComponent(term) + '&hl=zh-CN'));
  }

  static async detail(id: string): Promise<YouTubeVideo> {
    if (!YouTubeApi.validId(id)) throw new Error('无效的 YouTube 视频链接');
    const html: string = await YouTubeApi.page('https://www.youtube.com/watch?v=' + id + '&hl=zh-CN');
    const player: Record<string, Object> | null = YouTubeApi.initialObject(html, 'ytInitialPlayerResponse');
    if (player === null) throw new Error('暂时无法读取视频详情，请稍后重试');
    const data: Record<string, Object> = asObject(player['videoDetails']);
    const result: YouTubeVideo = new YouTubeVideo();
    result.id = id;
    result.title = asString(data['title']);
    result.channel = asString(data['author']);
    result.thumbnail = 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg';
    result.description = asString(data['shortDescription']);
    const seconds: number = Number(asString(data['lengthSeconds']));
    if (seconds > 0) result.duration = formatDuration(seconds);
    result.views = asString(data['viewCount']);
    if (result.views.length > 0) result.views += ' 次观看';
    // 即使匿名取流被要求登录，公开 watch 页的标题、作者、简介通常仍然可读。
    const initial: Record<string, Object> | null = YouTubeApi.initialObject(html, 'ytInitialData');
    if (initial !== null) {
      const watch: Record<string, Object> = asObject(asObject(initial['contents'])['twoColumnWatchNextResults']);
      const content: Object = asObject(asObject(watch['results'])['results'])['contents'];
      if (Array.isArray(content)) {
        for (const item of content as Array<Object>) {
          const section: Record<string, Object> = asObject(item);
          const primary: Record<string, Object> = asObject(section['videoPrimaryInfoRenderer']);
          const secondary: Record<string, Object> = asObject(section['videoSecondaryInfoRenderer']);
          if (result.title.length === 0) result.title = textValue(primary['title']);
          if (result.views.length === 0) result.views = textValue(asObject(asObject(primary['viewCount'])['videoViewCountRenderer'])['viewCount']);
          if (result.published.length === 0) result.published = textValue(primary['dateText']);
          if (result.channel.length === 0) result.channel = textValue(asObject(asObject(secondary['owner'])['videoOwnerRenderer'])['title']);
          if (result.description.length === 0) result.description = asString(asObject(secondary['attributedDescription'])['content']) || textValue(secondary['description']);
        }
      }
    }
    if (result.title.length === 0) {
      const status: Record<string, Object> = asObject(player['playabilityStatus']);
      throw new Error(asString(status['reason']) || '视频详情不可用');
    }
    return result;
  }
}
