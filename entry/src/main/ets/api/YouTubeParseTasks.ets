/**
 * YouTube 解析 taskpool 任务：2MB 级 HTML / InnerTube JSON 的提取与 JSON.parse 全部在后台线程执行。
 * 核心逻辑在 YouTubeParseCore.ets（@Concurrent 函数只能引用 import 或局部，解析器必须独立成模块）。
 */
import { taskpool } from '@kit.ArkTS';
import { SendableYtCommentPage, SendableYtSearchPage, SendableYtWatchPage,
  parseCommentsCore, parseContinuationCore, parseDetailPageCore, parseSearchPageCore } from './YouTubeParseCore';

export { SendableYtComment, SendableYtCommentPage, SendableYtFilter, SendableYtFilterGroup,
  SendableYtSearchPage, SendableYtVideo, SendableYtWatchPage } from './YouTubeParseCore';

@Concurrent
function parseSearchPageTask(html: string): SendableYtSearchPage {
  return parseSearchPageCore(html);
}

@Concurrent
function parseContinuationTask(json: string): SendableYtSearchPage {
  return parseContinuationCore(json);
}

@Concurrent
function parseCommentsTask(json: string): SendableYtCommentPage {
  return parseCommentsCore(json);
}

@Concurrent
function parseDetailPageTask(html: string, id: string): SendableYtWatchPage {
  return parseDetailPageCore(html, id);
}

/** 搜索页整页解析（视频 + 翻页 token + 筛选项 + InnerTube 配置，单次扫描）。 */
export async function parseSearchPageAsync(html: string): Promise<SendableYtSearchPage> {
  return await taskpool.execute(parseSearchPageTask, html) as SendableYtSearchPage;
}

/** InnerTube 翻页响应解析。 */
export async function parseContinuationAsync(json: string): Promise<SendableYtSearchPage> {
  return await taskpool.execute(parseContinuationTask, json) as SendableYtSearchPage;
}

/** 评论响应解析。 */
export async function parseCommentsAsync(json: string): Promise<SendableYtCommentPage> {
  return await taskpool.execute(parseCommentsTask, json) as SendableYtCommentPage;
}

/** 详情页整页解析（ytInitialPlayerResponse + ytInitialData）。 */
export async function parseDetailPageAsync(html: string, id: string): Promise<SendableYtWatchPage> {
  return await taskpool.execute(parseDetailPageTask, html, id) as SendableYtWatchPage;
}
