import { BiliEmote, ReplyItem, ReplyJump } from '../model/Models';

/** 评论正文和回复预览共用的富文本片段。 */
export class ReplyRenderPart {
  text: string = '';
  image: string = '';
  imageSize: number = 1;
  seekSeconds: number = -1;
  bvid: string = '';
  aid: number = 0;
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
  const match: RegExpExecArray | null = /BV[0-9A-Za-z]{10}/.exec(value);
  return match === null ? '' : match[0];
}

function aidFrom(value: string): number {
  const match: RegExpExecArray | null = /(?:^|[^A-Za-z])av(\d{1,18})/i.exec(value);
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
  const result: Array<ReplyRenderPart> = [];
  let rest: string = item.content;
  let serial: number = 0;
  while (rest.length > 0) {
    let foundAt: number = rest.length;
    let foundLength: number = 0;
    let foundEmote: BiliEmote | null = null;
    let foundJump: ReplyJump | null = null;
    let foundToken: string = '';

    for (let i: number = 0; i < item.emotes.length; i++) {
      const at: number = rest.indexOf(item.emotes[i].text);
      if (at >= 0 && at < foundAt) {
        foundAt = at;
        foundLength = item.emotes[i].text.length;
        foundEmote = item.emotes[i];
        foundJump = null;
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
        foundToken = '';
      }
    }
    const actionMatch: RegExpExecArray | null = /(BV[0-9A-Za-z]{10}|(?:^|\s|[（(【\[])(?:\d{1,2}:)?[0-5]?\d:[0-5]\d|(?:^|[^A-Za-z])av\d{1,18})/i.exec(rest);
    if (actionMatch !== null) {
      const leading: string = actionMatch[0];
      const trimmed: string = leading.trim().replace(/^[（(【\[]/, '');
      const tokenAt: number = actionMatch.index + leading.indexOf(trimmed);
      if (tokenAt < foundAt) {
        foundAt = tokenAt;
        foundLength = trimmed.length;
        foundEmote = null;
        foundJump = null;
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
      part.image = foundEmote.url;
      part.imageSize = foundEmote.size;
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
  return result;
}
