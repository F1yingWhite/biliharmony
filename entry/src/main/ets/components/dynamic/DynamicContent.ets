import { DynamicItem, DynamicRichNode, BiliEmote } from '../../model/Models';
import { DynamicApi } from '../../api/DynamicApi';
import { EmoteResolver } from '../../common/EmoteResolver';

export class DynamicContentPart {
  text: string = '';
  image: string = '';
  key: string = '';
  /** 1 = 单行高，2 = 双行高（动态卡片行内表情放大 2 倍）。 */
  imageSize: number = 1;
  /** 表情标签（如 [doge]）：图加载失败时回退文字，避免行内空白。 */
  imageLabel: string = '';
  /** 话题片段（#话题#）：强调色渲染，点击跳搜索。 */
  isTopic: boolean = false;
}

// 表情拆分结果按动态 id 缓存（内容不可变），避免每次 build 重算 O(内容×表情数) 扫描。
const DYN_PARTS_CACHE_LIMIT: number = 100;
const dynPartsCache: Map<string, Array<DynamicContentPart>> = new Map<string, Array<DynamicContentPart>>();
const DYN_RICH_DETAIL_CACHE_LIMIT: number = 80;
const dynRichDetailCache: Map<string, DynamicItem> = new Map<string, DynamicItem>();
const dynRichDetailInFlight: Map<string, Promise<DynamicItem | null>> =
  new Map<string, Promise<DynamicItem | null>>();

export function cachedDynamicRichDetail(dynId: string): DynamicItem | undefined {
  return dynRichDetailCache.get(dynId);
}

export function ensureDynamicRichDetail(dynId: string): Promise<DynamicItem | null> {
  const cached: DynamicItem | undefined = dynRichDetailCache.get(dynId);
  if (cached !== undefined) return Promise.resolve(cached);
  const running: Promise<DynamicItem | null> | undefined = dynRichDetailInFlight.get(dynId);
  if (running !== undefined) return running;
  const request: Promise<DynamicItem | null> = DynamicApi.getDynamicDetail(dynId).then((detail: DynamicItem | null) => {
    if (detail !== null) {
      if (dynRichDetailCache.size >= DYN_RICH_DETAIL_CACHE_LIMIT) {
        const oldest: IteratorResult<string> = dynRichDetailCache.keys().next();
        if (!oldest.done) dynRichDetailCache.delete(oldest.value);
      }
      dynRichDetailCache.set(dynId, detail);
    }
    return detail;
  }).catch((): DynamicItem | null => null).finally(() => {
    dynRichDetailInFlight.delete(dynId);
  });
  dynRichDetailInFlight.set(dynId, request);
  return request;
}

function splitDynamicText(text: string, emotes: Array<BiliEmote>, keyPrefix: string): Array<DynamicContentPart> {
  const result: Array<DynamicContentPart> = [];
  let rest: string = text;
  let keyIndex: number = 0;
  while (rest.length > 0) {
    let foundAt: number = rest.length;
    let found: BiliEmote | null = null;
    for (let i: number = 0; i < emotes.length; i++) {
      if (emotes[i].text.length === 0) continue;
      const at: number = rest.indexOf(emotes[i].text);
      if (at >= 0 && (at < foundAt || (at === foundAt && found !== null &&
        emotes[i].text.length > found.text.length))) {
        foundAt = at;
        found = emotes[i];
      }
    }
    // 兜底：接口没下发 emoji 节点时（直播预告等），用通用表情表解析 [xxx] 占位符。
    let fallbackUrl: string = '';
    let fallbackToken: string = '';
    if (found === null) {
      // 官方主题表情的名称可能很长（例如活动周年同人表情），16 字限制会把它留成原文。
      const tokenMatch: RegExpExecArray | null = /\[[^\[\]]{1,64}\]/.exec(rest);
      if (tokenMatch !== null) {
        const url: string = EmoteResolver.lookup(tokenMatch[0]);
        if (url.length > 0) {
          foundAt = tokenMatch.index;
          fallbackUrl = url;
          fallbackToken = tokenMatch[0];
        }
      }
    }
    if (found === null && fallbackUrl.length === 0) {
      const part: DynamicContentPart = new DynamicContentPart();
      part.text = rest; part.key = keyPrefix + '-t' + String(keyIndex++); result.push(part); break;
    }
    if (foundAt > 0) {
      const part: DynamicContentPart = new DynamicContentPart();
      part.text = rest.substring(0, foundAt); part.key = keyPrefix + '-t' + String(keyIndex++); result.push(part);
    }
    const emotePart: DynamicContentPart = new DynamicContentPart();
    emotePart.image = found !== null ? found.displayUrl() : fallbackUrl;
    emotePart.imageSize = found !== null ? found.size : 1;
    emotePart.imageLabel = found !== null ? found.text : fallbackToken;
    emotePart.key = keyPrefix + '-e' + String(keyIndex++);
    result.push(emotePart);
    rest = rest.substring(foundAt + (found !== null ? found.text.length : fallbackToken.length));
  }
  return result;
}

export function contentPartsOf(item: DynamicItem, emoteVersion: number): Array<DynamicContentPart> {
  // 同一 dynId 的 feed 简版与 detail 完整版可能拥有不同表情节点，缓存键必须包含节点签名。
  let nodeSignature: string = '';
  for (let i: number = 0; i < item.richNodes.length; i++) {
    const node: DynamicRichNode = item.richNodes[i];
    nodeSignature += '|n' + node.text + '=' + String(node.isTopic) + ':' +
      (node.emote !== null ? node.emote.displayUrl() + ':' + String(node.emote.size) : '');
  }
  for (let i: number = 0; i < item.emotes.length; i++) {
    const emote: BiliEmote = item.emotes[i];
    nodeSignature += '|e' + emote.text + '=' + emote.displayUrl() + ':' + String(emote.size);
  }
  // 版本号纳入缓存键：表情表加载完成后用旧缓存会永远拿不到表情图。
  const cacheKey: string = item.dynId + '|v' + String(emoteVersion) + '|' + item.content + nodeSignature;
  const cached: Array<DynamicContentPart> | undefined = dynPartsCache.get(cacheKey);
  if (cached !== undefined) return cached;
  let result: Array<DynamicContentPart> = [];
  if (item.richNodes.length > 0) {
    for (let i: number = 0; i < item.richNodes.length; i++) {
      const node: DynamicRichNode = item.richNodes[i];
      if (node.emote !== null && node.emote.displayUrl().length > 0) {
        const emotePart: DynamicContentPart = new DynamicContentPart();
        emotePart.image = node.emote.displayUrl();
        emotePart.imageSize = node.emote.size;
        emotePart.imageLabel = node.text;
        emotePart.key = item.dynId + '-node-emote-' + String(i);
        result.push(emotePart);
      } else if (node.text.length > 0) {
        if (node.isTopic) {
          const topicPart: DynamicContentPart = new DynamicContentPart();
          topicPart.text = node.text;
          topicPart.key = item.dynId + '-node-topic-' + String(i);
          topicPart.isTopic = true;
          result.push(topicPart);
        } else {
          result = result.concat(splitDynamicText(node.text, [], item.dynId + '-node-' + String(i)));
        }
      }
    }
  } else {
    result = splitDynamicText(item.content, item.emotes, item.dynId);
  }
  if (dynPartsCache.size >= DYN_PARTS_CACHE_LIMIT) {
    const oldest: IteratorResult<string> = dynPartsCache.keys().next();
    if (!oldest.done) {
      dynPartsCache.delete(oldest.value);
    }
  }
  dynPartsCache.set(cacheKey, result);
  return result;
}
