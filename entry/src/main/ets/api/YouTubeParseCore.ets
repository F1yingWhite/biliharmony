/**
 * YouTube 页面/接口解析核心（纯函数，无 UI / 网络依赖）。
 * 解析对象是 2MB 级的 HTML（含 ytInitialData / ytInitialPlayerResponse）与 InnerTube JSON，
 * 全部在 taskpool 工作线程执行；任务封装见 YouTubeParseTasks.ets。
 *
 * 注意：@Concurrent 函数只能引用「import 的或局部」的变量/类型，因此解析器必须独立成模块。
 * @Sendable 类字段只允许基础类型与 @arkts.collections 容器（普通 Array 不能作为字段）。
 */
import { collections } from '@kit.ArkTS';
import { asObject, asString, formatDuration } from '../common/Utils';

/** 视频元数据（跨线程共享）。字段与 YouTubeVideo 一一对应，主线程再映射为 UI 模型。 */
@Sendable
export class SendableYtVideo {
  id: string = '';
  title: string = '';
  channel: string = '';
  thumbnail: string = '';
  duration: string = '';
  views: string = '';
  published: string = '';
  description: string = '';
  notice: string = '';
  channelAvatar: string = '';
  subscribers: string = '';
}

@Sendable
export class SendableYtFilter {
  label: string = '';
  params: string = '';
}

@Sendable
export class SendableYtFilterGroup {
  title: string = '';
  filters: collections.Array<SendableYtFilter> = new collections.Array<SendableYtFilter>();
}

/** 搜索结果页：视频 + 下一页 token + 筛选项 + 页面下发的 InnerTube 配置（空串=不可用）。 */
@Sendable
export class SendableYtSearchPage {
  videos: collections.Array<SendableYtVideo> = new collections.Array<SendableYtVideo>();
  continuation: string = '';
  filters: collections.Array<SendableYtFilterGroup> = new collections.Array<SendableYtFilterGroup>();
  innerApiKey: string = '';
  innerClientVersion: string = '';
}

@Sendable
export class SendableYtComment {
  id: string = '';
  author: string = '';
  avatar: string = '';
  text: string = '';
  likes: string = '';
  published: string = '';
}

@Sendable
export class SendableYtCommentPage {
  comments: collections.Array<SendableYtComment> = new collections.Array<SendableYtComment>();
  continuation: string = '';
  total: string = '';
}

@Sendable
export class SendableYtWatchPage {
  video: SendableYtVideo = new SendableYtVideo();
  related: collections.Array<SendableYtVideo> = new collections.Array<SendableYtVideo>();
  commentToken: string = '';
  innerApiKey: string = '';
  innerClientVersion: string = '';
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

/** 扫描 JSON 的字符串/括号边界；标题中的分号、花括号不会截断数据。绝不执行远端脚本。 */
export function extractInitialObject(html: string, variable: string): Record<string, Object> | null {
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

function collect(node: Object, videos: collections.Array<SendableYtVideo>, seen: Set<string>, depth: number): void {
  if (depth > 40 || node === null || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    for (const item of node as Array<Object>) collect(item, videos, seen, depth + 1);
    return;
  }
  const record: Record<string, Object> = asObject(node);
  // 广告位、推荐搜索词和频道卡片不冒充视频结果。
  if (record['adSlotRenderer'] !== undefined || record['promotedSparklesWebRenderer'] !== undefined) return;
  if (record['videoRenderer'] !== undefined) {
    const data: Record<string, Object> = asObject(record['videoRenderer']);
    const id: string = asString(data['videoId']);
    if (!validId(id) || seen.has(id)) return;
    const video: SendableYtVideo = new SendableYtVideo();
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
  for (const key of Object.keys(record)) collect(record[key], videos, seen, depth + 1);
}

function validId(id: string): boolean {
  return /^[a-zA-Z0-9_-]{11}$/.test(id);
}

/**
 * 搜索结果列表的下一页 token。位置固定：primaryContents → sectionListRenderer →
 * contents 末尾的 continuationItemRenderer。取不到就返回空串——列表如实收尾。
 */
function searchContinuation(initial: Record<string, Object>): string {
  const primary: Record<string, Object> = asObject(asObject(asObject(initial['contents'])
    ['twoColumnSearchResultsRenderer'])['primaryContents']);
  const sections: Object = asObject(primary['sectionListRenderer'])['contents'];
  if (!Array.isArray(sections)) return '';
  for (const section of sections as Array<Object>) {
    const endpoint: Record<string, Object> =
      asObject(asObject(asObject(section)['continuationItemRenderer'])['continuationEndpoint']);
    const token: string = asString(asObject(endpoint['continuationCommand'])['token']);
    if (token.length > 0) return token;
  }
  return '';
}

/** 搜索筛选定义（searchFilterOptionsDialogRenderer）：只读 label 与 params，回传时原样带上。 */
function collectFilters(initial: Record<string, Object>): collections.Array<SendableYtFilterGroup> {
  const out: collections.Array<SendableYtFilterGroup> = new collections.Array<SendableYtFilterGroup>();
  const header: Record<string, Object> = asObject(asObject(initial['header'])['searchHeaderRenderer']);
  const button: Record<string, Object> = asObject(asObject(header['searchFilterButton'])['buttonRenderer']);
  const dialog: Record<string, Object> = asObject(
    asObject(asObject(asObject(button['command'])['openPopupAction'])['popup'])
      ['searchFilterOptionsDialogRenderer']);
  const groups: Object = asObject(dialog)['groups'];
  if (!Array.isArray(groups)) return out;
  for (const entry of groups as Array<Object>) {
    const group: Record<string, Object> = asObject(asObject(entry)['searchFilterGroupRenderer']);
    const filters: Object = group['filters'];
    if (!Array.isArray(filters)) continue;
    const parsed: SendableYtFilterGroup = new SendableYtFilterGroup();
    parsed.title = textValue(group['title']);
    for (const item of filters as Array<Object>) {
      const renderer: Record<string, Object> = asObject(asObject(item)['searchFilterRenderer']);
      const endpoint: Record<string, Object> = asObject(asObject(renderer['navigationEndpoint'])['searchEndpoint']);
      const filter: SendableYtFilter = new SendableYtFilter();
      filter.label = textValue(renderer['label']);
      filter.params = asString(endpoint['params']);
      if (filter.label.length > 0 && filter.params.length > 0) parsed.filters.push(filter);
    }
    if (parsed.filters.length > 0) out.push(parsed);
  }
  return out;
}

/** 从 ytcfg 里取字符串配置。 */
function configString(html: string, key: string): string {
  const match: RegExpMatchArray | null = html.match(new RegExp('"' + key + '"\\s*:\\s*"([^"]*)"'));
  return match === null ? '' : match[1];
}

/**
 * 搜索页整页解析：一次 HTML 扫描 + 一次 ytInitialData 解析，
 * 同时产出视频列表、翻页 token、筛选项与 InnerTube 配置（旧实现提取/解析了两遍）。
 */
export function parseSearchPageCore(html: string): SendableYtSearchPage {
  const initial: Record<string, Object> | null = extractInitialObject(html, 'ytInitialData');
  if (initial === null || initial['contents'] === undefined) {
    throw new Error('YouTube 返回了验证页或页面格式已变化，请稍后重试');
  }
  const page: SendableYtSearchPage = new SendableYtSearchPage();
  collect(initial['contents'], page.videos, new Set<string>(), 0);
  page.continuation = searchContinuation(initial);
  page.filters = collectFilters(initial);
  page.innerApiKey = configString(html, 'INNERTUBE_API_KEY');
  page.innerClientVersion = configString(html, 'INNERTUBE_CLIENT_VERSION');
  return page;
}

/** 只解析筛选项（测试与兼容入口；页面缺失时返回空，不抛错）。 */
export function parseFiltersCore(html: string): collections.Array<SendableYtFilterGroup> {
  const initial: Record<string, Object> | null = extractInitialObject(html, 'ytInitialData');
  if (initial === null) return new collections.Array<SendableYtFilterGroup>();
  return collectFilters(initial);
}

/**
 * InnerTube 翻页响应：新老两种容器都兼容
 * （onResponseReceivedCommands[].appendContinuationItemsAction / reloadContinuationItemsCommand，
 * 以及旧版 continuationContents.sectionListContinuation）。解析不到就是空页，不抛错。
 */
export function parseContinuationCore(json: string): SendableYtSearchPage {
  const page: SendableYtSearchPage = new SendableYtSearchPage();
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
    collect(list, page.videos, seen, 0);
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
 * 评论正文不在 commentThreadRenderer 里，而在 frameworkUpdates 的 commentEntityPayload，
 * 两边靠 commentKey / key 对应。取不到对应关系的那条直接跳过，不猜内容。
 */
export function parseCommentsCore(json: string): SendableYtCommentPage {
  const page: SendableYtCommentPage = new SendableYtCommentPage();
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
    const comment: SendableYtComment = new SendableYtComment();
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

/**
 * 详情页解析：ytInitialPlayerResponse（videoDetails）+ watch 页补充信息 + 相关推荐 + 评论入口。
 * 标题为空时按 playabilityStatus.reason 抛错（视频不可用），与旧行为一致。
 */
export function parseDetailPageCore(html: string, id: string): SendableYtWatchPage {
  const page: SendableYtWatchPage = new SendableYtWatchPage();
  const result: SendableYtVideo = new SendableYtVideo();
  page.video = result;
  const player: Record<string, Object> | null = extractInitialObject(html, 'ytInitialPlayerResponse');
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
  const initial: Record<string, Object> | null = extractInitialObject(html, 'ytInitialData');
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
    page.related = parseRelated(initial);
    page.commentToken = parseCommentToken(initial);
  }
  page.innerApiKey = configString(html, 'INNERTUBE_API_KEY');
  page.innerClientVersion = configString(html, 'INNERTUBE_CLIENT_VERSION');
  return page;
}

/**
 * 相关推荐：新版用 lockupViewModel（旧版 compactVideoRenderer 也兼容）。
 * 位置固定在 secondaryResults，不做全页扫描——播放器推荐位的数据结构会变。
 */
function parseRelated(initial: Record<string, Object>): collections.Array<SendableYtVideo> {
  const videos: collections.Array<SendableYtVideo> = new collections.Array<SendableYtVideo>();
  const watch: Record<string, Object> = asObject(asObject(initial['contents'])['twoColumnWatchNextResults']);
  const secondary: Record<string, Object> = asObject(asObject(watch['secondaryResults'])['secondaryResults']);
  const results: Object = secondary['results'];
  const seen: Set<string> = new Set<string>();
  if (Array.isArray(results)) {
    collectLockups(results as Array<Object>, videos, seen, 0);
    collect(results as Array<Object>, videos, seen, 0);
  }
  return videos;
}

/** lockupViewModel → 视频：标题/频道/观看数/时长都在 metadata 与 overlays 里。 */
function collectLockups(node: Object, videos: collections.Array<SendableYtVideo>, seen: Set<string>, depth: number): void {
  if (depth > 30 || node === null || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    for (const item of node as Array<Object>) collectLockups(item, videos, seen, depth + 1);
    return;
  }
  const record: Record<string, Object> = asObject(node);
  if (record['lockupViewModel'] !== undefined) {
    const lockup: Record<string, Object> = asObject(record['lockupViewModel']);
    const id: string = asString(lockup['contentId']);
    if (validId(id) && !seen.has(id)) {
      const metadata: Record<string, Object> = asObject(asObject(lockup['metadata'])['lockupMetadataViewModel']);
      const video: SendableYtVideo = new SendableYtVideo();
      video.id = id;
      video.title = asString(asObject(metadata['title'])['content']);
      video.thumbnail = 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg';
      video.duration = lockupDuration(lockup);
      fillLockupMetadata(metadata, video);
      if (video.title.length > 0) {
        seen.add(id);
        videos.push(video);
      }
    }
  }
  for (const key of Object.keys(record)) collectLockups(record[key], videos, seen, depth + 1);
}

/** 封面右下角的时长角标。 */
function lockupDuration(lockup: Record<string, Object>): string {
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
function fillLockupMetadata(metadata: Record<string, Object>, video: SendableYtVideo): void {
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
function parseCommentToken(initial: Record<string, Object>): string {
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
