import { webGet, getData } from './internal/ApiCommon';
import { HttpString } from '../common/Constants';
import { asObject, searchPlainText, str } from '../common/Utils';

export class ArticleDocument {
  title: string = '';
  author: string = '';
  content: string = '';
}

export class ArticleApi {
  static async getArticle(id: number): Promise<ArticleDocument> {
    if (id <= 0) throw new Error('文章参数无效');
    const params: Record<string, string> = { 'id': String(id) };
    const data: Record<string, Object> | null = getData(await webGet(HttpString.apiBaseUrl + '/x/article/view', params));
    if (data === null) throw new Error('文章加载失败，请稍后重试');
    const article: ArticleDocument = new ArticleDocument();
    article.title = searchPlainText(str(data, 'title', ''));
    article.author = searchPlainText(str(asObject(data['author']), 'name', ''));
    article.content = str(data, 'content', '');
    if (article.content.trim().length === 0) throw new Error('此文章暂未提供可阅读正文');
    return article;
  }
}
