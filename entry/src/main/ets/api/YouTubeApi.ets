/**
 * YouTube 公开页面/接口读取与解析。
 * 大 JSON（ytInitialData / InnerTube 响应）的提取与解析在 taskpool 后台线程执行
 * （核心在 YouTubeParseCore.ets，任务封装在 YouTubeParseTasks.ets），
 * 本文件只负责网络请求、把可跨线程的结果映射为 UI 模型、以及 InnerTube 配置缓存。
 */
import { collections } from '@kit.ArkTS';
import { HttpClient, HttpResponse } from '../services/network/HttpClient';
import { parseSearchPageAsync, parseContinuationAsync, parseCommentsAsync, parseDetailPageAsync,
  SendableYtComment, SendableYtCommentPage, SendableYtFilterGroup, SendableYtSearchPage,
  SendableYtVideo, SendableYtWatchPage } from './YouTubeParseTasks';
import { extractInitialObject, parseContinuationCore, parseCommentsCore, parseDetailPageCore,
  parseFiltersCore, parseSearchPageCore } from './YouTubeParseCore';

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
  /** 频道头像与订阅数：详情页频道行用，搜索/相关推荐列表里为空。 */
  channelAvatar: string = '';
  subscribers: string = '';
}

/** 搜索筛选的一个选项：label 是页面给的中文名，params 是回传时必须原样带的串。 */
export class YouTubeSearchFilter {
  label: string = '';
  params: string = '';
}

/** 一组筛选（类型 / 时长 / 上传时间 / 功能 / 排序）。 */
export class YouTubeSearchFilterGroup {
  title: string = '';
  filters: Array<YouTubeSearchFilter> = [];
}

/** 搜索结果的一页：视频列表 + 下一页 token（空串表示没有更多）+ 可用筛选项。 */
export class YouTubeSearchPage {
  videos: Array<YouTubeVideo> = [];
  continuation: string = '';
  /** 只有首页带筛选定义；翻页响应里没有。 */
  filters: Array<YouTubeSearchFilterGroup> = [];
}

/** 一条评论。只读公开数据，不涉及账号或发布能力。 */
export class YouTubeComment {
  id: string = '';
  author: string = '';
  avatar: string = '';
  text: string = '';
  likes: string = '';
  published: string = '';
}

export class YouTubeCommentPage {
  comments: Array<YouTubeComment> = [];
  continuation: string = '';
  /** 评论区标题里的总数文案，取不到就是空串。 */
  total: string = '';
}

/** 详情页聚合：视频本身 + 相关推荐 + 评论入口。 */
export class YouTubeWatchPage {
  video: YouTubeVideo = new YouTubeVideo();
  related: Array<YouTubeVideo> = [];
  commentToken: string = '';
  commentTotal: string = '';
}

/** InnerTube 翻页请求体。字段名是 YouTube 自己的拼写，不能改名。 */
interface InnerTubeClient {
  clientName: string;
  clientVersion: string;
  hl: string;
}

interface InnerTubeContext {
  client: InnerTubeClient;
}

interface InnerTubeRequest {
  context: InnerTubeContext;
  continuation: string;
}

export class YouTubeApi {
  /**
   * 请求公开页面时声明桌面版 UA。不带 UA 会被 YouTube 判为不可信客户端并返回
   * 验证页/移动版页面：ytInitialData 里没有 videoRenderer，搜索解析会失败。
   * 这是服务端兼容性所需，不涉及伪装登录态，也不改变任何账号语义。
   */
  private static readonly DESKTOP_UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /**
   * InnerTube 翻页配置来自搜索页 HTML 自带的 ytcfg（公开网页配置，不是账号凭据）。
   * 只在进程内缓存；取不到就关闭翻页，而不是拿旧值拼一个可能已失效的请求。
   */
  private static innerApiKey: string = '';
  private static innerClientVersion: string = '';

  static validId(id: string): boolean { return /^[a-zA-Z0-9_-]{11}$/.test(id); }

  /**
   * 规范分享/打开链接：只用校验过的 11 位 ID 拼，绝不把用户输入直接塞进 URL。
   * 无效 ID 返回空串，调用方据此禁用入口，而不是发一个畸形链接。
   */
  static watchUrl(id: string): string {
    return YouTubeApi.validId(id) ? 'https://youtu.be/' + id : '';
  }

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

  /** 扫描 JSON 的字符串/括号边界（实现与 worker 解析核心共用）。 */
  static initialObject(html: string, variable: string): Record<string, Object> | null {
    return extractInitialObject(html, variable);
  }

  // ===== 可跨线程解析结果 → UI 模型 =====

  private static toVideo(s: SendableYtVideo): YouTubeVideo {
    const video: YouTubeVideo = new YouTubeVideo();
    video.id = s.id;
    video.title = s.title;
    video.channel = s.channel;
    video.thumbnail = s.thumbnail;
    video.duration = s.duration;
    video.views = s.views;
    video.published = s.published;
    video.description = s.description;
    video.notice = s.notice;
    video.channelAvatar = s.channelAvatar;
    video.subscribers = s.subscribers;
    return video;
  }

  private static toFilterGroups(groups: collections.Array<SendableYtFilterGroup>): Array<YouTubeSearchFilterGroup> {
    const out: Array<YouTubeSearchFilterGroup> = [];
    for (let i: number = 0; i < groups.length; i++) {
      const group: SendableYtFilterGroup = groups[i];
      const target: YouTubeSearchFilterGroup = new YouTubeSearchFilterGroup();
      target.title = group.title;
      for (let j: number = 0; j < group.filters.length; j++) {
        const filter: YouTubeSearchFilter = new YouTubeSearchFilter();
        filter.label = group.filters[j].label;
        filter.params = group.filters[j].params;
        target.filters.push(filter);
      }
      out.push(target);
    }
    return out;
  }

  private static toSearchPage(s: SendableYtSearchPage): YouTubeSearchPage {
    const page: YouTubeSearchPage = new YouTubeSearchPage();
    for (let i: number = 0; i < s.videos.length; i++) {
      page.videos.push(YouTubeApi.toVideo(s.videos[i]));
    }
    page.continuation = s.continuation;
    page.filters = YouTubeApi.toFilterGroups(s.filters);
    return page;
  }

  private static toCommentPage(s: SendableYtCommentPage): YouTubeCommentPage {
    const page: YouTubeCommentPage = new YouTubeCommentPage();
    for (let i: number = 0; i < s.comments.length; i++) {
      const source: SendableYtComment = s.comments[i];
      const comment: YouTubeComment = new YouTubeComment();
      comment.id = source.id;
      comment.author = source.author;
      comment.avatar = source.avatar;
      comment.text = source.text;
      comment.likes = source.likes;
      comment.published = source.published;
      page.comments.push(comment);
    }
    page.continuation = s.continuation;
    page.total = s.total;
    return page;
  }

  private static toWatchPage(s: SendableYtWatchPage): YouTubeWatchPage {
    const page: YouTubeWatchPage = new YouTubeWatchPage();
    page.video = YouTubeApi.toVideo(s.video);
    for (let i: number = 0; i < s.related.length; i++) {
      page.related.push(YouTubeApi.toVideo(s.related[i]));
    }
    page.commentToken = s.commentToken;
    return page;
  }

  /** 记住本次页面下发的 InnerTube 配置，返回是否可用（不可用时调用方须关闭翻页/评论）。 */
  private static applyInnerTube(apiKey: string, clientVersion: string): boolean {
    if (apiKey.length === 0 || clientVersion.length === 0) return false;
    YouTubeApi.innerApiKey = apiKey;
    YouTubeApi.innerClientVersion = clientVersion;
    return true;
  }

  // ===== 同步解析入口（QA 测试与兼容调用；生产链路走异步 + taskpool） =====

  static parseSearchPage(html: string): YouTubeSearchPage {
    return YouTubeApi.toSearchPage(parseSearchPageCore(html));
  }

  static parseFilters(html: string): Array<YouTubeSearchFilterGroup> {
    return YouTubeApi.toFilterGroups(parseFiltersCore(html));
  }

  /** 只取视频列表的兼容入口；翻页需要 continuation，请用 parseSearchPage。 */
  static parseSearch(html: string): Array<YouTubeVideo> {
    return YouTubeApi.parseSearchPage(html).videos;
  }

  static parseContinuation(json: string): YouTubeSearchPage {
    return YouTubeApi.toSearchPage(parseContinuationCore(json));
  }

  static parseComments(json: string): YouTubeCommentPage {
    return YouTubeApi.toCommentPage(parseCommentsCore(json));
  }

  static parseDetailPage(html: string, id: string): YouTubeWatchPage {
    return YouTubeApi.toWatchPage(parseDetailPageCore(html, id));
  }

  // ===== 网络请求（响应解析在 taskpool 执行） =====

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

  /**
   * 搜索联想：Google 的公开 suggest 接口，`client=firefox` 返回纯 JSON（不是 JSONP），
   * 因此不需要执行任何远端脚本。失败一律返回空数组——联想挂了不能影响输入与搜索本身。
   */
  static async suggest(query: string): Promise<Array<string>> {
    const term: string = query.trim().substring(0, 200);
    if (term.length === 0) return [];
    try {
      const response: HttpResponse = await HttpClient.get(
        'https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&hl=zh-CN&q=' +
        encodeURIComponent(term), {
          'Accept': 'application/json',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          'User-Agent': YouTubeApi.DESKTOP_UA,
        });
      if (!response.ok) return [];
      return YouTubeApi.parseSuggest(response.body);
    } catch (e) {
      // 联想是输入辅助，网络失败不该把异常抛给调用方，更不该挡住输入与搜索。
      return [];
    }
  }

  /** 联想响应是 `["关键词", ["建议", ...], ...]`；只取字符串项并去重。 */
  static parseSuggest(body: string): Array<string> {
    try {
      const parsed: Object = JSON.parse(body) as Object;
      if (!Array.isArray(parsed) || (parsed as Array<Object>).length < 2) return [];
      const list: Object = (parsed as Array<Object>)[1];
      if (!Array.isArray(list)) return [];
      const out: Array<string> = [];
      for (const item of list as Array<Object>) {
        if (typeof item !== 'string') continue;
        const value: string = (item as string).trim();
        if (value.length > 0 && out.indexOf(value) < 0 && out.length < 8) out.push(value);
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /**
   * 搜索。`filterParams` 来自上一页 `/results` 里的筛选项，必须原样回传（含 %3D 转义），
   * 不自己拼 protobuf，避免猜错含义。
   */
  static async search(query: string, filterParams: string = ''): Promise<YouTubeSearchPage> {
    const term: string = query.trim().substring(0, 200);
    if (term.length === 0) return new YouTubeSearchPage();
    const suffix: string = filterParams.length > 0 ? '&sp=' + filterParams : '';
    const html: string = await YouTubeApi.page(
      'https://www.youtube.com/results?search_query=' + encodeURIComponent(term) + suffix + '&hl=zh-CN');
    // 单次 HTML 扫描产出视频/翻页/筛选/InnerTube 配置（旧实现提取+解析了两遍）。
    const sendable: SendableYtSearchPage = await parseSearchPageAsync(html);
    const page: YouTubeSearchPage = YouTubeApi.toSearchPage(sendable);
    if (!YouTubeApi.applyInnerTube(sendable.innerApiKey, sendable.innerClientVersion)) page.continuation = '';
    return page;
  }

  /**
   * 翻页：YouTube 网页端的「加载更多」走 InnerTube continuation（POST + 页面下发的 key），
   * 不是给结果页加 page 参数。token 由上一页携带，空 token 直接返回空页。
   */
  static async searchMore(token: string): Promise<YouTubeSearchPage> {
    if (token.length === 0 || YouTubeApi.innerApiKey.length === 0) return new YouTubeSearchPage();
    const response: HttpResponse = await YouTubeApi.postInnerTube('youtubei/v1/search', token);
    YouTubeApi.ensureOk(response);
    return YouTubeApi.toSearchPage(await parseContinuationAsync(response.body));
  }

  /** 搜索翻页与评论共用同一份 InnerTube 请求形态；默认不下发代理，与历史行为一致。 */
  private static async postInnerTube(path: string, continuation: string): Promise<HttpResponse> {
    const body: InnerTubeRequest = {
      context: { client: { clientName: 'WEB', clientVersion: YouTubeApi.innerClientVersion, hl: 'zh-CN' } },
      continuation: continuation,
    };
    return await HttpClient.post(
      'https://www.youtube.com/' + path + '?key=' + YouTubeApi.innerApiKey + '&prettyPrint=false',
      JSON.stringify(body), {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        // 与首页请求同样的桌面 UA：缺了它会拿到验证页而不是结果。
        'User-Agent': YouTubeApi.DESKTOP_UA,
      });
  }

  private static ensureOk(response: HttpResponse): void {
    if (response.ok) return;
    throw new Error(response.status < 0 ?
      'YouTube 连接失败，请确认当前网络能访问 YouTube。' + response.transportMessage :
      'YouTube 暂时无法访问（HTTP ' + String(response.status) + '）');
  }

  /**
   * 评论第一页：watch 页只给 continuation token，正文要 POST InnerTube `next`。
   * 只读公开评论，不涉及账号、点赞或回复。
   */
  static async comments(token: string): Promise<YouTubeCommentPage> {
    if (token.length === 0 || YouTubeApi.innerApiKey.length === 0) return new YouTubeCommentPage();
    const response: HttpResponse = await YouTubeApi.postInnerTube('youtubei/v1/next', token);
    YouTubeApi.ensureOk(response);
    return YouTubeApi.toCommentPage(await parseCommentsAsync(response.body));
  }

  static async detail(id: string): Promise<YouTubeVideo> {
    return (await YouTubeApi.detailPage(id)).video;
  }

  /** 详情页需要的全部公开数据：视频本身、相关推荐、评论入口（一次页面请求拿齐）。 */
  static async detailPage(id: string): Promise<YouTubeWatchPage> {
    if (!YouTubeApi.validId(id)) throw new Error('无效的 YouTube 视频链接');
    const html: string = await YouTubeApi.page('https://www.youtube.com/watch?v=' + id + '&hl=zh-CN');
    const sendable: SendableYtWatchPage = await parseDetailPageAsync(html, id);
    const page: YouTubeWatchPage = YouTubeApi.toWatchPage(sendable);
    // 评论要复用同一份 InnerTube 配置；拿不到就老实关掉评论入口，不发无效请求。
    if (!YouTubeApi.applyInnerTube(sendable.innerApiKey, sendable.innerClientVersion)) page.commentToken = '';
    return page;
  }

  // 注：watch 页的 commentsHeaderRenderer.countText 是区块标题（「评论」）而不是数量，
  // 未登录的评论响应也常常没有计数，因此不猜数字——拿不到就不显示数量。
}
