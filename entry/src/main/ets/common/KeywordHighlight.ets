export class KeywordPart {
  text: string;
  matched: boolean;
  constructor(text: string, matched: boolean) {
    this.text = text;
    this.matched = matched;
  }
}

/** 按字面匹配，不将用户输入解释为正则或 HTML，保留原文及全部重复匹配。 */
export class KeywordHighlight {
  static split(text: string, keyword: string): Array<KeywordPart> {
    const query: string = keyword.trim();
    if (query.length === 0) return [new KeywordPart(text, false)];
    const parts: Array<KeywordPart> = [];
    let cursor: number = 0;
    let found: number = text.indexOf(query, cursor);
    while (found >= 0) {
      if (found > cursor) parts.push(new KeywordPart(text.slice(cursor, found), false));
      parts.push(new KeywordPart(text.slice(found, found + query.length), true));
      cursor = found + query.length;
      found = text.indexOf(query, cursor);
    }
    if (cursor < text.length || parts.length === 0) parts.push(new KeywordPart(text.slice(cursor), false));
    return parts;
  }
}
