import { KeywordHighlight, KeywordPart } from '../common/KeywordHighlight';

export interface KeywordSpansParam {
  text: string;
  keyword: string;
  isDark: boolean;
}

/** Text 内的局部强调；按引用接收数据，让复用卡片的标题与封面同步更新。普通片段继承外层样式。深色模式用亮色维持对比度。 */
@Builder
export function KeywordSpans($$: KeywordSpansParam) {
  ForEach(KeywordHighlight.split($$.text, $$.keyword), (part: KeywordPart) => {
    if (part.matched) {
      Span(part.text).fontWeight(FontWeight.Bold).fontColor($$.isDark ? '#FFFFFF' : '#000000')
    } else {
      Span(part.text)
    }
  }, (part: KeywordPart, index: number) => String(index) + ':' + String(part.matched) + ':' + part.text)
}
