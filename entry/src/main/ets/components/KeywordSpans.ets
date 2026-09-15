import { KeywordHighlight, KeywordPart } from '../common/KeywordHighlight';

/** Text 内的局部强调；普通片段继承外层字号、颜色和字重。深色模式用亮色维持对比度。 */
@Builder
export function KeywordSpans(text: string, keyword: string, isDark: boolean) {
  ForEach(KeywordHighlight.split(text, keyword), (part: KeywordPart) => {
    if (part.matched) {
      Span(part.text).fontWeight(FontWeight.Bold).fontColor(isDark ? '#FFFFFF' : '#000000')
    } else {
      Span(part.text)
    }
  }, (part: KeywordPart, index: number) => String(index) + ':' + String(part.matched) + ':' + part.text)
}
