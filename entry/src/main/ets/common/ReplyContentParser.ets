import { BiliEmote, ReplyItem, ReplyJump, ReplyMention } from '../model/Models';

// 模块级正则与结果缓存：列表重渲染会反复解析同一条评论，避免重复建正则与重复解析
const BVID_REGEX: RegExp = /BV[0-9A-Za-z]{10}/;
// 整条视频链接（含协议与域名前缀）作为一个片段：拆成“白字前缀+蓝 BV”两半时，
// Flex/Text 会在两片之间换行，出现上半行白下半行蓝的断裂感。
const VIDEO_URL_REGEX: RegExp = /https?:\/\/(?:www\.)?bilibili\.com\/video\/(?:BV[0-9A-Za-z]{10}|av\d{1,18})\/?/i;
const AID_REGEX: RegExp = /(?:^|[^A-Za-z])av(\d{1,18})/i;
const ACTION_REGEX: RegExp = /(BV[0-9A-Za-z]{10}|(?:^|\s|[（(【\[])(?:\d{1,2}:)?[0-5]?\d:[0-5]\d|(?:^|[^A-Za-z])av\d{1,18})/i;
const LEADING_BRACKET_REGEX: RegExp = /^[（(【\[]/;
const PARSE_CACHE_MAX: number = 300;
const PARSE_CACHE_TRIM: number = 60;
const parseCache: Map<string, Array<ReplyRenderPart>> = new Map<string, Array<ReplyRenderPart>>();

/** 评论正文和回复预览共用的富文本片段。 */
export class ReplyRenderPart {
  text: string = '';
  image: string = '';
  /** 表情原标签（如 [doge]）：图片加载失败时回退成文字，避免留下固定尺寸的空白块。 */
  imageLabel: string = '';
  imageSize: number = 1;
  seekSeconds: number = -1;
  bvid: string = '';
  aid: number = 0;
  mentionMid: number = 0;
  key: string = '';
}

function parseClock(value: string): number {
  const pieces: Array<string> = value.split(':');
  if (pieces.length < 2 || pieces.length > 3) return -1;
  let seconds: number = 0;
  for (let i: number = 0; i < pieces.length; i++) {
    const part: number = Number(pieces[i]);
    if (!Number.isFinite(part) || part < 0) return -1;
    seconds = seconds * 60 + part;
  }
  return seconds;
}

function bvidFrom(value: string): string {
  const match: RegExpExecArray | null = BVID_REGEX.exec(value);
  return match === null ? '' : match[0];
}

function aidFrom(value: string): number {
  const match: RegExpExecArray | null = AID_REGEX.exec(value);
  return match === null ? 0 : Number(match[1]);
}

function pushText(result: Array<ReplyRenderPart>, item: ReplyItem, text: string, index: number): void {
  if (text.length === 0) return;
  const part: ReplyRenderPart = new ReplyRenderPart();
  part.text = text;
  part.key = String(item.rpid) + '-text-' + String(index);
  result.push(part);
}

/**
 * 把正文统一拆成文本、表情、BV/av 跳转和时间空降片段。
 * 主评论与未展开的回复预览必须调用同一个解析器，避免功能再次分叉。
 */
export function parseReplyContent(item: ReplyItem): Array<ReplyRenderPart> {
  // key 含 rpid：不同评论正文可能相同，而片段 key 取自 rpid，混在一起会拿到错误的渲染 key
  let mentionSignature: string = '';
  for (let i: number = 0; i < item.mentions.length; i++) {
    mentionSignature += '|' + item.mentions[i].label + ':' + String(item.mentions[i].mid);
  }
  // 表情签名必须进缓存 key：精简上下文（无 content.emote）解析过的同 rpid+正文
  // 结果若被全量数据复用，表情图会缺失。
  let emoteSignature: string = '';
  for (let i: number = 0; i < item.emotes.length; i++) {
    emoteSignature += '|' + item.emotes[i].text;
  }
  const cacheKey: string = String(item.rpid) + '\n' + item.content + mentionSignature + emoteSignature;
  const cached: Array<ReplyRenderPart> | undefined = parseCache.get(cacheKey);
  if (cached !== undefined) {
    return cached.slice();
  }
  const result: Array<ReplyRenderPart> = [];
  let rest: string = item.content;
  let serial: number = 0;
  while (rest.length > 0) {
    let foundAt: number = rest.length;
    let foundLength: number = 0;
    let foundEmote: BiliEmote | null = null;
    let foundJump: ReplyJump | null = null;
    let foundMention: ReplyMention | null = null;
    let foundToken: string = '';

    for (let i: number = 0; i < item.emotes.length; i++) {
      const at: number = rest.indexOf(item.emotes[i].text);
      if (at >= 0 && at < foundAt) {
        foundAt = at;
        foundLength = item.emotes[i].text.length;
        foundEmote = item.emotes[i];
        foundJump = null;
        foundMention = null;
        foundToken = '';
      }
    }
    for (let i: number = 0; i < item.jumps.length; i++) {
      const videoId: string = bvidFrom(item.jumps[i].url);
      const aid: number = aidFrom(item.jumps[i].url);
      if (videoId.length === 0 && aid <= 0) continue;
      const at: number = rest.indexOf(item.jumps[i].label);
      if (at >= 0 && at < foundAt) {
        foundAt = at;
        foundLength = item.jumps[i].label.length;
        foundEmote = null;
        foundJump = item.jumps[i];
        foundMention = null;
        foundToken = '';
      }
    }
    for (let i: number = 0; i < item.mentions.length; i++) {
      const at: number = rest.indexOf(item.mentions[i].label);
      if (at >= 0 && at < foundAt) {
        foundAt = at;
        foundLength = item.mentions[i].label.length;
        foundEmote = null;
        foundJump = null;
        foundMention = item.mentions[i];
        foundToken = '';
      }
    }
    const urlMatch: RegExpExecArray | null = VIDEO_URL_REGEX.exec(rest);
    if (urlMatch !== null && urlMatch.index < foundAt) {
      foundAt = urlMatch.index;
      foundLength = urlMatch[0].length;
      foundEmote = null;
      foundJump = null;
      foundMention = null;
      foundToken = urlMatch[0];
    }
    const actionMatch: RegExpExecArray | null = ACTION_REGEX.exec(rest);
    if (actionMatch !== null) {
      const leading: string = actionMatch[0];
      const trimmed: string = leading.trim().replace(LEADING_BRACKET_REGEX, '');
      const tokenAt: number = actionMatch.index + leading.indexOf(trimmed);
      if (tokenAt < foundAt) {
        foundAt = tokenAt;
        foundLength = trimmed.length;
        foundEmote = null;
        foundJump = null;
        foundMention = null;
        foundToken = trimmed;
      }
    }

    if (foundLength <= 0 || foundAt >= rest.length) {
      pushText(result, item, rest, serial++);
      break;
    }
    pushText(result, item, rest.substring(0, foundAt), serial++);
    const part: ReplyRenderPart = new ReplyRenderPart();
    part.key = String(item.rpid) + '-action-' + String(serial++);
    if (foundEmote !== null) {
      // 有动态图用 GIF（Image 自动播放），否则静态图；大小按 1/2 行高传递。
      part.image = foundEmote.displayUrl();
      part.imageLabel = foundEmote.text;
      part.imageSize = foundEmote.size;
    } else if (foundMention !== null) {
      part.text = foundMention.label;
      part.mentionMid = foundMention.mid;
      // 接口正文常见“@用户名 : 内容”。如果冒号继续作为下一个 Text 片段，
      // Flex 在窄屏会把冒号单独换到下一行；将它连同周边空格一起消费并绑定到 @。
      const mentionTail: string = rest.substring(foundAt + foundLength);
      const colonMatch: RegExpExecArray | null = /^\s*([:：])\s*/.exec(mentionTail);
      if (colonMatch !== null) {
        part.text += colonMatch[1];
        foundLength += colonMatch[0].length;
      }
    } else {
      part.text = foundJump !== null ? foundJump.label : foundToken;
      const target: string = foundJump !== null ? foundJump.url : foundToken;
      part.bvid = bvidFrom(target);
      part.aid = aidFrom(target);
      if (part.bvid.length === 0 && part.aid <= 0) part.seekSeconds = parseClock(foundToken);
    }
    result.push(part);
    rest = rest.substring(foundAt + foundLength);
  }
  if (parseCache.size >= PARSE_CACHE_MAX) {
    // Map 迭代序即插入序：超限删除最老的一批
    const keys: Array<string> = Array.from(parseCache.keys());
    const removeCount: number = Math.min(PARSE_CACHE_TRIM, keys.length);
    for (let i: number = 0; i < removeCount; i++) {
      parseCache.delete(keys[i]);
    }
  }
  parseCache.set(cacheKey, result);
  // 返回拷贝：调用方直接拿到的数组不进缓存，缓存副本不被外部修改污染
  return result.slice();
}
