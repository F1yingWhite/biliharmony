import { ReplyItem } from '../../model/Models';
import { parseReplyContent, ReplyRenderPart } from '../../common/ReplyContentParser';

export class ReplyShareRun {
  text: string = '';
  image: string = '';
  imageLabel: string = '';
  imageSize: number = 18;
  linked: boolean = false;
}

export class ReplyShareLine {
  runs: Array<ReplyShareRun> = [];
  width: number = 0;
  height: number = 32;
}

/** Bounds must fit the current window: createFromBuilder clamps its root to that window. */
export class ReplySharePage {
  lines: Array<ReplyShareLine> = [];
  pictures: Array<string> = [];
  height: number = 0;
  width: number = 380;
  pictureSize: number = 104;
  number: number = 1;
  total: number = 1;
}

export const REPLY_SHARE_WIDTH: number = 380;
export const REPLY_SHARE_CONTENT_WIDTH: number = 332;
export const REPLY_SHARE_BRAND: string = '#FB7299';

export type ShareTextMeasure = (text: string, fontSize: number) => number;

/** Keep combining marks, variation selectors, skin tones, flag pairs and ZWJ emoji together at line breaks. */
export function replyShareGraphemes(text: string): Array<string> {
  const result: Array<string> = [];
  let previous: number = -1;
  let regionalCount: number = 0;
  for (let offset: number = 0; offset < text.length;) {
    const code: number = text.codePointAt(offset) ?? 0;
    const glyph: string = String.fromCodePoint(code);
    offset += glyph.length;
    const regional: boolean = code >= 0x1F1E6 && code <= 0x1F1FF;
    const combining: boolean = (code >= 0x0300 && code <= 0x036F) ||
      (code >= 0x1AB0 && code <= 0x1AFF) || (code >= 0x1DC0 && code <= 0x1DFF) ||
      (code >= 0x20D0 && code <= 0x20FF) || (code >= 0xFE00 && code <= 0xFE0F) ||
      (code >= 0xFE20 && code <= 0xFE2F) || (code >= 0x1F3FB && code <= 0x1F3FF) ||
      (code >= 0xE0100 && code <= 0xE01EF);
    const join: boolean = result.length > 0 && (combining || code === 0x200D || previous === 0x200D ||
      (regional && regionalCount % 2 === 1));
    if (join) result[result.length - 1] += glyph;
    else result.push(glyph);
    regionalCount = regional ? regionalCount + 1 : 0;
    previous = code;
  }
  return result;
}

function appendText(line: ReplyShareLine, text: string, linked: boolean): void {
  const previous: ReplyShareRun | undefined = line.runs[line.runs.length - 1];
  if (previous !== undefined && previous.image.length === 0 && previous.linked === linked) {
    previous.text += text;
  } else {
    const run: ReplyShareRun = new ReplyShareRun();
    run.text = text;
    run.linked = linked;
    line.runs.push(run);
  }
}

/** Wrap measured glyphs, preserving every character and inline image instead of applying maxLines. */
export function wrapReplyShareParts(parts: Array<ReplyRenderPart>, measure: ShareTextMeasure,
  imageSources: Map<string, string> = new Map<string, string>(),
  contentWidth: number = REPLY_SHARE_CONTENT_WIDTH): Array<ReplyShareLine> {
  const lines: Array<ReplyShareLine> = [];
  let line: ReplyShareLine = new ReplyShareLine();
  for (let i: number = 0; i < parts.length; i++) {
    const part: ReplyRenderPart = parts[i];
    const resolved: string | undefined = imageSources.get(part.image);
    const missingImage: boolean = part.image.length > 0 && resolved === '';
    if (part.image.length > 0 && !missingImage) {
      const size: number = part.imageSize > 1 ? 30 : 18;
      if (line.width + size > contentWidth && line.runs.length > 0) {
        lines.push(line);
        line = new ReplyShareLine();
      }
      const run: ReplyShareRun = new ReplyShareRun();
      run.image = resolved ?? part.image;
      run.imageLabel = part.imageLabel;
      run.imageSize = size;
      line.runs.push(run);
      line.width += size;
      continue;
    }
    const linked: boolean = part.mentionMid > 0 || part.seekSeconds >= 0 || part.bvid.length > 0 ||
      part.aid > 0 || part.url.length > 0;
    const glyphs: Array<string> = replyShareGraphemes(missingImage ? (part.imageLabel || '[表情]') : part.text);
    for (let glyphIndex: number = 0; glyphIndex < glyphs.length; glyphIndex++) {
      const glyph: string = glyphs[glyphIndex];
      if (glyph === '\n') {
        // Preserve explicit paragraph boundaries, including blank lines.
        appendText(line, '\n', linked);
        lines.push(line);
        line = new ReplyShareLine();
        continue;
      }
      // Small safety margin covers native Span rounding and mixed-font glyph advances.
      const width: number = Math.max(0, measure(glyph, 19)) + 0.3;
      // Keep closing punctuation with the preceding glyph instead of starting the next line with it.
      let followingPunctuationWidth: number = 0;
      for (let next: number = glyphIndex + 1; next < glyphs.length; next++) {
        if (!/^[，。！？；：、）》】〕］｝〉」』〗〙〛”’…,.!?;:%‰)\]}]+$/.test(glyphs[next])) break;
        followingPunctuationWidth += Math.max(0, measure(glyphs[next], 19)) + 0.3;
      }
      if (line.width + width + followingPunctuationWidth > contentWidth - 4 && line.runs.length > 0) {
        lines.push(line);
        line = new ReplyShareLine();
      }
      appendText(line, glyph, linked);
      line.width += width;
    }
  }
  if (line.runs.length > 0) lines.push(line);
  return lines;
}

/** Every page repeats the source and QR. Content and attachments are never discarded. */
export function planReplySharePages(item: ReplyItem, measure: ShareTextMeasure,
  maxHeight: number = 720, imageSources: Map<string, string> = new Map<string, string>(),
  width: number = REPLY_SHARE_WIDTH): Array<ReplySharePage> {
  // Padding 48 + header 50 + body gap 20 + source 104 + footer 114 + page number 20.
  const baseHeight: number = 48 + 50 + 20 + 104 + 114 + 20 +
    (item.upLiked ? 32 : 0);
  const pictureSize: number = (width - 68) / 3;
  if (width < 280 || maxHeight < baseHeight + pictureSize + 16) {
    throw new Error('当前窗口过小，请放大窗口后生成分享图片');
  }
  const limit: number = maxHeight;
  const pages: Array<ReplySharePage> = [];
  let page: ReplySharePage = new ReplySharePage();
  page.height = baseHeight;
  const lines: Array<ReplyShareLine> = wrapReplyShareParts(parseReplyContent(item), measure, imageSources, width - 48);
  for (let i: number = 0; i < lines.length; i++) {
    if (page.height + lines[i].height > limit && page.lines.length > 0) {
      pages.push(page);
      page = new ReplySharePage();
      page.height = baseHeight;
    }
    page.lines.push(lines[i]);
    page.height += lines[i].height;
  }
  // Three fully contained images per row. All attachments continue onto later pages when needed.
  for (let i: number = 0; i < item.pictures.length; i += 3) {
    const rowHeight: number = pictureSize + (page.pictures.length === 0 ? 16 : 6);
    if (page.height + rowHeight > limit && (page.lines.length > 0 || page.pictures.length > 0)) {
      pages.push(page);
      page = new ReplySharePage();
      page.height = baseHeight;
    }
    page.height += pictureSize + (page.pictures.length === 0 ? 16 : 6);
    for (let column: number = i; column < Math.min(i + 3, item.pictures.length); column++) {
      page.pictures.push(item.pictures[column]);
    }
  }
  pages.push(page);
  for (let i: number = 0; i < pages.length; i++) {
    pages[i].number = i + 1;
    pages[i].total = pages.length;
    pages[i].width = width;
    pages[i].pictureSize = pictureSize;
  }
  return pages;
}

/** Resolve emotes before measuring; unavailable images become their original labels with the correct text width. */
export async function resolveReplyShareEmotes(item: ReplyItem,
  resolveImage: (url: string) => Promise<string>): Promise<Map<string, string>> {
  const sources: Map<string, string> = new Map<string, string>();
  const tasks: Array<Promise<void>> = [];
  const parts: Array<ReplyRenderPart> = parseReplyContent(item);
  for (let i: number = 0; i < parts.length; i++) {
    const url: string = parts[i].image;
    if (url.length === 0 || sources.has(url)) continue;
    sources.set(url, '');
    tasks.push(resolveImage(url).then((local: string): void => {
      sources.set(url, local.startsWith('http') ? '' : local);
    }).catch((): void => {}));
  }
  await Promise.all(tasks);
  return sources;
}
