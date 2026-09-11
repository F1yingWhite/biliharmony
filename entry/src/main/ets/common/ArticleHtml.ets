import { ArticleDocument } from '../api/ArticleApi';

function escapeArticleText(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/** 正文沿用服务端排版；禁用脚本/表单/嵌入内容，仅加载 HTTPS 图片。 */
export function articleHtml(article: ArticleDocument, dark: boolean): string {
  const bg: string = dark ? '#18191C' : '#FFFFFF';
  const fg: string = dark ? '#E6E6E6' : '#18191C';
  const content: string = article.content.replace(/src="[/][/]/gi, 'src="https://')
    .replace(/src="http:[/][/]/gi, 'src="https://')
    .replace(/<p\b[^>]*>(?:\s|&nbsp;|<br\s*[/]?>|<[/]?(?:span|strong|b|i|em)\b[^>]*>)*<[/]p>/gi, '');
  return '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src https: data:; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'">' +
    '<style>html{background:' + bg + ';color:' + fg + ';color-scheme:' + (dark ? 'dark' : 'light') + '}' +
    'body{margin:0 auto;padding:20px 18px 36px;max-width:760px;font:17px/1.85 sans-serif;overflow-wrap:anywhere}' +
    'h1{font-size:25px;line-height:1.45;margin:0 0 12px}header{margin-bottom:26px}' +
    '.author{color:#9499A0;font-size:14px}p{margin:0 0 1.1em}figure{margin:20px 0}' +
    'img{max-width:100%!important;height:auto!important;object-fit:contain;vertical-align:middle}' +
    'figure img{display:block;margin:auto}figcaption{color:#9499A0;font-size:13px;text-align:center}' +
    'blockquote{border-left:3px solid #9499A0;margin:18px 0;padding-left:14px}' +
    'pre{white-space:pre-wrap}table{display:block;overflow-x:auto;max-width:100%}' +
    'a{color:#E65B87}iframe,object,embed,form,script{display:none!important}' +
    (dark ? 'article,article p,article span,article div{color:inherit!important;background-color:transparent!important}' : '') +
    '</style></head><body><header><h1>' + escapeArticleText(article.title) + '</h1><div class="author">' +
    escapeArticleText(article.author) + '</div></header><article>' + content + '</article></body></html>';
}
