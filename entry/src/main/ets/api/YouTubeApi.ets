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

/** 取一组缩略图里的第一个地址（YouTube 按尺寸从小到大排列，首个足够列表使用）。 */
function thumbnailUrl(node: Object | undefined): string {
  const list: Object = asObject(node)['thumbnails'];
  if (!Array.isArray(list) || (list as Array<Object>).length === 0) return '';
  return asString(asObject((list as Array<Object>)[0])['url']);
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

  /**
   * 搜索结果列表的下一页 token。位置固定：primaryContents → sectionListRenderer →
   * contents 末尾的 continuationItemRenderer。取不到就返回空串——列表如实收尾，
   * 不伪造"还有更多"。
   */
  private static searchContinuation(initial: Record<string, Object>): string {
    const primary: Record<string, Object> = asObject(asObject(asObject(initial['contents'])
      ['twoColumnSearchResultsRenderer'])['primaryContents']);
    const sections: Object = asObject(primary['sectionListRenderer'])['contents'];
    if (!Array.isArray(sections)) return '';
    for (const section of sections as Array<Object>) {
      // 注意：asObject 只兜住自己那一层，中间层缺失时索引结果仍是 undefined，
      // 必须把索引结果再包一次，否则这里会抛 TypeError 而不是返回空 token。
      const endpoint: Record<string, Object> =
        asObject(asObject(asObject(section)['continuationItemRenderer'])['continuationEndpoint']);
      const token: string = asString(asObject(endpoint['continuationCommand'])['token']);
      if (token.length > 0) return token;
    }
    return '';
  }

  static parseSearchPage(html: string): YouTubeSearchPage {
    const initial: Record<string, Object> | null = YouTubeApi.initialObject(html, 'ytInitialData');
    if (initial === null || initial['contents'] === undefined) {
      throw new Error('YouTube 返回了验证页或页面格式已变化，请稍后重试');
    }
    const page: YouTubeSearchPage = new YouTubeSearchPage();
    YouTubeApi.collect(initial['contents'], page.videos, new Set<string>(), 0);
    page.continuation = YouTubeApi.searchContinuation(initial);
    return page;
  }

  /**
   * 搜索筛选定义：页面把「类型 / 时长 / 上传时间 / 功能 / 排序」放在搜索框旁边的
   * 过滤弹层里（searchFilterOptionsDialogRenderer）。只读取 label 与 params，
   * 不解释 params 的内容——回传时原样带上即可。
   */
  static parseFilters(html: string): Array<YouTubeSearchFilterGroup> {
    const initial: Record<string, Object> | null = YouTubeApi.initialObject(html, 'ytInitialData');
    if (initial === null) return [];
    const header: Record<string, Object> = asObject(asObject(initial['header'])['searchHeaderRenderer']);
    const button: Record<string, Object> = asObject(asObject(header['searchFilterButton'])['buttonRenderer']);
    // 每一层索引的结果都要再包一次 asObject：索引出来的是 Object，不能直接当 Record 用。
    const dialog: Record<string, Object> = asObject(
      asObject(asObject(asObject(button['command'])['openPopupAction'])['popup'])
        ['searchFilterOptionsDialogRenderer']);
    const groups: Object = asObject(dialog)['groups'];
    const out: Array<YouTubeSearchFilterGroup> = [];
    if (!Array.isArray(groups)) return out;
    for (const entry of groups as Array<Object>) {
      const group: Record<string, Object> = asObject(asObject(entry)['searchFilterGroupRenderer']);
      const filters: Object = group['filters'];
      if (!Array.isArray(filters)) continue;
      const parsed: YouTubeSearchFilterGroup = new YouTubeSearchFilterGroup();
      parsed.title = textValue(group['title']);
      for (const item of filters as Array<Object>) {
        const renderer: Record<string, Object> = asObject(asObject(item)['searchFilterRenderer']);
        const endpoint: Record<string, Object> = asObject(asObject(renderer['navigationEndpoint'])['searchEndpoint']);
        const filter: YouTubeSearchFilter = new YouTubeSearchFilter();
        filter.label = textValue(renderer['label']);
        filter.params = asString(endpoint['params']);
        if (filter.label.length > 0 && filter.params.length > 0) parsed.filters.push(filter);
      }
      if (parsed.filters.length > 0) out.push(parsed);
    }
    return out;
  }

  /** 只取视频列表的兼容入口；翻页需要 continuation，请用 parseSearchPage。 */
  static parseSearch(html: string): Array<YouTubeVideo> {
    return YouTubeApi.parseSearchPage(html).videos;
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

  /** 从 ytcfg 里取字符串配置。 */
  private static configString(html: string, key: string): string {
    const match: RegExpMatchArray | null = html.match(new RegExp('"' + key + '"\\s*:\\s*"([^"]*)"'));
    return match === null ? '' : match[1];
  }

  /**
   * 记住本次页面下发的 InnerTube 配置，返回是否可用。
   * 不可用时调用方必须关闭翻页/评论入口——宁可少一块，也不发注定无效的请求。
   */
  private static rememberInnerTube(html: string): boolean {
    const key: string = YouTubeApi.configString(html, 'INNERTUBE_API_KEY');
    const version: string = YouTubeApi.configString(html, 'INNERTUBE_CLIENT_VERSION');
    if (key.length === 0 || version.length === 0) return false;
    YouTubeApi.innerApiKey = key;
    YouTubeApi.innerClientVersion = version;
    return true;
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
    const page: YouTubeSearchPage = YouTubeApi.parseSearchPage(html);
    if (!YouTubeApi.rememberInnerTube(html)) page.continuation = '';
    page.filters = YouTubeApi.parseFilters(html);
    return page;
  }

  /**
   * 解析 InnerTube 翻页响应。新老两种容器都兼容：
   * onResponseReceivedCommands[].appendContinuationItemsAction / reloadContinuationItemsCommand，
   * 以及旧版 continuationContents.sectionListContinuation。解析不到就是空页，不抛错。
   */
  static parseContinuation(json: string): YouTubeSearchPage {
    const page: YouTubeSearchPage = new YouTubeSearchPage();
    let data: Record<string, Object>;
    try {
      data = asObject(JSON.parse(json) as Object);
    } catch (_) {
      throw new Error('YouTube 返回了无法解析的翻页数据');
    }
    const lists: Array<Object> = [];
    const commands: Object = data['onResponseReceivedCommands'];
    if (Array.isArray(commands)) {
      for (const command of commands as Array<Object>) {
        const record: Record<string, Object> = asObject(command);
        const append: Object = asObject(record['appendContinuationItemsAction'])['continuationItems'];
        const reload: Object = asObject(record['reloadContinuationItemsCommand'])['continuationItems'];
        if (Array.isArray(append)) lists.push(append);
        if (Array.isArray(reload)) lists.push(reload);
      }
    }
    if (lists.length === 0) {
      const legacy: Object =
        asObject(asObject(data['continuationContents'])['sectionListContinuation'])['contents'];
      if (Array.isArray(legacy)) lists.push(legacy);
    }
    const seen: Set<string> = new Set<string>();
    for (const list of lists) {
      YouTubeApi.collect(list, page.videos, seen, 0);
      for (const item of list as Array<Object>) {
        const endpoint: Record<string, Object> =
          asObject(asObject(asObject(item)['continuationItemRenderer'])['continuationEndpoint']);
        const token: string = asString(asObject(endpoint['continuationCommand'])['token']);
        if (token.length > 0) page.continuation = token;
      }
    }
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
    return YouTubeApi.parseContinuation(response.body);
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
    return YouTubeApi.parseComments(response.body);
  }

  /**
   * 评论正文不在 commentThreadRenderer 里，而在 frameworkUpdates 的 commentEntityPayload，
   * 两边靠 commentKey / key 对应。取不到对应关系的那条直接跳过，不猜内容。
   */
  static parseComments(json: string): YouTubeCommentPage {
    const page: YouTubeCommentPage = new YouTubeCommentPage();
    let data: Record<string, Object>;
    try {
      data = asObject(JSON.parse(json) as Object);
    } catch (_) {
      throw new Error('YouTube 返回了无法解析的评论数据');
    }
    const contents: Array<Object> = [];
    const endpoints: Object = data['onResponseReceivedEndpoints'];
    if (Array.isArray(endpoints)) {
      for (const endpoint of endpoints as Array<Object>) {
        const action: Record<string, Object> = asObject(endpoint);
        const append: Object = asObject(action['appendContinuationItemsAction'])['continuationItems'];
        const reload: Object = asObject(action['reloadContinuationItemsCommand'])['continuationItems'];
        if (Array.isArray(append)) for (const item of append as Array<Object>) contents.push(item);
        if (Array.isArray(reload)) for (const item of reload as Array<Object>) contents.push(item);
      }
    }
    const payloads: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>();
    const mutations: Object = asObject(asObject(data['frameworkUpdates'])['entityBatchUpdate'])['mutations'];
    if (Array.isArray(mutations)) {
      for (const mutation of mutations as Array<Object>) {
        const entity: Record<string, Object> =
          asObject(asObject(asObject(mutation)['payload'])['commentEntityPayload']);
        const key: string = asString(entity['key']);
        if (key.length > 0) payloads.set(key, entity);
      }
    }
    for (const item of contents) {
      const record: Record<string, Object> = asObject(item);
      if (record['commentsHeaderRenderer'] !== undefined) {
        page.total = textValue(asObject(record['commentsHeaderRenderer'])['countText']);
        continue;
      }
      if (record['continuationItemRenderer'] !== undefined) {
        const endpoint: Record<string, Object> =
          asObject(asObject(record['continuationItemRenderer'])['continuationEndpoint']);
        const next: string = asString(asObject(endpoint['continuationCommand'])['token']);
        if (next.length > 0) page.continuation = next;
        continue;
      }
      const thread: Record<string, Object> = asObject(record['commentThreadRenderer']);
      const viewModel: Record<string, Object> = asObject(asObject(thread['commentViewModel'])['commentViewModel']);
      const entity: Record<string, Object> | undefined = payloads.get(asString(viewModel['commentKey']));
      if (entity === undefined) continue;
      const properties: Record<string, Object> = asObject(entity['properties']);
      const author: Record<string, Object> = asObject(entity['author']);
      const toolbar: Record<string, Object> = asObject(entity['toolbar']);
      const comment: YouTubeComment = new YouTubeComment();
      comment.id = asString(properties['commentId']);
      comment.text = asString(asObject(properties['content'])['content']);
      comment.published = asString(properties['publishedTime']);
      comment.author = asString(author['displayName']);
      comment.avatar = asString(author['avatarThumbnailUrl']);
      comment.likes = asString(toolbar['likeCountNotliked']) || asString(toolbar['likeCountLiked']);
      if (comment.text.length > 0) page.comments.push(comment);
    }
    return page;
  }

  static async detail(id: string): Promise<YouTubeVideo> {
    return (await YouTubeApi.detailPage(id)).video;
  }

  /** 详情页需要的全部公开数据：视频本身、相关推荐、评论入口（一次页面请求拿齐）。 */
  static async detailPage(id: string): Promise<YouTubeWatchPage> {
    if (!YouTubeApi.validId(id)) throw new Error('无效的 YouTube 视频链接');
    const html: string = await YouTubeApi.page('https://www.youtube.com/watch?v=' + id + '&hl=zh-CN');
    const page: YouTubeWatchPage = YouTubeApi.parseDetailPage(html, id);
    // 评论要复用同一份 InnerTube 配置；拿不到就老实关掉评论入口，不发无效请求。
    if (!YouTubeApi.rememberInnerTube(html)) page.commentToken = '';
    return page;
  }

  static parseDetailPage(html: string, id: string): YouTubeWatchPage {
    const result: YouTubeVideo = new YouTubeVideo();
    const page: YouTubeWatchPage = new YouTubeWatchPage();
    page.video = result;
    const player: Record<string, Object> | null = YouTubeApi.initialObject(html, 'ytInitialPlayerResponse');
    if (player === null) throw new Error('暂时无法读取视频详情，请稍后重试');
    if (player === null) throw new Error('暂时无法读取视频详情，请稍后重试');
    const data: Record<string, Object> = asObject(player['videoDetails']);
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
          const owner: Record<string, Object> = asObject(asObject(secondary['owner'])['videoOwnerRenderer']);
          if (result.channel.length === 0) result.channel = textValue(owner['title']);
          if (result.channelAvatar.length === 0) result.channelAvatar = thumbnailUrl(owner['thumbnail']);
          if (result.subscribers.length === 0) result.subscribers = textValue(owner['subscriberCountText']);
          if (result.description.length === 0) result.description = asString(asObject(secondary['attributedDescription'])['content']) || textValue(secondary['description']);
        }
      }
    }
    if (result.title.length === 0) {
      const status: Record<string, Object> = asObject(player['playabilityStatus']);
      throw new Error(asString(status['reason']) || '视频详情不可用');
    }
    if (initial !== null) {
      page.related = YouTubeApi.parseRelated(initial);
      page.commentToken = YouTubeApi.parseCommentToken(initial);
    }
    return page;
  }

  /**
   * 相关推荐：新版用 lockupViewModel（旧版 compactVideoRenderer 也兼容）。
   * 位置固定在 secondaryResults，不做全页扫描——播放器推荐位的数据结构会变。
   */
  private static parseRelated(initial: Record<string, Object>): Array<YouTubeVideo> {
    const watch: Record<string, Object> = asObject(asObject(initial['contents'])['twoColumnWatchNextResults']);
    const secondary: Record<string, Object> = asObject(asObject(watch['secondaryResults'])['secondaryResults']);
    const results: Object = secondary['results'];
    const videos: Array<YouTubeVideo> = [];
    const seen: Set<string> = new Set<string>();
    if (Array.isArray(results)) {
      YouTubeApi.collectLockups(results as Array<Object>, videos, seen, 0);
      YouTubeApi.collect(results as Array<Object>, videos, seen, 0);
    }
    return videos;
  }

  /** lockupViewModel → YouTubeVideo：标题/频道/观看数/时长都在 metadata 与 overlays 里。 */
  private static collectLockups(node: Object, videos: Array<YouTubeVideo>, seen: Set<string>, depth: number): void {
    if (depth > 30 || node === null || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      for (const item of node as Array<Object>) YouTubeApi.collectLockups(item, videos, seen, depth + 1);
      return;
    }
    const record: Record<string, Object> = asObject(node);
    if (record['lockupViewModel'] !== undefined) {
      const lockup: Record<string, Object> = asObject(record['lockupViewModel']);
      const id: string = asString(lockup['contentId']);
      if (YouTubeApi.validId(id) && !seen.has(id)) {
        const metadata: Record<string, Object> = asObject(asObject(lockup['metadata'])['lockupMetadataViewModel']);
        const video: YouTubeVideo = new YouTubeVideo();
        video.id = id;
        video.title = asString(asObject(metadata['title'])['content']);
        video.thumbnail = 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg';
        video.duration = YouTubeApi.lockupDuration(lockup);
        YouTubeApi.fillLockupMetadata(metadata, video);
        if (video.title.length > 0) {
          seen.add(id);
          videos.push(video);
        }
      }
    }
    for (const key of Object.keys(record)) YouTubeApi.collectLockups(record[key], videos, seen, depth + 1);
  }

  /** 封面右下角的时长角标。 */
  private static lockupDuration(lockup: Record<string, Object>): string {
    const overlays: Object = asObject(asObject(lockup['contentImage'])['thumbnailViewModel'])['overlays'];
    if (!Array.isArray(overlays)) return '';
    for (const overlay of overlays as Array<Object>) {
      const badges: Object = asObject(asObject(overlay)['thumbnailBottomOverlayViewModel'])['badges'];
      if (!Array.isArray(badges)) continue;
      for (const badge of badges as Array<Object>) {
        const text: string = asString(asObject(asObject(badge)['thumbnailBadgeViewModel'])['text']);
        if (text.length > 0) return text;
      }
    }
    return '';
  }

  /** metadataRows：第一段是频道名，其余是观看数/发布时间。 */
  private static fillLockupMetadata(metadata: Record<string, Object>, video: YouTubeVideo): void {
    const rows: Object = asObject(metadata['metadata'])['contentMetadataViewModel'];
    const list: Object = asObject(rows)['metadataRows'];
    if (!Array.isArray(list)) return;
    const parts: Array<string> = [];
    for (const row of list as Array<Object>) {
      const items: Object = asObject(row)['metadataParts'];
      if (!Array.isArray(items)) continue;
      for (const part of items as Array<Object>) {
        const text: string = asString(asObject(asObject(part)['text'])['content']);
        if (text.length > 0) parts.push(text);
      }
    }
    if (parts.length > 0) video.channel = parts[0];
    if (parts.length > 1) {
      video.views = parts[1];
      if (parts.length > 2) video.published = parts[2];
    }
  }

  /** 评论区入口：watch 页只给一个 continuation token，评论正文要再请求一次 InnerTube next。 */
  private static parseCommentToken(initial: Record<string, Object>): string {
    const watch: Record<string, Object> = asObject(asObject(initial['contents'])['twoColumnWatchNextResults']);
    const content: Object = asObject(asObject(watch['results'])['results'])['contents'];
    if (!Array.isArray(content)) return '';
    for (const item of content as Array<Object>) {
      const section: Record<string, Object> = asObject(asObject(item)['itemSectionRenderer']);
      const identifier: string = asString(section['sectionIdentifier']);
      if (identifier.indexOf('comment') < 0) continue;
      const items: Object = section['contents'];
      if (!Array.isArray(items)) continue;
      for (const entry of items as Array<Object>) {
        const endpoint: Record<string, Object> =
          asObject(asObject(asObject(entry)['continuationItemRenderer'])['continuationEndpoint']);
        const token: string = asString(asObject(endpoint['continuationCommand'])['token']);
        if (token.length > 0) return token;
      }
    }
    return '';
  }

  // 注：watch 页的 commentsHeaderRenderer.countText 是区块标题（「评论」）而不是数量，
  // 未登录的评论响应也常常没有计数，因此不猜数字——拿不到就不显示数量。
}
